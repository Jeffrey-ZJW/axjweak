// ============================================================
//  fishtweakd —— 常驻 daemon（v3.6.1）
//  职责：仅服务本机游戏《捕鱼大决战》(com.gzlj.fishdecisive)
//  1) 监听 127.0.0.1:8888（本地回环，只服务按键精灵）
//  2) /set_account 收号 → 判库 → 无则写DB + 写16键plist（LastPwdAccount=phonepass 明文）
//  3) /status       返回当前缓存账号状态（直接查容器内 plist + DB）
//  4) /send_sms /reset_password  老功能（原插件内实现，迁到本进程）
//  v3.6.1：不拉起游戏（按键精灵自己开）、不清 cfprefsd（按键精灵自己清）、无 /launch 接口
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
#include <stdlib.h>
#include <mach/mach.h>
#include <dispatch/dispatch.h>
#include <sqlite3.h>

// ---- 固定路径（daemon 自用：日志；v3.6.0 起不再有"参数文件/状态文件"机制，缓存登录改为游戏外直写）----
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
//  收号落盘（写参数文件，0644 保证游戏进程 mobile 可读）
// ============================================================
static NSString *strParam(NSDictionary *p, NSString *key) {
    id v = p[key];
    if (!v || [v isKindOfClass:[NSNull class]]) return @"";
    if ([v isKindOfClass:[NSString class]]) return v;
    return [v stringValue];
}

// ============================================================
//  v3.4.0 新增：daemon（游戏外）直接操作游戏数据库
//  依据 frida 实验结论：游戏进程内 sqlite 查询受 WAL/锁影响不可见，
//  游戏外（daemon/SpringBoard 视角）查询 100% 可靠 —— 判定必须放游戏外
// ============================================================

// 游戏数据容器内的 zs_data.sqlite 路径
static NSString *gameDbPath(void) {
    NSString *container = findDataContainer(kGameBundleId);
    if (!container) return nil;
    return [container stringByAppendingPathComponent:@"Documents/AnaestheticsYachtsman/zs_data.sqlite"];
}

// 游戏外查询：user_info 是否存在该 openid（判定"要不要注入"的唯一依据）
static BOOL dbHasOpenId(NSString *openId) {
    NSString *dbPath = gameDbPath();
    if (!dbPath || openId.length == 0) {
        fishlog(@"[dbHasOpenId] 库路径无效 openid=%@", openId ?: @"nil");
        return NO;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:dbPath]) {
        fishlog(@"[dbHasOpenId] 数据库不存在（游戏从未启动过）");
        return NO;
    }
    sqlite3 *db = NULL;
    if (sqlite3_open([dbPath UTF8String], &db) != SQLITE_OK) {
        fishlog(@"[dbHasOpenId] sqlite3_open 失败: %s", sqlite3_errmsg(db));
        if (db) sqlite3_close(db);
        return NO;
    }
    BOOL found = NO;
    sqlite3_stmt *stmt = NULL;
    const char *sql = "SELECT COUNT(*) FROM user_info WHERE openId=?;";
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, [openId UTF8String], -1, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            found = (sqlite3_column_int(stmt, 0) > 0);
        }
    }
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    fishlog(@"[dbHasOpenId] openid=%@ count=%d", openId, found ? 1 : 0);
    return found;
}

