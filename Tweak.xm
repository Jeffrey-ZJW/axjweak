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
// 缓存登录模块前置声明（HTTP 已迁 daemon，本进程仅保留文件通道所需）
static NSDictionary *loadPendingAccount(void);
static BOOL userInfoHasOpenId(NSString *openId);
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
//  缓存登录（v3.0 新增）—— 免验证码进服
//  流程：按键精灵 POST /set_account 传入账号参数（落盘持久化）
//        → 每次游戏启动后 2.5s 做一次检查：
//        → user_info 已有缓存记录 → 不介入，游戏自动跑缓存登录（过期会自动 refresh）
//        → 无缓存记录 → 用待注入参数写 defaults + user_info 制造缓存
//  写入公式与 frida V18(defaults)/V21(user_info) 实证完全一致：
//    defaults: Login_OpenId=openid / Login_Name=appid / GameLastAccountId=appid
//              LastLoginType=3 / LastIDAccount=phone / LastPwdAccount=password(md5)
//    user_info: loginTime=1 / expires_in=1 → 游戏必判过期 → 强制 refresh 换新 token
// ========================================
// ========================================
//  缓存登录（v3.1 新增）—— 免验证码进服（文件通道版）
//  流程：daemon(fishtweakd) 常驻 8888 收号 → 写参数文件
//        → 按键精灵传号后 daemon 自动拉起游戏
//        → 游戏启动后 2.5s 做一次检查：
//        → user_info 已有缓存记录 → 不介入，游戏自动跑缓存登录（过期会自动 refresh）
//        → 无缓存记录 → 读参数文件写 defaults + user_info 制造缓存 → 删参数文件
//  写入公式与 frida V18(defaults)/V21(user_info) 实证完全一致：
//    defaults: Login_OpenId=openid / Login_Name=appid / GameLastAccountId=appid
//              LastLoginType=3 / LastIDAccount=phone / LastPwdAccount=password(md5)
//    user_info: loginTime=1 / expires_in=1 → 游戏必判过期 → 强制 refresh 换新 token
// ========================================
// 与 daemon(fishtweakd) 约定共享的固定路径
static NSString *const kAccountFile = @"/var/mobile/Library/Preferences/com.jeffrey.fishtweak.account.plist";  // daemon 写 / tweak 读
static NSString *const kStatusFile  = @"/var/mobile/Library/Preferences/com.jeffrey.fishtweak.status.plist";   // tweak 写 / daemon 读

static NSDictionary *loadPendingAccount(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kAccountFile];
    if (!d || ![d[@"openid"] length] || ![d[@"refresh"] length]) return nil;
    return d;
}

static void clearPendingAccount(void) {
    [[NSFileManager defaultManager] removeItemAtPath:kAccountFile error:NULL];
    NSLog(@"[CacheLogin] 参数文件已删除");
}

// 状态写盘（daemon 的 /status 接口读取，按键精灵据此判断是否传号）
static void writeStatus(NSString *curOpenId, BOOL hasCache) {
    NSDictionary *s = @{@"has_cache": @(hasCache), @"cache_openid": curOpenId ?: @""};
    [s writeToFile:kStatusFile atomically:YES];
}

static NSString *cacheDbPath(void) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/AnaestheticsYachtsman/zs_data.sqlite"] stringByStandardizingPath];
}

// user_info 是否存在该 openId 记录（有无缓存 = 以此为准）
static BOOL userInfoHasOpenId(NSString *openId) {
    if (!openId || openId.length == 0) return NO;
    sqlite3 *db = NULL;
    if (sqlite3_open([cacheDbPath() UTF8String], &db) != SQLITE_OK) {
        NSLog(@"[CacheLogin] sqlite3_open 失败: %s", sqlite3_errmsg(db));
        if (db) sqlite3_close(db);
        return NO;
    }
    const char *sql = "SELECT COUNT(*) FROM user_info WHERE openId=?;";
    sqlite3_stmt *stmt = NULL;
    BOOL found = NO;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, [openId UTF8String], -1, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            found = (sqlite3_column_int(stmt, 0) > 0);
        }
    }
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return found;
}

