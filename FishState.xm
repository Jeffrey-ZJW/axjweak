// FishState.xm
// 捕鱼大决战 只读状态模块（账号 / 金币 / 最大炮倍 / 倍率上限）
// 目标进程：com.gzlj.fishdecisive（进程名「捕鱼大决战」，主二进制 Fuel5）
// 行为：纯被动读取，绝不修改、绝不伪造、绝不发送任何报文
// 依赖：CydiaSubstrate（MSHookFunction）
//
// 编译注意：本文件必须保存为 UTF-8（无 BOM）。中文键名已用 \x 转义，即使编码被改也不会乱码。

#import <Foundation/Foundation.h>
#import <substrate.h>
#import <sys/socket.h>
#import <sys/types.h>
#import <pthread.h>
#import <string.h>
#import <stdio.h>
#import <stdint.h>
#import <unistd.h>
#import <stdlib.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <stdarg.h>

// 本地控制接口（只监听 127.0.0.1，游戏中一个独立线程，一行一条命令）
#define CTRL_PORT 5399

// 单一输出路径（Download 目录，任意 App 都能读）
#define OUT_PATH "/private/var/mobile/Media/Downloads/fish_state.json"

// 炮倍目标值：按键精灵往这个文件里写数字（例如 40000），插件在开炮前把档位对齐
#define CANNON_PATH "/private/var/mobile/Media/Downloads/cannon_target.txt"

// 倍率目标值：往这个文件里写数字（1~倍率上限），插件往 Lua attrs 里塞 id=25
#define RATE_PATH   "/private/var/mobile/Media/Downloads/rate_target.txt"

// 【唯一控制入口】按键精灵读金币后把目标写这里，插件按参数执行并自动夹上限
//   炮倍=30000
//   倍率=8
#define CTRL_PATH   "/private/var/mobile/Media/Downloads/fish_ctrl.txt"

// 热路径只记账不写盘：解析命中次数由 1 秒线程统一打印
static volatile unsigned g_base_hits = 0;
static volatile unsigned g_attr_hits = 0;

// 炮倍对齐：目标档 gap（0 = 不干预），以及命中计数
static volatile int g_target_gap = 0;
static volatile int g_last_fd = -1;      // 业务 socket 的 fd，只在出站包出现 proto.cs_player_by_ 时记录
static volatile int g_target_bet = 0;
static volatile unsigned g_cannon_hits = 0;

// 倍率改写：目标值（0 = 不干预）、是否正在 hook 内（防重入）、写入次数
static volatile int g_target_rate = 0;
static volatile int g_in_rate_hook = 0;
static volatile unsigned g_rate_hits = 0;
static volatile int g_rate_ready = 0;    // lua 符号是否全部找到

// 接口侧设定值（接口优先于配置文件；-1 = 接口未设定）
static volatile int g_api_bet = -1;
static volatile int g_api_rate = -1;
static volatile int g_last_sent = -1;    // 已成功下发的 gap（-1 = 允许重新下发）

// ================= 炮倍档位表 =================
// gap = 27 + 下标，共 23 档
static const int TIERS[23] = {
    3000, 3500, 4000, 4500, 5000, 6000, 7000, 8000, 9000, 10000,
    15000, 20000, 25000, 30000, 35000, 40000, 45000, 50000,
    60000, 70000, 80000, 90000, 100000
};

static int gap_to_bet(int gap) {
    int i = gap - 27;
    if (i >= 0 && i < 23) return TIERS[i];
    return 0; // 未知
}

// 炮倍数值 → 档位 gap（只认 23 档白名单，其它值返回 0 = 不下发）—— 已由 gap_floor 取代，注释保留备查
// static int bet_to_gap(int bet) {
//     int i;
//     for (i = 0; i < 23; i++) if (TIERS[i] == bet) return i + 27;
//     return 0;
// }

// 任意炮倍数值 → 不超过它的最高档 gap（如 32000 → 30000 的档）；低于 3000 返回 0
static int gap_floor(int bet) {
    int i, best = 0;
    if (bet < TIERS[0]) return 0;
    for (i = 0; i < 23; i++) if (TIERS[i] <= bet) best = i + 27;
    return best;
}

// ================= 账号来源 =================
// 只认服务器下发：sc_player_by_base_data 的 f1。
// 不再读本地 CFPreferences(Login_Name)，避免"本地值冒充下发值"。

// ================= 进程判定 + 调试日志 =================
#import <mach-o/dyld.h>
#import <stdarg.h>
#import <time.h>

// 只在游戏进程生效：避免按键精灵等其它被 filter 的进程也写同一个 json
static int is_game_process(void) {
    static int c = -1;
    if (c >= 0) return c;
    char p[1024];
    uint32_t sz = sizeof(p);
    c = 0;
    if (_NSGetExecutablePath(p, &sz) == 0 && strstr(p, "Fuel5.app/Fuel5")) c = 1;
    return c;
}

#define FLOG_PATH "/var/mobile/Library/Preferences/com.jeffrey.fishtweak.tweak.log"

static void flog(const char *fmt, ...) {
    FILE *f = fopen(FLOG_PATH, "a");
    if (!f) return;
    char ts[32];
    time_t t = time(NULL);
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", localtime(&t));
    fprintf(f, "[%s] ", ts);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fflush(f);
    fclose(f);
}

// ================= 全局状态 =================
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_acc = 0;        // 本人 account_id（下发包确认，或本地启动值）
static long long g_coin = 0;      // 金币
static int g_max_gap = 0;         // 个人最高炮倍档
static int g_rate_max = 0;        // 倍率上限

// 协议名首见记录（每个名字只写一次，最多 32 行，日志不会膨胀）
#define NSEEN 64
static char g_seen[NSEEN][44];
static int g_seen_n = 0;

