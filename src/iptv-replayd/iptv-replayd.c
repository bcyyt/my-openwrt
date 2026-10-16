// iptv-replayd — 独立 C 回看 RTSP 代理守护进程
//
// 把原先内嵌在 iptv-auth.py 里的 554 端口回看/时移代理拆分出来，改为一个无依赖的
// 静态 C 程序：回看的 RTSP 媒体流不再穿过 Python 解释器，避免解释器常驻与 GIL 抖动。
//
// 与控制面 iptv-auth.py 的接口（所有路径与 Python 侧常量一致）：
//   - 运行时状态文件 /tmp/iptv-replayd.state（key=value，Python 侧原子写入）：
//       rtsp_source_ip / rtsp_source_port / upstream_iface / upstream_src_ip
//   - 活跃日志 /var/log/iptv-auth/iptv-auth.log：与 Python 共用一个 flock 锁文件，
//     两边都做“读-追加-截断到最近 500 行-重写”
//   - 历史日志 /mnt/data/iptv-auth/logs/history-YYYY-MM-DD.log（追加）
//   - 客户端档案 /var/log/iptv-auth/clients.json（供 LuCI 状态页读取）
//
// 行为与 Python 版逐字节对齐：四轮握手（OPTIONS/DESCRIBE/SETUP/PLAY）、首轮内部
// DESCRIBE 触发 302 重定向并重连、URL/host 改写、双向阻塞转发。

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <time.h>
#include <ctype.h>
#include <signal.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <poll.h>

#define LOG_DIR        "/var/log/iptv-auth"
#define LOG_FILE       LOG_DIR "/iptv-auth.log"
#define LOG_LOCK       LOG_DIR "/.log.lock"
#define HISTORY_DIR    "/mnt/data/iptv-auth/logs"
#define CLIENTS_FILE   LOG_DIR "/clients.json"
#define STATE_FILE     "/tmp/iptv-replayd.state"

#define MAX_LOG_LINES      500
#define CLIENTS_KEEP_DAYS  7
#define PROXY_RECV_BUF     262144
#define SOCK_TIMEOUT       30
#define MAX_CLIENTS        256

// ===================== 全局 =====================
static volatile sig_atomic_t g_stop = 0;
static pthread_mutex_t g_log_lock = PTHREAD_MUTEX_INITIALIZER;

typedef struct {
    char iface[64];
    char src_ip[64];
    char rtsp_ip[64];
    int  rtsp_port;
} cfg_t;

static void on_signal(int sig) { (void)sig; g_stop = 1; }

// OpenWrt 把时区放在 /etc/TZ（POSIX TZ 串，如 CST-8），/etc/localtime 常为指向
// 不存在的 /tmp/localtime 的悬空软链。上游静态 musl 只认 TZ/localtime，会退回 UTC，
// 导致日志时间比 busybox/Python 少 8 小时。这里显式读取 /etc/TZ 对齐。
static void init_timezone(void) {
    char tz[128] = "";
    FILE *f = fopen("/etc/TZ", "r");
    if (f) {
        if (fgets(tz, sizeof(tz), f)) {
            size_t n = strlen(tz);
            while (n && (tz[n - 1] == '\n' || tz[n - 1] == '\r')) tz[--n] = 0;
        }
        fclose(f);
    }
    if (tz[0]) setenv("TZ", tz, 1);
    tzset();
}

// ===================== 动态字符串 =====================
typedef struct { char *p; size_t len, cap; } sbuf;

