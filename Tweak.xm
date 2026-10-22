#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonCrypto.h>
#import <objc/runtime.h>
#include <substrate.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <time.h>
#include <stdlib.h>
#include <dlfcn.h>

// ========================================
//  IDFA 伪造（原有功能）
// ========================================
static NSString *gCurrentUUID = nil;
static NSString *gCachedIDFV = nil;

static NSString *deriveUUIDFromIDFV(NSString *idfv) {
    if (!idfv || idfv.length == 0) return nil;
    const char *idfvBytes = [idfv UTF8String];
    size_t idfvLen = strlen(idfvBytes);
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(idfvBytes, (CC_LONG)idfvLen, hash);
    unsigned char uuidBytes[16];
    memcpy(uuidBytes, hash, 16);
    uuidBytes[6] = (uuidBytes[6] & 0x0F) | 0x40;
    uuidBytes[8] = (uuidBytes[8] & 0x3F) | 0x80;
    NSUUID *newUUID = [[NSUUID alloc] initWithUUIDBytes:uuidBytes];
    return [newUUID UUIDString];
}

static NSString *getOrDeriveUUID(void) {
    @try {
        NSUUID *idfvObj = [[UIDevice currentDevice] identifierForVendor];
        if (!idfvObj) {
            NSLog(@"[FishTweak] IDFV 返回 nil");
            return [[NSUUID UUID] UUIDString];
        }
        NSString *idfvStr = [idfvObj UUIDString];
        if (!idfvStr || idfvStr.length != 36) {
            NSLog(@"[FishTweak] IDFV 格式异常: %@", idfvStr);
            return [[NSUUID UUID] UUIDString];
        }
        if (gCachedIDFV && [gCachedIDFV isEqualToString:idfvStr] && gCurrentUUID) {
            return gCurrentUUID;
        }
        NSString *derived = deriveUUIDFromIDFV(idfvStr);
        if (!derived) {
            return [[NSUUID UUID] UUIDString];
        }
        gCachedIDFV = [idfvStr copy];
        gCurrentUUID = [derived copy];
        NSLog(@"[FishTweak] IDFV: %@", idfvStr);
        NSLog(@"[FishTweak] 派生 IDFA: %@", derived);
        return derived;
    } @catch (NSException *e) {
        NSLog(@"[FishTweak] 异常: %@", e);
        return [[NSUUID UUID] UUIDString];
    }
}

%hook LSApplicationWorkspace
- (NSUUID *)deviceIdentifierForAdvertising {
    NSString *newUUIDStr = getOrDeriveUUID();
    NSUUID *newUUID = [[NSUUID alloc] initWithUUIDString:newUUIDStr];
    NSLog(@"[FishTweak] 拦截 IDFA，返回: %@", newUUIDStr);
    return newUUID;
}
%end

%hook ASIdentifierManager
- (NSUUID *)advertisingIdentifier {
    NSString *newUUIDStr = getOrDeriveUUID();
    NSUUID *newUUID = [[NSUUID alloc] initWithUUIDString:newUUIDStr];
    NSLog(@"[FishTweak] 拦截 ASIM IDFA，返回: %@", newUUIDStr);
    return newUUID;
}
%end

// ========================================
//  本地 HTTP 服务 + 游戏API请求（v2.2）
// ========================================

static NSString *buildUserAgent(void) {
    NSString *iosVer = [[UIDevice currentDevice] systemVersion];
    CGFloat screenScale = [[UIScreen mainScreen] scale];
    NSString *scaleStr = (screenScale > 2.5) ? @"3.00" : @"2.00";
    return [NSString stringWithFormat:@"Fuel5/2.13.1 (iPhone; iOS %@; Scale/%@)", iosVer, scaleStr];
}

static NSString *const kAPIHost = @"https://openapi.buyuios.com";
static NSString *const kPackageNo = @"10011001001";
static const int kLocalPort = 8888;
static NSString *const kKeyHex = @"5a6531514c55466a3239365441686f32576963364f4e33704f6572727a516f31";
static NSString *const kIvHex  = @"5a6531514c55466a3239365441686f32";

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
    CCCrypt(kCCEncrypt, kCCAlgorithmAES, 0,
            key.bytes, key.length, iv.bytes,
            padded.bytes, padded.length,
            result.mutableBytes, result.length, &outLen);
    result.length = outLen;
    return [result base64EncodedStringWithOptions:0];
}