// ===== table_info 时序兜底 =====
// 背景：进渔场的 sc_player_by_table_info 可能早于登录下发的 base_data。
// 旧代码「g_acc 必须已知才收」会把整条丢掉，而且之后不会重来 → 倍率上限永远 0。
// 现在账号未确定时先把各玩家条目按账号缓存，等 base_data 确认本人后回填。
#define PEND_MAX 32
static struct { uint64_t acc; int mg; int rate; } g_pend[PEND_MAX];
static int g_pend_pos = 0;
static int g_pend_n = 0;

static void pend_add(uint64_t acc, int mg, int rate) {
    if (!acc) return;
    int i;
    pthread_mutex_lock(&g_lock);
    for (i = 0; i < g_pend_n; i++) {
        if (g_pend[i].acc == acc) {
            if (mg > 0) g_pend[i].mg = mg;
            if (rate > 0) g_pend[i].rate = rate;
            pthread_mutex_unlock(&g_lock);
            return;
        }
    }
    i = g_pend_pos;
    g_pend[i].acc = acc;
    g_pend[i].mg = mg;
    g_pend[i].rate = rate;
    g_pend_pos = (g_pend_pos + 1) % PEND_MAX;
    if (g_pend_n < PEND_MAX) g_pend_n++;
    pthread_mutex_unlock(&g_lock);
}

// 账号确认后回填。返回 1 = 命中过缓存
static int pend_apply(uint64_t acc) {
    int i, hit = 0;
    if (!acc) return 0;
    pthread_mutex_lock(&g_lock);
    for (i = 0; i < g_pend_n; i++) {
        if (g_pend[i].acc == acc) {
            if (g_pend[i].mg > 0) g_max_gap = g_pend[i].mg;
            if (g_pend[i].rate > 0) g_rate_max = g_pend[i].rate;
            g_pend[i].mg = 0;
            g_pend[i].rate = 0;
            hit = 1;
            break;
        }
    }
    pthread_mutex_unlock(&g_lock);
    return hit;
}

// ================= 写文件 =================
static void write_file(const char *path, const char *s, int len) {
    FILE *f = fopen(path, "w");
    if (!f) return;
    fwrite(s, 1, (size_t)len, f);
    fflush(f);
    fclose(f);
}

static void write_state_locked(void) {
    static char last[192];
    char json[192];
    int n = snprintf(json, sizeof json,
        "{\"\xE8\xB4\xA6\xE5\x8F\xB7\":%llu,"
        "\"\xE9\x87\x91\xE5\xB8\x81\":%lld,"
        "\"\xE6\x9C\x80\xE5\xA4\xA7\xE7\x82\xAE\xE5\x80\x8D\":%d,"
        "\"\xE5\x80\x8D\xE7\x8E\x87\xE4\xB8\x8A\xE9\x99\x90\":%d}",
        (unsigned long long)g_acc,
        g_coin,
        gap_to_bet(g_max_gap),
        g_rate_max);

    if (n <= 0 || n >= (int)sizeof json) return;
    // 内容没变且文件还在 → 不写；
    // 但文件被外部（按键精灵）删掉时必须重建，否则外部会误判"插件没读到数据"
    if (n == (int)strlen(last) && memcmp(json, last, (size_t)n) == 0
        && access(OUT_PATH, F_OK) == 0) return;
    memcpy(last, json, (size_t)n);
    last[n] = 0;

    write_file(OUT_PATH, json, n);   // 只写一处，减少 IO
    NSLog(@"[FishState] %s", json);
}

// ================= protobuf 解析 =================
typedef struct {
    int f;              // field number
    int wt;             // wire type
    uint64_t v;         // wt==0 时的值
    const uint8_t *bs;  // wt==2 时的数据
    size_t bl;
} Fld;

static int rd_varint(const uint8_t *b, size_t n, size_t *p, uint64_t *out) {
    uint64_t v = 0;
    int sh = 0;
    while (*p < n && sh < 64) {
        uint8_t c = b[(*p)++];
        v |= (uint64_t)(c & 0x7f) << sh;
        if (!(c & 0x80)) { *out = v; return 1; }
        sh += 7;
    }
    return 0;
}

// 取下一个字段；注意 tag 本身可能是多字节 varint（如 a0 01 = field20）
static int next_field(const uint8_t *b, size_t n, size_t *p, Fld *o) {
    if (*p >= n) return 0;
    uint64_t tag;
    if (!rd_varint(b, n, p, &tag)) return 0;

    memset(o, 0, sizeof *o);
    o->f  = (int)(tag >> 3);
    o->wt = (int)(tag & 7);

    if (o->wt == 0) {
        uint64_t v;
        if (!rd_varint(b, n, p, &v)) return 0;
        o->v = v;
        return 1;
    }
    if (o->wt == 2) {
        uint64_t l;
        if (!rd_varint(b, n, p, &l)) return 0;
        if (*p + (size_t)l > n) return 0;
        o->bs = b + *p;
        o->bl = (size_t)l;
        *p += (size_t)l;
        return 1;
    }
    if (o->wt == 1) { if (*p + 8 > n) return 0; *p += 8; return 1; }
    if (o->wt == 5) { if (*p + 4 > n) return 0; *p += 4; return 1; }
    return 0;
}

// 从 "[1,2,3,...,9]" 这类字符串里取最大整数
static int max_int_in(const uint8_t *s, size_t n) {
    int mx = 0, cur = 0, has = 0;
    size_t i;
    for (i = 0; i < n; i++) {
        if (s[i] >= '0' && s[i] <= '9') {
            cur = cur * 10 + (s[i] - '0');
            if (cur > 1000) cur = 1000; // 防溢出
            has = 1;
        } else {
            if (has && cur > mx) mx = cur;
            cur = 0;
            has = 0;
        }
    }
    if (has && cur > mx) mx = cur;
    return mx;
}

