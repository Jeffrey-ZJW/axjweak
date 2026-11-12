#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <stdarg.h>

// ========================================
//  v3.6.6 测试构建：自报公网 IP 伪造（FakeIP）
//
//  依据（经验库 ios-public-ip-single-source-gzip-response，真机实测结论）：
//    · 客户端唯一的公网 IP 来源 = GET https://ip.buyuios.com/ 的响应正文
//    · 该请求走 -[NSURLSession dataTaskWithRequest:completionHandler:]
//    · completion 回调拿到的已是解压后的 12~13 字节明文，不存在等长约束
//    · 只改这一处，loginIP / Log.report 的 ip / api/ip/info 请求体 / GameRunIP 全部跟着变
//    · 必须在客户端取值处改，让它拿假 IP 自己算签名；事后改报文签名会对不上
//
//  v2 修订（按 v3.4 的 hook 经验）：
//    · %ctor 第一行无条件写日志（bundle + 进程名）：只要 dylib 进了进程就一定留痕
//    · 加载判定放宽：bundle 命中 或 进程名 Fuel5 命中，任一即认（不再因 bundle 判定失败静默退出）
//    · 配置无效也把 hook 挂上，回调里透传并说明原因（真机能看出"挂上了但没值"）
//    · host 命中时打一行请求日志（能看出 hook 到底拦没拦到请求）
//
//  不要碰 GameRunIP（结果缓存）、不要碰 api/ip/info（消费方）、不要引入 gzip 逻辑。
// ========================================

static NSString *const kFakeIPConfigPath = @"/var/mobile/Library/Preferences/com.jeffrey.fishtweak.plist";
static NSString *const kFakeIPLogFile    = @"/var/mobile/Library/Preferences/com.jeffrey.fishtweak.tweak.log";
static NSString *const kFakeIPHost       = @"ip.buyuios.com";
static NSString *const kFakeIPBundleId   = @"com.gzlj.fishdecisive";
static NSString *const kFakeIPProcess    = @"Fuel5";

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

    // 命中目标域名：先留痕，说明 hook 真的拦到了这个请求
    fiplog(@"[FakeIP] 命中 host=%@ 请求，等待回调 (假IP=%@)", host, gFakeIP ?: @"(无)");

    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSData *outData = data;
        if (!error && [data isKindOfClass:[NSData class]] && data.length > 0 && data.length <= 15) {
            NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (text && fiIsValidIPv4(text)) {
                if (gFakeIP) {
                    NSData *fakeData = [gFakeIP dataUsingEncoding:NSUTF8StringEncoding];
                    if (fakeData) {
                        outData = fakeData;
                        fiplog(@"[FakeIP] 替换成功: %@ -> %@ (len %lu -> %lu)",
                               text, gFakeIP, (unsigned long)data.length, (unsigned long)fakeData.length);
                    }
                } else {
                    fiplog(@"[FakeIP] 拿到真实 IP %@，但没有假 IP 值，原样透传", text);
                }
            } else {
                fiplog(@"[FakeIP] 跳过: 返回不是合法 IPv4 (len=%lu)", (unsigned long)data.length);
            }
        } else if (error) {
            fiplog(@"[FakeIP] 跳过: 回调带错误 %@", error.localizedDescription);
        }
        // 三个参数顺序与语义不变
        handler(outData, response, error);
    };

    // block 必须 copy 到堆再交给原实现，否则回调执行时栈帧已释放
    void (^copiedHandler)(NSData *, NSURLResponse *, NSError *) = [wrapped copy];
    return orig_dataTaskWithRequest(self, _cmd, request, copiedHandler);
}

// ---- 运行时挂 hook ----
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
        // 第一步就留痕：只要 dylib 进到进程里，这一行一定写在 tweak 日志里
        NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSString *processName = [[NSProcessInfo processInfo] processName] ?: @"";
        fiplog(@"[FakeIP] ctor 进入 bundle=%@ process=%@", bundleId, processName);

        // 判定放宽：bundle 命中 或 进程名命中，任一即认（按键精灵两个都不命中，自动跳过）
        BOOL isGame = [bundleId isEqualToString:kFakeIPBundleId] ||
                      [processName isEqualToString:kFakeIPProcess];
        if (!isGame) {
            fiplog(@"[FakeIP] 非游戏进程，跳过（不挂 hook）");
            return;
        }
        fiplog(@"[FakeIP] 判定为游戏进程（bundle命中=%d 进程名命中=%d）",
               [bundleId isEqualToString:kFakeIPBundleId] ? 1 : 0,
               [processName isEqualToString:kFakeIPProcess] ? 1 : 0);

        gFakeIP = fiLoadFakeIP();
        fiplog(@"[FakeIP] 读取配置 FakeIPValue=%@", gFakeIP ?: @"(缺失或非法)");

        // 配置无效也挂 hook：真机日志能区分"没挂上"和"挂上了但没值"
        fiInstallHook();
    }
}