static NSString *calculateSign(NSString *did, NSString *mobile, NSString *sesskey, NSString *type) {
    NSData *key = hexToData(kKeyHex);
    NSString *str = [NSString stringWithFormat:@"did=%@&mobile=%@&packageNo=%@&sesskey=%@&smsProvider=0&type=%@",
                     did, mobile, kPackageNo, sesskey, type];
    NSMutableData *hash = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length,
           [str dataUsingEncoding:NSUTF8StringEncoding].bytes,
           [str dataUsingEncoding:NSUTF8StringEncoding].length,
           hash.mutableBytes);
    NSMutableString *hex = [NSMutableString string];
    for (NSUInteger i = 0; i < hash.length; i++) {
        [hex appendFormat:@"%02x", ((uint8_t *)hash.bytes)[i]];
    }
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
    [req setValue:@"br, gzip, deflate" forHTTPHeaderField:@"Accept-Encoding"];
    [req setValue:@"zh-Hans;q=1, en;q=0.9" forHTTPHeaderField:@"Accept-Language"];
    [req setHTTPBody:bodyData];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { callback(@{@"error": error.localizedDescription}); return; }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        callback(json ?: @{@"raw": [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]});
    }];
    [task resume];
}

static void sendLocalHttpResponse(int clientSocket, NSDictionary *json) {
    NSData *body = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    NSString *response = [NSString stringWithFormat:
        @"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n%@",
        (unsigned long)body.length,
        [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding]];
    send(clientSocket, response.UTF8String, strlen(response.UTF8String), 0);
    close(clientSocket);
}