// ---- sc_player_by_base_data：f1=账号 f6=金币 f9=个人最高炮倍档 ----
static void apply_base(const uint8_t *b, size_t n) {
    uint64_t acc = 0;
    long long coin = -1;
    int mg = -1;
    size_t p = 0;
    Fld f;

    while (next_field(b, n, &p, &f)) {
        if (f.wt != 0) continue;
        if (f.f == 1) acc = f.v;
        else if (f.f == 6) coin = (long long)f.v;
        else if (f.f == 9) mg = (int)f.v;
    }

    pthread_mutex_lock(&g_lock);
    if (acc && acc != g_acc) {
        // 换号：四项全部清零，随后用本包数据填新值
        NSLog(@"[FishState] 换号 %llu -> %llu", (unsigned long long)g_acc, (unsigned long long)acc);
        g_acc = acc;
        g_coin = 0;
        g_max_gap = 0;
        g_rate_max = 0;
    }
    if (coin >= 0) g_coin = coin;
    if (mg > 0) g_max_gap = mg;   // 只更新内存，落盘交给 1 秒线程
    pthread_mutex_unlock(&g_lock);

    // 若 table_info 比本包先到过，用缓存把倍率上限/炮倍档补上（时序兜底）
    if (acc && pend_apply(acc)) {
        flog("[FishState] table_info 早到，已按账号 %llu 回填（炮倍档 %d 倍率上限 %d）",
             (unsigned long long)acc, gap_to_bet(g_max_gap), g_rate_max);
    }

    __atomic_fetch_add(&g_base_hits, 1, __ATOMIC_RELAXED);   // 热路径零 IO，日志由 monitor 打
}

// ---- sc_player_by_table_info：玩家条目内 f1=账号 f5=最高炮倍档 f16=倍率列表 ----
static void apply_table_info(const uint8_t *b, size_t n) {
    size_t p = 0;
    Fld f;
    int found = 0;
    int mg = -1;
    int rate = -1;

    while (next_field(b, n, &p, &f)) {
        if (f.wt != 2) continue;

        size_t q = 0;
        Fld g;
        uint64_t acc = 0;
        int emg = -1;
        int er = -1;

        while (next_field(f.bs, f.bl, &q, &g)) {
            if (g.wt == 0 && g.f == 1) acc = g.v;
            else if (g.wt == 0 && g.f == 5) emg = (int)g.v;
            else if (g.wt == 2 && g.f == 16) er = max_int_in(g.bs, g.bl);
        }

        // 必须认准本人条目：acc 等于已知账号才取
        if (acc && g_acc && acc == g_acc) {
            found = 1;
            if (emg > 0) mg = emg;
            if (er > 0) rate = er;
        } else if (acc && g_acc == 0) {
            pend_add(acc, emg, er);   // 账号还没确定：先缓存，等 base_data 到再回填
        }
    }

    if (!found) return;

    pthread_mutex_lock(&g_lock);
    if (mg > 0) g_max_gap = mg;
    if (rate > 0) g_rate_max = rate;   // 只更新内存
    pthread_mutex_unlock(&g_lock);
}

// ---- sc_player_by_change_attr：外层 f1=账号（必须过滤），内层 {f1=属性id, f2=值} ----
static void apply_change_attr(const uint8_t *b, size_t n) {
    uint64_t acc = 0;
    long long coin = -1;
    size_t p = 0;
    Fld f;

    while (next_field(b, n, &p, &f)) {
        if (f.wt == 0 && f.f == 1) {
            acc = f.v;
        } else if (f.wt == 2) {
            size_t q = 0;
            Fld g;
            int id = -1;
            long long val = 0;
            while (next_field(f.bs, f.bl, &q, &g)) {
                if (g.wt == 0) {
                    if (g.f == 1) id = (int)g.v;
                    else if (g.f == 2) val = (long long)g.v;
                }
            }
            if (id == 1) coin = val;   // 属性 1 = 金币
        }
    }

    if (coin < 0) return;

    __atomic_fetch_add(&g_attr_hits, 1, __ATOMIC_RELAXED);   // 热路径零 IO

    pthread_mutex_lock(&g_lock);
    if (g_acc == 0) {                     // 还不知道本人账号，先不收，避免被别人金币污染
        pthread_mutex_unlock(&g_lock);
        return;
    }
    if (acc && acc != g_acc) {   // 不是本人的包，丢弃
        pthread_mutex_unlock(&g_lock);
        return;
    }
    g_coin = coin;   // 只更新内存
    pthread_mutex_unlock(&g_lock);
}

// ---- 首见协议名只记账不落盘（由 1 秒线程统一打印，热路径零 IO）----
static void record_seen(const uint8_t *name, size_t nlen) {
    if (nlen == 0 || nlen >= 44) return;
    int i;
    for (i = 0; i < g_seen_n; i++) {
        if ((size_t)strlen(g_seen[i]) == nlen && memcmp(g_seen[i], name, nlen) == 0) return;
    }
    if (g_seen_n < NSEEN) {
        memcpy(g_seen[g_seen_n], name, nlen);
        g_seen[g_seen_n][nlen] = 0;
        g_seen_n++;
    }
}

// ---- 协议派发：名字匹配后把子消息交给对应解析器（返回 1 = 命中已知协议）----
static int dispatch_proto(const uint8_t *name, size_t nlen, const uint8_t *sub, size_t subl) {
#define IS(s) (nlen == sizeof(s) - 1 && memcmp(name, s, nlen) == 0)
    if (IS("proto.sc_player_by_base_data")) { apply_base(sub, subl); return 1; }
    if (IS("proto.sc_player_by_table_info")) { apply_table_info(sub, subl); return 1; }
    if (IS("proto.sc_player_by_attr")) { apply_change_attr(sub, subl); return 1; }
    if (IS("proto.sc_player_by_change_attr")) { apply_change_attr(sub, subl); return 1; }
#undef IS
    return 0;
}

