// ============================================================
//  fishtweakd —— 常驻 daemon（v3.2）
//  职责：仅服务本机游戏《捕鱼大决战》(com.gzlj.fishdecisive)
//  1) 监听 127.0.0.1:8888（本地回环，只服务按键精灵）
//  2) /set_account 收号 → 写参数文件 → (可选)自动拉起游戏
//  3) /launch       拉起游戏
//  4) /status       返回缓存/待注入状态（读游戏内 tweak 写盘的状态文件）
//  5) /send_sms /reset_password  老功能（原插件内实现，迁到本进程）
//  资源：单 accept 线程 + 短连接同步处理，无轮询无后台任务，ARC 无泄漏
// ============================================================
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonCrypto.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>
#include <errno.h>
#include <mach/mach.h>
#include <dispatch/dispatch.h>

// ---- 固定路径（tweak 与 daemon 共用约定）----
static NSString *const kAccountFile = @"/var/mobile/Library/Preferences/com.jeffrey.fishtweak.account.plist";   // daemon 写 / tweak 读
static NSString *const kStatusFile  = @"/var/mobile/Library/Preferences/com.jeffrey.fishtweak.status.plist";    // tweak 写 / daemon 读
static NSString *const kLogFile     = @"/var/mobile/Library/Preferences/com.jeffrey.fishtweakd.log";            // daemon 运行日志
static NSString *const kGameBundleId = @"com.gzlj.fishdecisive";

// ---- 文件日志（老 iOS 无 log 命令，syslog 不可靠；写文件最稳）----
static void fishlog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogFile];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:kLogFile contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:kLogFile];
    }
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
    NSLog(@"%@", msg);
}

// ---- 游戏 API 常量（原插件迁入）----
static NSString *const kAPIHost = @"https://openapi.buyuios.com";
static NSString *const kPackageNo = @"10011001001";
static const int kLocalPort = 8888;
static NSString *const kKeyHex = @"5a6531514c55466a3239365441686f32576963364f4e33704f6572727a516f31";
static NSString *const kIvHex  = @"5a6531514c55466a3239365441686f32";

// ============================================================
//  定位游戏主程序（只匹配本游戏 bundle id）
// ============================================================
static NSString *findGameBinaryPath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *top = [fm contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application" error:NULL];
    for (NSString *d in top) {
        NSString *appRoot = [@"/var/containers/Bundle/Application" stringByAppendingPathComponent:d];
        NSArray *items = [fm contentsOfDirectoryAtPath:appRoot error:NULL];
        for (NSString *it in items) {
            if (![it hasSuffix:@".app"]) continue;
            NSString *appDir = [appRoot stringByAppendingPathComponent:it];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                                  [appDir stringByAppendingPathComponent:@"Info.plist"]];
            if ([info[@"CFBundleIdentifier"] isEqualToString:kGameBundleId]) {
                NSString *exec = info[@"CFBundleExecutable"];
                if (!exec || exec.length == 0) exec = @"Fuel5";
                return [appDir stringByAppendingPathComponent:exec];
            }
        }
    }
    return nil;
}

// ============================================================
//  私有 API 动态调用辅助（NSInvocation，避免 ARC performSelector 警告）
// ============================================================
static id invoke0(id target, NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig) return nil;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = target;
    inv.selector = sel;
    [inv invoke];
    __unsafe_unretained id ret = nil;
    if (sig.methodReturnLength > 0) [inv getReturnValue:&ret];
    return ret;
}
static id invoke1(id target, NSString *selName, id arg) {
    SEL sel = NSSelectorFromString(selName);
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig) return nil;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = target;
    inv.selector = sel;
    [inv setArgument:&arg atIndex:2];
    [inv invoke];
    __unsafe_unretained id ret = nil;
    if (sig.methodReturnLength > 0) [inv getReturnValue:&ret];
    return ret;
}