static void handleLocalRequest(int clientSocket, NSString *path) {
    NSURLComponents *components = [NSURLComponents componentsWithString:[NSString stringWithFormat:@"http://localhost%@", path]];
    NSString *reqPath = components.path;
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in components.queryItems) {
        params[item.name] = item.value;
    }

    if ([reqPath isEqualToString:@"/send_sms"]) {
        NSString *mobile = params[@"mobile"];
        NSString *uuid = params[@"uuid"];
        if (!mobile || !uuid) { sendLocalHttpResponse(clientSocket, @{@"error": @"missing mobile/uuid"}); return; }

        NSString *ts = [NSString stringWithFormat:@"%lld", (long long)[[NSDate date] timeIntervalSince1970]];
        NSString *sesskey = sesskeyForMobile(mobile);
        NSString *did = generateDid(uuid, ts);
        NSString *sign = calculateSign(did, mobile, sesskey, @"2");

        NSDictionary *body = @{
            @"mobile": mobile,
            @"sesskey": sesskey,
            @"did": did,
            @"smsProvider": @0,
            @"type": @2,
            @"sign": sign,
            @"packageNo": kPackageNo
        };
        NSLog(@"[FishHttp] 发送短信 mobile=%@ sesskey=%@", mobile, sesskey);
        sendGameRequest(@"/openplatformplayercenter/api/VerifyCode/sms", body, ^(NSDictionary *resp) {
            NSLog(@"[FishHttp] 短信响应: %@", resp);
            sendLocalHttpResponse(clientSocket, resp);
        });

    } else if ([reqPath isEqualToString:@"/reset_password"]) {
        NSString *mobile = params[@"mobile"];
        NSString *code = params[@"code"];
        NSString *password = params[@"password"];
        NSString *uuid = params[@"uuid"];
        if (!mobile || !code || !password || !uuid) {
            sendLocalHttpResponse(clientSocket, @{@"error": @"missing params"});
            return;
        }
        NSString *pwd16 = md5Password(password);
        NSString *sesskey = sesskeyForMobile(mobile);
        NSDictionary *body = @{
            @"code": code,
            @"deviceNumber": uuid,
            @"sessKey": sesskey,
            @"mobile": mobile,
            @"password": pwd16,
            @"packageNo": kPackageNo
        };
        NSLog(@"[FishHttp] 重置密码 mobile=%@ code=%@", mobile, code);
        sendGameRequest(@"/openplatformplayercenter/api/Player/ResetPassword", body, ^(NSDictionary *resp) {
            NSLog(@"[FishHttp] 重置密码响应: %@", resp);
            sendLocalHttpResponse(clientSocket, resp);
        });

    } else if ([reqPath isEqualToString:@"/status"]) {
        // ============ 自检接口: 验证插件生效 + VPN 隐藏 + sys/boot 伪造 ============
        // 真实隧道数: 走 orig_getifaddrs（绕过 hook），看系统实际有没有隧道
        int realCount = 0;
        struct ifaddrs *realIfs = NULL;
        if (orig_getifaddrs && orig_getifaddrs(&realIfs) == 0) {
            struct ifaddrs *cur = realIfs;
            while (cur) {
                const char *nm = cur->ifa_name ? cur->ifa_name : "";
                if (strncmp(nm, "utun", 4) == 0 || strncmp(nm, "ipsec", 5) == 0 ||
                    strncmp(nm, "ppp", 3) == 0 || strncmp(nm, "tun", 3) == 0 ||
                    strncmp(nm, "tap", 3) == 0) realCount++;
                cur = cur->ifa_next;
            }
            freeifaddrs(realIfs);
        }
        // 可见隧道数: 走 getifaddrs（被 hook），即游戏视角
        int visibleCount = 0;
        struct ifaddrs *visIfs = NULL;
        if (getifaddrs(&visIfs) == 0) {
            struct ifaddrs *cur = visIfs;
            while (cur) {
                const char *nm = cur->ifa_name ? cur->ifa_name : "";
                if (strncmp(nm, "utun", 4) == 0 || strncmp(nm, "ipsec", 5) == 0 ||
                    strncmp(nm, "ppp", 3) == 0 || strncmp(nm, "tun", 3) == 0 ||
                    strncmp(nm, "tap", 3) == 0) visibleCount++;
                cur = cur->ifa_next;
            }
            freeifaddrs(visIfs);
        }
        BOOL vpnActive = (realCount > 0);
        BOOL hideWorking = (realCount > 0 && visibleCount == 0);
        NSString *sysStr = [NSString stringWithFormat:@"%lld.%09ld",
                            (long long)gFakeSysTime.tv_sec, (long)gFakeSysTime.tv_nsec];
        NSString *bootStr = [NSString stringWithFormat:@"%lld.%06d",
                             (long long)gFakeBootTime.tv_sec, (int)gFakeBootTime.tv_usec];
        NSDictionary *status = @{
            @"plugin": @"fishtweak",
            @"version": @"2.3.1",
            @"tweak_enabled": @(gTweakEnabled),
            @"vpn_hide": @{
                @"real_tunnel_count": @(realCount),
                @"visible_tunnel_count": @(visibleCount),
                @"vpn_active": @(vpnActive),
                @"hide_working": @(hideWorking)
            },
            @"sys_fake": sysStr,
            @"boot_fake": bootStr,
            @"idfa": (getOrDeriveUUID() ?: @"(null)")
        };
        NSLog(@"[FishTweak] /status: real=%d visible=%d vpnActive=%d hideWorking=%d",
              realCount, visibleCount, vpnActive, hideWorking);
        sendLocalHttpResponse(clientSocket, status);

    } else {
        sendLocalHttpResponse(clientSocket, @{
            @"endpoints": @[@"/send_sms?mobile=X&uuid=Y",
                            @"/reset_password?mobile=X&code=Y&password=Z&uuid=Y",
                            @"/status"]
        });
    }
}

static void *httpAcceptThread(void *arg) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    int yes = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    addr.sin_port = htons(kLocalPort);
    bind(s, (struct sockaddr *)&addr, sizeof(addr));
    listen(s, 10);
    NSLog(@"[FishHttp] 监听 127.0.0.1:%d", kLocalPort);

    while (YES) {
        int client = accept(s, NULL, NULL);
        if (client < 0) break;
        char buffer[8192];
        ssize_t n = recv(client, buffer, sizeof(buffer) - 1, 0);
        if (n > 0) {
            buffer[n] = '\0';
            NSString *request = [NSString stringWithUTF8String:buffer];
            NSArray *lines = [request componentsSeparatedByString:@"\r\n"];
            NSArray *parts = [lines.firstObject componentsSeparatedByString:@" "];
            if (parts.count >= 2) {
                handleLocalRequest(client, parts[1]);
                continue;
            }
        }
        close(client);
    }
    return NULL;
}

