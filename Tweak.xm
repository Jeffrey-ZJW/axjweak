#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonCrypto.h>
#import <objc/runtime.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <string.h>

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
//  本地 HTTP 服务 + 游戏API请求（v2.1）
// ========================================
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
    [req setValue:@"Fuel5/2.13.1 (iPhone; iOS 12.0; Scale/2.00)" forHTTPHeaderField:@"User-Agent"];
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

    } else {
        sendLocalHttpResponse(clientSocket, @{
            @"endpoints": @[@"/send_sms?mobile=X&uuid=Y", @"/reset_password?mobile=X&code=Y&password=Z&uuid=Y"]
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

%ctor {
    NSLog(@"[FishTweak] 插件已加载 v2.1.0");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *uuid = getOrDeriveUUID();
        NSLog(@"[FishTweak] 预热完成，当前环境 IDFA: %@", uuid);
    });

    pthread_t tid;
    pthread_create(&tid, NULL, httpAcceptThread, NULL);
}