// ============================================================
//  定位游戏数据容器（/var/mobile/Containers/Data/Application/<uuid>）
//  通过 .com.apple.mobile_container_manager.metadata.plist 匹配 bundle id
// ============================================================
static NSString *findDataContainer(NSString *bundleId) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *top = [fm contentsOfDirectoryAtPath:@"/var/mobile/Containers/Data/Application" error:NULL];
    for (NSString *d in top) {
        NSString *dir = [@"/var/mobile/Containers/Data/Application" stringByAppendingPathComponent:d];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:
                              [dir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
        if ([meta[@"MCMMetadataIdentifier"] isEqualToString:bundleId]) return dir;
    }
    return nil;
}

// ============================================================
//  拉起游戏
//  首选 FBSOpenApplicationService（SpringBoard 标准拉起通道，带错误回调）；
//  FBS 失败/超时 → 回退 posix_spawn（带完整容器环境变量，避免黑屏/闪退）
//  全步骤写文件日志 kLogFile（SSH: cat /var/mobile/Library/Preferences/com.jeffrey.fishtweakd.log）
// ============================================================
static void launchGame(void) {
    fishlog(@"[launchGame] 开始拉起 %@", kGameBundleId);
    NSString *exe = findGameBinaryPath();
    fishlog(@"[launchGame] findGameBinaryPath -> %@", exe ?: @"nil");
    BOOL started = NO;
    @try {
        Class svcClass = NSClassFromString(@"FBSOpenApplicationService");
        Class infoClass = NSClassFromString(@"FBSApplicationInfo");
        Class handleClass = NSClassFromString(@"FBSProcessHandle");
        fishlog(@"[launchGame] FBS 类可用: svc=%d info=%d handle=%d", svcClass != nil, infoClass != nil, handleClass != nil);
        if (svcClass && infoClass && handleClass) {
            id svc = invoke0(svcClass, @"serviceWithDefaultShellEndpoint");
            id appInfo = invoke1(infoClass, @"applicationInfoWithBundleIdentifier:", kGameBundleId);
            id handle = invoke1(handleClass, @"processHandleForApplication:", appInfo);
            id options = invoke0(NSClassFromString(@"FBSOpenApplicationOptions"), @"optionsWithDefaultValues");
            fishlog(@"[launchGame] FBS 对象: svc=%d appInfo=%d handle=%d options=%d", svc != nil, appInfo != nil, handle != nil, options != nil);
            if (svc && appInfo && handle) {
                SEL sel = NSSelectorFromString(@"openApplication:withOptions:completion:");
                NSMethodSignature *sig = [svc methodSignatureForSelector:sel];
                if (sig) {
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    inv.target = svc;
                    inv.selector = sel;
                    [inv setArgument:&handle atIndex:2];
                    [inv setArgument:&options atIndex:3];
                    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                    __block NSError *fbsErr = nil;
                    void (^completion)(BOOL, NSError *) = ^(BOOL success, NSError *error) {
                        fbsErr = error;
                        fishlog(@"[launchGame] FBS completion: success=%d error=%@", success, error);
                        dispatch_semaphore_signal(sem);
                    };
                    [inv setArgument:&completion atIndex:4];
                    [inv invoke];
                    fishlog(@"[launchGame] FBS openApplication 已调用，等待回调(≤3s)...");
                    long r = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
                    fishlog(@"[launchGame] FBS 等待结束 r=%ld error=%@", r, fbsErr);
                    if (r == 0 && !fbsErr) started = YES;
                } else {
                    fishlog(@"[launchGame] FBS 无 openApplication:withOptions:completion: 方法");
                }
            }
        } else {
            fishlog(@"[launchGame] FBS 类不可用，走 posix_spawn");
        }
    } @catch (NSException *e) {
        fishlog(@"[launchGame] FBS 拉起异常: %@", e);
    }
    if (started) {
        fishlog(@"[launchGame] FBS 拉起成功，返回");
        return;
    }

    // ---- 通道2：LSApplicationWorkspace（iOS 4+ 通用，LaunchServices 正式拉起通道）----
    @try {
        Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
        if (wsClass) {
            id ws = invoke0(wsClass, @"defaultWorkspace");
            if (!ws) ws = [[wsClass alloc] init];
            SEL sel = NSSelectorFromString(@"openApplicationWithBundleID:");
            NSMethodSignature *sig = [ws methodSignatureForSelector:sel];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = ws;
                inv.selector = sel;
                NSString *bid = kGameBundleId;
                [inv setArgument:&bid atIndex:2];
                [inv invoke];
                BOOL ok = NO;
                if (sig.methodReturnLength == sizeof(BOOL)) {
                    [inv getReturnValue:&ok];
                }
                fishlog(@"[launchGame] LSApplicationWorkspace openApplicationWithBundleID -> %d", ok);
                if (ok) started = YES;
            } else {
                fishlog(@"[launchGame] LSApplicationWorkspace 无 openApplicationWithBundleID:");
            }
        } else {
            fishlog(@"[launchGame] LSApplicationWorkspace 类不可用");
        }
    } @catch (NSException *e) {
        fishlog(@"[launchGame] LSApplicationWorkspace 异常: %@", e);
    }
    if (started) {
        fishlog(@"[launchGame] LSApplicationWorkspace 拉起成功，返回");
        return;
    }

    // ---- 通道3：FBSSystemService（iOS 8-10 专用）----
    @try {
        Class fbss = NSClassFromString(@"FBSSystemService");
        if (fbss) {
            id sysSvc = [[fbss alloc] init];
            if (!sysSvc) sysSvc = invoke0(fbss, @"sharedService");
            SEL sel = NSSelectorFromString(@"openApplication:options:clientPort:withResult:");
            NSMethodSignature *sig = [sysSvc methodSignatureForSelector:sel];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = sysSvc;
                inv.selector = sel;
                NSString *bid = kGameBundleId;
                [inv setArgument:&bid atIndex:2];
                NSDictionary *options = @{};
                [inv setArgument:&options atIndex:3];
                uint32_t port = MACH_PORT_NULL;
                [inv setArgument:&port atIndex:4];
                id resultBlock = nil;
                [inv setArgument:&resultBlock atIndex:5];
                [inv invoke];
                fishlog(@"[launchGame] FBSSystemService openApplication 已调用（假定成功）");
                started = YES;
            } else {
                fishlog(@"[launchGame] FBSSystemService 无 openApplication:options:clientPort:withResult:");
            }
        } else {
            fishlog(@"[launchGame] FBSSystemService 类不可用");
        }
    } @catch (NSException *e) {
        fishlog(@"[launchGame] FBSSystemService 异常: %@", e);
    }
    if (started) {
        fishlog(@"[launchGame] FBSSystemService 通道执行完毕，返回");
        return;
    }

    // ---- 兜底：posix_spawn（完整容器环境）----
    if (!exe) { fishlog(@"[launchGame] 未找到游戏二进制，放弃"); return; }
    NSString *container = findDataContainer(kGameBundleId);
    fishlog(@"[launchGame] data 容器: %@", container ?: @"未找到");
    pid_t pid = 0;
    char *argv[] = {(char *)[exe UTF8String], NULL};
    char envTmp[1024], envBundle[1024];
    char *envp[8];
    int ei = 0;
    envp[ei++] = (char *)"HOME=/var/mobile";
    envp[ei++] = (char *)"CFFIXED_USER_HOME=/var/mobile";
    if (container) {
        snprintf(envTmp, sizeof(envTmp), "TMPDIR=%s/tmp", [container UTF8String]);
        snprintf(envBundle, sizeof(envBundle), "BUNDLE_CONTAINER=%s", [container UTF8String]);
        envp[ei++] = envTmp;
        envp[ei++] = envBundle;
    }
    envp[ei++] = (char *)"XPC_SERVICE_NAME=0";
    envp[ei] = NULL;
    int rc = posix_spawn(&pid, [exe UTF8String], NULL, NULL, argv, envp);
    fishlog(@"[launchGame] posix_spawn rc=%d pid=%d (%s)", rc, (int)pid, rc == 0 ? "OK" : strerror(rc));
    if (rc == 0) {
        usleep(1000 * 1000);   // 等 1s 看进程是否存活（缺环境会立即退出）
        int st = 0;
        pid_t r2 = waitpid(pid, &st, WNOHANG);
        fishlog(@"[launchGame] 1s 后 waitpid=%d status=%d (0=进程仍在运行)", (int)r2, st);
    }
}