static void sb_init(sbuf *b) {
    b->cap = 256;
    b->p = malloc(b->cap);
    if (!b->p) { b->cap = 0; b->len = 0; return; }
    b->p[0] = 0;
    b->len = 0;
}
static void sb_need(sbuf *b, size_t extra) {
    if (!b->p) return;
    if (b->len + extra + 1 > b->cap) {
        while (b->len + extra + 1 > b->cap) b->cap *= 2;
        b->p = realloc(b->p, b->cap);
    }
}
static void sb_putn(sbuf *b, const char *s, size_t n) {
    sb_need(b, n);
    if (!b->p) return;
    memcpy(b->p + b->len, s, n);
    b->len += n;
    b->p[b->len] = 0;
}
static void sb_puts(sbuf *b, const char *s) { sb_putn(b, s, strlen(s)); }
static void sb_printf(sbuf *b, const char *fmt, ...) {
    char tmp[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(tmp, sizeof(tmp), fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if ((size_t)n < sizeof(tmp)) { sb_putn(b, tmp, n); return; }
    char *d = malloc(n + 1);
    if (!d) return;
    va_start(ap, fmt);
    vsnprintf(d, n + 1, fmt, ap);
    va_end(ap);
    sb_putn(b, d, n);
    free(d);
}

static char *xstrdup(const char *s) {
    if (!s) return NULL;
    size_t n = strlen(s) + 1;
    char *r = malloc(n);
    if (r) memcpy(r, s, n);
    return r;
}

// 全部替换（Python str.replace 语义）
static char *replace_all(const char *src, const char *from, const char *to) {
    if (!from || !*from) return xstrdup(src);
    size_t fl = strlen(from);
    sbuf b; sb_init(&b);
    const char *p = src;
    for (;;) {
        const char *m = strstr(p, from);
        if (!m) { sb_puts(&b, p); break; }
        sb_putn(&b, p, (size_t)(m - p));
        sb_puts(&b, to);
        p = m + fl;
    }
    return b.p;
}

static char *replace_first(const char *s, const char *from, const char *to) {
    const char *m = strstr(s, from);
    if (!m) return xstrdup(s);
    sbuf b; sb_init(&b);
    sb_putn(&b, s, (size_t)(m - s));
    sb_puts(&b, to);
    sb_puts(&b, m + strlen(from));
    return b.p;
}

// ===================== 日志 =====================
static void trim_and_append(const char *line) {
    char *buf = NULL;
    size_t len = 0;
    FILE *f = fopen(LOG_FILE, "r");
    if (f) {
        if (fseek(f, 0, SEEK_END) == 0) {
            long sz = ftell(f);
            if (sz > 0 && fseek(f, 0, SEEK_SET) == 0) {
                buf = malloc((size_t)sz + 1);
                if (buf) {
                    size_t rd = fread(buf, 1, (size_t)sz, f);
                    buf[rd] = 0;
                    len = rd;
                }
            }
        }
        fclose(f);
    }
    size_t start = 0;
    if (buf) {
        int total = 0;
        for (size_t i = 0; i < len; i++) if (buf[i] == '\n') total++;
        if (total > MAX_LOG_LINES - 1) {
            int skip = total - (MAX_LOG_LINES - 1);
            size_t i = 0;
            while (i < len && skip > 0) {
                if (buf[i] == '\n') skip--;
                i++;
            }
            start = i;
        }
    }
    FILE *o = fopen(LOG_FILE, "w");
    if (o) {
        if (buf && len > start) fwrite(buf + start, 1, len - start, o);
        fwrite(line, 1, strlen(line), o);
        fputc('\n', o);
        fclose(o);
    }
    free(buf);
}

static void log_line(int err, const char *fmt, ...) {
    char msg[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);

    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    char line[1200];
    snprintf(line, sizeof(line), "[%04d-%02d-%02d %02d:%02d:%02d]%s %s",
             tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
             tm.tm_hour, tm.tm_min, tm.tm_sec, err ? "[ERR]" : "", msg);

    fprintf(stdout, "%s\n", line);
    fflush(stdout);

    // 历史日志（追加，跨进程安全）
    char hpath[256];
    snprintf(hpath, sizeof(hpath), HISTORY_DIR "/history-%04d-%02d-%02d.log",
             tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday);
    int hf = open(hpath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (hf >= 0) {
        ssize_t w = write(hf, line, strlen(line));
        (void)w;
        w = write(hf, "\n", 1);
        (void)w;
        close(hf);
    }

    // 活跃日志：与 Python 共用一个 flock，保证读-改-写不互相覆盖
    pthread_mutex_lock(&g_log_lock);
    int lf = open(LOG_LOCK, O_WRONLY | O_CREAT, 0644);
    if (lf >= 0) flock(lf, LOCK_EX);
    trim_and_append(line);
    if (lf >= 0) { flock(lf, LOCK_UN); close(lf); }
    pthread_mutex_unlock(&g_log_lock);
}

// ===================== socket 工具 =====================
static void tune_socket(int fd) {
    int v = 262144;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &v, sizeof(v));
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &v, sizeof(v));
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
}

static void set_timeout(int fd, int sec) {
    struct timeval tv;
    tv.tv_sec = sec;
    tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

static void bind_upstream(int fd, const cfg_t *c) {
    if (c->src_ip[0]) {
        struct sockaddr_in a;
        memset(&a, 0, sizeof(a));
        a.sin_family = AF_INET;
        a.sin_port = 0;
        if (inet_pton(AF_INET, c->src_ip, &a.sin_addr) == 1)
            bind(fd, (struct sockaddr *)&a, sizeof(a));
    }
    if (c->iface[0]) {
        setsockopt(fd, SOL_SOCKET, SO_BINDTODEVICE, c->iface, strlen(c->iface) + 1);
    }
}

static int sendall_fd(int fd, const char *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = send(fd, buf + off, len - off, MSG_NOSIGNAL);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        off += (size_t)n;
    }
    return 0;
}

static int tcp_connect(const char *host, int port, const cfg_t *c, int timeout) {
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    char ps[16];
    snprintf(ps, sizeof(ps), "%d", port);
    struct addrinfo *res = NULL;
    if (getaddrinfo(host, ps, &hints, &res) != 0) return -1;
    int fd = -1;
    for (struct addrinfo *r = res; r; r = r->ai_next) {
        fd = socket(r->ai_family, r->ai_socktype, r->ai_protocol);
        if (fd < 0) continue;
        set_timeout(fd, timeout);
        tune_socket(fd);
        bind_upstream(fd, c);
        if (connect(fd, r->ai_addr, r->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    return fd;
}

// ===================== 运行时状态文件 =====================
// 单次打开解析全部键：旧实现每个 key 都 fopen 一次（共 4 次），每个连接都要读
static void load_cfg(cfg_t *c) {
    memset(c, 0, sizeof(*c));
    FILE *f = fopen(STATE_FILE, "r");
    if (f) {
        char line[512];
        while (fgets(line, sizeof(line), f)) {
            char *eq = strchr(line, '=');
            if (!eq) continue;
            *eq = 0;
            char *v = eq + 1;
            size_t n = strlen(v);
            while (n && (v[n - 1] == '\n' || v[n - 1] == '\r')) v[--n] = 0;
            if (strcmp(line, "upstream_iface") == 0)
                snprintf(c->iface, sizeof(c->iface), "%s", v);
            else if (strcmp(line, "upstream_src_ip") == 0)
                snprintf(c->src_ip, sizeof(c->src_ip), "%s", v);
            else if (strcmp(line, "rtsp_source_ip") == 0)
                snprintf(c->rtsp_ip, sizeof(c->rtsp_ip), "%s", v);
            else if (strcmp(line, "rtsp_source_port") == 0)
                c->rtsp_port = atoi(v);
        }
        fclose(f);
    }
    if (c->rtsp_port <= 0) c->rtsp_port = 554;
}

// ===================== RTSP 文本改写 =====================
static int all_digits_n(const char *s, size_t n) {
    if (!n) return 0;
    for (size_t i = 0; i < n; i++)
        if (!isdigit((unsigned char)s[i])) return 0;
    return 1;
}

static int is_ipv4_n(const char *s, size_t n) {
    if (!n) return 0;
    int parts = 0;
    size_t i = 0;
    for (;;) {
        size_t j = i;
        while (j < n && s[j] != '.') j++;
        if (j == i || j - i > 3) return 0;
        if (!all_digits_n(s + i, j - i)) return 0;
        parts++;
        if (j == n) break;
        i = j + 1;
        if (i >= n) return 0;
    }
    return parts == 4;
}

// host 形如 a.b 且 TLD 为 >=2 个字母（对应 Python 正则 [a-zA-Z0-9_.-]+\.[a-zA-Z]{2,}）
static int has_dotted_tld_n(const char *s, size_t n) {
    if (n < 3) return 0;
    size_t last = 0;
    int found = 0;
    for (size_t i = 0; i < n; i++) {
        if (s[i] == '.') { last = i; found = 1; }
    }
    if (!found) return 0;
    size_t tl = n - (last + 1);
    if (tl < 2) return 0;
    for (size_t i = last + 1; i < n; i++)
        if (!isalpha((unsigned char)s[i])) return 0;
    return 1;
}

// 对应 Python replaceip()：rtsp:// 的 IP/域名主机替换为目标 IP，所有 :// 主机补端口
static char *do_replaceip(const char *text, const char *ip, int port) {
    sbuf b; sb_init(&b);
    const char *base = text;
    const char *p = text;
    for (;;) {
        const char *m = strstr(p, "://");
        if (!m) { sb_puts(&b, p); break; }
        sb_putn(&b, p, (size_t)(m - p) + 3);
        int is_rtsp = ((m - base) >= 4) && (strncmp(m - 4, "rtsp", 4) == 0);
        const char *a = m + 3;
        const char *e = a;
        while (*e && *e != '/' && *e != '?' && *e != ' ' && *e != '\t'
               && *e != '\r' && *e != '\n') e++;
        const char *colon = NULL;
        for (const char *q = a; q < e; q++) if (*q == ':') colon = q;
        size_t hlen = colon ? (size_t)(colon - a) : (size_t)(e - a);
        int replace_host = is_rtsp && (is_ipv4_n(a, hlen) || has_dotted_tld_n(a, hlen));
        if (replace_host) {
            sb_printf(&b, "%s:%d", ip, port);
        } else {
            sb_putn(&b, a, hlen);
            sb_printf(&b, ":%d", port);
        }
        p = e;
    }
    return b.p;
}

// 对应 describe() 里的两个 re.sub：只改带显式端口的 rtsp://IP|域名
static char *rewrite_rtsp_hostport(const char *text, const char *ip, int port) {
    sbuf b; sb_init(&b);
    const char *base = text;
    const char *p = text;
    for (;;) {
        const char *m = strstr(p, "://");
        if (!m) { sb_puts(&b, p); break; }
        sb_putn(&b, p, (size_t)(m - p) + 3);
        int is_rtsp = ((m - base) >= 4) && (strncmp(m - 4, "rtsp", 4) == 0);
        const char *a = m + 3;
        const char *e = a;
        while (*e && *e != '/' && *e != '?' && *e != ' ' && *e != '\t'
               && *e != '\r' && *e != '\n') e++;
        const char *colon = NULL;
        for (const char *q = a; q < e; q++) if (*q == ':') colon = q;
        size_t hlen = colon ? (size_t)(colon - a) : (size_t)(e - a);
        int explicit_port = colon && all_digits_n(colon + 1, (size_t)(e - colon - 1));
        if (is_rtsp && explicit_port && (is_ipv4_n(a, hlen) || has_dotted_tld_n(a, hlen)))
            sb_printf(&b, "%s:%d", ip, port);
        else
            sb_putn(&b, a, (size_t)(e - a));
        p = e;
    }
    return b.p;
}

// 对应 describe(firstrequest)
static char *do_describe(const char *text, const char *srcip, int srcport) {
    char *t1 = rewrite_rtsp_hostport(text, srcip, srcport);
    char *t2 = replace_first(t1, "OPTIONS", "DESCRIBE");
    free(t1);
    char *t3 = replace_first(t2, "CSeq: 1", "CSeq: 2");
    free(t2);
    char *nl = strchr(t3, '\n');
    sbuf b; sb_init(&b);
    if (nl) {
        sb_putn(&b, t3, (size_t)(nl - t3) + 1);
        sb_puts(&b, "Accept: application/sdp\n");
        sb_puts(&b, nl + 1);
    } else {
        sb_puts(&b, t3);
        sb_puts(&b, "\nAccept: application/sdp");
    }
    free(t3);
    return b.p;
}

// 对应 replacelocation(request, location)
static char *do_replacelocation(const char *request, const char *location) {
    const char *u = strstr(request, "rtsp://");
    if (!u) return xstrdup(request);
    const char *e = u;
    while (*e && !isspace((unsigned char)*e)) e++;
    const char *w = e;
    while (*w == ' ' || *w == '\t' || *w == '\r' || *w == '\n') w++;
    if (strncmp(w, "RTSP/1.0", 8) != 0) return xstrdup(request);
    size_t ul = (size_t)(e - u);
    char *url = malloc(ul + 1);
    if (!url) return xstrdup(request);
    memcpy(url, u, ul);
    url[ul] = 0;
    char *r = replace_all(request, url, location);
    free(url);
    return r;
}

// 对应 getaddress(response)
static void do_getaddress(const char *resp, char *host, size_t hostcap, int *port) {
    host[0] = 0;
    *port = 0;
    const char *u = strstr(resp, "rtsp://");
    if (!u) return;
    u += 7;
    const char *e = u;
    while (*e && *e != '/' && *e != ':' && !isspace((unsigned char)*e)) e++;
    size_t n = (size_t)(e - u);
    if (n >= hostcap) n = hostcap - 1;
    memcpy(host, u, n);
    host[n] = 0;
    if (*e == ':') *port = atoi(e + 1);
}

// 对应 getlocation(response)
static char *do_getlocation(const char *resp) {
    const char *p = strcasestr(resp, "location:");
    if (!p) return xstrdup("");
    p += 9;
    while (*p == ' ' || *p == '\t') p++;
    const char *e = p;
    while (*e && !isspace((unsigned char)*e)) e++;
    char *r = malloc((size_t)(e - p) + 1);
    if (!r) return xstrdup("");
    memcpy(r, p, (size_t)(e - p));
    r[e - p] = 0;
    return r;
}

// 对应 _parse_rtsp_status(data)：返回状态码，失败返回 0
static int do_parse_status(const char *resp) {
    if (strncmp(resp, "RTSP/", 5) != 0) return 0;
    const char *p = resp + 5;
    while (*p && *p != ' ' && *p != '\t') p++;
    while (*p == ' ' || *p == '\t') p++;
    return atoi(p);
}

// 对应 Translator(source)
static char *do_translator(const char *text) {
    if (strstr(text, "playseek")) {
        const char *ps = strstr(text, "playseek=");
        int ok = 0;
        if (ps) {
            const char *d = ps + 9;
            ok = 1;
            for (int i = 0; i < 14; i++)
                if (!isdigit((unsigned char)d[i])) { ok = 0; break; }
            if (ok && d[14] == '-') {
                for (int i = 0; i < 14; i++)
                    if (!isdigit((unsigned char)d[15 + i])) { ok = 0; break; }
            } else {
                ok = 0;
            }
        }
        if (!ok) return xstrdup(text);
        char a[16], b2[16];
        memcpy(a, ps + 9, 14); a[14] = 0;
        memcpy(b2, ps + 9 + 15, 14); b2[14] = 0;
        char psbuf[64];
        size_t pslen = 9 + 14 + 1 + 14;
        memcpy(psbuf, ps, pslen);
        psbuf[pslen] = 0;
        // 上游门户拒绝 programend 落在未来的 playseek 请求（RTSP 562），而
        // rtp2httpd 的 (e) 占位符会落在“现在”这个边界上，偶发超前 1 秒即失败。
        // 这里把 end 收敛到当前时刻前 2 秒，消除边界抖动（start 同步收敛，避免倒置）。
        struct tm tmv;
        time_t nowsec = time(NULL);
        char nowb[16];
        localtime_r(&nowsec, &tmv);
        strftime(nowb, sizeof(nowb), "%Y%m%d%H%M%S", &tmv);
        if (strcmp(b2, nowb) > 0) {
            time_t safest = nowsec - 2;
            localtime_r(&safest, &tmv);
            strftime(b2, sizeof(b2), "%Y%m%d%H%M%S", &tmv);
            if (strcmp(a, b2) > 0) memcpy(a, b2, sizeof(a));
        }
        char pt[160];
        snprintf(pt, sizeof(pt), "programbegin=%s+08&programend=%s+08", a, b2);
        // 回看日志：频道 + 时间区间
        char ch[96] = "unknown";
        const char *cp = strstr(text, "/PLTV/");
        if (cp) {
            cp += 6;
            const char *ce = cp;
            while (isalnum((unsigned char)*ce) || *ce == '_') ce++;
            size_t cn = (size_t)(ce - cp);
            if (cn && cn < sizeof(ch)) {
                memcpy(ch, cp, cn);
                ch[cn] = 0;
            }
        }
        log_line(0, "代理: 回看 %s | %s~%s", ch, a, b2);
        char *r1 = replace_all(text, "TVOD", "live");
        char *r2 = replace_all(r1, "smil?", "mpg?vcdnid=001&boid=001&contname=&");
        char *r3 = replace_all(r2, psbuf, pt);
        free(r1);
        free(r2);
        return r3;
    }
    char *r1 = replace_all(text, "PLTV", "live");
    char *r2 = replace_all(r1, "smil", "sdp?vcdnid=001");
    free(r1);
    return r2;
}

// ===================== 客户端档案 clients.json =====================
typedef struct {
    char ip[64];
    char ua[160];
    char ch[96];
    double last;
    long count;
} prec_t;

static pthread_mutex_t g_clients_lock = PTHREAD_MUTEX_INITIALIZER;
static prec_t g_clients[MAX_CLIENTS];
static int g_nclients = 0;
static int g_clients_loaded = 0;

static void skip_ws(const char **p) {
    while (**p == ' ' || **p == '\t' || **p == '\r' || **p == '\n') (*p)++;
}

static int json_str(const char **pp, char *out, size_t cap) {
    const char *p = *pp;
    skip_ws(&p);
    if (*p != '"') return -1;
    p++;
    size_t o = 0;
    while (*p && *p != '"') {
        char c = *p;
        if (c == '\\') {
            p++;
            if (!*p) break;
            char esc = *p++;
            switch (esc) {
                case 'n': c = '\n'; break;
                case 't': c = '\t'; break;
                case 'r': c = '\r'; break;
                case 'b': c = '\b'; break;
                case 'f': c = '\f'; break;
                case '/': c = '/'; break;
                case '"': c = '"'; break;
                case '\\': c = '\\'; break;
                case 'u': {
                    for (int i = 0; i < 4 && isxdigit((unsigned char)p[i]); i++) p++;
                    c = '?';
                    break;
                }
                default: break;
            }
        } else {
            p++;
        }
        if (o + 1 < cap) out[o++] = c;
    }
    if (*p == '"') p++;
    if (o >= cap) o = cap ? cap - 1 : 0;
    out[o] = 0;
    *pp = p;
    return 0;
}

static int parse_clients(const char *js, prec_t *arr, int max) {
    const char *p = js;
    skip_ws(&p);
    if (*p != '{') return 0;
    p++;
    int n = 0;
    for (;;) {
        skip_ws(&p);
        if (*p == '}' || *p == 0) break;
        char key[64];
        if (json_str(&p, key, sizeof(key)) != 0) break;
        skip_ws(&p);
        if (*p != ':') break;
        p++;
        skip_ws(&p);
        if (*p != '{') break;
        p++;
        prec_t tmp;
        memset(&tmp, 0, sizeof(tmp));
        snprintf(tmp.ip, sizeof(tmp.ip), "%s", key);
        for (;;) {
            skip_ws(&p);
            if (*p == '}' || *p == 0) { if (*p == '}') p++; break; }
            char fld[32];
            if (json_str(&p, fld, sizeof(fld)) != 0) break;
            skip_ws(&p);
            if (*p != ':') break;
            p++;
            skip_ws(&p);
            if (*p == '"') {
                char val[160];
                if (json_str(&p, val, sizeof(val)) != 0) break;
                if (strcmp(fld, "ua") == 0) snprintf(tmp.ua, sizeof(tmp.ua), "%s", val);
                else if (strcmp(fld, "channel") == 0) snprintf(tmp.ch, sizeof(tmp.ch), "%s", val);
            } else if (strncmp(p, "null", 4) == 0) {
                p += 4;
            } else {
                char *end = NULL;
                double d = strtod(p, &end);
                if (end == p) break;
                p = end;
                if (strcmp(fld, "last") == 0) tmp.last = d;
                else if (strcmp(fld, "count") == 0) tmp.count = (long)d;
            }
            skip_ws(&p);
            if (*p == ',') { p++; continue; }
            if (*p == '}') { p++; break; }
            break;
        }
        if (n < max) arr[n++] = tmp;
        skip_ws(&p);
        if (*p == ',') { p++; continue; }
        if (*p == '}') { p++; break; }
        break;
    }
    return n;
}

static void clients_load_once(void) {
    if (g_clients_loaded) return;
    g_clients_loaded = 1;
    FILE *f = fopen(CLIENTS_FILE, "r");
    if (!f) return;
    char *buf = NULL;
    long sz = 0;
    if (fseek(f, 0, SEEK_END) == 0 && (sz = ftell(f)) > 0 && fseek(f, 0, SEEK_SET) == 0) {
        buf = malloc((size_t)sz + 1);
        if (buf) {
            size_t rd = fread(buf, 1, (size_t)sz, f);
            buf[rd] = 0;
            g_nclients = parse_clients(buf, g_clients, MAX_CLIENTS);
        }
    }
    fclose(f);
    free(buf);
}

static void json_escape(sbuf *b, const char *s) {
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') { sb_putn(b, "\\", 1); sb_putn(b, (char *)s, 1); }
        else if (c == '\n') sb_puts(b, "\\n");
        else if (c == '\r') sb_puts(b, "\\r");
        else if (c == '\t') sb_puts(b, "\\t");
        else if (c < 0x20) sb_printf(b, "\\u%04x", c);
        else sb_putn(b, (char *)s, 1);
    }
}

static void clients_write(void) {
    sbuf b; sb_init(&b);
    sb_puts(&b, "{");
    int first = 1;
    for (int i = 0; i < g_nclients; i++) {
        prec_t *r = &g_clients[i];
        if (!first) sb_puts(&b, ",");
        first = 0;
        sb_puts(&b, "\"");
        json_escape(&b, r->ip);
        sb_puts(&b, "\":{\"ua\":\"");
        json_escape(&b, r->ua);
        sb_puts(&b, "\",\"channel\":\"");
        json_escape(&b, r->ch);
        sb_printf(&b, "\",\"last\":%.3f,\"count\":%ld}", r->last, r->count);
    }
    sb_puts(&b, "}");
    char tmp[256];
    snprintf(tmp, sizeof(tmp), CLIENTS_FILE ".tmp.%d", (int)getpid());
    FILE *f = fopen(tmp, "w");
    if (f) {
        fwrite(b.p, 1, b.len, f);
        fclose(f);
        rename(tmp, CLIENTS_FILE);
    }
    free(b.p);
}

static void record_client(const char *cip, const char *ua, const char *ch) {
    pthread_mutex_lock(&g_clients_lock);
    clients_load_once();

    char ip[64];
    snprintf(ip, sizeof(ip), "%s", cip);
    if (strncmp(ip, "::ffff:", 7) == 0) memmove(ip, ip + 7, strlen(ip + 7) + 1);

    double now = (double)time(NULL);
    prec_t *ent = NULL;
    for (int i = 0; i < g_nclients; i++) {
        if (strcmp(g_clients[i].ip, ip) == 0) { ent = &g_clients[i]; break; }
    }
    if (!ent) {
        if (g_nclients >= MAX_CLIENTS) {
            // 淘汰最旧的一条
            int oldest = 0;
            for (int i = 1; i < g_nclients; i++)
                if (g_clients[i].last < g_clients[oldest].last) oldest = i;
            ent = &g_clients[oldest];
        } else {
            ent = &g_clients[g_nclients++];
        }
        memset(ent, 0, sizeof(*ent));
        snprintf(ent->ip, sizeof(ent->ip), "%s", ip);
    }
    if (ua && ua[0]) snprintf(ent->ua, sizeof(ent->ua), "%s", ua);
    if (ch && ch[0]) snprintf(ent->ch, sizeof(ent->ch), "%s", ch);
    ent->last = now;
    ent->count++;

    double cutoff = now - (double)CLIENTS_KEEP_DAYS * 86400.0;
    int w = 0;
    for (int i = 0; i < g_nclients; i++) {
        if (g_clients[i].last >= cutoff) {
            if (w != i) g_clients[w] = g_clients[i];
            w++;
        }
    }
    g_nclients = w;

    clients_write();
    pthread_mutex_unlock(&g_clients_lock);
}

// ===================== 双向转发 =====================
typedef struct {
    int from;
    int to;
    int cfd;
    int sfd;
    int stoc;
} fwd_t;

// 单方向阻塞转发循环（不含线程/资源管理），可在线程内或调用线程内直接执行
static void forward_loop(fwd_t *f) {
    char *buf = malloc(PROXY_RECV_BUF);
    if (buf) {
        for (;;) {
            ssize_t n = recv(f->from, buf, PROXY_RECV_BUF, 0);
            if (n <= 0) {
                if (n == 0) {
                    log_line(0, f->stoc ? "代理: 上游关闭 (S→C)" : "代理: 客户端关闭 (C→S)");
                } else {
                    if (errno != EINTR)
                        log_line(0, f->stoc ? "代理: S→C 转发错误: %s" : "代理: C→S 转发错误: %s",
                                 strerror(errno));
                }
                break;
            }
            if (sendall_fd(f->to, buf, (size_t)n) < 0) {
                log_line(0, f->stoc ? "代理: S→C 转发错误: %s" : "代理: C→S 转发错误: %s",
                         strerror(errno));
                break;
            }
        }
        free(buf);
    }
}

static void *forward_thread(void *arg) {
    fwd_t *f = arg;
    forward_loop(f);
    // 唤醒对向线程后由 handle_entrance 统一 close
    shutdown(f->cfd, SHUT_RDWR);
    shutdown(f->sfd, SHUT_RDWR);
    free(f);
    return NULL;
}

// ===================== 连接处理 =====================
static void extract_ua_ch(const char *req, char *ua, size_t uacap,
                          char *ch, size_t chcap) {
    const char *p = strcasestr(req, "User-Agent:");
    if (p) {
        p += 11;
        while (*p == ' ' || *p == '\t') p++;
        const char *e = p;
        while (*e && *e != '\r' && *e != '\n') e++;
        size_t n = (size_t)(e - p);
        if (n >= uacap) n = uacap - 1;
        if (n > 80) n = 80;
        memcpy(ua, p, n);
        ua[n] = 0;
    }
    const char *q = strstr(req, "/PLTV/");
    if (q) {
        q += 6;
        const char *e = q;
        while (isalnum((unsigned char)*e) || *e == '_') e++;
        size_t n = (size_t)(e - q);
        if (n >= 2 && n < chcap && strncmp(q, "ch", 2) == 0 && strncmp(e, ".smil", 5) == 0) {
            memcpy(ch, q, n);
            ch[n] = 0;
        }
    }
}

static void client_ip_str(const struct sockaddr_storage *ss, char *out, size_t cap, int *port) {
    out[0] = 0;
    *port = 0;
    if (ss->ss_family == AF_INET6) {
        const struct sockaddr_in6 *a = (const struct sockaddr_in6 *)ss;
        inet_ntop(AF_INET6, &a->sin6_addr, out, cap);
        *port = ntohs(a->sin6_port);
    } else if (ss->ss_family == AF_INET) {
        const struct sockaddr_in *a = (const struct sockaddr_in *)ss;
        inet_ntop(AF_INET, &a->sin_addr, out, cap);
        *port = ntohs(a->sin_port);
    }
}

typedef struct {
    int cfd;
    struct sockaddr_storage cli;
} connarg_t;

static char *do_newoptions(const char *location) {
    sbuf b; sb_init(&b);
    sb_printf(&b, "OPTIONS %s RTSP/1.0\r\nCSeq: 1\r\nUser-Agent: Lavf62.1.100\r\n\r\n", location);
    return b.p;
}

static void *handle_entrance(void *arg) {
    connarg_t *ca = arg;
    int cfd = ca->cfd;
    char cip[64];
    int cport = 0;
    client_ip_str(&ca->cli, cip, sizeof(cip), &cport);
    free(ca);

    int sfd = -1;
    char *location = xstrdup("");
    char targetaddr[128] = "";
    int targetport = 554;
    char *reqbuf = NULL;
    char *resbuf = NULL;
    char ua[160] = "";
    char ch[96] = "";
    int forward = 0;
    int abnormal = 0;   // 出现异常错误：直接收尾，不进入转发

    // 等待源站 IP 就绪（首次鉴权完成前代理已在监听）
    cfg_t cfg;
    for (int i = 0; i < 120; i++) {
        load_cfg(&cfg);
        if (cfg.rtsp_ip[0]) break;
        usleep(500000);
    }
    if (!cfg.rtsp_ip[0]) {
        log_line(1, "代理: 源站 IP 未就绪（鉴权未完成），关闭连接");
        goto done;
    }

    set_timeout(cfd, SOCK_TIMEOUT);
    tune_socket(cfd);
    snprintf(targetaddr, sizeof(targetaddr), "%s", cfg.rtsp_ip);
    targetport = cfg.rtsp_port;

    sfd = tcp_connect(targetaddr, targetport, &cfg, SOCK_TIMEOUT);
    if (sfd < 0) {
        log_line(1, "代理: 连接源站失败 %s:%d: %s", targetaddr, targetport, strerror(errno));
        goto done;
    }

    reqbuf = malloc(PROXY_RECV_BUF);
    resbuf = malloc(PROXY_RECV_BUF);
    if (!reqbuf || !resbuf) goto done;

    for (int idx = 0; idx < 4; idx++) {
        ssize_t rn = recv(cfd, reqbuf, PROXY_RECV_BUF - 1, 0);
        if (rn == 0) {
            if (idx == 0) log_line(0, "代理: 客户端未发送请求即断开");
            // 客户端在握手完成前断开：不得继续进入转发
            abnormal = 1;
            break;
        }
        if (rn < 0) {
            if (errno == EINTR) { idx--; continue; }
            abnormal = 1;
            break;
        }
        reqbuf[rn] = 0;

        if (!ua[0] || !ch[0]) extract_ua_ch(reqbuf, ua, sizeof(ua), ch, sizeof(ch));

        char *toserver;
        if (location[0] == 0) toserver = do_replaceip(reqbuf, targetaddr, targetport);
        else toserver = do_replacelocation(reqbuf, location);
        char *translated = do_translator(toserver);  // 对应 Python: toserver = Translator(toserver)
        free(toserver);

        if (sendall_fd(sfd, translated, strlen(translated)) < 0) {
            free(translated);
            abnormal = 1;
            break;
        }

        ssize_t sn = recv(sfd, resbuf, PROXY_RECV_BUF - 1, 0);
        if (sn < 0) { free(translated); abnormal = 1; break; }
        if (sn == 0) { free(translated); abnormal = 1; break; }
        resbuf[sn] = 0;

        if (idx == 0) {
            // 首轮内部 DESCRIBE 触发 302：Python 基于已翻译请求构造 DESCRIBE
            char *twotoserver = do_describe(translated, cfg.rtsp_ip, cfg.rtsp_port);
            free(translated);
            if (sendall_fd(sfd, twotoserver, strlen(twotoserver)) < 0) {
                free(twotoserver);
                abnormal = 1;
                break;
            }
            free(twotoserver);
            ssize_t sn2 = recv(sfd, resbuf, PROXY_RECV_BUF - 1, 0);
            if (sn2 > 0) {
                resbuf[sn2] = 0;
                char addr[128];
                int port = 0;
                do_getaddress(resbuf, addr, sizeof(addr), &port);
                char *loc = do_getlocation(resbuf);
                if (loc[0]) {
                    log_line(0, "代理: 302跳转 %s:%d", addr, port);
                    close(sfd);
                    sfd = tcp_connect(addr, port, &cfg, SOCK_TIMEOUT);
                    if (sfd < 0) {
                        log_line(1, "代理: 302 重连失败 %s:%d: %s", addr, port, strerror(errno));
                        free(loc);
                        abnormal = 1;
                        break;
                    }
                    char *newopt = do_newoptions(loc);
                    if (sendall_fd(sfd, newopt, strlen(newopt)) >= 0) {
                        ssize_t sn3 = recv(sfd, resbuf, PROXY_RECV_BUF - 1, 0);
                        if (sn3 > 0) resbuf[sn3] = 0;
                        else resbuf[0] = 0;
                    }
                    free(newopt);
                    snprintf(targetaddr, sizeof(targetaddr), "%s", addr);
                    targetport = port;
                    free(location);
                    location = loc;   // 保留 loc
                } else {
                    free(loc);
                }
            } else {
                abnormal = (sn2 < 0);
                break;
            }
        } else {
            free(translated);
        }

        int status = do_parse_status(resbuf);
        static const char *names[4] = { "OPTIONS", "DESCRIBE", "SETUP", "PLAY" };
        log_line(0, "代理: %s %d", names[idx], status);

        // 回给客户端时，把响应里的主机改成客户端侧看到的本机地址
        char lip[64];
        int lport = 0;
        struct sockaddr_storage lss;
        socklen_t lsl = sizeof(lss);
        if (getsockname(cfd, (struct sockaddr *)&lss, &lsl) == 0)
            client_ip_str(&lss, lip, sizeof(lip), &lport);
        else { lip[0] = 0; lport = 0; }
        char *toclient = do_replaceip(resbuf, lip, lport);
        if (sendall_fd(cfd, toclient, strlen(toclient)) < 0) {
            free(toclient);
            abnormal = 1;
            break;
        }
        free(toclient);

        // 上游返回非 2xx（如 562）：本次握手失败，不得进入转发
        if (status < 200 || status >= 300) {
            abnormal = 1;
            break;
        }
    }

    if (!abnormal) forward = 1;

done:
    if (forward) {
        log_line(0, "代理: 握手完成 %s:%d", targetaddr, targetport);
        if (cip[0]) record_client(cip, ua, ch);
        set_timeout(cfd, 0);
        if (sfd >= 0) set_timeout(sfd, 0);

        // 转发阶段不再需要握手缓冲区，提前释放（每会话共 512KB）
        free(reqbuf); reqbuf = NULL;
        free(resbuf); resbuf = NULL;

        fwd_t *fc = malloc(sizeof(*fc));
        if (fc && sfd >= 0) {
            fc->from = cfd; fc->to = sfd; fc->cfd = cfd; fc->sfd = sfd; fc->stoc = 0;
            log_line(0, "代理: 开始转发 S→C");
            pthread_t t2;
            if (pthread_create(&t2, NULL, forward_thread, fc) == 0) {
                log_line(0, "代理: 握手完成，进入双向转发");
                // S→C 方向直接在 entrance 线程内转发，省去一个线程及其栈
                fwd_t fs;
                fs.from = sfd; fs.to = cfd; fs.cfd = cfd; fs.sfd = sfd; fs.stoc = 1;
                forward_loop(&fs);
                shutdown(fs.cfd, SHUT_RDWR);
                shutdown(fs.sfd, SHUT_RDWR);
                pthread_join(t2, NULL);
            } else {
                free(fc);
                shutdown(sfd, SHUT_RDWR);
                shutdown(cfd, SHUT_RDWR);
            }
        } else {
            free(fc);
            shutdown(sfd, SHUT_RDWR);
            shutdown(cfd, SHUT_RDWR);
        }
    }

    if (sfd >= 0) close(sfd);
    close(cfd);
    free(reqbuf);
    free(resbuf);
    free(location);
    return NULL;
}

// ===================== 主循环 =====================
int main(int argc, char **argv) {
    int port = 554;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-l") == 0 && i + 1 < argc) port = atoi(argv[++i]);
    }
    if (port <= 0) port = 554;

    signal(SIGPIPE, SIG_IGN);
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    init_timezone();
    mkdir(LOG_DIR, 0755);
    mkdir(HISTORY_DIR, 0755);

    int ls = socket(AF_INET6, SOCK_STREAM, 0);
    int ok = 0;
    if (ls >= 0) {
        int one = 0, re = 1;
        setsockopt(ls, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof(one));
        setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &re, sizeof(re));
        struct sockaddr_in6 a6;
        memset(&a6, 0, sizeof(a6));
        a6.sin6_family = AF_INET6;
        a6.sin6_addr = in6addr_any;
        a6.sin6_port = htons((uint16_t)port);
        if (bind(ls, (struct sockaddr *)&a6, sizeof(a6)) == 0) ok = 1;
        else close(ls);
    }
    if (!ok) {
        ls = socket(AF_INET, SOCK_STREAM, 0);
        int re = 1;
        setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &re, sizeof(re));
        struct sockaddr_in a4;
        memset(&a4, 0, sizeof(a4));
        a4.sin_family = AF_INET;
        a4.sin_addr.s_addr = htonl(INADDR_ANY);
        a4.sin_port = htons((uint16_t)port);
        if (ls < 0 || bind(ls, (struct sockaddr *)&a4, sizeof(a4)) != 0) {
            log_line(1, "回看代理监听 %d 失败: %s", port, strerror(errno));
            return 1;
        }
    }
    listen(ls, 128);
    log_line(0, "回看代理已启动: :%d (C 守护进程)", port);

    while (!g_stop) {
        struct pollfd pfd;
        pfd.fd = ls;
        pfd.events = POLLIN;
        pfd.revents = 0;
        int pr = poll(&pfd, 1, 2000);
        if (pr <= 0) continue;

        struct sockaddr_storage cli;
        socklen_t cl = sizeof(cli);
        int cfd = accept(ls, (struct sockaddr *)&cli, &cl);
        if (cfd < 0) {
            if (errno == EINTR) continue;
            break;
        }
        char cip[64];
        int cport = 0;
        client_ip_str(&cli, cip, sizeof(cip), &cport);
        log_line(0, "代理: 新连接 (%s, %d)", cip, cport);

        connarg_t *ca = malloc(sizeof(*ca));
        if (!ca) { close(cfd); continue; }
        ca->cfd = cfd;
        ca->cli = cli;
        pthread_t t;
        pthread_attr_t at;
        pthread_attr_init(&at);
        pthread_attr_setstacksize(&at, 512 * 1024);
        if (pthread_create(&t, &at, handle_entrance, ca) != 0) {
            close(cfd);
            free(ca);
        } else {
            pthread_detach(t);
        }
        pthread_attr_destroy(&at);
    }

    close(ls);
    return 0;
}
