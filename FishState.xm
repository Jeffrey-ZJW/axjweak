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
static volatile int g_hit = 0;    // 命中已知协议的帧数（热路径只自增）

// 命中帧快照（诊断用：抓一帧完整的命中报文，交给 1 秒线程打印）
static uint8_t g_hb[240];
static volatile size_t g_hbn = 0;
static volatile int g_hbf = 0;

// 协议名统计表：把收到的所有不同协议名记下来（诊断用，最多 20 个）
#define NNAMES 20
static char g_nm[NNAMES][40];
static int g_nmc[NNAMES];
static volatile int g_nmn = 0;

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
    if (mg > 0) g_max_gap = mg;   // 只更新内存，落盘交给 1 秒线程
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

    pthread_mutex_lock(&g_lock);
    if (acc && g_acc && acc != g_acc) {   // 不是本人的包，丢弃
        pthread_mutex_unlock(&g_lock);
        return;
    }
    g_coin = coin;   // 只更新内存
    pthread_mutex_unlock(&g_lock);
}

// ---- 命中帧快照：只做一次 memcpy，不碰磁盘 ----
static void snap(const uint8_t *fr, size_t total) {
    if (g_hbf) return;
    size_t k = total > sizeof(g_hb) ? sizeof(g_hb) : total;
    memcpy(g_hb, fr, k);
    g_hbn = k;
    g_hbf = 1;
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

    // 记账：这个名字见过几次（只统计，不落盘）
    if (nlen < 40) {
        int i, done = 0;
        for (i = 0; i < g_nmn; i++) {
            if (g_nm[i][0] && strncmp(g_nm[i], (const char *)name, nlen) == 0
                && (size_t)strlen(g_nm[i]) == nlen) { g_nmc[i]++; done = 1; break; }
        }
        if (!done && g_nmn < NNAMES) {
            memcpy(g_nm[g_nmn], name, nlen);
            g_nm[g_nmn][nlen] = 0;
            g_nmc[g_nmn] = 1;
            g_nmn++;
        }
    }

    if (p >= total || fr[p] != 0x12) return;
    p++;
    uint64_t sl;
    if (!rd_varint(fr, total, &p, &sl)) return;
    if (p + (size_t)sl > total) return;

    const uint8_t *sub = fr + p;
    size_t subl = (size_t)sl;

#define IS(s) (nlen == sizeof(s) - 1 && memcmp(name, s, nlen) == 0)
    if (IS("proto.sc_player_by_base_data")) { __sync_add_and_fetch(&g_hit, 1); snap(fr, total); apply_base(sub, subl); }
    else if (IS("proto.sc_player_by_table_info")) { __sync_add_and_fetch(&g_hit, 1); snap(fr, total); apply_table_info(sub, subl); }
    else if (IS("proto.sc_player_by_attr")) { __sync_add_and_fetch(&g_hit, 1); snap(fr, total); apply_change_attr(sub, subl); }
    else if (IS("proto.sc_player_by_change_attr")) { __sync_add_and_fetch(&g_hit, 1); snap(fr, total); apply_change_attr(sub, subl); }
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
        // 帧头 4 字节长度：真机抓到的报文是 “22 00 00 00”（小端，长度在前），
        // 而移植资料里的样例是大端写法，两种都兼容，取合理值
        uint32_t le = (uint32_t)g_buf[off] | ((uint32_t)g_buf[off + 1] << 8)
                    | ((uint32_t)g_buf[off + 2] << 16) | ((uint32_t)g_buf[off + 3] << 24);
        uint32_t be = ((uint32_t)g_buf[off] << 24) | ((uint32_t)g_buf[off + 1] << 16)
                    | ((uint32_t)g_buf[off + 2] << 8) | (uint32_t)g_buf[off + 3];
        uint32_t tl = (le > 3 && le <= 60000) ? le : be;
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

// ================= 挂钩（热路径零 IO，1 秒统一处理） =================
// 只挂 recvfrom：recv 是 libsystem 里的超短 syscall 跳转桩，
// MSHookFunction 挂上去会让游戏直接崩，这里绝不挂 recv。
// alen 在 Darwin 上是 socklen_t*（4 字节无符号），不是 size_t*
static ssize_t (*orig_recvfrom)(int, void *, size_t, int, struct sockaddr *, socklen_t *);
static volatile int g_n_rf = 0;         // 收到多少次
static uint8_t g_smp[64];               // 最近一次报文的前 64 字节
static volatile size_t g_smpn = 0;
static volatile int g_need_smp = 1;     // 1 = 需要抓一份新样本

static ssize_t my_recvfrom(int s, void *buf, size_t len, int flags,
                           struct sockaddr *addr, socklen_t *alen) {
    ssize_t r = orig_recvfrom(s, buf, len, flags, addr, alen);
    if (r > 0) {
        __sync_add_and_fetch(&g_n_rf, 1);
        if (g_need_smp) {                       // 只做一次 64 字节 memcpy，不碰磁盘
            size_t k = (size_t)r > 64 ? 64 : (size_t)r;
            memcpy(g_smp, buf, k);
            g_smpn = k;
            g_need_smp = 0;
        }
        feed((const uint8_t *)buf, (size_t)r);  // 纯内存解析
    }
    return r;
}

// 1 秒线程：写 json + 打一行采样日志（所有磁盘 IO 都只在这里发生）
static void *fish_monitor(void *arg) {
    (void)arg;
    int lastn = -1;
    while (1) {
        sleep(1);

        int n = g_n_rf;
        if (n != lastn) {
            lastn = n;
            size_t k = g_smpn;
            if (k > 32) k = 32;
            char hex[128];
            int o = 0;
            for (size_t i = 0; i < k && o < 100; i++)
                o += snprintf(hex + o, sizeof(hex) - (size_t)o, "%02x", g_smp[i]);
            if (o == 0) snprintf(hex, sizeof hex, "(none)");
            flog("[FishState] rf=%d hit=%d sample=%s", n, g_hit, hex);
            g_need_smp = 1;

            char nb[420];
            int o2 = 0;
            for (int i = 0; i < g_nmn && o2 < 380; i++)
                o2 += snprintf(nb + o2, sizeof(nb) - (size_t)o2, "%s:%d ", g_nm[i], g_nmc[i]);
            flog("[FishState] names=%s", o2 ? nb : "(none)");

            if (g_hbf) {   // 命中帧完整内容
                size_t k = g_hbn;
                char hb[760];
                int o3 = 0;
                for (size_t i = 0; i < k && o3 < 720; i++)
                    o3 += snprintf(hb + o3, sizeof(hb) - (size_t)o3, "%02x", g_hb[i]);
                flog("[FishState] HITFRAME n=%zu %s", k, hb);
                g_hbf = 0;
            }
        }

        pthread_mutex_lock(&g_lock);
        write_state_locked();     // 内部已做“内容没变不写”
        pthread_mutex_unlock(&g_lock);
    }
    return NULL;
}

%ctor {
    if (!is_game_process()) return;   // 按键精灵等其它进程不碰这个文件
    MSHookFunction((void *)recvfrom, (void *)my_recvfrom, (void **)&orig_recvfrom);
    write_state_locked();             // 启动即写一份全 0，保证文件存在
    flog("[FishState] armed, out=%s", OUT_PATH);
    pthread_t th;
    if (pthread_create(&th, NULL, fish_monitor, NULL) == 0) pthread_detach(th);
}
