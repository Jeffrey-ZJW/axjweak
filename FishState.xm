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

// 单一输出路径（Download 目录，任意 App 都能读）
#define OUT_PATH "/private/var/mobile/Media/Downloads/fish_state.json"

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
static uint64_t g_acc = 0;        // 本人 account_id
static long long g_coin = 0;      // 金币
static int g_max_gap = 0;         // 个人最高炮倍档
static int g_rate_max = 0;        // 倍率上限

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
    if (n == (int)strlen(last) && memcmp(json, last, (size_t)n) == 0) return; // 没变化不重复写
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
    if (mg > 0) g_max_gap = mg;
    write_state_locked();
    pthread_mutex_unlock(&g_lock);
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

        // 必须认准本人条目：acc 等于已知账号才取（g_acc==0 时跳过，避免抓到别人）
        if (acc && g_acc && acc == g_acc) {
            found = 1;
            if (emg > 0) mg = emg;
            if (er > 0) rate = er;
        }
    }

    if (!found) return;

    pthread_mutex_lock(&g_lock);
    if (mg > 0) g_max_gap = mg;
    if (rate > 0) g_rate_max = rate;
    write_state_locked();
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

    pthread_mutex_lock(&g_lock);
    if (acc && g_acc && acc != g_acc) {   // 不是本人的包，丢弃
        pthread_mutex_unlock(&g_lock);
        return;
    }
    g_coin = coin;
    write_state_locked();
    pthread_mutex_unlock(&g_lock);
}

// ---- 单帧解析：4字节大端长度 + 0a协议名 + 12子消息 ----
static void parse_frame(const uint8_t *fr, size_t total) {
    if (total < 8) return;
    size_t p = 4;
    if (fr[p] != 0x0a) return;
    p++;

    uint64_t nl;
    if (!rd_varint(fr, total, &p, &nl)) return;
    if (p + (size_t)nl > total) return;
    const uint8_t *name = fr + p;
    size_t nlen = (size_t)nl;
    p += nlen;

    if (p >= total || fr[p] != 0x12) return;
    p++;
    uint64_t sl;
    if (!rd_varint(fr, total, &p, &sl)) return;
    if (p + (size_t)sl > total) return;

    const uint8_t *sub = fr + p;
    size_t subl = (size_t)sl;

#define IS(s) (nlen == sizeof(s) - 1 && memcmp(name, s, nlen) == 0)
    if (IS("proto.sc_player_by_base_data")) { flog("[FishState] HIT base len=%zu", nlen); apply_base(sub, subl); }
    else if (IS("proto.sc_player_by_table_info")) { flog("[FishState] HIT table len=%zu", nlen); apply_table_info(sub, subl); }
    else if (IS("proto.sc_player_by_change_attr")) { flog("[FishState] HIT attr len=%zu", nlen); apply_change_attr(sub, subl); }
#undef IS
}

// ---- 累积缓冲：处理一次 recvfrom 带多条报文、或一条报文被切开 ----
#define ACCBUF (1 << 17)
static uint8_t g_buf[ACCBUF];
static size_t g_len = 0;
static pthread_mutex_t g_buf_lock = PTHREAD_MUTEX_INITIALIZER;

static void feed(const uint8_t *d, size_t n) {
    if (n == 0 || n > ACCBUF) return;
    pthread_mutex_lock(&g_buf_lock);

    if (g_len + n > ACCBUF) g_len = 0; // 极端情况丢弃旧数据
    memcpy(g_buf + g_len, d, n);
    g_len += n;

    size_t off = 0;
    while (g_len - off >= 4) {
        uint32_t tl = ((uint32_t)g_buf[off] << 24) | ((uint32_t)g_buf[off + 1] << 16)
                    | ((uint32_t)g_buf[off + 2] << 8) | (uint32_t)g_buf[off + 3];
        if (tl == 0 || tl > 60000) { off += 1; continue; }  // 帧头不可信则滑动
        size_t total = (size_t)tl + 4;
        if (off + total > g_len) break;                     // 数据还没到齐，等下一次
        if (g_buf[off + 4] == 0x0a) parse_frame(g_buf + off, total);
        off += total;
    }
    if (off) {
        memmove(g_buf, g_buf + off, g_len - off);
        g_len -= off;
    }
    pthread_mutex_unlock(&g_buf_lock);
}

// ================= 挂钩 =================
// 收包只走 recvfrom（recv 抓不到任何数据，已实测）
// alen 在 Darwin 上是 socklen_t*（4 字节无符号），不是 size_t*
static ssize_t (*orig_recvfrom)(int, void *, size_t, int, struct sockaddr *, socklen_t *);
static ssize_t (*orig_recv)(int, void *, size_t, int);
static int g_n_rf = 0, g_n_rv = 0;

static ssize_t my_recvfrom(int s, void *buf, size_t len, int flags,
                           struct sockaddr *addr, socklen_t *alen) {
    ssize_t r = orig_recvfrom(s, buf, len, flags, addr, alen);
    if (r > 0) {
        int c = __sync_add_and_fetch(&g_n_rf, 1);
        if (c <= 30 || c % 300 == 0) flog("[FishState] recvfrom #%d r=%zd", c, (ssize_t)r);
        feed((const uint8_t *)buf, (size_t)r);
    }
    return r;
}

static ssize_t my_recv(int s, void *buf, size_t len, int flags) {
    ssize_t r = orig_recv(s, buf, len, flags);
    if (r > 0) {
        int c = __sync_add_and_fetch(&g_n_rv, 1);
        if (c <= 30 || c % 300 == 0) flog("[FishState] recv #%d r=%zd", c, (ssize_t)r);
        feed((const uint8_t *)buf, (size_t)r);
    }
    return r;
}

%ctor {
    if (!is_game_process()) return;
    MSHookFunction((void *)recvfrom, (void *)my_recvfrom, (void **)&orig_recvfrom);
    MSHookFunction((void *)recv, (void *)my_recv, (void **)&orig_recv);
    write_state_locked();   // 启动即写一份全 0，保证文件存在
    flog("[FishState] armed, out=%s", OUT_PATH);
    NSLog(@"[FishState] armed, out=%s", OUT_PATH);
}