// ================= 逐切片扫描 =================
// 【2026-11-18 修正，照最新 frida 实测 fish_export.js handleBuffer 的做法】
// 原实现"拼累积缓冲 + 4 字节帧长对齐"是错的：注入晚于 socket 建立时首包不在帧边界，
// 一旦滑到假帧头（实测撞出 143205 / 358505 的假长度），整段流错位，真 base_data 帧被吃掉。
// frida 从来不做帧对齐，它直接逐字节找：
//   0x0a + 单字节名字长度(6..69) + "proto." 前缀
// 找到后用 0x12 + varint 长度定位子消息；子消息超出本切片时按切片截断解析
// （f1 账号 / f6 金币 / f9 炮倍都在包体前部，截断也拿得到）。
#define DUMPBUF 400000
static uint8_t g_dumpbuf[DUMPBUF];
static volatile int g_dump_ready = 0;
static volatile size_t g_dump_len = 0;

static void scan_proto(const uint8_t *a, size_t n, int fd) {
    size_t k = 0;
    while (k + 6 <= n) {
        if (a[k] != 0x0a) { k++; continue; }
        uint8_t ln = a[k + 1];
        if (ln <= 5 || ln >= 70) { k++; continue; }
        if (k + 8 > n) break;
        if (memcmp(a + k + 2, "proto.", 6) != 0) { k++; continue; }
        if (k + 2 + (size_t)ln > n) break;              // 名字还没到齐，等下一片
        const uint8_t *name = a + k + 2;
        size_t nlen = ln;
        size_t after = k + 2 + nlen;
        record_seen(name, nlen);
        if (after < n && a[after] == 0x12) {
            size_t p = after + 1;
            uint64_t L = 0;
            if (rd_varint(a, n, &p, &L)) {
                size_t avail = n - p;
                size_t sub = (L <= avail) ? (size_t)L : avail;   // 截断而不是整体丢弃
                if (sub > 0 && dispatch_proto(name, nlen, a + p, sub)) {
                    // 下行命中已知协议 → 这个 fd 就是业务 socket（比靠上行前缀猜可靠）
                    if (fd >= 0 && fd != g_last_fd) {
                        g_last_fd = fd;
                        flog("[FD] 业务 socket -> %d（下行命中 %.*s）", fd, (int)nlen, name);
                    }
                }
            }
        }
        // 取证：命中 base_data 就把这一整片原样留下（一次）
        if (nlen == 28 && memcmp(name, "proto.sc_player_by_base_data", 28) == 0
            && n <= DUMPBUF && !g_dump_ready) {
            memcpy(g_dumpbuf, a, n);
            g_dump_len = n;
            g_dump_ready = 1;
        }
        k = after;
    }
}

// 探针：只要原始切片里出现过 base_data 字样就记一次（纯内存，不写盘）
static volatile unsigned g_saw_base_raw = 0;
static volatile unsigned g_max_frame_seen = 0;   // 现在记录的是"最大单次 recv 切片"

static void probe_bytes(const uint8_t *d, size_t n) {
    size_t i;
    for (i = 0; i + 9 <= n; i++) {
        if (memcmp(d + i, "base_data", 9) == 0) {
            __atomic_fetch_add(&g_saw_base_raw, 1, __ATOMIC_RELAXED);
            return;
        }
    }
}

// 每个 recvfrom 切片独立扫描，不拼缓冲、不做帧对齐（与 frida 完全一致）
static void feed(const uint8_t *d, size_t n, int fd) {
    if (n == 0 || n > (1u << 20)) return;
    probe_bytes(d, n);
    if (n > g_max_frame_seen) g_max_frame_seen = (unsigned)n;
    scan_proto(d, n, fd);
}

// ================= 挂钩（热路径零 IO，1 秒统一写盘） =================
// 只挂 recvfrom：recv 是 libsystem 里的超短 syscall 跳转桩，
// MSHookFunction 挂上去会让游戏直接崩，这里绝不挂 recv。
// alen 在 Darwin 上是 socklen_t*（4 字节无符号），不是 size_t*
static ssize_t (*orig_recvfrom)(int, void *, size_t, int, struct sockaddr *, socklen_t *);

static ssize_t my_recvfrom(int s, void *buf, size_t len, int flags,
                           struct sockaddr *addr, socklen_t *alen) {
    ssize_t r = orig_recvfrom(s, buf, len, flags, addr, alen);
    if (r >= 20) feed((const uint8_t *)buf, (size_t)r, s);   // 纯内存解析，不碰磁盘（20 字节以下不可能有协议名）
    return r;
}

// 只为了拿到"游戏真正往外发业务数据那个 socket"。
// 【唯一正确口径，手册 3.1】出站包体里出现 "proto.cs_player_by_" 才算业务 socket。
// 绝不能无条件记 fd —— 心跳/同步包也走 send，记错了 ret 照样 41，但界面不动。
static ssize_t (*orig_send)(int, const void *, size_t, int);

static ssize_t my_send(int fd, const void *buf, size_t len, int flags) {
    if (len >= 20 && len <= 65536) {
        const uint8_t *b = (const uint8_t *)buf;
        size_t i;
        for (i = 0; i + 20 <= len; i++) {
            if (memcmp(b + i, "proto.cs_player_by_", 20) == 0) {
                if (g_last_fd != fd) {
                    g_last_fd = fd;   // 认准业务 socket
                    flog("[FD] 业务 socket -> %d（上行命中，len=%u）", fd, (unsigned)len);
                }
                break;
            }
        }
    }
    return orig_send(fd, buf, len, flags);
}