// ============================================================
//  收号落盘（写参数文件，0644 保证游戏进程 mobile 可读）
// ============================================================
static NSString *strParam(NSDictionary *p, NSString *key) {
    id v = p[key];
    if (!v || [v isKindOfClass:[NSNull class]]) return @"";
    if ([v isKindOfClass:[NSString class]]) return v;
    return [v stringValue];
}
static void saveAccount(NSDictionary *params) {
    NSMutableDictionary *acct = [NSMutableDictionary dictionaryWithCapacity:8];
    acct[@"appid"]    = strParam(params, @"appid");
    acct[@"openid"]   = strParam(params, @"openid");
    acct[@"refresh"]  = strParam(params, @"refresh");
    acct[@"token"]    = strParam(params, @"token");
    acct[@"nickname"] = strParam(params, @"nickname");
    acct[@"account"]  = strParam(params, @"account");
    acct[@"phone"]    = strParam(params, @"phone");
    acct[@"password"] = strParam(params, @"password");
    BOOL ok = [acct writeToFile:kAccountFile atomically:YES];
    chmod([kAccountFile UTF8String], 0644);
    NSLog(@"[FishTweakD] 账号参数已保存 openid=%@ ok=%d", acct[@"openid"], ok);
}

// ============================================================
//  本地 HTTP 服务（原插件实现迁入，短连接同步处理）
// ============================================================
static NSString *buildUserAgent(void) {
    return @"Fuel5/2.13.1 (iPhone; iOS 13.1.2; Scale/3.00)";
}