// password AES-128-ECB+PKCS7 加密（key=Ze1QLUFj296TAho2，与插件/游戏自然标准一致）
static NSString *aesEncryptPassword(NSString *plain) {
    if (!plain || plain.length == 0) return nil;
    if (plain.length == 44 && [plain hasSuffix:@"="]) return plain; // 已是密文
    NSData *keyData = [@"Ze1QLUFj296TAho2" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *plainData = [plain dataUsingEncoding:NSUTF8StringEncoding];
    size_t outLen = [plainData length] + kCCBlockSizeAES128;
    NSMutableData *outData = [NSMutableData dataWithLength:outLen];
    CCCryptorStatus status = CCCrypt(kCCEncrypt, kCCAlgorithmAES,
                                     kCCOptionPKCS7Padding | kCCOptionECBMode, // 与插件 v3.3.5 一致：显式 ECB
                                     keyData.bytes, kCCKeySizeAES128,
                                     NULL, // ECB 无 IV
                                     plainData.bytes, plainData.length,
                                     outData.mutableBytes, outLen, &outLen);
    if (status != kCCSuccess) return plain;
    [outData setLength:outLen];
    return [outData base64EncodedStringWithOptions:0];
}

// 游戏外写库：INSERT OR REPLACE user_info（字段与插件 writeUserInfo 完全一致）
static void writeUserInfoDb(NSDictionary *acct) {
    NSString *dbPath = gameDbPath();
    if (!dbPath) { fishlog(@"[writeDb] 未找到游戏数据库，放弃"); return; }
    sqlite3 *db = NULL;
    if (sqlite3_open([dbPath UTF8String], &db) != SQLITE_OK) {
        fishlog(@"[writeDb] sqlite3_open 失败: %s", sqlite3_errmsg(db));
        if (db) sqlite3_close(db);
        return;
    }
    const char *createSql = "CREATE TABLE IF NOT EXISTS user_info(openId varchar(100) PRIMARY KEY NOT NULL,token TEXT NOT NULL,refreshToken TEXT NOT NULL,tokenType int NOT NULL,mobile varchar(50),nickName varchar(100),loginTime INTEGER NOT NULL,account varchar(100),password varchar(100),expires_in INTEGER NOT NULL,thirdUserId TEXT);";
    sqlite3_exec(db, createSql, NULL, NULL, NULL);
    // nickname 含特殊字符时转义单引号（其余字段为 Base64/数字/md5，无单引号）
    NSString *nick = [strParam(acct, @"nickname") stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
    NSString *pwd = strParam(acct, @"password");
    NSString *enc = (pwd.length > 0) ? aesEncryptPassword(pwd) : nil;
    NSString *sql;
    if (enc && enc.length > 0) {
        // 老号有 password：照常写入（密文）
        sql = [NSString stringWithFormat:
            @"INSERT OR REPLACE INTO user_info(openId,token,refreshToken,tokenType,mobile,nickName,loginTime,account,password,expires_in,thirdUserId) VALUES('%@','%@','%@',2,'','%@',1,'%@','%@',1,NULL);",
            strParam(acct, @"openid"), strParam(acct, @"token"), strParam(acct, @"refresh"),
            nick, strParam(acct, @"phone"), enc];
    } else {
        // 新号无 password：不写 password 列（NULL），让游戏客户端登录时自己生成
        sql = [NSString stringWithFormat:
            @"INSERT OR REPLACE INTO user_info(openId,token,refreshToken,tokenType,mobile,nickName,loginTime,account,expires_in,thirdUserId) VALUES('%@','%@','%@',2,'','%@',1,'%@',1,NULL);",
            strParam(acct, @"openid"), strParam(acct, @"token"), strParam(acct, @"refresh"),
            nick, strParam(acct, @"phone")];
    }
    char *err = NULL;
    int rc = sqlite3_exec(db, [sql UTF8String], NULL, NULL, &err);
    if (rc != SQLITE_OK) {
        fishlog(@"[writeDb] user_info 写入失败 rc=%d err=%s", rc, err ? err : "");
        sqlite3_free(err);
    } else {
        fishlog(@"[writeDb] ★ user_info 已写入 appid=%@ phone=%@", strParam(acct, @"appid"), strParam(acct, @"phone"));
    }
    sqlite3_close(db);
}

// ============================================================
//  v3.6.0 新增：游戏外直写【容器内 plist】（16 键）
//  依据 2026-10-30 frida 递减实验结论：
//    基础4（ZSFirst/LAST_LAUNCH/InstallVer/Agree）+ 状态4（SDK/ONLINE/device_id/session_count）
//    + 缓存8（OpenId/Name/User/GameAcc/LastID/LastPwd/LastLoginType/LoginType）= 16 键全量
//    → 游戏直接跳过初始化界面 + 显示缓存登录（玩家XXX+更换账号）
//  键类型与 frida 实证一致：字符串用 NSString、整型用 NSNumber
// ============================================================

// 写游戏容器内 plist（16 键全量）并删除全局域同名 plist（游戏只读容器内，全局域是误写位置）
static void writeGamePrefs(NSDictionary *acct) {
    NSString *container = findDataContainer(kGameBundleId);
    if (!container) { fishlog(@"[writePrefs] 未找到游戏容器，放弃"); return; }

    // 1) 删除全局域同名 plist（游戏不读，避免与容器内混淆）
    NSString *globalPlist = @"/var/mobile/Library/Preferences/com.gzlj.fishdecisive.plist";
    if ([[NSFileManager defaultManager] fileExistsAtPath:globalPlist]) {
        [[NSFileManager defaultManager] removeItemAtPath:globalPlist error:NULL];
        fishlog(@"[writePrefs] 已删除全局域 plist（游戏不读该位置）");
    }

    // 2) 写容器内 plist（16 键全量）
    NSString *prefDir  = [container stringByAppendingPathComponent:@"Library/Preferences"];
    NSString *plistPath = [prefDir stringByAppendingPathComponent:@"com.gzlj.fishdecisive.plist"];
    [[NSFileManager defaultManager] createDirectoryAtPath:prefDir
                             withIntermediateDirectories:YES attributes:nil error:NULL];
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"yyyyMMdd"];
    NSString *today = [df stringFromDate:[NSDate date]];

    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithCapacity:16];
    // 基础4：首启时间 / 上次启动 / 安装版本 / 同意协议
    d[@"ZSFirstStartupLaunchTime"] = @((long long)[[NSDate date] timeIntervalSince1970]);
    d[@"LAST_LAUNCH_GAME_TIME"]    = today;
    d[@"InstallAppVersion"]        = @"2.13";
    d[@"Login_Agree"]              = @1;
    // 状态4：SDK初始化 / 在线状态 / 设备ID / 启动次数（必须全给，部分给会卡加载）
    d[@"LoginInitSDK"]             = @(-1);
    d[@"KEY_ONLINE_STATE_213"]     = @1;
    d[@"device_id"]                = [[NSUUID UUID] UUIDString];
    d[@"unity.player_session_count"] = @1;
    // 缓存8：账号缓存信息
    d[@"Login_OpenId"]             = strParam(acct, @"openid");
    d[@"Login_Name"]               = [NSString stringWithFormat:@"玩家%@", strParam(acct, @"appid")];
    d[@"Login_User"]               = strParam(acct, @"appid");
    d[@"GameLastAccountId"]        = strParam(acct, @"appid");
    d[@"LastIDAccount"]            = strParam(acct, @"phone");
    NSString *phonepass = strParam(acct, @"phonepass");   // 明文密码（按键精灵新参数），直接写 LastPwdAccount
    if (phonepass.length > 0) d[@"LastPwdAccount"] = phonepass;
    d[@"LastLoginType"]            = @4;
    d[@"Login_Type"]               = @1;

    BOOL ok = [d writeToFile:plistPath atomically:YES];
    chmod([plistPath UTF8String], 0644);
    fishlog(@"[writePrefs] 容器内 plist 写入 %@ → %@ (16键)", plistPath, ok ? @"成功" : @"失败");
}