// ---- 炮倍对齐：游戏自己不发这条 op（打炮时只发 fire），必须插件自造一条 send 出去。
// 【2026-11-17 实测修正】真机抓包发现资料里的模板是错的。点一下炮倍"减号"，游戏自己发出的是：
//   23 00 00 00 0a 1d <"proto.cs_player_by_cannon_opt" 29字节> 12 02 08 04
// 即 39 字节，只有一个字段 08 = 04，没有 10 <gap>。
// 这个 04 不是 gap，是"炮倍档位下标"（0 起，共 23 档；gap = 27 + 下标）。
// 所以 39 字节结构：长度4(23 00 00 00) + 0a 1d + 名字(29) + 12 02 + 08 + <档位下标>
// 偏移 38 = 档位下标(0..22)
// ---- 炮倍对齐：游戏打炮时只发 fire、不发这条 op，必须插件自造一条 send 到业务 socket。
// 【2026-11-18 修正 手册 3.4】真机已验证有效的模板是 41 字节：
//   25 00 00 00 | 0a 1d | "proto.cs_player_by_cannon_opt"(29) | 12 04 | 10 <gap> | 08 02
// offset 38 = gap(27..49)，offset 39 的 08 02 固定不动，绝不能改。
// 之前误按"点减号抓到的 39 字节 12 02 08 04"改过一版，那是错的（那条不是服务器认的切档请求）。
static const uint8_t OP_TPL[41] = {
    0x25, 0x00, 0x00, 0x00,
    0x0a, 0x1d,
    0x70, 0x72, 0x6f, 0x74, 0x6f, 0x2e,                            /* "proto." 6 */
    0x63, 0x73, 0x5f, 0x70, 0x6c, 0x61, 0x79, 0x65, 0x72,           /* "cs_player" 9 */
    0x5f, 0x62, 0x79, 0x5f, 0x63, 0x61, 0x6e, 0x6e, 0x6f, 0x6e,     /* "_by_cannon" 10 */
    0x5f, 0x6f, 0x70, 0x74,                                        /* "_opt" 4 */
    0x12, 0x04,
    0x10, 0x1c,                                    /* gap = 28（运行时替换） */
    0x08, 0x02
};

// 发一条炮倍 op。返回 send 的字节数（41 = 成功）。
// 【2026-11-18 用户口径】不再自动补发/自动锁档：只在 cannon_target.txt 内容变化时发一次，
// 成功后就不再重复。要不要再调，由外部按键精灵改写该文件内容来决定。
static int try_send_cannon(void) {
    int gap = g_target_gap;
    if (gap <= 0 || gap < 27 || gap > 49) return 0;
    if (g_last_fd < 0) {           // 业务 socket 还没认出来：限流提示，不静默
        static time_t lastw = 0;
        time_t now = time(NULL);
        if (now - lastw >= 10) { lastw = now; flog("[CANNON] 跳过：业务 socket 未识别（fd=-1）"); }
        return 0;
    }
    uint8_t pkt[41];
    memcpy(pkt, OP_TPL, sizeof pkt);
    pkt[38] = (uint8_t)gap;                 // 只换 gap 这一个字节
    ssize_t r = orig_send(g_last_fd, pkt, sizeof pkt, 0);   // 走原生 send，不再被自己的钩子二次扫描
    __atomic_fetch_add(&g_cannon_hits, 1, __ATOMIC_RELAXED);
    flog("[CANNON] 发炮倍报文 gap=%d 返回=%ld fd=%d", gap, (long)r, g_last_fd);
    return (r == 41) ? 1 : 0;
}

// ================= 倍率改写：往 Lua attrs 里塞 {id=25, value_int=N} =================
// 依据 frida 实测（fish_switch.js）：hook lua_setfield，key=="attrs"、值是 table、
// 且该 table 的 account_id 等于本人时，往数组槽位 1 追加一条伪造属性 id=25。
// 游戏会把它当成服务器同步值渲染，界面立即变化。
// 硬约束：目标值必须 1..倍率上限(g_rate_max)，超了直接不执行（越界试探 = 封号）。
// 热路径纪律：hook 内绝不写盘、绝不打日志，只记计数器。

static int    (*lua_gettop_)(void *);
static void   (*lua_settop_)(void *, int);
static int    (*lua_type_)(void *, int);
static double (*lua_tonumber_)(void *, int);
static int    (*lua_getfield_)(void *, int, const char *);
static void   (*lua_createtable_)(void *, int, int);
static void   (*lua_pushnumber_)(void *, double);
static void   (*lua_rawseti_)(void *, int, int);
static void   (*lua_setfield_x)(void *, int, const char *);
static void   (*orig_lua_setfield_)(void *, int, const char *);
static void *(*lua_topointer_)(void *, int);

// ===== 金币 Lua 通道（照 frida fish_switch.js 98-116）=====
// 同一个玩家 table 上，游戏会连续 setfield：coin=值、account_id=账号（顺序不定）。
// 两者凑齐且 account_id == 本人 → 认定这是本人的实时金币。
// 比 change_attr 更即时（打炮扣费立刻反映），且不依赖服务器补发。
#define COINSLOT_MAX 64
typedef struct { void *p; long long coin; uint64_t acc; int has_c, has_a, used; } CoinSlot;
static CoinSlot g_cslot[COINSLOT_MAX];
static unsigned g_coin_lua_hits = 0;

static void coin_lua_note(void *L, int idx, const char *k) {
    int is_coin;
    if (k[0] == 'c' && strcmp(k, "coin") == 0) is_coin = 1;
    else if (k[0] == 'a' && strcmp(k, "account_id") == 0) is_coin = 0;
    else return;
    if (lua_type_(L, -1) != 3) return;                       // 只要数字（LUA_TNUMBER）
    long long v = (long long)(lua_tonumber_(L, -1) + 0.5);
    void *p = lua_topointer_(L, idx);                        // 该 table 的身份指针
    if (!p) return;

    int i, slot = -1, vacant = -1;
    for (i = 0; i < COINSLOT_MAX; i++) {
        if (g_cslot[i].used && g_cslot[i].p == p) { slot = i; break; }
        if (vacant < 0 && !g_cslot[i].used) vacant = i;
    }
    if (slot < 0) {
        if (vacant < 0) return;                              // 槽满就放弃，绝不无限增长
        slot = vacant;
        g_cslot[slot].p = p; g_cslot[slot].has_c = 0; g_cslot[slot].has_a = 0;
        g_cslot[slot].used = 1;
    }
    if (is_coin) { g_cslot[slot].coin = v; g_cslot[slot].has_c = 1; }
    else         { g_cslot[slot].acc = (uint64_t)v; g_cslot[slot].has_a = 1; }

    if (g_cslot[slot].has_c && g_cslot[slot].has_a) {
        long long c = g_cslot[slot].coin;
        uint64_t a = g_cslot[slot].acc;
        g_cslot[slot].used = 0;                              // 配对完立即释放槽
        uint64_t me = g_acc;
        if (me && a == me && c >= 0) {
            pthread_mutex_lock(&g_lock);
            if (c != g_coin) {
                g_coin = c;
                __atomic_fetch_add(&g_coin_lua_hits, 1, __ATOMIC_RELAXED);
            }
            pthread_mutex_unlock(&g_lock);
        }
    }
}