static NSData *hexToData(NSString *hex) {
    NSMutableData *d = [NSMutableData data];
    for (NSUInteger i = 0; i + 2 <= hex.length; i += 2) {
        unsigned int byte;
        [[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(i, 2)]] scanHexInt:&byte];
        [d appendBytes:&byte length:1];
    }
    return d;
}

static NSString *generateDid(NSString *uuid, NSString *timestamp) {
    NSData *key = hexToData(kKeyHex);
    NSData *iv = hexToData(kIvHex);
    NSString *plain = [NSString stringWithFormat:@"AES:%@:%@", uuid, timestamp];
    NSData *plainData = [plain dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *padded = [NSMutableData dataWithData:plainData];
    NSUInteger padLen = 16 - (plainData.length % 16);
    if (padLen == 0) padLen = 16;
    uint8_t padByte = (uint8_t)padLen;
    for (int i = 0; i < padLen; i++) [padded appendBytes:&padByte length:1];
    NSMutableData *result = [NSMutableData dataWithLength:padded.length];
    size_t outLen = 0;
    CCCrypt(kCCEncrypt, kCCAlgorithmAES, 0, key.bytes, key.length, iv.bytes,
            padded.bytes, padded.length, result.mutableBytes, result.length, &outLen);
    result.length = outLen;
    return [result base64EncodedStringWithOptions:0];
}

static NSString *calculateSign(NSString *did, NSString *mobile, NSString *sesskey, NSString *type) {
    NSData *key = hexToData(kKeyHex);
    NSString *str = [NSString stringWithFormat:@"did=%@&mobile=%@&packageNo=%@&sesskey=%@&smsProvider=0&type=%@",
                     did, mobile, kPackageNo, sesskey, type];
    NSData *sdata = [str dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *hash = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, sdata.bytes, sdata.length, hash.mutableBytes);
    NSMutableString *hex = [NSMutableString string];
    for (NSUInteger i = 0; i < hash.length; i++) [hex appendFormat:@"%02x", ((uint8_t *)hash.bytes)[i]];
    return hex;
}

static NSString *sesskeyForMobile(NSString *mobile) {
    long long num = mobile.longLongValue;
    long long result = ((num * 137) % 90000) + 10000;
    return [NSString stringWithFormat:@"%lld", result];
}

static NSString *md5Password(NSString *plainPwd) {
    const char *cstr = [plainPwd UTF8String];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(cstr, (CC_LONG)strlen(cstr), digest);
    NSMutableString *hex = [NSMutableString string];
    for (int i = 0; i < 16; i++) [hex appendFormat:@"%02X", digest[i]];
    return [hex substringWithRange:NSMakeRange(8, 16)];
}

static void sendGameRequest(NSString *path, NSDictionary *bodyDict, void (^callback)(NSDictionary *response)) {
    NSString *url = [NSString stringWithFormat:@"%@%@?api-version=1", kAPIHost, path];
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:bodyDict options:0 error:nil];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:buildUserAgent() forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"*/*" forHTTPHeaderField:@"Accept"];
    [req setHTTPBody:bodyData];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { callback(@{@"error": error.localizedDescription}); return; }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        callback(json ?: @{@"raw": [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]});
    }];
    [task resume];
}

