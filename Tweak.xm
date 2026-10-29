#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonCrypto.h>
#import <objc/runtime.h>
#import <sqlite3.h>
#include <substrate.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>
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

// ---- 全局状态定义（sysboot/VPN 使用，必须先于所有使用点）----
static struct timeval gFakeBootTime = {0, 0};      // boot 伪值（sysctl kern.boottime）
static struct timespec gFakeSysTime = {0, 0};      // sys 伪值（MCMeta.plist 的 st_mtime）
static int gTweakEnabled = 1;                      // 总开关
static int (*orig_getifaddrs)(struct ifaddrs **);  // getifaddrs 原函数指针
// ========================================
//  SysFileTime + bootTimeInSec 伪造 + VPN 隐藏（v2.3 新增）
// ========================================
// （gFakeBootTime / gFakeSysTime / gTweakEnabled / orig_getifaddrs 定义见前部）

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
// （orig_getifaddrs 定义已上移到前部）
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

// ========================================
//  v3.6.0 起：缓存登录改为【游戏外直写】（daemon 收号 → 写容器内 plist 16键 + DB → 清 cfprefsd）
//  游戏启动直接读到 16 键 → 跳过初始化 + 显示缓存登录，不再依赖进程内 hook。
//  本进程（游戏/按键精灵）仅保留：IDFA伪造 / sys-boot时间伪造 / VPN隐藏 / 屏蔽按键精灵广告。
// ========================================
// ---- tweak 文件日志（老 iOS 无 log 命令，写文件最稳；诊断 hook 是否触发）----
static NSString *const kTweakLogFile = @"/var/mobile/Library/Preferences/com.jeffrey.fishtweak.tweak.log";
static void tlog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kTweakLogFile];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:kTweakLogFile contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:kTweakLogFile];
    }
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

// v3.6.0：缓存登录不再需要 NSUserDefaults 读取 hook（游戏外直写 16 键已完成），
// 本进程仅保留 sys/boot/VPN/IDFA/广告屏蔽 hook。

// ========================================
//  屏蔽按键精灵(DZZ新版)广告（v3.3 新增）
//  广告结构（frida 实测确认）：
//    UIWindow 直接子视图 = UIView（广告容器）
//      ├─ UIImageView（广告图，内嵌 UIButton 关闭/跳过）
//      └─ UIButton（点击跳转，内嵌 UIImageView 图标）
//  命中 → 隐藏容器 + 隐藏容器所在 window（避免 key window 灰底遮挡主界面）
// ========================================
static BOOL isGameProcess(void) {
    static BOOL sInit = NO, sIsGame = NO;
    if (!sInit) {
        sInit = YES;
        NSString *bn = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        sIsGame = [bn isEqualToString:@"com.gzlj.fishdecisive"];
    }
    return sIsGame;
}

static BOOL isDZZProcess(void) {
    static BOOL sInit = NO, sIsDZZ = NO;
    if (!sInit) {
        sInit = YES;
        NSString *bn = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSString *pn = [[NSProcessInfo processInfo] processName] ?: @"";
        sIsDZZ = [bn isEqualToString:@"com.cyjh.MobileAnjiandjz"] ||
                 [pn isEqualToString:@"DZZ新版"] || [pn isEqualToString:@"MobileAnjiandjz"];
    }
    return sIsDZZ;
}

// 广告容器结构判定（必须是纯 UIView + window 直接子视图 + 2 子视图组合）
static BOOL isAdBannerContainer(UIView *v) {
    if (!v || [v class] != [UIView class]) return NO;
    if (![v.superview isKindOfClass:[UIWindow class]]) return NO;
    NSArray *subs = v.subviews;
    if (subs.count != 2) return NO;
    UIView *v0 = subs[0];
    UIView *v1 = subs[1];
    if (![v0 isKindOfClass:[UIImageView class]] || ![v1 isKindOfClass:[UIButton class]]) return NO;
    BOOL v0HasBtn = NO, v1HasImg = NO;
    for (UIView *s in v0.subviews) {
        if ([s isKindOfClass:[UIButton class]]) { v0HasBtn = YES; break; }
    }
    for (UIView *s in v1.subviews) {
        if ([s isKindOfClass:[UIImageView class]]) { v1HasImg = YES; break; }
    }
    return v0HasBtn && v1HasImg;
}

static void hideDZZAdIfMatch(UIView *v) {
    if (isAdBannerContainer(v)) {
        v.hidden = YES;
        if ([v.superview isKindOfClass:[UIWindow class]]) {
            v.superview.hidden = YES;
        }
        tlog(@"★ 屏蔽按键精灵广告: 容器+window 已隐藏");
        NSLog(@"[FishTweak] 屏蔽按键精灵广告: 容器+window 已隐藏");
    }
}

%hook UIView
- (void)layoutSubviews {
    %orig;
    if (isDZZProcess() && self.window != nil) {
        hideDZZAdIfMatch(self);
    }
}
%end

%hook UIWindow
- (void)layoutSubviews {
    %orig;
    // v3.3.2: 广告容器添加到 window 后 window 必触发 layout，
    // 扫描 window 直接子视图命中广告容器即隐藏（解决容器自身不触发 layoutSubviews 的问题）
    if (isDZZProcess()) {
        for (UIView *sub in self.subviews) {
            hideDZZAdIfMatch(sub);
        }
    }
}
%end

// v3.6.0：缓存登录检查移除（daemon 游戏外直写 16 键 plist + DB 已完成，无需进程内兜底）

%ctor {
    tlog(@"★ 插件已加载 v3.6.0，进程=%@", [[NSProcessInfo processInfo] processName]);
    NSLog(@"[FishTweak] 插件已加载 v3.6.0");
    if (!isGameProcess()) {
        // 非游戏进程（如按键精灵）：仅广告屏蔽等通用 hook 生效，跳过游戏专属逻辑
        tlog(@"非游戏进程(%@)，跳过 sys/boot/VPN 逻辑", [[NSProcessInfo processInfo] processName]);
        return;
    }
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

    // v3.6.0：缓存登录由 daemon 游戏外直写 16 键 plist + DB 完成，本进程不再做兜底检查
}