// 读游戏容器内 plist 的 Login_OpenId（/status 判定"当前缓存账号"用，v3.6.0 不再依赖 tweak 写状态文件）
static NSString *currentCachedOpenId(void) {
    NSString *container = findDataContainer(kGameBundleId);
    if (!container) return @"";
    NSString *plistPath = [container stringByAppendingPathComponent:@"Library/Preferences/com.gzlj.fishdecisive.plist"];
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    NSString *oid = d[@"Login_OpenId"];
    return (oid && oid.length > 0) ? oid : @"";
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
        // v3.6.0：直接查容器内 plist 的 Login_OpenId + 查库，判定当前缓存账号（不再依赖 tweak 写状态文件）
        NSString *curOpenId = currentCachedOpenId();
        BOOL hasCache = (curOpenId.length > 0) ? dbHasOpenId(curOpenId) : NO;
        NSDictionary *status = @{
            @"plugin": @"fishtweakd",
            @"version": @"3.6.1",
            @"daemon": @"alive",
            @"cache": @{
                @"has_cache": @(hasCache),
                @"cache_openid": curOpenId,
                @"pending_account": @NO
            }
        };
        sendHttp(clientSocket, status);

    } else if ([reqPath isEqualToString:@"/set_account"]) {
        NSString *openid = params[@"openid"];
        NSString *refresh = params[@"refresh"];
        if (!openid || openid.length == 0 || !refresh || refresh.length == 0) {
            sendHttp(clientSocket, @{@"error": @"missing openid/refresh",
                                     @"need": @[@"appid", @"openid", @"refresh", @"token",
                                                @"nickname", @"account", @"phone", @"phonepass", @"password"]});
            return;
        }
        // v3.6.1：游戏外查库判定 + 游戏外直写（frida 实证：16 键全量写容器内 plist + DB → 跳过初始化+缓存登录）
        //   库里已有该号 → 只更新 DB（token/refresh 可能轮换），不写 plist → 游戏自然缓存登录
        //   库里没有该号 → 写 DB + 写 16 键 plist（LastPwdAccount=phonepass 明文）→ 注入
        //   v3.6.1：不拉起游戏（按键精灵自己开）、不清 cfprefsd（按键精灵自己清）
        BOOL hasCache = dbHasOpenId(openid);
        if (hasCache) {
            writeUserInfoDb(params);
            fishlog(@"[set_account] 账号 %@ 库里已有缓存 → 只更新DB，不写plist，游戏自然缓存登录", openid);
            sendHttp(clientSocket, @{@"ok": @1, @"saved": openid, @"injected": @NO});
        } else {
            writeUserInfoDb(params);
            writeGamePrefs(params);
            fishlog(@"[set_account] 账号 %@ 库里无缓存 → 已写DB+16键plist（注入，LastPwd=phonepass）", openid);
            sendHttp(clientSocket, @{@"ok": @1, @"saved": openid, @"injected": @YES});
        }

    } else {
        sendHttp(clientSocket, @{
            @"endpoints": @[@"/send_sms?mobile=X&uuid=Y",
                            @"/reset_password?mobile=X&code=Y&password=Z&uuid=Y",
                            @"/status",
                            @"/set_account?appid=X&openid=Y&refresh=Z&token=T&nickname=N&account=A&phone=P&phonepass=M&password=H"]
        });
    }
}