static void sendHttp(int clientSocket, NSDictionary *json) {
    NSData *body = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    NSString *response = [NSString stringWithFormat:
        @"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n%@",
        (unsigned long)body.length,
        [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding]];
    send(clientSocket, response.UTF8String, strlen(response.UTF8String), 0);
    close(clientSocket);
}

static void handleRequest(int clientSocket, NSString *request) {
    NSArray *lines = [request componentsSeparatedByString:@"\r\n"];
    if (lines.count == 0) return;
    NSArray *parts = [lines.firstObject componentsSeparatedByString:@" "];
    if (parts.count < 2) return;
    NSString *path = parts[1];
    NSURLComponents *components = [NSURLComponents componentsWithString:[NSString stringWithFormat:@"http://localhost%@", path]];
    NSString *reqPath = components.path;
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in components.queryItems) {
        params[item.name] = item.value;
    }
    // POST JSON body 合并（body 键值优先，兼容 URL 长参数传不全的场景）
    NSRange hdrEnd = [request rangeOfString:@"\r\n\r\n"];
    if (hdrEnd.location != NSNotFound) {
        NSString *body = [request substringFromIndex:hdrEnd.location + 4];
        if (body.length > 0) {
            NSData *bd = [body dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:bd options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) {
                for (NSString *k in json) params[k] = json[k];
            }
        }
    }

    if ([reqPath isEqualToString:@"/send_sms"]) {
        NSString *mobile = params[@"mobile"];
        NSString *uuid = params[@"uuid"];
        if (!mobile || !uuid) { sendHttp(clientSocket, @{@"error": @"missing mobile/uuid"}); return; }
        NSString *ts = [NSString stringWithFormat:@"%lld", (long long)[[NSDate date] timeIntervalSince1970]];
        NSString *sesskey = sesskeyForMobile(mobile);
        NSString *did = generateDid(uuid, ts);
        NSString *sign = calculateSign(did, mobile, sesskey, @"2");
        NSDictionary *body = @{
            @"mobile": mobile, @"sesskey": sesskey, @"did": did,
            @"smsProvider": @0, @"type": @2, @"sign": sign, @"packageNo": kPackageNo
        };
        NSLog(@"[FishTweakD] 发送短信 mobile=%@", mobile);
        sendGameRequest(@"/openplatformplayercenter/api/VerifyCode/sms", body, ^(NSDictionary *resp) {
            sendHttp(clientSocket, resp);
        });

    } else if ([reqPath isEqualToString:@"/reset_password"]) {
        NSString *mobile = params[@"mobile"];
        NSString *code = params[@"code"];
        NSString *password = params[@"password"];
        NSString *uuid = params[@"uuid"];
        if (!mobile || !code || !password || !uuid) {
            sendHttp(clientSocket, @{@"error": @"missing params"});
            return;
        }
        NSString *pwd16 = md5Password(password);
        NSString *sesskey = sesskeyForMobile(mobile);
        NSDictionary *body = @{
            @"code": code, @"deviceNumber": uuid, @"sessKey": sesskey,
            @"mobile": mobile, @"password": pwd16, @"packageNo": kPackageNo
        };
        NSLog(@"[FishTweakD] 重置密码 mobile=%@", mobile);
        sendGameRequest(@"/openplatformplayercenter/api/Player/ResetPassword", body, ^(NSDictionary *resp) {
            sendHttp(clientSocket, resp);
        });

    } else if ([reqPath isEqualToString:@"/status"]) {
        NSDictionary *statusFile = [NSDictionary dictionaryWithContentsOfFile:kStatusFile] ?: @{};
        BOOL hasPending = [[NSFileManager defaultManager] fileExistsAtPath:kAccountFile];
        NSDictionary *status = @{
            @"plugin": @"fishtweakd",
            @"version": @"3.2.0",
            @"daemon": @"alive",
            @"cache": @{
                @"has_cache": statusFile[@"has_cache"] ?: @NO,
                @"cache_openid": statusFile[@"cache_openid"] ?: @"",
                @"pending_account": @(hasPending)
            }
        };
        sendHttp(clientSocket, status);

    } else if ([reqPath isEqualToString:@"/set_account"]) {
        NSString *openid = params[@"openid"];
        NSString *refresh = params[@"refresh"];
        if (!openid || openid.length == 0 || !refresh || refresh.length == 0) {
            sendHttp(clientSocket, @{@"error": @"missing openid/refresh",
                                     @"need": @[@"appid", @"openid", @"refresh", @"token",
                                                @"nickname", @"account", @"phone", @"password", @"launch"]});
            return;
        }
        saveAccount(params);
        fishlog(@"[set_account] 收号 appid=%@ openid=%@ launch=%@", params[@"appid"] ?: @"", params[@"openid"] ?: @"", params[@"launch"] ?: @"1");
        BOOL doLaunch = YES;
        id launchVal = params[@"launch"];
        if (launchVal) {
            NSString *ls = [launchVal isKindOfClass:[NSString class]] ? launchVal : [launchVal stringValue];
            if ([ls isEqualToString:@"0"]) doLaunch = NO;
        }
        if (doLaunch) launchGame();
        sendHttp(clientSocket, @{@"ok": @1, @"saved": openid, @"launch": @(doLaunch)});

    } else if ([reqPath isEqualToString:@"/launch"]) {
        launchGame();
        sendHttp(clientSocket, @{@"ok": @1, @"launch": @"sent"});

    } else {
        sendHttp(clientSocket, @{
            @"endpoints": @[@"/send_sms?mobile=X&uuid=Y",
                            @"/reset_password?mobile=X&code=Y&password=Z&uuid=Y",
                            @"/status",
                            @"/set_account?appid=X&openid=Y&refresh=Z&token=T&nickname=N&account=A&phone=P&password=M&launch=1",
                            @"/launch"]
        });
    }
}