// ========================================
//  SysFileTime + bootTimeInSec 伪造 + VPN 隐藏（v2.3 新增）
// ========================================
static struct timeval gFakeBootTime = {0, 0};     // boot 伪值（sysctl kern.boottime）
static struct timespec gFakeSysTime = {0, 0};     // sys 伪值（MCMeta.plist 的 st_mtime）
static int gTweakEnabled = 1;                     // 总开关

// 生成成对伪值: boot 必须在 sys 之后（避免"文件创建晚于开机"破绽）
static void initFakeTimes(void) {
    time_t now = time(NULL);
    time_t sysOffset = 3600 + (arc4random_uniform(172800));      // sys = 当前时间往前 1~48h
    time_t bootGap    = 600 + (arc4random_uniform(21600));       // boot 在 sys 之后 10min~6h
    gFakeSysTime.tv_sec  = now - sysOffset;
    gFakeSysTime.tv_nsec = arc4random_uniform(1000000000);
    gFakeBootTime.tv_sec  = gFakeSysTime.tv_sec + bootGap;
    gFakeBootTime.tv_usec = (__darwin_suseconds_t)arc4random_uniform(1000000);
    NSLog(@"[FishTweak] 伪造 sys=%lld.%09ld boot=%lld.%06d (boot>sys ✓)",
          (long long)gFakeSysTime.tv_sec, (long)gFakeSysTime.tv_nsec,
          (long long)gFakeBootTime.tv_sec, (int)gFakeBootTime.tv_usec);
}

// ---- sysctl: 拦截 kern.boottime 返回伪 boot ----
static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t);
static int my_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    if (!gTweakEnabled) return ret;
    if (ret == 0 && oldp && namelen == 2 && name[0] == CTL_KERN && name[1] == KERN_BOOTTIME) {
        struct timeval *tv = (struct timeval *)oldp;
        tv->tv_sec = gFakeBootTime.tv_sec;
        tv->tv_usec = gFakeBootTime.tv_usec;
    }
    return ret;
}

// ---- stat 系列: 命中 MCMeta.plist 改写 st_mtime 为伪 sys ----
// arm64 上 stat 本身就是 64 位宽（无独立 struct stat64），
// stat64/lstat64 符号存在时用 dlsym 动态 hook 到同一实现。
static int (*orig_stat_fn)(const char *, struct stat *);
static int my_stat(const char *path, struct stat *st) {
    int ret = orig_stat_fn(path, st);
    if (!gTweakEnabled || ret != 0 || !path || !st) return ret;
    if (strstr(path, "MCMeta.plist") != NULL) {
        st->st_mtimespec.tv_sec  = gFakeSysTime.tv_sec;
        st->st_mtimespec.tv_nsec = gFakeSysTime.tv_nsec;
        st->st_atimespec.tv_sec  = gFakeSysTime.tv_sec;
        st->st_atimespec.tv_nsec = gFakeSysTime.tv_nsec;
        st->st_ctimespec.tv_sec  = gFakeSysTime.tv_sec;
        st->st_ctimespec.tv_nsec = gFakeSysTime.tv_nsec;
        NSLog(@"[FishTweak] stat 命中 %s -> sys=%lld.%09ld", path,
              (long long)gFakeSysTime.tv_sec, (long)gFakeSysTime.tv_nsec);
    }
    return ret;
}

static int (*orig_lstat_fn)(const char *, struct stat *);
static int my_lstat(const char *path, struct stat *st) {
    int ret = orig_lstat_fn(path, st);
    if (!gTweakEnabled || ret != 0 || !path || !st) return ret;
    if (strstr(path, "MCMeta.plist") != NULL) {
        st->st_mtimespec.tv_sec  = gFakeSysTime.tv_sec;
        st->st_mtimespec.tv_nsec = gFakeSysTime.tv_nsec;
        st->st_atimespec.tv_sec  = gFakeSysTime.tv_sec;
        st->st_atimespec.tv_nsec = gFakeSysTime.tv_nsec;
        st->st_ctimespec.tv_sec  = gFakeSysTime.tv_sec;
        st->st_ctimespec.tv_nsec = gFakeSysTime.tv_nsec;
        NSLog(@"[FishTweak] lstat 命中 %s -> sys=%lld.%09ld", path,
              (long long)gFakeSysTime.tv_sec, (long)gFakeSysTime.tv_nsec);
    }
    return ret;
}

