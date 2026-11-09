#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <stdarg.h>

// ========================================
//  v3.6.6 测试构建：自报公网 IP 伪造（FakeIP）
//
//  真机已验证的结论（详见 插件需求与实现规格_IP自报伪造_v1.md）：
//    · 客户端唯一的公网 IP 来源 = GET https://ip.buyuios.com/ 的响应正文
//    · 该请求走 -[NSURLSession dataTaskWithRequest:completionHandler:]
//    · 回调层拿到的已是解压后的 12~13 字节明文，不存在等长约束
//    · 只改这一处，loginIP / Log.report 的 ip / api/ip/info 请求体 / GameRunIP 全部跟着变
//    · 必须在客户端取值处改，让它拿假 IP 自己算签名；事后改报文签名会对不上
//
//  本文件独立于 Tweak.xm，不改动任何现有函数；出问题整段删除即可回退。
//  不要碰 GameRunIP（结果缓存）、不要碰 api/ip/info（消费方）、不要引入 gzip 逻辑。
// ========================================

static NSString *const kFakeIPConfigPath = @"/var/mobile/Library/Preferences/com.jeffrey.fishtweak.plist";
static NSString *const kFakeIPLogFile    = @"/var/mobile/Library/Preferences/com.jeffrey.fishtweak.tweak.log";
static NSString *const kFakeIPHost       = @"ip.buyuios.com";

static NSString *gFakeIP = nil;       // 本次进程生效的假 IP（启动时读一次）
static BOOL gHookInstalled = NO;

// ---- 文件日志（与 Tweak.xm 共用同一个日志文件，靠 [FakeIP] 前缀区分）----
static void fiplog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kFakeIPLogFile];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:kFakeIPLogFile contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:kFakeIPLogFile];
    }
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

// ---- 合法 IPv4 判定（四段点分十进制，每段 0~255）----
static BOOL fiIsValidIPv4(NSString *s) {
    if (s.length < 7 || s.length > 15) return NO;
    NSArray *parts = [s componentsSeparatedByString:@"."];
    if (parts.count != 4) return NO;
    for (NSString *p in parts) {
        if (p.length == 0 || p.length > 3) return NO;
        for (NSUInteger i = 0; i < p.length; i++) {
            unichar c = [p characterAtIndex:i];
            if (c < '0' || c > '9') return NO;
        }
        NSInteger v = [p integerValue];
        if (v < 0 || v > 255) return NO;
    }
    return YES;
}

// ---- 读配置：FakeIPValue（注入时由 daemon 按 appid 写好）----
//  直接读文件，不经过 CFPreferences，避开 cfprefsd 缓存。
static NSString *fiLoadFakeIP(void) {
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kFakeIPConfigPath];
    if (![cfg isKindOfClass:[NSDictionary class]]) return nil;
    id v = cfg[@"FakeIPValue"];
    if (![v isKindOfClass:[NSString class]]) return nil;
    NSString *s = [(NSString *)v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!fiIsValidIPv4(s)) return nil;
    return s;
}

// ---- 包装 completion block：命中 ip.buyuios.com 时把 NSData 换成假 IP ----
static NSURLSessionDataTask *(*orig_dataTaskWithRequest)(id, SEL, NSURLRequest *,
                                                         void (^)(NSData *, NSURLResponse *, NSError *));

static NSURLSessionDataTask *my_dataTaskWithRequest(id self, SEL _cmd, NSURLRequest *request,
                                                    void (^handler)(NSData *, NSURLResponse *, NSError *)) {
    // delegate 形态（没有 block）直接放行，不处理、不崩溃
    if (!handler) {
        return orig_dataTaskWithRequest(self, _cmd, request, handler);
    }
    NSString *host = request.URL.host.lowercaseString;
    if (!host || ![host isEqualToString:kFakeIPHost]) {
        return orig_dataTaskWithRequest(self, _cmd, request, handler);
    }

    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSData *outData = data;
        if (!error && [data isKindOfClass:[NSData class]] && data.length > 0 && data.length <= 15) {
            NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (text && fiIsValidIPv4(text)) {
                NSData *fakeData = [gFakeIP dataUsingEncoding:NSUTF8StringEncoding];
                if (fakeData) {
                    outData = fakeData;
                    fiplog(@"[FakeIP] 命中 ip.buyuios.com: %@ -> %@ (len %lu -> %lu)",
                           text, gFakeIP, (unsigned long)data.length, (unsigned long)fakeData.length);
                }
            } else {
                fiplog(@"[FakeIP] 跳过: 返回不是合法 IPv4 (len=%lu)", (unsigned long)data.length);
            }
        }
        // 三个参数顺序与语义不变
        handler(outData, response, error);
    };

    // block 必须 copy 到堆再交给原实现，否则回调执行时栈帧已释放
    void (^copiedHandler)(NSData *, NSURLResponse *, NSError *) = [wrapped copy];
    return orig_dataTaskWithRequest(self, _cmd, request, copiedHandler);
}

// ---- 运行时挂 hook（不用 %hook：开关关闭时必须一个 hook 都不挂）----
static void fiInstallHook(void) {
    if (gHookInstalled) return;
    Class cls = (Class)objc_getClass("NSURLSession");
    if (!cls) {
        fiplog(@"[FakeIP] 找不到 NSURLSession，无法挂 hook");
        return;
    }
    SEL sel = @selector(dataTaskWithRequest:completionHandler:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        fiplog(@"[FakeIP] NSURLSession 上没有 dataTaskWithRequest:completionHandler:，无法挂 hook");
        return;
    }
    MSHookMessageEx(cls, sel, (IMP)my_dataTaskWithRequest, (IMP *)&orig_dataTaskWithRequest);
    gHookInstalled = YES;
    fiplog(@"[FakeIP] hook 已挂: NSURLSession dataTaskWithRequest:completionHandler:");
}

%ctor {
    @autoreleasepool {
        NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        // 按键精灵也在 Filter 里，这里主动跳过，只对游戏生效
        if (![bundleId isEqualToString:@"com.gzlj.fishdecisive"]) {
            return;
        }
        gFakeIP = fiLoadFakeIP();
        if (!gFakeIP) {
            fiplog(@"[FakeIP] 配置里没有有效的 FakeIPValue，本次不挂任何 hook（走真实 IP）");
            return;
        }
        fiplog(@"[FakeIP] 模块加载，目标 IP=%@", gFakeIP);
        fiInstallHook();
    }
}