// ============================================================
//  v3.4.0 新增：插件自动更新
//  固定 URL（GitHub Release latest 直链，Actions 每次编译后自动发布同名资产）
//  daemon 启动后 5s 检查一次 + 每 6 小时一次：
//    下载 deb → dpkg-deb 读新版号 → 对比 dpkg -s 本地版本 → 不同则 dpkg -i → 杀游戏+重启自身
// ============================================================
static NSString *const kUpdateURL = @"https://github.com/Jeffrey-ZJW/axjweak/releases/latest/download/fishtweak.deb";
static NSString *const kUpdateTmp = @"/tmp/fishtweak-update.deb";
static NSString *const kPackageName = @"com.jeffrey.fishtweak";

static NSString *shellOutput(NSString *cmd) {
    FILE *fp = popen([cmd UTF8String], "r");
    if (!fp) return nil;
    char buf[512];
    NSMutableString *out = [NSMutableString string];
    while (fgets(buf, sizeof(buf), fp)) [out appendFormat:@"%s", buf];
    pclose(fp);
    return out;
}

// v3.4.0 修复：本地版本直接读 /var/lib/dpkg/status 解析（不依赖 dpkg/grep/awk 管道，iOS launchd 环境管道工具可能缺失）
static NSString *localInstalledVersion(void) {
    NSString *status = [NSString stringWithContentsOfFile:@"/var/lib/dpkg/status" encoding:NSUTF8StringEncoding error:NULL];
    if (!status) return nil;
    NSRange r = [status rangeOfString:@"Package: com.jeffrey.fishtweak"];
    if (r.location == NSNotFound) return nil;
    NSString *seg = [status substringFromIndex:r.location];
    NSRange v = [seg rangeOfString:@"\nVersion: "];
    if (v.location == NSNotFound) return nil;
    NSUInteger start = v.location + v.length;
    NSRange eol = [seg rangeOfString:@"\n" options:0 range:NSMakeRange(start, MIN(seg.length - start, 64))];
    if (eol.location == NSNotFound) return nil;
    return [[seg substringWithRange:NSMakeRange(start, eol.location - start)]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static void checkForUpdate(void) {
    @autoreleasepool {
        NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:kUpdateURL]
                                             options:NSDataReadingUncached
                                               error:NULL];
        if (!data || data.length < 1000) {
            fishlog(@"[update] 下载失败/过小(%lu bytes)，跳过本次检查（网络或 GitHub 不可达）", (unsigned long)data.length);
            return;
        }
        [data writeToFile:kUpdateTmp atomically:YES];
        NSString *newVer = [shellOutput([NSString stringWithFormat:@"dpkg-deb -f %@ Version 2>/dev/null", kUpdateTmp]) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *local = localInstalledVersion();
        fishlog(@"[update] 下载 %lu bytes | 新版=%@ | 本地=%@", (unsigned long)data.length, newVer, local);
        if (newVer.length == 0) { fishlog(@"[update] 解析新版版本号失败，跳过"); return; }
        if ([newVer isEqualToString:local]) { fishlog(@"[update] 版本一致(%@)，无需更新", newVer); return; }
        fishlog(@"[update] ★ 发现新版本 %@ → %@，开始后台安装", local, newVer);
        // 后台 dpkg 安装（不阻塞 daemon；输出写文件，避免 popen 管道卡住）
        NSString *cmd = [NSString stringWithFormat:@"dpkg -i %@ >/tmp/fishtweak-dpkg.log 2>&1 &", kUpdateTmp];
        popen([cmd UTF8String], "r"); // 打开即返回，dpkg 在后台执行
        pclose(NULL);
        [NSThread sleepForTimeInterval:3.0]; // 等 dpkg 完成（正常 <2s）
        fishlog(@"[update] dpkg 后台结果:\n%@", shellOutput(@"cat /tmp/fishtweak-dpkg.log 2>/dev/null; echo ---"));
        // 安装完成：杀游戏（新插件注入需重启进程）；daemon 二进制已被覆盖，kill 自身由 launchd KeepAlive 拉起新版本
        shellOutput(@"killall -9 捕鱼大决战 Fuel5 2>/dev/null; killall -9 fishtweakd 2>/dev/null; echo done");
        fishlog(@"[update] 安装完成，游戏与 daemon 已重启");
    }
}

// 后台启动更新检查：5 秒后首查 + 每 6 小时
static void startUpdateLoop(void) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        [NSThread sleepForTimeInterval:5.0];
        checkForUpdate();
        while (1) {
            [NSThread sleepForTimeInterval:6 * 3600.0];
            checkForUpdate();
        }
    });
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
        NSLog(@"[FishTweakD] 常驻 daemon 启动 v3.6.1");
        pthread_t tid;
        pthread_create(&tid, NULL, httpThread, NULL);
        startUpdateLoop(); // v3.4.0：自动更新（GitHub Release）
        // 主线程保活（不轮询、无后台任务）
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