// stat64/lstat64 独立 orig 指针（arm64 布局与 stat 一致，类型复用 struct stat*）
static int (*orig_stat64_fn)(const char *, struct stat *);
static int my_stat64(const char *path, struct stat *st) {
    int ret = orig_stat64_fn(path, st);
    if (!gTweakEnabled || ret != 0 || !path || !st) return ret;
    if (strstr(path, "MCMeta.plist") != NULL) {
        st->st_mtimespec.tv_sec  = gFakeSysTime.tv_sec;
        st->st_mtimespec.tv_nsec = gFakeSysTime.tv_nsec;
        st->st_atimespec.tv_sec  = gFakeSysTime.tv_sec;
        st->st_atimespec.tv_nsec = gFakeSysTime.tv_nsec;
        st->st_ctimespec.tv_sec  = gFakeSysTime.tv_sec;
        st->st_ctimespec.tv_nsec = gFakeSysTime.tv_nsec;
        NSLog(@"[FishTweak] stat64 命中 %s -> sys=%lld.%09ld", path,
              (long long)gFakeSysTime.tv_sec, (long)gFakeSysTime.tv_nsec);
    }
    return ret;
}

static int (*orig_lstat64_fn)(const char *, struct stat *);
static int my_lstat64(const char *path, struct stat *st) {
    int ret = orig_lstat64_fn(path, st);
    if (!gTweakEnabled || ret != 0 || !path || !st) return ret;
    if (strstr(path, "MCMeta.plist") != NULL) {
        st->st_mtimespec.tv_sec  = gFakeSysTime.tv_sec;
        st->st_mtimespec.tv_nsec = gFakeSysTime.tv_nsec;
        st->st_atimespec.tv_sec  = gFakeSysTime.tv_sec;
        st->st_atimespec.tv_nsec = gFakeSysTime.tv_nsec;
        st->st_ctimespec.tv_sec  = gFakeSysTime.tv_sec;
        st->st_ctimespec.tv_nsec = gFakeSysTime.tv_nsec;
        NSLog(@"[FishTweak] lstat64 命中 %s -> sys=%lld.%09ld", path,
              (long long)gFakeSysTime.tv_sec, (long)gFakeSysTime.tv_nsec);
    }
    return ret;
}

// ---- getifaddrs: 摘除 VPN 隧道接口（utun/ipsec/ppp/tun/tap）----
static int (*orig_getifaddrs)(struct ifaddrs **);
static int my_getifaddrs(struct ifaddrs **ifap) {
    int ret = orig_getifaddrs(ifap);
    if (!gTweakEnabled || ret != 0 || !ifap || !*ifap) return ret;
    struct ifaddrs *cur = *ifap;
    struct ifaddrs *prev = NULL;
    int removedCount = 0;
    while (cur != NULL) {
        struct ifaddrs *next = cur->ifa_next;
        const char *nm = cur->ifa_name ? cur->ifa_name : "";
        int isVpn = (strncmp(nm, "utun", 4) == 0 || strncmp(nm, "ipsec", 5) == 0 ||
                     strncmp(nm, "ppp", 3) == 0  || strncmp(nm, "tun", 3) == 0 ||
                     strncmp(nm, "tap", 3) == 0);
        if (isVpn) {
            if (prev) prev->ifa_next = next;
            else *ifap = next;
            removedCount++;
        } else {
            prev = cur;
        }
        cur = next;
    }
    if (removedCount > 0) {
        NSLog(@"[FishTweak] VPN隐身: 摘除 %d 个隧道接口 (utun/ipsec/ppp)", removedCount);
    }
    return ret;
}

// ---- if_nametoindex: 隧道名查询返回 0 ----
static unsigned int (*orig_if_nametoindex)(const char *);
static unsigned int my_if_nametoindex(const char *ifname) {
    if (gTweakEnabled && ifname) {
        if (strncmp(ifname, "utun", 4) == 0 || strncmp(ifname, "ipsec", 5) == 0 ||
            strncmp(ifname, "ppp", 3) == 0  || strncmp(ifname, "tun", 3) == 0 ||
            strncmp(ifname, "tap", 3) == 0) {
            return 0;
        }
    }
    return orig_if_nametoindex(ifname);
}