static void *find_sym(const char *name) {
    void *p = MSFindSymbol(NULL, name);
    if (p) return p;
    char alt[96];
    snprintf(alt, sizeof alt, "_%s", name);
    return MSFindSymbol(NULL, alt);
}

static void my_lua_setfield(void *L, int idx, const char *k) {
    if (!k) { orig_lua_setfield_(L, idx, k); return; }
    // 金币通道：coin / account_id 配对（只读栈、不压栈，看完照原样放行）
    if (g_rate_ready && lua_topointer_ && (k[0] == 'c' || k[0] == 'a')) {
        coin_lua_note(L, idx, k);
    }
    if (k[0] != 'a' || strcmp(k, "attrs") != 0) {   // 只认 attrs，其余零开销放过
        orig_lua_setfield_(L, idx, k);
        return;
    }
    int tgt = g_target_rate, cap = g_rate_max;
    uint64_t me = g_acc;
    if (!g_rate_ready || g_in_rate_hook || tgt < 1 || cap < 1 || tgt > cap || me == 0
        || lua_type_(L, -1) != 5) {                       // 5 = LUA_TTABLE
        orig_lua_setfield_(L, idx, k);
        return;
    }
    int top = lua_gettop_(L);
    int ai = idx > 0 ? idx : top + idx + 1;
    lua_getfield_(L, ai, "account_id");
    uint64_t owner = (lua_type_(L, -1) == 3) ? (uint64_t)(lua_tonumber_(L, -1) + 0.5) : 0;
    lua_settop_(L, top);                                  // 还原栈，回到干净状态
    if (owner == 0 || owner != me) {                       // 别人的条目（观战/炮台）绝不动
        orig_lua_setfield_(L, idx, k);
        return;
    }
    g_in_rate_hook = 1;
    lua_createtable_(L, 0, 2);
    int ct = lua_gettop_(L);                              // 新表的绝对索引
    lua_pushnumber_(L, 25);
    orig_lua_setfield_(L, ct, "id");
    lua_pushnumber_(L, (double)tgt);
    orig_lua_setfield_(L, ct, "value_int");
    lua_rawseti_(L, top, 1);                              // attrs 的 objlen 恒为 0，写槽位 1 即覆盖生效
    g_in_rate_hook = 0;
    __atomic_fetch_add(&g_rate_hits, 1, __ATOMIC_RELAXED);
    lua_settop_(L, top);
    orig_lua_setfield_(L, idx, k);
}

static void install_rate_hook(void) {
    lua_gettop_      = (int    (*)(void *))                    find_sym("lua_gettop");
    lua_settop_      = (void   (*)(void *, int))               find_sym("lua_settop");
    lua_type_        = (int    (*)(void *, int))               find_sym("lua_type");
    lua_tonumber_    = (double (*)(void *, int))               find_sym("lua_tonumber");
    lua_getfield_    = (int    (*)(void *, int, const char *)) find_sym("lua_getfield");
    lua_createtable_ = (void   (*)(void *, int, int))          find_sym("lua_createtable");
    lua_pushnumber_  = (void   (*)(void *, double))            find_sym("lua_pushnumber");
    lua_rawseti_     = (void   (*)(void *, int, int))          find_sym("lua_rawseti");
    lua_setfield_x    = (void  (*)(void *, int, const char *)) find_sym("lua_setfield");
    lua_topointer_    = (void *(*)(void *, int))               find_sym("lua_topointer");
    if (!lua_gettop_ || !lua_settop_ || !lua_type_ || !lua_tonumber_ || !lua_getfield_
        || !lua_createtable_ || !lua_pushnumber_ || !lua_rawseti_ || !lua_setfield_x) {
        flog("[RATE] lua 符号不全 top=%p settop=%p type=%p tonum=%p getfield=%p ct=%p pushn=%p rawseti=%p setfield=%p",
             lua_gettop_, lua_settop_, lua_type_, lua_tonumber_, lua_getfield_,
             lua_createtable_, lua_pushnumber_, lua_rawseti_, lua_setfield_x);
        return;
    }
    MSHookFunction((void *)lua_setfield_x, (void *)my_lua_setfield, (void **)&orig_lua_setfield_);
    g_rate_ready = 1;
    flog("[RATE] lua_setfield hook 已安装（倍率改写可用）");
    flog("[COIN] lua 金币通道 %s", lua_topointer_ ? "已启用" : "不可用（缺 lua_topointer）");
}