// user_info 表是否已有任意缓存账号（防止"二次启动/无 pending"时仍被首启判定拦截）
static BOOL hasAnyCachedAccount(void) {
    sqlite3 *db = NULL;
    if (sqlite3_open([cacheDbPath() UTF8String], &db) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return NO;
    }
    const char *sql = "SELECT COUNT(*) FROM user_info;";
    sqlite3_stmt *stmt = NULL;
    BOOL found = NO;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            found = (sqlite3_column_int(stmt, 0) > 0);
        }
    }
    sqlite3_finalize(stmt);
    sqlite3_close(db);
    return found;
}

// 写游戏域 defaults（登录页显示名 = "玩家"+appid，nickName 保持"用户XXXX"由 user_info 决定）
// v3.2: 补齐 ZSFirstStartupLaunchTime(当前时间戳) + Login_Agree(1) —— 未初始化环境直接骗过"首启判定"
static void writeLoginDefaults(NSDictionary *acct) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:acct[@"openid"] forKey:@"Login_OpenId"];
    [ud setObject:[NSString stringWithFormat:@"玩家%@", acct[@"appid"]] forKey:@"Login_Name"];
    [ud setObject:acct[@"appid"] forKey:@"GameLastAccountId"];
    [ud setInteger:3 forKey:@"LastLoginType"];
    NSString *lastId = acct[@"phone"];
    if (!lastId || lastId.length == 0) lastId = acct[@"account"];
    [ud setObject:lastId forKey:@"LastIDAccount"];
    [ud setObject:acct[@"password"] forKey:@"LastPwdAccount"];
    [ud setObject:@((long long)[[NSDate date] timeIntervalSince1970]) forKey:@"ZSFirstStartupLaunchTime"];
    [ud setObject:@1 forKey:@"Login_Agree"];
    [ud synchronize];
    NSLog(@"[CacheLogin] defaults 已写回(玩家%@/%@)", acct[@"appid"], lastId);
}