// ---- if_nameindex: 另一种接口枚举途径（v2.3.1 补漏）----
static struct if_nameindex *(*orig_if_nameindex)(void);
static struct if_nameindex *my_if_nameindex(void) {
    struct if_nameindex *ni = orig_if_nameindex();
    if (!gTweakEnabled || !ni) return ni;
    for (struct if_nameindex *p = ni; p && p->if_index != 0 && p->if_name; p++) {
        if (strncmp(p->if_name, "utun", 4) == 0 || strncmp(p->if_name, "ipsec", 5) == 0 ||
            strncmp(p->if_name, "ppp", 3) == 0 || strncmp(p->if_name, "tun", 3) == 0 ||
            strncmp(p->if_name, "tap", 3) == 0) {
            NSLog(@"[FishTweak] if_nameindex 屏蔽: %s", p->if_name);
            p->if_name[0] = '\0';   // 名字置空, 调用方视为无效接口
        }
    }
    return ni;
}

// ---- if_indextoname: 索引反查接口名（v2.3.1 补漏）----
static char *(*orig_if_indextoname)(unsigned int, char *);
static char *my_if_indextoname(unsigned int ifindex, char *ifname) {
    char *ret = orig_if_indextoname(ifindex, ifname);
    if (gTweakEnabled && ret) {
        if (strncmp(ret, "utun", 4) == 0 || strncmp(ret, "ipsec", 5) == 0 ||
            strncmp(ret, "ppp", 3) == 0 || strncmp(ret, "tun", 3) == 0 ||
            strncmp(ret, "tap", 3) == 0) {
            NSLog(@"[FishTweak] if_indextoname 屏蔽: %s", ret);
            ifname[0] = '\0';
            return ifname;
        }
    }
    return ret;
}

%ctor {
    NSLog(@"[FishTweak] 插件已加载 v2.3.1");
    initFakeTimes();

    // ---- v2.3: sys/boot 伪造 + VPN 隐藏 ----
    // MSHookFunction 需要显式 void* cast（C++ 不允许函数指针隐式转 void*）
    MSHookFunction((void *)&sysctl, (void *)&my_sysctl, (void **)&orig_sysctl);
    MSHookFunction((void *)&stat, (void *)&my_stat, (void **)&orig_stat_fn);
    MSHookFunction((void *)&lstat, (void *)&my_lstat, (void **)&orig_lstat_fn);
    // arm64 下 stat64/lstat64 符号存在则动态 hook（布局与 stat 一致）
    void *symStat64 = dlsym(RTLD_DEFAULT, "stat64");
    if (symStat64) {
        MSHookFunction(symStat64, (void *)&my_stat64, (void **)&orig_stat64_fn);
    }
    void *symLstat64 = dlsym(RTLD_DEFAULT, "lstat64");
    if (symLstat64) {
        MSHookFunction(symLstat64, (void *)&my_lstat64, (void **)&orig_lstat64_fn);
    }
    MSHookFunction((void *)&getifaddrs, (void *)&my_getifaddrs, (void **)&orig_getifaddrs);
    MSHookFunction((void *)&if_nametoindex, (void *)&my_if_nametoindex, (void **)&orig_if_nametoindex);
    // v2.3.1 补漏: if_nameindex / if_indextoname 也屏蔽隧道接口
    MSHookFunction((void *)&if_nameindex, (void *)&my_if_nameindex, (void **)&orig_if_nameindex);
    MSHookFunction((void *)&if_indextoname, (void *)&my_if_indextoname, (void **)&orig_if_indextoname);
    NSLog(@"[FishTweak] v2.3 hook 就绪: sysctl/stat*/getifaddrs/if_nametoindex/if_nameindex/if_indextoname");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *uuid = getOrDeriveUUID();
        NSLog(@"[FishTweak] 预热完成，当前环境 IDFA: %@", uuid);
    });

    pthread_t tid;
    pthread_create(&tid, NULL, httpAcceptThread, NULL);
}