// 1 秒线程：唯一的磁盘写入点，内容没变不写
static void *fish_monitor(void *arg) {    (void)arg;
    int tick = 0;
    int printed = 0;
    time_t last_try = 0;     // 上次尝试时间（失败重试节流）
    while (1) {
        sleep(1);
        tick++;

        // 【接口优先】press 接口命令设定的目标优先；接口没设的字段才去读配置文件兜底。
        //  炮倍=30000      超个人最高炮倍 → 自动夹到上限；非整档值 → 退到不超过它的最近档
        //  倍率=8          超该号倍率上限 → 自动夹到上限；上限还没读到时不动（越界=301）
        {
            int bet = g_api_bet, rate = g_api_rate;
            if (bet < 0 || rate < 0) {
                int fbet = -1, frate = -1;
                FILE *cf = fopen(CTRL_PATH, "r");
                if (cf) {
                    char ln[64];
                    while (fgets(ln, sizeof ln, cf)) {
                        if (!strncmp(ln, "炮倍", 6) || !strncmp(ln, "cannon", 6)) {
                            char *p = strpbrk(ln, "=:");
                            if (p) fbet = atoi(p + 1);
                        } else if (!strncmp(ln, "倍率", 6) || !strncmp(ln, "rate", 4)) {
                            char *p = strpbrk(ln, "=:");
                            if (p) frate = atoi(p + 1);
                        }
                    }
                    fclose(cf);
                }
                if (fbet < 0) {          // 兼容旧入口 cannon_target.txt
                    FILE *f2 = fopen(CANNON_PATH, "r");
                    if (f2) { char b2[32]; if (fgets(b2, sizeof b2, f2)) fbet = atoi(b2); fclose(f2); }
                }
                if (frate < 0) {         // 兼容旧入口 rate_target.txt
                    FILE *f3 = fopen(RATE_PATH, "r");
                    if (f3) { char b3[32]; if (fgets(b3, sizeof b3, f3)) frate = atoi(b3); fclose(f3); }
                }
                if (bet < 0) bet = fbet;
                if (rate < 0) rate = frate;
            }

            // ---- 炮倍：先退到不超过目标的最近档，再夹到个人最高档 ----
            if (bet > 0) {
                int gap = gap_floor(bet);
                int cap = g_max_gap;
                if (gap > 0 && cap > 0 && gap > cap) gap = cap;    // 超上限 → 用上限
                g_target_gap = gap;
                g_target_bet = gap ? gap_to_bet(gap) : 0;
            } else {
                g_target_gap = 0;
                g_target_bet = 0;
            }

            // ---- 倍率：夹到该号上限（上限未知就不下发，避免 301）----
            if (rate >= 1 && g_rate_max >= 1) {
                int r = rate > g_rate_max ? g_rate_max : rate;
                g_target_rate = r;
            } else {
                g_target_rate = 0;
            }
        }
        // 【用户口径】只在新目标出现时下发一次，成功后不再重复补发。
        // 接口命令会当场发一条并记账；这里只兜住"文件入口写法"和"发送失败后的重试"。
        if (g_target_gap > 0) {
            if (g_target_gap != g_last_sent) {
                time_t now = time(NULL);
                if (now - last_try >= 3) {      // 失败（fd 未就绪等）每 3 秒重试，不刷屏
                    last_try = now;
                    if (try_send_cannon() == 1) g_last_sent = g_target_gap;
                }
            }
        } else {
            g_last_sent = -1;                   // 目标清空，允许下次重新下发
        }

        while (printed < g_seen_n) {   // 首见协议名补打，最多 32 行
            flog("[FishState] 首见 %s", g_seen[printed]);
            printed++;
        }

        {   // 解析命中计数（热路径只记账，这里统一落盘；不变就不打）
            static unsigned lb = 0, la = 0, lc = 0, lr = 0, lp = 0, lf = 0, lcl = 0;
            unsigned nb = g_base_hits, na = g_attr_hits, nc = g_cannon_hits, nr = g_rate_hits;
            unsigned np_ = g_saw_base_raw, nf = g_max_frame_seen, ncl = g_coin_lua_hits;
            if (nb != lb) { flog("[FishState] BASE 命中 %u 次", nb); lb = nb; }
            if (na != la) { flog("[FishState] ATTR 命中 %u 次", na); la = na; }
            if (ncl != lcl) { flog("[COIN] lua 实时金币 %lld（第 %u 次）", g_coin, ncl); lcl = ncl; }
            if (nc != lc) { flog("[FishState] 炮倍已对齐 %u 次 (目标 %d)", nc, g_target_bet); lc = nc; }
            if (nr != lr) { flog("[RATE] 倍率已写入 %u 次 (目标 %d 上限 %d)", nr, g_target_rate, g_rate_max); lr = nr; }
            if (np_ != lp) { flog("[PROBE] 原始字节出现 base_data %u 次", np_); lp = np_; }
            if (nf > lf) { flog("[PROBE] 最大单次 recv 切片 %u 字节", nf); lf = nf; }
        }

        // 大帧取证落盘（一次性）
        if (g_dump_ready) {
            static int dump_done = 0;
            if (!dump_done) {
                const char *dp = "/private/var/mobile/Media/Downloads/base_dump.bin";
                FILE *fp = fopen(dp, "wb");
                if (fp) {
                    fwrite(g_dumpbuf, 1, g_dump_len, fp);
                    fclose(fp);
                    flog("[DUMPB] 大帧已落盘 %u 字节 -> %s", (unsigned)g_dump_len, dp);
                } else {
                    flog("[DUMPB] 写大帧失败 %s", dp);
                }
                dump_done = 1;
            }
        }

        if (tick % 30 == 0) {          // 每 30 秒把"账号是否已由下发包确认"落一次日志，不做本地核对
            static unsigned long long lacc = 0;
            if (g_acc != lacc) {
                flog("[FishState] 账号已由下发包确认 = %llu", (unsigned long long)g_acc);
                lacc = g_acc;
            }
        }
        pthread_mutex_lock(&g_lock);
        write_state_locked();
        pthread_mutex_unlock(&g_lock);
    }
    return NULL;
}

