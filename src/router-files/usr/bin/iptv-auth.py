#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""iptv-auth.py — 中兴 IPTV 鉴权 + 频道抓取 + M3U 生成（回看代理已拆为 C 守护进程 iptv-replayd）

工作流程：
  1. 从 UCI 读取配置
  2. 中兴三步鉴权 → 抓取频道 → 生成 M3U（喂给 rtp2httpd）
  3. 落盘运行时状态（源站 IP 等）供 iptv-replayd 读取
  4. 定时循环刷新频道和节目单
  5. 输出状态 JSON 供 LuCI 读取
"""
import os, sys, re, json, time, gzip, socket, subprocess, datetime, threading, ssl, fcntl, queue
import http.client, http.cookiejar, urllib.request, urllib.parse, urllib.error
from urllib.parse import quote
from datetime import timedelta
# ===================== 路径常量 =====================
M3U_PATH = '/www/Lan.m3u'
REPLAY_M3U_PATH = '/www/LanReplay.m3u'     # 回看专用播放列表
WAN_M3U_PATH = '/www/WanPlay.m3u'          # 外网融合版（直播+回看）
WAN_REPLAY_M3U_PATH = '/www/WanReplay.m3u' # 外网纯回看版
LEGACY_M3U_PATH = '/www/IPTV.m3u'          # 旧版播放列表名，生成后清理
EPG_PATH = '/www/PL.xml'
EPG_GZ_PATH = '/www/PL.xml.gz'
LOG_DIR = '/var/log/iptv-auth'
LOG_FILE = os.path.join(LOG_DIR, 'iptv-auth.log')
LOG_LOCK = os.path.join(LOG_DIR, '.log.lock')   # 与 C 回看代理 iptv-replayd 共用的跨进程锁
STATUS_FILE = os.path.join(LOG_DIR, 'status.json')
CLIENTS_FILE = os.path.join(LOG_DIR, 'clients.json')  # 回看客户端档案（IP→UA/频道/最近时间）
CLIENTS_KEEP_DAYS = 7                                  # 客户端档案保留天数
HISTORY_DIR = '/mnt/data/iptv-auth/logs'   # 历史日志（持久化，重启不丢）
HISTORY_KEEP_DAYS = 7                        # 历史日志保留天数（超期自动覆盖清理）
MAX_LOG_LINES = 500                        # 活跃日志保留条数
_last_history_cleanup = 0.0

# ===================== 全局状态 =====================
config = {}
upstream_iface = 'eth1'
upstream_src_ip = ''
rtsp_source_ip = ''     # 原始 RTSP 源站 IP
rtsp_source_port = 554
_log_lock = threading.Lock()   # 日志线程锁：任务线程与定时器线程并发写保护
IPTV_RT_TABLE = '100'
IPTV_RT_PREF_SRC = '10000'
IPTV_RT_PREF_OIF = '10001'

# 预编译热点正则：频道属性、EPG 节目、回看频道号、响应字符集
_CH_ATTR_KEYS = ('ChannelURL', 'ChannelSDP', 'ChannelFCCIP', 'ChannelFCCPort')
_RE_CH_ATTRS = {k: re.compile(k + r'="([^"]*)"') for k in _CH_ATTR_KEYS}
_RE_CHANNEL_CODE = re.compile(r"jsSetChannelInfo\('[\w]+','[\w]+','[\w]+','[\w]+','([\w]+)'")
_RE_EPG_PROGRAM = re.compile(
    r'(?:prevuename|prevueName)":"(.*?)".*?'
    r'(?:begintime|beginTime)":"(.*?)".*?'
    r'(?:endtime|endTime)":"(.*?)"', re.DOTALL)
_RE_CATCHUP_ID = re.compile(r'rtsp://[\d.]+:\d+/live/(.+?)\.sdp')
_RE_CHARSET = re.compile(r'charset=([\w-]+)', re.I)
_EPG_TITLE_TRANS = str.maketrans({'<': '《', '>': '》'})


def _catchup_channel_id(rtsp_url):
    """从 RTSP 直播地址取频道号（回看路径最后一段）"""
    m = _RE_CATCHUP_ID.search(rtsp_url or '')
    return m.group(1) if m else ''

def _read_tail_lines(path, max_lines, max_bytes=512 * 1024):
    """只读取日志尾部若干字节再切行，避免每次追加都整份读入长日志。
    从中间截断时丢弃首个残行；返回行均以换行结尾。"""
    with open(path, 'rb') as f:
        f.seek(0, os.SEEK_END)
        size = f.tell()
        start = max(0, size - max_bytes)
        f.seek(start)
        data = f.read()
    lines = data.decode('utf-8', 'replace').splitlines(keepends=True)
    if start > 0 and lines:
        lines = lines[1:]
    if len(lines) > max_lines:
        lines = lines[-max_lines:]
    if lines and not lines[-1].endswith('\n'):
        lines[-1] += '\n'
    return lines


def log(msg, error=False):
    """日志：控制台 + 活跃日志(最近500条) + 按天历史日志(持久化)
    并发安全：加锁防止多线程同时重写活跃日志导致字节交错损坏"""
    global _last_history_cleanup
    ts = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    line = f"[{ts}]{'[ERR]' if error else ''} {msg}"
    print(line, flush=True)
    # 历史日志：append 模式天然安全，锁外执行减少阻塞
    try:
        day = datetime.datetime.now().strftime('%Y-%m-%d')
        os.makedirs(HISTORY_DIR, exist_ok=True)
        with open(os.path.join(HISTORY_DIR, f'history-{day}.log'), 'a', encoding='utf-8') as f:
            f.write(line + '\n')
    except Exception:
        pass
    # 活跃日志：读→追加→重写（加锁 + 容错读取，坏字节不致停更）
    try:
        with _log_lock:
            os.makedirs(LOG_DIR, exist_ok=True)
            # 跨进程锁：C 回看代理 iptv-replayd 也重写同一活跃日志，必须互斥
            lock_fd = None
            try:
                lock_fd = os.open(LOG_LOCK, os.O_WRONLY | os.O_CREAT, 0o644)
                fcntl.flock(lock_fd, fcntl.LOCK_EX)
            except OSError:
                lock_fd = None
            try:
                try:
                    # errors='replace'：历史损坏字节用替代符读入，避免 UnicodeDecodeError 中断
                    lines = _read_tail_lines(LOG_FILE, MAX_LOG_LINES)
                except FileNotFoundError:
                    lines = []
                lines.append(line + '\n')
                if len(lines) > MAX_LOG_LINES:
                    lines = lines[-MAX_LOG_LINES:]
                with open(LOG_FILE, 'w', encoding='utf-8') as f:
                    f.writelines(lines)
            finally:
                if lock_fd is not None:
                    try:
                        fcntl.flock(lock_fd, fcntl.LOCK_UN)
                    except OSError:
                        pass
                    os.close(lock_fd)
    except Exception:
        pass
    # 定期清理过期历史日志（每 6 小时最多执行一次）
    try:
        if time.time() - _last_history_cleanup > 21600:
            _last_history_cleanup = time.time()
            now = time.time()
            for fn in os.listdir(HISTORY_DIR):
                if not (fn.startswith('history-') and fn.endswith('.log')):
                    continue
                fp = os.path.join(HISTORY_DIR, fn)
                try:
                    if now - os.path.getmtime(fp) > HISTORY_KEEP_DAYS * 86400:
                        os.remove(fp)
                except OSError:
                    pass
    except Exception:
        pass

def save_status(**kwargs):
    """保存状态 JSON 供 LuCI 读取"""
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        # 原子替换：LuCI 轮询时不会读到写了一半的 JSON
        tmp = STATUS_FILE + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            json.dump(kwargs, f, ensure_ascii=False)
        os.replace(tmp, STATUS_FILE)
    except Exception:
        pass

# ===================== UCI 配置读取 =====================
def _cfg_int(val, default):
    """UCI 数值项容错：填错时退回默认值，避免整个配置加载失败"""
    try:
        return int(str(val).strip())
    except (TypeError, ValueError):
        return default

def _iface_src_ip(iface):
    if not iface:
        return ''
    try:
        out = subprocess.run(['ip', '-4', '-o', 'addr', 'show', 'dev', iface],
                             capture_output=True, text=True, timeout=3)
        m = re.search(r'inet (\d+\.\d+\.\d+\.\d+)', out.stdout or '')
        return m.group(1) if m else ''
    except Exception:
        return ''

def _resolve_l3_device(iface):
    if not iface:
        return ''
    try:
        out = subprocess.run(['ubus', 'call', f'network.interface.{iface}', 'status'],
                             capture_output=True, text=True, timeout=5)
        data = json.loads(out.stdout or '{}')
        return data.get('l3_device') or data.get('device') or iface
    except Exception:
        return iface

def _iface_gateway(iface):
    if not iface:
        return ''
    try:
        listing = subprocess.run(['ubus', 'list'], capture_output=True, text=True, timeout=5)
        for line in (listing.stdout or '').splitlines():
            if not line.startswith('network.interface.'):
                continue
            name = line.split('.', 2)[-1]
            out = subprocess.run(['ubus', 'call', f'network.interface.{name}', 'status'],
                                 capture_output=True, text=True, timeout=5)
            data = json.loads(out.stdout or '{}')
            l3 = data.get('l3_device') or data.get('device') or ''
            if l3 != iface and data.get('device') != iface:
                continue
            for block in (data, data.get('inactive') or {}):
                if not isinstance(block, dict):
                    continue
                for rt in block.get('route') or []:
                    if str(rt.get('target')) == '0.0.0.0' and rt.get('nexthop'):
                        return str(rt['nexthop'])
    except Exception:
        pass
    return ''

def clear_upstream_policy():
    for pref in (IPTV_RT_PREF_SRC, IPTV_RT_PREF_OIF):
        subprocess.run(['ip', 'rule', 'del', 'pref', pref], capture_output=True, timeout=5)
    subprocess.run(['ip', 'route', 'flush', 'table', IPTV_RT_TABLE], capture_output=True, timeout=5)

def ensure_upstream_policy():
    if not upstream_iface or upstream_iface in ('br-lan', 'lan', 'docker0'):
        clear_upstream_policy()
        return
    src = upstream_src_ip or _iface_src_ip(upstream_iface)
    gw = _iface_gateway(upstream_iface)
    if not src or not gw:
        log(f"上游策略：{upstream_iface} 未拿到地址或网关 (src={src} gw={gw})，跳过", error=True)
        return
    try:
        subprocess.run(['ip', 'route', 'replace', 'default', 'via', gw, 'dev', upstream_iface,
                        'table', IPTV_RT_TABLE], capture_output=True, timeout=5)
        subprocess.run(['ip', 'rule', 'del', 'pref', IPTV_RT_PREF_SRC], capture_output=True, timeout=5)
        subprocess.run(['ip', 'rule', 'add', 'pref', IPTV_RT_PREF_SRC, 'from', src,
                        'lookup', IPTV_RT_TABLE], capture_output=True, timeout=5)
        subprocess.run(['ip', 'rule', 'del', 'pref', IPTV_RT_PREF_OIF], capture_output=True, timeout=5)
        subprocess.run(['ip', 'rule', 'add', 'pref', IPTV_RT_PREF_OIF, 'oif', upstream_iface,
                        'lookup', IPTV_RT_TABLE], capture_output=True, timeout=5)
        log(f"上游策略：源 {src} / oif {upstream_iface} via {gw} table {IPTV_RT_TABLE}")
    except Exception as e:
        log(f"上游策略失败: {e}", error=True)

def load_config():
    global config, upstream_iface, upstream_src_ip
    c = {}
    try:
        out = subprocess.run(['uci', 'show', 'iptv-auth'], capture_output=True, text=True, timeout=5)
        for line in out.stdout.splitlines():
            if '=' in line and '.' in line:
                key, val = line.split('=', 1)
                c[key.strip()] = val.strip().strip("'\"")
        g = lambda k, d='': c.get(f'iptv-auth.main.{k}', d)
        config = {
            'IPTVServer': g('iptv_server', 'http://182.137.9.86:8080'),
            'LivePort': g('live_port', '23234'),
            'ReplayPort': g('replay_port', '554'),
            'auth': {
                'UserID': g('userid'), 'Authenticator': g('authenticator'),
                'StbIP': g('stbip'), 'LastTermno': g('lasttermno', '0'),
                'UserGroupNMB': g('usergroupnmb'), 'EPGGroupNMB': g('epggroupnmb'),
                'UserToken': g('usertoken'), 'STBID': g('stbid'),
                'stbinfo': g('stbinfo', 'undefined'),
            },
            'filter_pip': g('filter_pip', '1') == '1',
            'filter_keywords': [k.strip() for k in g('filter_keywords', '').split(',') if k.strip()],
            'interval': max(1, _cfg_int(g('interval', '10'), 10)),
            'epg_enabled': g('epg_enabled', '1') == '1',
            'fetch_workers': _cfg_int(g('fetch_workers', '4'), 4),
            'rtp2h_workers': g('rtp2h_workers', '4'),
            'rtp2h_rcvbuf': g('rtp2h_rcvbuf', '4194304'),
            'rtp2h_bufpool': g('rtp2h_bufpool', '16384'),
            'wan_domain': g('wan_domain', ''),
            'ota_url': g('ota_url', ''),
            'update_mirror': g('update_mirror', ''),
        }
        raw_iface = g('upstream_interface', 'eth1')
        upstream_iface = _resolve_l3_device(raw_iface) if raw_iface else ''
        upstream_src_ip = _iface_src_ip(upstream_iface) if upstream_iface else ''
        ensure_upstream_policy()
    except Exception as e:
        log(f"读取 UCI 配置失败: {e}", error=True)
    write_replayd_state()

# ===================== 回看代理运行时状态 =====================
# 回看/时移的 554 代理已拆分为独立 C 守护进程 iptv-replayd；控制面只负责在
# 鉴权拿到源站后把运行时状态原子落盘，守护进程每次接受连接时读取。
REPLAYD_STATE_FILE = '/tmp/iptv-replayd.state'

def write_replayd_state():
    """把回看代理所需的运行时状态原子写盘，供 C 守护进程 iptv-replayd 读取"""
    try:
        ip = rtsp_source_ip
        if not ip:
            # 保留上一次已落盘的源站 IP：--apply-route 等旁路进程也会刷新状态，
            # 它们拿不到频道里的源站 IP，若无条件写入空值会把主流程的值清掉
            try:
                with open(REPLAYD_STATE_FILE, encoding='utf-8') as f:
                    for ln in f:
                        if ln.startswith('rtsp_source_ip='):
                            ip = ln.split('=', 1)[1].strip()
                            break
            except FileNotFoundError:
                pass
        data = (
            f"rtsp_source_ip={ip}\n"
            f"rtsp_source_port={rtsp_source_port}\n"
            f"upstream_iface={upstream_iface}\n"
            f"upstream_src_ip={upstream_src_ip}\n"
        )
        tmp = REPLAYD_STATE_FILE + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            f.write(data)
        os.replace(tmp, REPLAYD_STATE_FILE)
    except Exception as e:
        log(f"回看代理状态写盘失败: {e}", error=True)

# ===================== HTTP 请求绑定上游接口 =====================
# 用标准库 urllib 实现 requests 的最小等价子集：保持 Cookie、可绑定上游接口、
# 支持 params/data/timeout/headers，响应对象提供 status_code / text / content / json()。
# 不再依赖第三方 requests / urllib3，装机无需 pip。
_UA = 'Mozilla/5.0'

def _raw_connect(conn):
    """建立 TCP 连接，出站前绑定上游接口与源 IP（等价 requests adapter 的 socket_options）"""
    last_err = None
    for af, socktype, proto, _canon, sa in socket.getaddrinfo(conn.host, conn.port, 0, socket.SOCK_STREAM):
        s = None
        try:
            s = socket.socket(af, socktype, proto)
            if conn.timeout is not None and conn.timeout is not socket._GLOBAL_DEFAULT_TIMEOUT:
                s.settimeout(conn.timeout)
            if upstream_iface:
                try:
                    s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, (upstream_iface + '\0').encode())
                except Exception:
                    pass
            if upstream_src_ip and af == socket.AF_INET:
                try:
                    s.bind((upstream_src_ip, 0))
                except Exception:
                    pass
            s.connect(sa)
            # 长连接复用必须关闭 Nagle：否则小请求体与延迟 ACK 叠加会引入 ~40-100ms/请求的停顿
            try:
                s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            except Exception:
                pass
            conn.sock = s
            return
        except Exception as e:
            last_err = e
            if s is not None:
                try: s.close()
                except Exception: pass
    raise last_err or OSError('connect failed')

class _BoundHTTPConnection(http.client.HTTPConnection):
    def connect(self):
        _raw_connect(self)

class _BoundHTTPSConnection(http.client.HTTPSConnection):
    def connect(self):
        _raw_connect(self)
        self.sock = self._context.wrap_socket(self.sock, server_hostname=self.host)

class _BoundHTTPHandler(urllib.request.HTTPHandler):
    def http_open(self, req):
        return self.do_open(_BoundHTTPConnection, req)

class _BoundHTTPSHandler(urllib.request.HTTPSHandler):
    def https_open(self, req):
        return self.do_open(_BoundHTTPSConnection, req, context=self._context)

class _Response:
    """requests.Response 的最小替身：status_code / text / content / json()"""
    def __init__(self, status_code, content, headers):
        self.status_code = status_code
        self.content = content
        self.headers = headers
        self._text = None
    @property
    def text(self):
        # 解码结果缓存：同一响应常被 .text 多次访问（如先判空再解析）
        if self._text is not None:
            return self._text
        enc = ''
        try:
            m = _RE_CHARSET.search(self.headers.get('Content-Type', '') or '')
            if m: enc = m.group(1)
        except Exception:
            enc = ''
        if enc:
            try:
                self._text = self.content.decode(enc, 'replace')
                return self._text
            except LookupError:
                pass
        # 无 charset：依次尝试 UTF-8 / GBK / BIG5（IPTV 页面可能是 GBK）
        for e in ('utf-8', 'gbk', 'big5'):
            try:
                self._text = self.content.decode(e)
                return self._text
            except UnicodeDecodeError: continue
        self._text = self.content.decode('utf-8', 'replace')
        return self._text
    def json(self):
        return json.loads(self.text)

def _build_opener(bound=False):
    """CookieJar 会话；bound=True 时使用绑定上游接口的连接处理器"""
    cj = http.cookiejar.CookieJar()
    handlers = [urllib.request.HTTPCookieProcessor(cj)]
    if bound:
        handlers.append(_BoundHTTPHandler())
        handlers.append(_BoundHTTPSHandler(context=ssl.create_default_context()))
    op = urllib.request.build_opener(*handlers)
    op.addheaders = [('User-Agent', _UA)]
    return op

class _Session:
    """requests.Session 的最小替代：get/post + params/data/timeout/headers"""
    def __init__(self, opener):
        self._opener = opener
    def _request(self, method, url, params=None, data=None, timeout=None, headers=None):
        if params:
            sep = '&' if '?' in url else '?'
            url = url + sep + urllib.parse.urlencode(params, doseq=True)
        body = None
        if data is not None:
            body = urllib.parse.urlencode(data, doseq=True).encode('utf-8')
        req = urllib.request.Request(url, data=body, method=method)
        if body is not None:
            req.add_header('Content-Type', 'application/x-www-form-urlencoded')
        if headers:
            for k, v in headers.items():
                req.add_header(k, v)
        try:
            resp = self._opener.open(req, timeout=timeout)
        except urllib.error.HTTPError as e:
            return _Response(e.code, e.read(), e.headers)
        with resp:
            content = resp.read()
            try:
                if 'gzip' in (resp.headers.get('Content-Encoding', '') or '').lower():
                    content = gzip.decompress(content)
            except Exception:
                pass
            return _Response(resp.status, content, resp.headers)
    def get(self, url, params=None, timeout=None, headers=None):
        return self._request('GET', url, params=params, timeout=timeout, headers=headers)
    def post(self, url, data=None, params=None, timeout=None, headers=None):
        return self._request('POST', url, params=params, data=data, timeout=timeout, headers=headers)

class _HttpClient:
    """极简 keep-alive HTTP 客户端，专用于 IPTV 内网 http:// 接口。
    相比 urllib 每次请求新建连接，这里按 host 复用一条长连接（省去每请求的 TCP
    握手与端口消耗），并维护最小 Cookie（承载鉴权会话）。仅处理明文 HTTP；https
    仍交给 _http_get 的 urllib 分支。
    """
    MAX_REDIRECTS = 5

    def __init__(self, bound=True):
        self._bound = bound
        self._conns = {}      # (host, port) -> HTTPConnection
        self._cookies = {}    # host -> {name: value}

    def _new_conn(self, host, port):
        if self._bound and (upstream_iface or upstream_src_ip):
            return _BoundHTTPConnection(host, port)
        return http.client.HTTPConnection(host, port)

    def _drop(self, key):
        conn = self._conns.pop(key, None)
        if conn is not None:
            try: conn.close()
            except Exception: pass

    def _cookie_header(self, host):
        ck = self._cookies.get(host)
        return '; '.join(f'{k}={v}' for k, v in ck.items()) if ck else None

    def _store_cookies(self, host, headers):
        for raw in (headers.get_all('Set-Cookie') or []):
            kv = raw.split(';', 1)[0].strip()
            if '=' in kv:
                k, v = kv.split('=', 1)
                if k.strip():
                    self._cookies.setdefault(host, {})[k.strip()] = v.strip()

    def _request(self, method, url, params=None, data=None, timeout=None,
                 headers=None, _redirects=0):
        parts = urllib.parse.urlsplit(url)
        if parts.scheme != 'http':
            # 非明文 HTTP：退化到 urllib（保留原行为）
            return _Session(_build_opener(bound=self._bound))._request(
                method, url, params=params, data=data, timeout=timeout, headers=headers)
        host = parts.hostname
        port = parts.port or 80
        key = (host, port)
        path = parts.path or '/'
        if parts.query:
            path += '?' + parts.query
        if params:
            qs = urllib.parse.urlencode(params, doseq=True)
            path += ('&' if '?' in path else '?') + qs
        body = None
        hdrs = {'User-Agent': _UA, 'Accept-Encoding': 'gzip', 'Connection': 'keep-alive'}
        if data is not None:
            body = urllib.parse.urlencode(data, doseq=True).encode('utf-8')
            hdrs['Content-Type'] = 'application/x-www-form-urlencoded'
        if headers:
            hdrs.update(headers)
        ck = self._cookie_header(host)
        if ck:
            hdrs['Cookie'] = ck

        status = rheaders = content = None
        for attempt in (0, 1):
            conn = self._conns.get(key)
            if conn is None:
                conn = self._new_conn(host, port)
                self._conns[key] = conn
            if timeout is not None:
                conn.timeout = timeout
                try:
                    if conn.sock is not None:
                        conn.sock.settimeout(timeout)
                except Exception:
                    pass
            try:
                conn.request(method, path, body=body, headers=hdrs)
                resp = conn.getresponse()
                content = resp.read()
                status = resp.status
                rheaders = resp.headers
                self._store_cookies(host, rheaders)
                if resp.will_close or (rheaders.get('Connection', '') or '').lower() == 'close':
                    self._drop(key)
                break
            except Exception:
                # 复用的长连接被对端关闭/失效：丢弃并重连重试一次
                self._drop(key)
                if attempt == 1:
                    raise
        if 'gzip' in (rheaders.get('Content-Encoding', '') or '').lower():
            try: content = gzip.decompress(content)
            except Exception: pass
        if status in (301, 302, 303, 307, 308) and _redirects < self.MAX_REDIRECTS:
            loc = rheaders.get('Location')
            if loc:
                nurl = urllib.parse.urljoin(url, loc)
                if status in (301, 302, 303):
                    return self._request('GET', nurl, timeout=timeout,
                                         headers=headers, _redirects=_redirects + 1)
                return self._request(method, nurl, params=None, data=data, timeout=timeout,
                                     headers=headers, _redirects=_redirects + 1)
        return _Response(status, content, rheaders)

    def get(self, url, params=None, timeout=None, headers=None):
        return self._request('GET', url, params=params, timeout=timeout, headers=headers)

    def post(self, url, data=None, params=None, timeout=None, headers=None):
        return self._request('POST', url, params=params, data=data, timeout=timeout, headers=headers)

_http_tls = threading.local()   # 每个线程独立会话：并发下载台标时互不共享 Cookie/连接

def _http_get(url, timeout=None, headers=None):
    """一次性 GET（台标 / OTA）：不绑定上游接口、不共享会话 Cookie（线程内复用连接）"""
    sess = getattr(_http_tls, 'session', None)
    if sess is None:
        sess = _Session(_build_opener(bound=False))
        _http_tls.session = sess
    return sess.get(url, timeout=timeout, headers=headers)

def create_session():
    return _HttpClient(bound=bool(upstream_iface or upstream_src_ip))

# ===================== 中兴三步鉴权 ======================
def authenticate():
    auth = config.get('auth', {})
    iptv_server = config.get('IPTVServer', '')
    if not auth or not iptv_server:
        log("鉴权配置不完整", error=True)
        return None
    session = create_session()
    try:
        session.post(f"{iptv_server}/iptvepg/platform/auth.jsp", data={
            "UserID": auth.get('UserID', ''), "Authenticator": auth.get('Authenticator', ''),
            "StbIP": auth.get('StbIP', ''), "LastTermno": auth.get('LastTermno', ''),
            "TerminalFlag": "1"
        }, timeout=15)
    except Exception as e:
        log(f"鉴权第一步失败: {e}", error=True)
        return None
    try:
        session.get(f"{iptv_server}/iptvepg/function/index.jsp", params={
            "UserGroupNMB": auth.get('UserGroupNMB', ''), "EPGGroupNMB": auth.get('EPGGroupNMB', ''),
            "UserToken": auth.get('UserToken', ''), "UserID": auth.get('UserID', ''),
            "STBID": auth.get('STBID', ''), "LastTermno": auth.get('LastTermno', ''),
            "TerminalFlag": "1"
        }, timeout=15)
    except Exception as e:
        log(f"鉴权第二步失败: {e}", error=True)
        return None
    try:
        resp = session.post(f"{iptv_server}/iptvepg/function/funcportalauth.jsp", data={
            "UserToken": auth.get('UserToken', ''), "LastTermno": auth.get('LastTermno', ''),
            "UserID": auth.get('UserID', ''), "stbinfo": auth.get('stbinfo', ''),
            "TerminalFlag": "1"
        }, timeout=15)
        log(f"鉴权完成 (响应: {resp.status_code})")
    except Exception as e:
        log(f"鉴权第三步失败: {e}", error=True)
        return None
    return session

# ===================== 频道分组 ======================
def get_group_title(nos, channelname):
    try:
        no = int(nos)
    except (ValueError, TypeError):
        no = 999
    if no < 21: group = '央视台'
    elif no < 72: group = '全国卫视'
    elif no < 178: group = '数字频道'
    else: group = '其他'
    if 'SCTV' in channelname or '四川' in channelname or '绵阳' in channelname: group = '四川省台'
    if 'CCTV' in channelname or 'CETV' in channelname: group = '央视台'
    if '4K' in channelname: group = '超高清4K'
    if 'PIP' in channelname: group = '其他'
    return group

# ===================== 频道台标（qist/TVLogo + fanmingming/live + vircloud/TVLogo + 内置种子 + 本地缓存）=====================
LOGO_DIR = '/www/logo'
LOGO_SEED_DIR = '/usr/share/iptv-auth/logos'   # 随包内置种子台标（无公开来源的频道，按台标身份命名）
# 台标仓库（gh-proxy 镜像, 直连 GitHub）：镜像优先，网络异常才直连（404 不回退，同仓库必同 404）
# qt = qist/TVLogo（1954+，扁平根目录，4K 专属台标最全，首选）
# fm = fanmingming/live（tv/=电视频道、radio/=广播电台，严禁混用）
# vc = vircloud/TVLogo
LOGO_REPO = {
    'qt': ('https://gh-proxy.com/https://raw.githubusercontent.com/qist/TVLogo/main',
           'https://raw.githubusercontent.com/qist/TVLogo/main'),
    'vc': ('https://gh-proxy.com/https://raw.githubusercontent.com/vircloud/TVLogo/main',
           'https://raw.githubusercontent.com/vircloud/TVLogo/main'),
    'fm': ('https://gh-proxy.com/https://raw.githubusercontent.com/fanmingming/live/main',
           'https://raw.githubusercontent.com/fanmingming/live/main'),
}
# 台标身份 → 显式候选 [(仓库, 相对路径), ...] 按优先级
# （fm 仓库 tv/=电视频道、radio/=广播电台，严禁混用；以下均已逐一验证存在）
LOGO_ALIAS = {
    'CCTV少儿': [('vc', 'CCTV14')],
    'CETV1': [('vc', '中国教育1台')],
    'CETV2': [('vc', '中国教育2台')],
    'CETV4': [('vc', '中国教育4台')],
    'CGTN英语': [('vc', 'CGTN')],
    'CGTN西班牙语': [('vc', 'CGTN西语')],
    'CGTN阿拉伯语': [('vc', 'CGTN阿语')],
    '北京纪实科教': [('vc', '北京纪实')],
    '书画频道': [('vc', '书画')],
    'SCTV2': [('fm', 'tv/四川文化旅游')],
    'SCTV3': [('fm', 'tv/四川经济')],
    'SCTV4': [('fm', 'tv/四川新闻')],
    'SCTV5': [('fm', 'tv/四川影视文艺')],
    'SCTV7': [('fm', 'tv/四川妇女儿童')],
    'SCTV科教': [('fm', 'tv/四川科教')],
    '峨眉电影': [('fm', 'tv/四川峨眉电影')],
    '四川乡村频道': [('fm', 'tv/四川乡村')],
    'CHC影迷电影': [('fm', 'tv/CHC影迷电影')],
    '四海钓鱼': [('fm', 'tv/四海钓鱼')],
    '环球旅游': [('fm', 'tv/环球旅游')],
    '深圳卫视4K': [('fm', 'tv/深圳卫视4K')],   # qist 该文件无 4K 元素，fm 版带"4K|超高清"标识更准
    '多彩文体4K': [('fm', 'tv/欢笑剧场4K')],   # 2026-04 由"4K欢笑剧场"更名，新台标以内置种子优先
}
# 台标网前缀：剥离后缀后只剩前缀时保留完整名
LOGO_PREFIXES = ('CCTV', 'CETV', 'CGTN', 'BRTV', 'SCTV')

def clean_channel_name(name):
    """频道名 → 台标身份（本地文件名 / URL 路径）
    规则：剥离"高清/超高清"后缀——高清台与频道本标共用台标；
          保留"4K/8K"后缀——4K 台是独立频道身份、独立文件，
          专属 4K 台标（如 北京卫视4K）不会被高清台共用；无专属台标的 4K 台
          由 download_logos 回退下载本标内容，同样存为独立文件。
          超高清须先于高清检查；剥离后只剩台标网前缀时保留完整名"""
    for suffix in ['超高清', '高清']:
        if name.endswith(suffix):
            base = name[:-len(suffix)].strip()
            if not base or base in LOGO_PREFIXES:
                return name
            return base
    return name

def logo_base_name(identity):
    """台标身份再剥离 4K/8K 后缀，得到频道本标候选名（用于无专属台标时的回退）"""
    for suffix in ['超高清', ' 8K', '8K', ' 4K', '4K']:
        if identity.endswith(suffix):
            base = identity[:-len(suffix)].strip()
            if base and base not in LOGO_PREFIXES:
                return base
            break
    return identity

def get_logo_url(name, host, port='2000'):
    """频道名 → 本地台标URL（由 download_logos 预先下载到 /www/logo/）
    路径做百分号编码（空格/中文），兼容严格解析的播放器；uhttpd 会自动解码"""
    clean = clean_channel_name(name)
    return f"http://{host}:{port}{quote('/logo/' + clean + '.png')}"

def _fetch_workers():
    """抓取类任务（节目单 / 台标）的并发度，1 表示串行"""
    try:
        return max(1, min(16, int(config.get('fetch_workers', 4) or 4)))
    except (ValueError, TypeError):
        return 4

def _parallel_map(func, items, workers):
    """在至多 workers 个线程中并发对 items 逐项调用 func(item)。
    func 需自行保证线程安全；单线程时直接串行调用（不建线程）。"""
    if workers <= 1 or len(items) <= 1:
        for it in items:
            try: func(it)
            except Exception: pass
        return
    q = queue.Queue()
    for it in items:
        q.put(it)
    def run():
        while True:
            try:
                it = q.get_nowait()
            except queue.Empty:
                return
            try: func(it)
            except Exception: pass
    ts = [threading.Thread(target=run, daemon=True) for _ in range(min(workers, len(items)))]
    for t in ts: t.start()
    for t in ts: t.join()

def download_logos(channels):
    """每次鉴权后自动下载频道台标到 /www/logo/（跳过已存在的文件）
    候选顺序：包内置种子 → 显式别名 → qist 精确身份/本标 → fm → vc
    完整名优先于本标回退：存在专属 4K 台标（qist 的四川/湖南/江苏等卫视4K）时优先采用"""
    os.makedirs(LOGO_DIR, exist_ok=True)
    counters = {'downloaded': 0, 'skipped': 0, 'failed': 0}
    lock = threading.Lock()
    # 同一台标身份可能对应多个频道，去重后既省请求也避免并发写同一文件
    seen, uniq = set(), []
    for item in channels:
        identity = clean_channel_name(item[2])
        if identity in seen:
            continue
        seen.add(identity)
        uniq.append(item)

    def one(item):
        identity = clean_channel_name(item[2])
        local_path = os.path.join(LOGO_DIR, f"{identity}.png")
        # 已存在且非空则跳过
        if os.path.exists(local_path) and os.path.getsize(local_path) > 100:
            with lock: counters['skipped'] += 1
            return
        ok = False
        # 1) 包内置种子台标（无公开来源的频道）
        seed_path = os.path.join(LOGO_SEED_DIR, f"{identity}.png")
        if os.path.exists(seed_path) and os.path.getsize(seed_path) > 100:
            try:
                with open(seed_path, 'rb') as sf:
                    data = sf.read()
                if len(data) > 100:
                    with open(local_path, 'wb') as df:
                        df.write(data)
                    ok = True
            except OSError:
                pass
        # 2) 网络候选：显式别名 → qist 精确身份/本标 → fm → vc
        # （qist 首选：4K 专属台标最全；别名优先于仓库通用匹配）
        if not ok:
            base = logo_base_name(identity)
            cands = list(LOGO_ALIAS.get(identity, []))
            for repo, rel in [('qt', identity), ('qt', base),
                              ('fm', f'tv/{identity}'), ('fm', f'tv/{base}'),
                              ('vc', identity), ('vc', base)]:
                if (repo, rel) not in cands:
                    cands.append((repo, rel))
            mirror_broken = False   # 镜像网络异常才回退直连
            for repo, rel in cands:
                mirror, direct = LOGO_REPO[repo]
                url = (direct if mirror_broken else mirror) + '/' + quote(rel, safe='/') + '.png'
                try:
                    resp = _http_get(url, timeout=15, headers={'User-Agent': _UA})
                    if resp.status_code == 200 and len(resp.content) > 100:
                        with open(local_path, 'wb') as f:
                            f.write(resp.content)
                        ok = True
                    # 404 等非 200：换下一个候选（不直连重试）
                except Exception:
                    mirror_broken = True   # 镜像不可达 → 后续候选改走直连
                if ok:
                    break
        if ok:
            with lock: counters['downloaded'] += 1
        else:
            # 下载失败时清理空文件
            try:
                os.remove(local_path)
            except OSError:
                pass
            with lock: counters['failed'] += 1

    _parallel_map(one, uniq, _fetch_workers())
    if counters['downloaded'] > 0 or counters['failed'] > 0:
        log(f"台标下载: 新增 {counters['downloaded']}, 跳过 {counters['skipped']}, 失败 {counters['failed']}")

# ===================== 频道抓取 ======================
def _parse_channel_rows(text):
    """按 addChannel(...) 逐条解析频道属性，返回 (name, url, sdp, fccip, fccport) 列表。

    门户把每个频道的全部属性放在一条 addChannel(...) 里。逐条解析而不是对
    全文做 5 次 findall 再 zip：后者在某个频道缺少 ChannelFCCIP/ChannelFCCPort
    时会因 zip 取最短而丢掉后面所有频道。以 ChannelName 为分界，缺失字段补空串。"""
    rows = []
    for part in text.split('ChannelName="')[1:]:
        name, sep, rest = part.partition('"')
        if not sep:
            name, rest = part, ''
        row = [name]
        for key in _CH_ATTR_KEYS:
            m = _RE_CH_ATTRS[key].search(rest)
            row.append(m.group(1) if m else '')
        rows.append(tuple(row))
    return rows


def fetch_channels(session):
    global rtsp_source_ip
    iptv_server = config['IPTVServer']
    try:
        resp = session.post(f"{iptv_server}/iptvepg/function/frameset_builder.jsp", data={
            "MAIN_WIN_SRC": "/iptvepg/frame78/portal.jsp", "NEED_UPDATE_STB": "1",
            "BUILD_ACTION": "FRAMESET_BUILDER"
        }, timeout=15)
        text = resp.text
    except Exception as e:
        log(f"获取频道页面失败: {e}", error=True)
        return []
    rows = _parse_channel_rows(text)
    # 频道编码：jsSetChannelInfo 第 5 个参数，EPG 查询必需（不能用频道名）
    channel_codes = _RE_CHANNEL_CODE.findall(text)
    if len(channel_codes) != len(rows):
        log(f"频道编码数量不匹配 (code={len(channel_codes)}, name={len(rows)})，以频道名为准对齐", error=True)
        if len(channel_codes) < len(rows):
            channel_codes += [''] * (len(rows) - len(channel_codes))
        else:
            channel_codes = channel_codes[:len(rows)]
    filter_pip = config.get('filter_pip', True)
    filter_kw = config.get('filter_keywords', [])
    channels = []
    index = 1
    for code, (name, url, sdp, fccip, fccport) in zip(channel_codes, rows):
        if filter_pip and 'PIP' in name: continue
        if any(kw in name for kw in filter_kw): continue
        igmp = re.search(r'igmp://([^\s|]+)', url)
        rtsp = re.search(r'(rtsp://[^\s|]+sdp)', sdp)
        if not (igmp and rtsp): continue
        group = get_group_title(index, name)
        rtsp_url = rtsp.group(1)
        # 提取 RTSP 源 IP
        if not rtsp_source_ip:
            m = re.search(r'rtsp://(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})', rtsp_url)
            if m:
                rtsp_source_ip = m.group(1)
                log(f"提取 RTSP 源 IP: {rtsp_source_ip}")
                # 源站就绪后立即落盘，回看代理（C 守护进程）据此放行连接
                write_replayd_state()
        channels.append((index, code, name, group, rtsp_url, igmp.group(1), fccip, fccport))
        index += 1
    log(f"共获取到 {len(channels)} 个有效频道")
    return channels

# ===================== 内网地址自动获取 =====================
def get_lan_ip():
    """获取本机局域网 IP：优先读 UCI 的 LAN 接口地址，兜底 UDP 探测。
    用于 M3U 播放列表的 EPG（x-tvg-url）地址，无需手工配置。"""
    try:
        out = subprocess.run(['uci', '-q', 'get', 'network.lan.ipaddr'],
                             capture_output=True, text=True, timeout=5)
        ip = out.stdout.strip().strip("'\"").split('/')[0]
        if ip:
            return ip
    except Exception:
        pass
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('192.168.10.1', 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return '127.0.0.1'

# ===================== M3U 生成（rtp2httpd 格式）=====================
def _fcc_suffix(fccip, fccport):
    """组播地址后的 FCC 参数；两字段都有效才携带"""
    if fccip and fccport and str(fccip).strip() and str(fccport).strip():
        return f"/?fcc={fccip}:{fccport}"
    return ''


def _catchup_source(host, live_port, replay_host, replay_port, ch_id):
    """回看地址模板；playseek 占位符原样保留给播放器替换"""
    return (f"http://{host}:{live_port}/rtsp/{replay_host}:{replay_port}/PLTV/{ch_id}.smil"
            f"?playseek=${{(b)yyyyMMddHHmmss}}-${{(e)yyyyMMddHHmmss}}")


def generate_m3u(channels):
    lan = get_lan_ip()
    replay_port = config['ReplayPort']
    live_port = config['LivePort']
    replay_host = lan if lan != '127.0.0.1' else '127.0.0.1'

    # ---- 内网直播版 Lan.m3u ----
    with open(M3U_PATH, 'w', encoding='utf-8') as f:
        f.write(f'#EXTM3U x-tvg-url="http://{lan}/PL.xml.gz"\n')
        for idx, code, name, group, rtspurl, igmpurl, fccip, fccport in channels:
            rtpurl = f"rtp://{igmpurl}{_fcc_suffix(fccip, fccport)}"
            logo = get_logo_url(name, lan)
            ch_id = _catchup_channel_id(rtspurl)
            if ch_id:
                catchup = _catchup_source(replay_host, live_port, replay_host, replay_port, ch_id)
                f.write(f'#EXTINF:-1 tvg-id="{idx}" tvg-name="{name}" tvg-logo="{logo}" group-title="{group}" '
                       f'catchup="default" catchup-source="{catchup}", {name}\n')
            else:
                f.write(f'#EXTINF:-1 tvg-id="{idx}" tvg-name="{name}" tvg-logo="{logo}" group-title="{group}", {name}\n')
            f.write(f'{rtpurl}\n')
    log(f"M3U 已生成: {M3U_PATH} ({len(channels)} 频道)")
    try:
        os.remove(LEGACY_M3U_PATH)
    except OSError:
        pass

    # ---- 内网回看版 LanReplay.m3u ----
    with open(REPLAY_M3U_PATH, 'w', encoding='utf-8') as f:
        f.write(f'#EXTM3U x-tvg-url="http://{lan}/PL.xml.gz"\n')
        replay_count = 0
        for idx, code, name, group, rtspurl, igmpurl, fccip, fccport in channels:
            ch_id = _catchup_channel_id(rtspurl)
            if not ch_id:
                continue
            logo = get_logo_url(name, lan)
            live_url = f"rtsp://{replay_host}:{replay_port}/PLTV/{ch_id}.smil"
            f.write(f'#EXTINF:-1 tvg-id="{idx}" tvg-name="{name}" tvg-logo="{logo}" group-title="回看", {name}\n')
            f.write(f'{live_url}\n')
            replay_count += 1
    log(f"回看 M3U 已生成: {REPLAY_M3U_PATH} ({replay_count} 频道)")

    # ============ 外网 M3U（融合版 + 纯回看版）============
    # 仅当用户配置了 wan_domain 时才生成
    # 外网需映射 554 (RTSP) + 2000 (HTTP) + 23234 (rtp2httpd HTTP 代理) 端口
    wan_domain = config.get('wan_domain', '').strip()
    if wan_domain:
        wan_domain = wan_domain.rstrip('/')
        wan_epg = f"http://{wan_domain}:2000/PL.xml.gz"

        # ---- 外网融合版 WanPlay.m3u ----
        # 直播 URL 走 rtp2httpd HTTP 代理（外网无法直接加入组播）：
        #   http://域名:23234/rtp/<组播地址>/?fcc=<fcc源>
        # catchup 同样走 HTTP 代理: http://域名:23234/rtsp/内网IP:554/PLTV/...
        with open(WAN_M3U_PATH, 'w', encoding='utf-8') as f:
            f.write(f'#EXTM3U x-tvg-url="{wan_epg}"\n')
            wan_count = 0
            for idx, code, name, group, rtspurl, igmpurl, fccip, fccport in channels:
                rtpurl = f"http://{wan_domain}:{live_port}/rtp/{igmpurl}{_fcc_suffix(fccip, fccport)}"
                logo = get_logo_url(name, wan_domain)
                ch_id = _catchup_channel_id(rtspurl)
                if ch_id:
                    catchup = _catchup_source(wan_domain, live_port, replay_host, replay_port, ch_id)
                    f.write(f'#EXTINF:-1 tvg-id="{idx}" tvg-name="{name}" tvg-logo="{logo}" group-title="{group}" '
                           f'catchup="default" catchup-source="{catchup}", {name}\n')
                else:
                    f.write(f'#EXTINF:-1 tvg-id="{idx}" tvg-name="{name}" tvg-logo="{logo}" group-title="{group}", {name}\n')
                f.write(f'{rtpurl}\n')
                wan_count += 1
        log(f"外网融合 M3U 已生成: {WAN_M3U_PATH} ({wan_count} 频道)")

        # ---- 外网回看版 WanReplay.m3u ----
        # 直播 URL 用 rtsp://域名:554/PLTV/...
        with open(WAN_REPLAY_M3U_PATH, 'w', encoding='utf-8') as f:
            f.write(f'#EXTM3U x-tvg-url="{wan_epg}"\n')
            wan_replay_count = 0
            for idx, code, name, group, rtspurl, igmpurl, fccip, fccport in channels:
                ch_id = _catchup_channel_id(rtspurl)
                if not ch_id:
                    continue
                logo = get_logo_url(name, wan_domain)
                live_url = f"rtsp://{wan_domain}:{replay_port}/PLTV/{ch_id}.smil"
                f.write(f'#EXTINF:-1 tvg-id="{idx}" tvg-name="{name}" tvg-logo="{logo}" group-title="回看", {name}\n')
                f.write(f'{live_url}\n')
                wan_replay_count += 1
        log(f"外网回看 M3U 已生成: {WAN_REPLAY_M3U_PATH} ({wan_replay_count} 频道)")
    else:
        for p in (WAN_M3U_PATH, WAN_REPLAY_M3U_PATH):
            try:
                os.remove(p)
            except OSError:
                pass

# ===================== 节目单 =====================
def _epg_base_name(name):
    n = (name or '').strip()
    for suffix in ('超高清', ' 8K', '8K', ' 4K', '4K'):
        if n.endswith(suffix):
            n = n[:-len(suffix)].rstrip()
            break
    return n

def _epg_prog_count(days):
    return sum(len(d) for d in days)

def backfill_4k_epg(playlistdata):
    """4K 频道运营商返回空单时，按去掉 4K 后的台名回填同名高清台节目单。"""
    by_name = {}
    for item in playlistdata:
        by_name.setdefault(item[1], []).append(item)
    filled = 0
    out = []
    for index, name, days in playlistdata:
        if _epg_prog_count(days) > 0 or '4K' not in name:
            out.append((index, name, days))
            continue
        base = _epg_base_name(name)
        source = None
        best = 0
        for cand in (base + '高清', base, base + ' HD'):
            for item in by_name.get(cand, []):
                n = _epg_prog_count(item[2])
                if n > best:
                    best = n
                    source = item
        if source and best > 0:
            copied = [list(d) for d in source[2]]
            out.append((index, name, copied))
            filled += 1
            log(f"4K节目单回填: {name} <- {source[1]} ({best} 条)")
        else:
            out.append((index, name, days))
    if filled:
        log(f"4K节目单回填完成: {filled} 个频道")
    return out

def _fetch_channel_epg(session, code):
    """抓取单个频道最近 8 天（含今天）的节目单，返回 [day_data, ...]"""
    iptv_server = config['IPTVServer']
    days_data = []
    start_date = datetime.datetime.today().date() - timedelta(days=6)
    for _ in range(8):
        query_date = start_date.strftime("%Y.%m.%d")
        try:
            resp = session.get(f"{iptv_server}/iptvepg/frame299/action/tvod/getTvodlist.jsp",
                             params={"channelcode": [code], "timedata": [query_date]}, timeout=10)
            if resp.status_code == 200 and resp.text:
                days_data.append(parse_day_data(resp.text))
            else:
                days_data.append([])
        except Exception:
            days_data.append([])
        start_date += timedelta(days=1)
    return days_data

def fetch_epg(session, channels):
    if not config.get('epg_enabled', True): return
    total = len(channels)
    log(f"开始获取 {total} 个频道的节目单...")
    if total == 0:
        generate_epg_xml(backfill_4k_epg([]))
        return
    workers = min(_fetch_workers(), total)

    # 串行：沿用传入会话，每 30 个频道重新鉴权（与原行为完全一致）
    if workers <= 1:
        playlistdata = []
        for idx, (index, code, name, group, rtspurl, igmpurl, fccip, fccport) in enumerate(channels):
            if (idx + 1) % 20 == 0:
                log(f"已处理 {idx+1}/{total} 个频道的节目单")
            if idx > 0 and idx % 30 == 0:
                log(f"重新验证鉴权信息 (频道 {index})")
                session = authenticate()
                if session is None: break
            playlistdata.append((index, name, _fetch_channel_epg(session, code)))
        generate_epg_xml(backfill_4k_epg(playlistdata))
        return

    # 并行：只做一次鉴权，随后每个 worker 复制该会话的 Cookie 并各自建立独立长连接。
    # 这样避免多路独立鉴权互相顶掉（门户通常单会话），又让请求真正并发。
    base_cookies = getattr(session, '_cookies', None) or {}
    bound = getattr(session, '_bound', bool(upstream_iface or upstream_src_ip))
    results = [None] * total
    q = queue.Queue()
    for i in range(total):
        q.put(i)
    lock = threading.Lock()
    progress = [0]

    def worker():
        sess = _HttpClient(bound=bound)
        sess._cookies = {h: dict(c) for h, c in base_cookies.items()}
        while True:
            try:
                i = q.get_nowait()
            except queue.Empty:
                return
            results[i] = _fetch_channel_epg(sess, channels[i][1])
            with lock:
                progress[0] += 1
                if progress[0] % 20 == 0:
                    log(f"已处理 {progress[0]}/{total} 个频道的节目单")

    ts = [threading.Thread(target=worker, daemon=True) for _ in range(workers)]
    for t in ts: t.start()
    for t in ts: t.join()
    playlistdata = [(channels[i][0], channels[i][2], results[i] or []) for i in range(total)]
    generate_epg_xml(backfill_4k_epg(playlistdata))

def parse_day_data(text):
    """解析节目单（formatdayplaydata：JSON 风格 prevueName/beginTime/endTime）"""
    programs = []
    try:
        for playname, starttime_str, endtime_str in _RE_EPG_PROGRAM.findall(text):
            playname = playname.translate(_EPG_TITLE_TRANS)
            start_dt = end_dt = None
            for fmt in ("%Y.%m.%d %H:%M:%S", "%Y-%m-%d %H:%M:%S", "%Y/%m/%d %H:%M:%S"):
                try:
                    start_dt = datetime.datetime.strptime(starttime_str, fmt)
                    end_dt = datetime.datetime.strptime(endtime_str, fmt)
                    break
                except ValueError:
                    continue
            if not start_dt or not end_dt:
                continue
            programs.append((start_dt.strftime("%Y%m%d%H%M%S") + " +0800", playname,
                             end_dt.strftime("%Y%m%d%H%M%S") + " +0800"))
    except Exception:
        pass
    return programs

def generate_epg_xml(playlistdata):
    def xml_escape(text):
        if not text: return ""
        return text.replace("&","&amp;").replace("<","&lt;").replace(">","&gt;").replace('"',"&quot;").replace("'","&apos;")
    try:
        # 明文与 gzip 同遍写盘：省掉写完 5MB 再整份读回压缩的开销
        with open(EPG_PATH, 'w', encoding='utf-8') as f, gzip.open(EPG_GZ_PATH, 'wb') as gz:
            def w(s):
                f.write(s)
                gz.write(s.encode('utf-8'))
            w('<?xml version="1.0" encoding="UTF-8"?>\n<tv info-name="四川电信EPG">\n')
            for index, name, days in playlistdata:
                w(f'    <channel id="{index}">\n        <display-name lang="zh">{xml_escape(name)}</display-name>\n    </channel>\n')
                for day_data in days:
                    for start, playname, end in day_data:
                        w(f'    <programme channel="{index}" start="{start}" stop="{end}">\n')
                        w(f'        <title lang="zh">{xml_escape(playname)}</title>\n    </programme>\n')
            w('</tv>')
        log(f"节目单已生成: {EPG_PATH}")
    except Exception as e:
        log(f"节目单生成失败: {e}", error=True)

def _get_installed_version():
    """查询当前安装的 iptv-auth 包版本（兼容 apk / opkg 双包管理器）"""
    # apk（iStoreOS 25.12+）：行格式 iptv-auth-2.2.1-r0 ...
    try:
        result = subprocess.run(['apk', 'list', '--installed'], capture_output=True, text=True, timeout=5)
        for line in result.stdout.splitlines():
            if line.startswith('iptv-auth-'):
                return line.split()[0].replace('iptv-auth-', '')
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        pass
    # opkg（传统 OpenWrt）：行格式 iptv-auth - 2.2.1-r0
    try:
        result = subprocess.run(['opkg', 'list-installed'], capture_output=True, text=True, timeout=5)
        for line in result.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[0] == 'iptv-auth' and parts[1] == '-':
                return parts[2]
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        pass
    return ''

def check_ota_update():
    """定时任务完成后自动检查 OTA 更新（仅日志提示，不自动安装）"""
    ota_url = config.get('ota_url', '')
    if not ota_url:
        return
    try:
        urls = [ota_url]
        mirror = config.get('update_mirror', '') or ''
        if mirror and not ota_url.startswith(mirror):
            urls = [mirror + ota_url]
        elif 'githubusercontent.com' in ota_url or 'github.com' in ota_url:
            urls.append('https://gh-proxy.com/' + ota_url)
        info = None
        for u in urls:
            try:
                resp = _http_get(u, timeout=15)
                if resp.status_code == 200:
                    info = resp.json()
                    break
            except Exception:
                continue
        if not info:
            return
        latest = info.get('version', '')
        if not latest:
            return
        # 获取当前版本（apk / opkg 双管理器兼容）
        current = _get_installed_version()
        if not current:
            return
        # 简单版本比较：去 -rN 后缀，逐段比对
        cur_parts = [int(x) for x in current.split('-')[0].split('.')]
        new_parts = [int(x) for x in latest.split('-')[0].split('.')]
        while len(cur_parts) < 3: cur_parts.append(0)
        while len(new_parts) < 3: new_parts.append(0)
        if new_parts > cur_parts:
            log(f"OTA 检测到新版本 {latest}（当前 {current}），可在 LuCI 状态页在线更新")
    except Exception:
        pass

# ===================== 主任务 =====================
def run_task():
    now_str = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    log("=== 开始执行 IPTV 鉴权任务 ===")
    session = authenticate()
    # 刷机/开机后专线 DHCP 已拿到地址但网关 ARP 未 REACHABLE 时，
    # 第一次会 Host unreachable；不重试就要等到 interval（默认 10 小时）
    if session is None:
        for attempt in range(1, 12):
            log(f"鉴权未连通，20 秒后重试 ({attempt}/11)")
            time.sleep(20)
            load_config()
            session = authenticate()
            if session is not None:
                break
    if session is None:
        log("鉴权失败，无法继续", error=True)
        save_status(last_run=now_str, auth_ok=False)
        return False
    channels = fetch_channels(session)
    if not channels:
        log("未获取到频道数据", error=True)
        save_status(last_run=now_str, auth_ok=False, channels=0)
        return False
    generate_m3u(channels)
    # M3U 写完立即通知 rtp2httpd 重载（不等 EPG——EPG 抓取耗时约 10 分钟，
    # 频道列表应尽快生效）
    try:
        subprocess.run(['killall', '-HUP', 'rtp2httpd'], capture_output=True, timeout=5)
        log("已通知 rtp2httpd 重新加载 M3U")
    except Exception:
        pass
    # 鉴权与频道已就绪，先落盘状态（EPG 在后台继续抓）
    save_status(last_run=now_str, auth_ok=True, channels=len(channels),
                next_run=(datetime.datetime.now() + timedelta(hours=config.get('interval', 10))).strftime('%Y-%m-%d %H:%M:%S'))
    download_logos(channels)
    if config.get('epg_enabled', True):
        fetch_epg(session, channels)
        # EPG 就绪后补一次重载：rtp2httpd 在上面 M3U 重载时会顺带抓 EPG，
        # 但首次运行时 PL.xml.gz 尚未生成（EPG 抓取约需 10 分钟），
        # 其内置重试撑不到 EPG 就绪就放弃，导致 /epg.xml 长期 404
        try:
            if os.path.exists(EPG_GZ_PATH) and os.path.getsize(EPG_GZ_PATH) > 0:
                subprocess.run(['killall', '-HUP', 'rtp2httpd'], capture_output=True, timeout=5)
                log("已通知 rtp2httpd 重新加载 EPG")
            else:
                log("EPG 文件未生成，跳过 rtp2httpd 重载通知", error=True)
        except Exception:
            pass
    save_status(last_run=now_str, auth_ok=True, channels=len(channels),
                next_run=(datetime.datetime.now() + timedelta(hours=config.get('interval', 10))).strftime('%Y-%m-%d %H:%M:%S'))
    # 定时任务完成后自动检查 OTA 更新（仅日志提示，不自动安装）
    check_ota_update()
    log("=== 任务执行完成 ===")
    return True

def main_loop():
    load_config()
    # 554 回看代理由独立 C 守护进程 iptv-replayd 承担，控制面仅负责状态落盘
    # 启动时执行一次
    run_task()
    # 定时循环 + 手动执行标志（/tmp/iptv-auth-runnow，LuCI 页面/保存配置时 touch）
    interval = config.get('interval', 10)
    log(f"定时任务已设置: 每 {interval} 小时执行一次（手动执行标志生效，5 秒内响应）")
    RUN_FLAG = '/tmp/iptv-auth-runnow'
    while True:
        interval = config.get('interval', 10)
        deadline = time.time() + interval * 3600
        # 内层 5 秒轮询：到点执行定时任务，或检测到手动执行标志立即执行
        while True:
            try:
                if os.path.exists(RUN_FLAG):
                    os.remove(RUN_FLAG)
                    log("检测到手动执行标志，立即执行任务")
                    load_config()
                    run_task()
                    break
            except OSError:
                pass
            if time.time() >= deadline:
                load_config()
                run_task()
                break
            time.sleep(5)

if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--apply-route':
        load_config()
        sys.exit(0)
    if len(sys.argv) > 1 and sys.argv[1] == '--clear-route':
        clear_upstream_policy()
        sys.exit(0)
    main_loop()