// 写 user_info（loginTime=1/expires_in=1 → 游戏必判过期 → refresh 换新 token）
static void writeUserInfo(NSDictionary *acct) {
    sqlite3 *db = NULL;
    if (sqlite3_open([cacheDbPath() UTF8String], &db) != SQLITE_OK) {
        NSLog(@"[CacheLogin] sqlite3_open 失败: %s", sqlite3_errmsg(db));
        if (db) sqlite3_close(db);
        return;
    }
    const char *createSql = "CREATE TABLE IF NOT EXISTS user_info(openId varchar(100) PRIMARY KEY NOT NULL,token TEXT NOT NULL,refreshToken TEXT NOT NULL,tokenType int NOT NULL,mobile varchar(50),nickName varchar(100),loginTime INTEGER NOT NULL,account varchar(100),password varchar(100),expires_in INTEGER NOT NULL,thirdUserId TEXT);";
    sqlite3_exec(db, createSql, NULL, NULL, NULL);
    // nickname 含特殊字符时转义单引号（其余字段为 Base64/数字/md5，无单引号）
    NSString *nick = [acct[@"nickname"] stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
    NSString *sql = [NSString stringWithFormat:
        @"INSERT OR REPLACE INTO user_info(openId,token,refreshToken,tokenType,mobile,nickName,loginTime,account,password,expires_in,thirdUserId) VALUES('%@','%@','%@',2,'%@','%@',1,'%@','%@',1,NULL);",
        acct[@"openid"], acct[@"token"], acct[@"refresh"], acct[@"phone"], nick, acct[@"phone"], acct[@"password"]];
    char *err = NULL;
    int rc = sqlite3_exec(db, [sql UTF8String], NULL, NULL, &err);
    if (rc != SQLITE_OK) {
        NSLog(@"[CacheLogin] user_info 写入失败 rc=%d err=%s", rc, err ? err : "");
        sqlite3_free(err);
    } else {
        NSLog(@"[CacheLogin] ★ user_info 缓存账号已写入(%@/%@)", acct[@"appid"], acct[@"phone"]);
    }
    sqlite3_close(db);
}

// 制造缓存登录（defaults + user_info 一次到位，随后清除待注入参数）
static void makeCacheLogin(NSDictionary *acct) {
    writeLoginDefaults(acct);
    writeUserInfo(acct);
    clearPendingAccount();
    NSLog(@"[CacheLogin] ★ 缓存登录已制造 appid=%@", acct[@"appid"]);
}

// ========================================
//  v3.2 新增：NSUserDefaults 读取 hook（frida 实证方案，任何环境/时机都显示缓存）
//  有待注入账号参数时（参数文件存在）：
//    ZSFirstStartupLaunchTime → 当前时间戳（骗过"首次启动"判定，未初始化环境直出缓存）
//    Login_Agree → 1 / LastLoginType → 3
//    Login_OpenId / Login_Name("玩家"+appid) / GameLastAccountId / LastIDAccount / LastPwdAccount → 目标值
//  无参数文件时全部走原实现（零干扰）
// ========================================
// ========================================
// 判断是否是缓存登录相关键（非相关键零开销直通，避免每次读参数文件）
static BOOL isLoginRelatedKey(NSString *k) {
    if (!k || k.length == 0) return NO;
    return [k isEqualToString:@"Login_OpenId"] || [k isEqualToString:@"Login_Name"] ||
           [k isEqualToString:@"GameLastAccountId"] || [k isEqualToString:@"LastIDAccount"] ||
           [k isEqualToString:@"LastPwdAccount"] || [k isEqualToString:@"ZSFirstStartupLaunchTime"] ||
           [k isEqualToString:@"Login_Agree"] || [k isEqualToString:@"LastLoginType"];
}

// v3.2.1 统一拦截：返回非 nil 表示本次读取应被替换（nil = 走 %orig 原实现）
//  - ZSFirstStartupLaunchTime：pending 在 或 user_info 已有缓存 → 返回当前时间戳（骗过"首次启动"判定）
//  - Login_OpenId：pending 在 → 立即制造缓存（不再等 2.5s），返回 openid；后续键直接读已写入的真实值
//  - Login_Name / GameLastAccountId / LastIDAccount / LastPwdAccount / Login_Agree / LastLoginType → 目标值
static id overrideLoginValueForKey(NSString *k) {
    if (!isLoginRelatedKey(k)) return nil;
    @try {
        NSDictionary *pending = loadPendingAccount();
        if ([k isEqualToString:@"ZSFirstStartupLaunchTime"]) {
            if (pending || hasAnyCachedAccount()) {
                return @((long long)[[NSDate date] timeIntervalSince1970]);
            }
            return nil;
        }
        if (!pending) return nil;
        if ([k isEqualToString:@"Login_OpenId"]) {
            makeCacheLogin(pending);   // 首读到账号键 → 立即写 defaults+user_info 并清参数文件
            return pending[@"openid"] ?: @"";
        } else if ([k isEqualToString:@"Login_Name"]) {
            NSString *appid = pending[@"appid"];
            if (appid && appid.length > 0) return [NSString stringWithFormat:@"玩家%@", appid];
        } else if ([k isEqualToString:@"GameLastAccountId"]) {
            return pending[@"appid"] ?: nil;
        } else if ([k isEqualToString:@"LastIDAccount"]) {
            NSString *ph = pending[@"phone"];
            if (!ph || ph.length == 0) ph = pending[@"account"];
            return ph ?: nil;
        } else if ([k isEqualToString:@"LastPwdAccount"]) {
            return pending[@"password"] ?: nil;
        } else if ([k isEqualToString:@"Login_Agree"]) {
            return @1;
        } else if ([k isEqualToString:@"LastLoginType"]) {
            return @3;
        }
    } @catch (NSException *e) {}
    return nil;
}

%hook NSUserDefaults
- (id)objectForKey:(NSString *)defaultName {
    id v = %orig;
    id ov = overrideLoginValueForKey(defaultName ?: @"");
    return ov ? ov : v;
}
- (NSString *)stringForKey:(NSString *)defaultName {
    NSString *v = %orig;
    id ov = overrideLoginValueForKey(defaultName ?: @"");
    if (!ov) return v;
    if ([ov isKindOfClass:[NSString class]]) return ov;
    if ([ov isKindOfClass:[NSNumber class]]) return [ov stringValue];
    return v;
}
- (NSInteger)integerForKey:(NSString *)defaultName {
    NSInteger v = %orig;
    id ov = overrideLoginValueForKey(defaultName ?: @"");
    if (!ov) return v;
    if ([ov isKindOfClass:[NSNumber class]]) return [ov integerValue];
    if ([ov isKindOfClass:[NSString class]]) return [ov integerValue];
    return v;
}
- (BOOL)boolForKey:(NSString *)defaultName {
    BOOL v = %orig;
    id ov = overrideLoginValueForKey(defaultName ?: @"");
    if (!ov) return v;
    if ([ov isKindOfClass:[NSNumber class]]) return [ov boolValue];
    return v;
}
- (double)doubleForKey:(NSString *)defaultName {
    double v = %orig;
    id ov = overrideLoginValueForKey(defaultName ?: @"");
    if (!ov) return v;
    if ([ov isKindOfClass:[NSNumber class]]) return [ov doubleValue];
    if ([ov isKindOfClass:[NSString class]]) return [ov doubleValue];
    return v;
}
- (NSArray *)arrayForKey:(NSString *)defaultName {
    NSArray *v = %orig;
    id ov = overrideLoginValueForKey(defaultName ?: @"");
    return ov ? ov : v;
}
- (NSDictionary *)dictionaryForKey:(NSString *)defaultName {
    NSDictionary *v = %orig;
    id ov = overrideLoginValueForKey(defaultName ?: @"");
    return ov ? ov : v;
}
- (NSData *)dataForKey:(NSString *)defaultName {
    NSData *v = %orig;
    id ov = overrideLoginValueForKey(defaultName ?: @"");
    return ov ? ov : v;
}
- (NSURL *)URLForKey:(NSString *)defaultName {
    NSURL *v = %orig;
    id ov = overrideLoginValueForKey(defaultName ?: @"");
    return ov ? ov : v;
}
%end

// 启动检查：有缓存(user_info 有记录) → 不介入；无缓存 → 有参数则制造；状态写盘供 daemon 查询
static void cacheLoginCheck(void) {
    @try {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        NSString *curOpenId = [ud stringForKey:@"Login_OpenId"];
        if (curOpenId && curOpenId.length > 0 && userInfoHasOpenId(curOpenId)) {
            NSLog(@"[CacheLogin] 已有缓存账号(%@)，不介入，游戏自动缓存登录", curOpenId);
            writeStatus(curOpenId, YES);
            return;
        }
        NSDictionary *pending = loadPendingAccount();
        if (!pending) {
            NSLog(@"[CacheLogin] 无缓存且无待注入账号，跳过");
            writeStatus(curOpenId, NO);
            return;
        }
        if (userInfoHasOpenId(pending[@"openid"])) {
            NSLog(@"[CacheLogin] 待注入账号 %@ 已有缓存记录，不重复制造", pending[@"openid"]);
            writeStatus(pending[@"openid"], YES);
            return;
        }
        makeCacheLogin(pending);
        writeStatus(pending[@"openid"], YES);
    } @catch (NSException *e) {
        NSLog(@"[CacheLogin] 异常: %@", e);
    }
}

%ctor {
    NSLog(@"[FishTweak] 插件已加载 v3.2.0");
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

    // v3.1: 启动 1.2s 后兜底检查缓存登录（HTTP 已迁 daemon，本进程只做读文件/制造/状态写盘）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        cacheLoginCheck();
    });
}