static void *httpThread(void *arg) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    int yes = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    addr.sin_port = htons(kLocalPort);
    if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        NSLog(@"[FishTweakD] bind 8888 失败: %s", strerror(errno));
        return NULL;
    }
    listen(s, 10);
    NSLog(@"[FishTweakD] 监听 127.0.0.1:%d 就绪", kLocalPort);
    while (1) {
        int client = accept(s, NULL, NULL);
        if (client < 0) break;
        char buffer[16384];
        ssize_t total = 0;
        while (total < (ssize_t)sizeof(buffer) - 1) {
            ssize_t n = recv(client, buffer + total, sizeof(buffer) - 1 - total, 0);
            if (n <= 0) break;
            total += n;
            buffer[total] = '\0';
            // 判断 header 是否完整，再按 Content-Length 等 body
            NSString *soFar = [NSString stringWithUTF8String:buffer];
            NSRange hdrEnd = [soFar rangeOfString:@"\r\n\r\n"];
            if (hdrEnd.location == NSNotFound) continue;
            NSInteger contentLength = 0;
            NSArray *hdrLines = [[soFar substringToIndex:hdrEnd.location] componentsSeparatedByString:@"\r\n"];
            for (NSString *hl in hdrLines) {
                if ([[hl lowercaseString] hasPrefix:@"content-length:"]) {
                    contentLength = [[hl substringFromIndex:15] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].integerValue;
                    break;
                }
            }
            if (total >= (ssize_t)(hdrEnd.location + 4 + contentLength)) break;
        }
        if (total > 0) {
            buffer[total] = '\0';
            NSString *request = [NSString stringWithUTF8String:buffer];
            handleRequest(client, request);
        }
        close(client);
    }
    return NULL;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSLog(@"[FishTweakD] 常驻 daemon 启动 v3.2.0");
        pthread_t tid;
        pthread_create(&tid, NULL, httpThread, NULL);
        // 主线程保活（不轮询、无后台任务）
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