// ================= 本地控制接口（127.0.0.1:5399）=================
// 协议：一行一条命令，回一行结果；连接即用即关，不做长连接。
//   ping            → pong
//   data            → 当前四项（json 一行）
//   state           → 当前目标值（接口/文件生效后的实际值）
//   cannon <n>      → 立即下发炮倍（自动退档 + 夹个人上限），回 ok/err
//   rate <n>        → 设定倍率（自动夹该号上限），回 ok/err
//   clear           → 清空两个目标，停止一切干预
// 热路径无影响：独立线程，只在自己的 accept/read 上阻塞。
static void ctrl_write(int cfd, const char *fmt, ...) {
    char b[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(b, sizeof b, fmt, ap);
    va_end(ap);
    ssize_t r = write(cfd, b, strlen(b));
    (void)r;
}

static void ctrl_handle(char *ln, int cfd) {
    char *e;
    while (*ln == ' ' || *ln == '\t') ln++;
    e = ln + strlen(ln);
    while (e > ln && (e[-1] == '\n' || e[-1] == '\r' || e[-1] == ' ')) *--e = 0;
    if (!*ln) return;

    if (!strcmp(ln, "ping")) { ctrl_write(cfd, "pong\n"); return; }

    if (!strcmp(ln, "data")) {
        ctrl_write(cfd, "{\"账号\":%llu,\"金币\":%lld,\"最大炮倍\":%d,\"倍率上限\":%d}\n",
                   (unsigned long long)g_acc, (long long)g_coin, gap_to_bet(g_max_gap), g_rate_max);
        return;
    }

    if (!strcmp(ln, "state")) {
        ctrl_write(cfd, "target_bet=%d target_gap=%d target_rate=%d last_sent=%d rate_max=%d max_bet=%d\n",
                   g_target_bet, g_target_gap, g_target_rate, g_last_sent, g_rate_max, gap_to_bet(g_max_gap));
        return;
    }

    if (!strcmp(ln, "clear")) {
        g_api_bet = -1; g_api_rate = -1;
        g_target_gap = 0; g_target_bet = 0; g_target_rate = 0; g_last_sent = -1;
        ctrl_write(cfd, "ok cleared\n");
        return;
    }

    if (!strncmp(ln, "cannon", 6)) {
        int bet = atoi(ln + 6);
        int gap = gap_floor(bet);
        int cap = g_max_gap;
        if (gap <= 0) { ctrl_write(cfd, "err range（低于 %d 或非数值）\n", TIERS[0]); return; }
        if (cap > 0 && gap > cap) gap = cap;        // 超个人最高炮倍 → 用上限
        g_api_bet = gap_to_bet(gap);
        g_target_gap = gap;
        g_target_bet = gap_to_bet(gap);
        int r = try_send_cannon();
        if (r == 1) g_last_sent = gap;
        if (r == 1) ctrl_write(cfd, "ok gap=%d bet=%d\n", gap, g_target_bet);
        else        ctrl_write(cfd, "err send（fd=%d，业务 socket 还没认出来）\n", g_last_fd);
        return;
    }

    if (!strncmp(ln, "rate", 4)) {
        int r = atoi(ln + 4);
        if (r < 1) { ctrl_write(cfd, "err range（倍率至少 1）\n"); return; }
        if (g_rate_max < 1) { ctrl_write(cfd, "err no_cap（该号倍率上限还没读到，进渔场后再试）\n"); return; }
        if (r > g_rate_max) r = g_rate_max;         // 超上限 → 用上限
        g_api_rate = r;
        g_target_rate = r;
        ctrl_write(cfd, "ok rate=%d (cap=%d)\n", r, g_rate_max);
        return;
    }

    ctrl_write(cfd, "err unknown（支持 ping/data/state/cannon/rate/clear）\n");
}

static void *fish_ctrl_server(void *arg) {
    (void)arg;
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) { flog("[CTRL] socket 创建失败"); return NULL; }
    int on = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons(CTRL_PORT);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);      // 只听回环，外部网络进不来
    if (bind(s, (struct sockaddr *)&a, sizeof a) < 0) {
        flog("[CTRL] bind 127.0.0.1:%d 失败（端口被占？）", CTRL_PORT);
        close(s);
        return NULL;
    }
    if (listen(s, 8) < 0) {
        flog("[CTRL] listen 失败");
        close(s);
        return NULL;
    }
    flog("[CTRL] 接口已就绪 127.0.0.1:%d", CTRL_PORT);
    while (1) {
        int c = accept(s, NULL, NULL);
        if (c < 0) continue;
        struct timeval tv = { 2, 0 };                 // 客户端不写就 2 秒放弃，绝不吊死线程
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        char buf[256];
        ssize_t n = read(c, buf, sizeof buf - 1);
        if (n > 0) {
            buf[n] = 0;
            ctrl_handle(buf, c);
        }
        close(c);
    }
    return NULL;
}

%ctor {
    if (!is_game_process()) return;   // 按键精灵等其它进程不碰这个文件
    pthread_mutex_lock(&g_lock);
    g_acc = 0;                        // 账号只等 sc_player_by_base_data 的 f1，不从本地读
    pthread_mutex_unlock(&g_lock);

    write_state_locked();             // 启动即写一份，保证文件存在
    flog("[FishState] armed, out=%s, acc=%llu", OUT_PATH, (unsigned long long)g_acc);
    pthread_t th;
    if (pthread_create(&th, NULL, fish_monitor, NULL) == 0) pthread_detach(th);

    // 本地控制接口线程（注入后即可用；端口被占只影响接口，不影响插件本身）
    pthread_t cth;
    if (pthread_create(&cth, NULL, fish_ctrl_server, NULL) == 0) pthread_detach(cth);

    // 关键：不要在这里立刻 hook。
    // cynject 是在游戏运行中 dlopen 本 dylib，此时游戏的网络线程可能正在执行 recvfrom，
    // 当场 patch 全局函数会和执行中的指令撞车，表现为"点登录进不去"。
    // 延后 2 秒（用户还没来得及点登录）再 patch，避开设完钩子的竞态窗口。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        MSHookFunction((void *)recvfrom, (void *)my_recvfrom, (void **)&orig_recvfrom);
        MSHookFunction((void *)send, (void *)my_send, (void **)&orig_send);
        flog("[FishState] hook 已安装 (recvfrom + send)");
        install_rate_hook();      // 倍率改写（hook lua_setfield）
    });
}
