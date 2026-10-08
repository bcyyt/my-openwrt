#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""iptv-auth.py — 中兴 IPTV 鉴权 + 频道抓取 + M3U 生成 + RTSP 回看代理

工作流程：
  1. 从 UCI 读取配置
  2. 中兴三步鉴权 → 抓取频道 → 生成 M3U（喂给 rtp2httpd）
  3. 启动 RTSP 代理（554 端口，处理回看/时移的 302 跳转 + URL 转换）
  4. 定时循环刷新频道和节目单
  5. 输出状态 JSON 供 LuCI 读取
"""
import os, sys, re, json, time, gzip, socket, subprocess, datetime, threading
import requests
from urllib.parse import quote
from datetime import timedelta

# ===================== 路径常量 =====================
M3U_PATH = '/www/IPTV.m3u'
REPLAY_M3U_PATH = '/www/LanReplay.m3u'     # 回看专用播放列表
WAN_M3U_PATH = '/www/WanPlay.m3u'          # 外网融合版（直播+回看）
WAN_REPLAY_M3U_PATH = '/www/WanReplay.m3u' # 外网纯回看版
EPG_PATH = '/www/PL.xml'
EPG_GZ_PATH = '/www/PL.xml.gz'
LOG_DIR = '/var/log/iptv-auth'
LOG_FILE = os.path.join(LOG_DIR, 'iptv-auth.log')
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
rtsp_source_ip = ''     # 原始 RTSP 源站 IP
rtsp_source_port = 554
proxy_listening = False
_log_lock = threading.Lock()   # 日志线程锁：RTSP 代理线程与任务线程并发写保护

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
            lines = []
            try:
                # errors='replace'：历史损坏字节用替代符读入，避免 UnicodeDecodeError 中断
                with open(LOG_FILE, 'r', encoding='utf-8', errors='replace') as f:
                    lines = f.readlines()
            except FileNotFoundError:
                pass
            lines.append(line + '\n')
            if len(lines) > MAX_LOG_LINES:
                lines = lines[-MAX_LOG_LINES:]
            with open(LOG_FILE, 'w', encoding='utf-8') as f:
                f.writelines(lines)
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
        with open(STATUS_FILE, 'w', encoding='utf-8') as f:
            json.dump(kwargs, f, ensure_ascii=False)
    except Exception:
        pass

# ===================== UCI 配置读取 =====================
def load_config():
    global config, upstream_iface
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
            'interval': int(g('interval', '10') or '10'),
            'epg_enabled': g('epg_enabled', '1') == '1',
            'rtp2h_workers': g('rtp2h_workers', '4'),
            'rtp2h_rcvbuf': g('rtp2h_rcvbuf', '1572864'),
            'rtp2h_bufpool': g('rtp2h_bufpool', '32768'),
            'wan_domain': g('wan_domain', ''),
            'ota_url': g('ota_url', ''),
        }
        upstream_iface = g('upstream_interface', 'eth1')
    except Exception as e:
        log(f"读取 UCI 配置失败: {e}", error=True)

# ===================== HTTP 请求绑定上游接口 =====================
def create_session():
    import requests
    from urllib3.connection import HTTPConnection
    session = requests.Session()
    session.headers.update({'User-Agent': 'Mozilla/5.0'})
    if upstream_iface:
        _iface_opts = list(HTTPConnection.default_socket_options) + [
            (socket.SOL_SOCKET, socket.SO_BINDTODEVICE, (upstream_iface + '\0').encode())
        ]
        class _IfaceAdapter(requests.adapters.HTTPAdapter):
            def init_poolmanager(self, *a, **kw):
                kw['socket_options'] = _iface_opts
                super().init_poolmanager(*a, **kw)
        session.mount('http://', _IfaceAdapter())
        session.mount('https://', _IfaceAdapter())
    return session

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

def download_logos(channels):
    """每次鉴权后自动下载频道台标到 /www/logo/（跳过已存在的文件）
    候选顺序：包内置种子 → 显式别名 → qist 精确身份/本标 → fm → vc
    完整名优先于本标回退：存在专属 4K 台标（qist 的四川/湖南/江苏等卫视4K）时优先采用"""
    os.makedirs(LOGO_DIR, exist_ok=True)
    downloaded = 0
    skipped = 0
    failed = 0
    for idx, code, name, group, rtspurl, igmpurl, fccip, fccport in channels:
        identity = clean_channel_name(name)
        local_path = os.path.join(LOGO_DIR, f"{identity}.png")
        # 已存在且非空则跳过
        if os.path.exists(local_path) and os.path.getsize(local_path) > 100:
            skipped += 1
            continue
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
                    resp = requests.get(url, timeout=15,
                                       headers={'User-Agent': 'Mozilla/5.0'})
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
            downloaded += 1
        else:
            # 下载失败时清理空文件
            try:
                os.remove(local_path)
            except OSError:
                pass
            failed += 1
    if downloaded > 0 or failed > 0:
        log(f"台标下载: 新增 {downloaded}, 跳过 {skipped}, 失败 {failed}")

# ===================== 频道抓取 ======================
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
    channel_names = re.findall(r'ChannelName="(.*?)"', text)
    channel_urls = re.findall(r'ChannelURL="(.*?)"', text)
    channelsdp = re.findall(r'ChannelSDP="(.*?)"', text)
    fcc_ips = re.findall(r'ChannelFCCIP="(.*?)"', text)
    fcc_ports = re.findall(r'ChannelFCCPort="(.*?)"', text)
    # 频道编码：jsSetChannelInfo 第 5 个参数，EPG 查询必需（不能用频道名）
    channel_codes = re.findall(r"jsSetChannelInfo\('[\w]+','[\w]+','[\w]+','[\w]+','([\w]+)'", text)
    if len(channel_codes) != len(channel_names):
        log(f"频道编码数量不匹配 (code={len(channel_codes)}, name={len(channel_names)})，以频道名为准对齐", error=True)
        if len(channel_codes) < len(channel_names):
            channel_codes += [''] * (len(channel_names) - len(channel_codes))
        else:
            channel_codes = channel_codes[:len(channel_names)]
    filter_pip = config.get('filter_pip', True)
    filter_kw = config.get('filter_keywords', [])
    channels = []
    index = 1
    for code, name, url, sdp, fccip, fccport in zip(channel_codes, channel_names, channel_urls, channelsdp, fcc_ips, fcc_ports):
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
        ip = out.stdout.strip().strip("'\"")
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
def generate_m3u(channels):
    lan = get_lan_ip()
    replay_port = config['ReplayPort']
    live_port = config['LivePort']
    replay_host = lan if lan != '127.0.0.1' else '127.0.0.1'

    # ---- 内网融合版 IPTV.m3u ----
    with open(M3U_PATH, 'w', encoding='utf-8') as f:
        f.write(f'#EXTM3U x-tvg-url="http://{lan}/PL.xml.gz"\n')
        for idx, code, name, group, rtspurl, igmpurl, fccip, fccport in channels:
            if fccip and fccport and str(fccip).strip() and str(fccport).strip():
                rtpurl = f"rtp://{igmpurl}/?fcc={fccip}:{fccport}"
            else:
                rtpurl = f"rtp://{igmpurl}"
            logo = get_logo_url(name, lan)
            m = re.search(r'rtsp://[\d.]+:\d+/live/(.+?)\.sdp', rtspurl)
            if m:
                catchup = f"http://{replay_host}:{live_port}/rtsp/{replay_host}:{replay_port}/PLTV/{m.group(1)}.smil?playseek=${{(b)yyyyMMddHHmmss}}-${{(e)yyyyMMddHHmmss}}"
                f.write(f'#EXTINF:-1 tvg-id="{idx}" tvg-name="{name}" tvg-logo="{logo}" group-title="{group}" '
                       f'catchup="default" catchup-source="{catchup}", {name}\n')
            else:
                f.write(f'#EXTINF:-1 tvg-id="{idx}" tvg-name="{name}" tvg-logo="{logo}" group-title="{group}", {name}\n')
            f.write(f'{rtpurl}\n')
    log(f"M3U 已生成: {M3U_PATH} ({len(channels)} 频道)")

    # ---- 内网回看版 LanReplay.m3u ----
    with open(REPLAY_M3U_PATH, 'w', encoding='utf-8') as f:
        f.write(f'#EXTM3U x-tvg-url="http://{lan}/PL.xml.gz"\n')
        replay_count = 0
        for idx, code, name, group, rtspurl, igmpurl, fccip, fccport in channels:
            m = re.search(r'rtsp://[\d.]+:\d+/live/(.+?)\.sdp', rtspurl)
            if not m:
                continue
            ch_id = m.group(1)
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
                if fccip and fccport and str(fccip).strip() and str(fccport).strip():
                    rtpurl = f"http://{wan_domain}:{live_port}/rtp/{igmpurl}/?fcc={fccip}:{fccport}"
                else:
                    rtpurl = f"http://{wan_domain}:{live_port}/rtp/{igmpurl}"
                logo = get_logo_url(name, wan_domain)
                m = re.search(r'rtsp://[\d.]+:\d+/live/(.+?)\.sdp', rtspurl)
                if m:
                    catchup = f"http://{wan_domain}:{live_port}/rtsp/{replay_host}:{replay_port}/PLTV/{m.group(1)}.smil?playseek=${{(b)yyyyMMddHHmmss}}-${{(e)yyyyMMddHHmmss}}"
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
                m = re.search(r'rtsp://[\d.]+:\d+/live/(.+?)\.sdp', rtspurl)
                if not m:
                    continue
                ch_id = m.group(1)
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
def fetch_epg(session, channels):
    if not config.get('epg_enabled', True): return
    iptv_server = config['IPTVServer']
    playlistdata = []
    total = len(channels)
    log(f"开始获取 {total} 个频道的节目单...")
    for idx, (index, code, name, group, rtspurl, igmpurl, fccip, fccport) in enumerate(channels):
        if (idx + 1) % 20 == 0:
            log(f"已处理 {idx+1}/{total} 个频道的节目单")
        if idx > 0 and idx % 30 == 0:
            log(f"重新验证鉴权信息 (频道 {index})")
            session = authenticate()
            if session is None: break
        days_data = []
        start_date = datetime.datetime.today().date() - timedelta(days=6)
        for day in range(8):
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
        playlistdata.append((index, name, days_data))
    generate_epg_xml(playlistdata)

def parse_day_data(text):
    """解析节目单（formatdayplaydata：JSON 风格 prevueName/beginTime/endTime）"""
    programs = []
    try:
        clean_text = re.findall(
            r'(prevuename|prevueName)":"(.*?)".*?(begintime|beginTime)":"(.*?)".*?(endtime|endTime)":"(.*?)"',
            text, re.DOTALL)
        trantab = str.maketrans({'<': '《', '>': '》'})
        for _, playname, _, starttime_str, _, endtime_str in clean_text:
            playname = playname.translate(trantab)
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
        with open(EPG_PATH, 'w', encoding='utf-8') as f:
            f.write('<?xml version="1.0" encoding="UTF-8"?>\n<tv info-name="四川电信EPG">\n')
            for index, name, days in playlistdata:
                f.write(f'    <channel id="{index}">\n        <display-name lang="zh">{xml_escape(name)}</display-name>\n    </channel>\n')
                for day_data in days:
                    for start, playname, end in day_data:
                        f.write(f'    <programme channel="{index}" start="{start}" stop="{end}">\n')
                        f.write(f'        <title lang="zh">{xml_escape(playname)}</title>\n    </programme>\n')
            f.write('</tv>')
        with open(EPG_PATH, 'r', encoding='utf-8') as f_in:
            with gzip.open(EPG_GZ_PATH, 'wb') as f_out:
                f_out.write(f_in.read().encode('utf-8'))
        log(f"节目单已生成: {EPG_PATH}")
    except Exception as e:
        log(f"节目单生成失败: {e}", error=True)

# ===================== RTSP 代理 ======================
SOCK_TIMEOUT = 30
PROXY_RECV_BUF = 262144

def _tune_socket(sock):
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 262144)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 262144)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    except Exception:
        pass

def _bind_upstream(sock):
    if upstream_iface:
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, (upstream_iface + '\0').encode())
        except Exception:
            pass

def _safe_decode(data):
    try: return data.decode('utf-8', errors='ignore')
    except: return None

def _parse_rtsp_status(data):
    txt = _safe_decode(data)
    if not txt: return ''
    m = re.match(r'RTSP/\d\.\d\s+(\d+)', txt)
    return m.group(1) if m else ''

def getaddress(response):
    txt = _safe_decode(response)
    if not txt: return "0", 0
    m = re.search(r'rtsp://([^/:]+)(?::(\d+))?', txt)
    return (m.group(1), int(m.group(2))) if m and m.group(1) else ("0", 0)

def replaceip(response, ip, port):
    txt = _safe_decode(response)
    if not txt: return response
    try:
        t = re.sub(r'rtsp://\b[a-zA-Z0-9_.-]+\.[a-zA-Z]{2,}\b', f'rtsp://{ip}', txt)
        t = re.sub(r'rtsp://\d+\.\d+\.\d+\.\d+', f'rtsp://{ip}', t)
        t = re.sub(r'(?<=://)([^/:]+)(?::\d+)?(?=/|$)', f'\\1:{port}', t)
        return t.encode('utf-8')
    except: return response

def replacelocation(request, location):
    txt = _safe_decode(request)
    if not txt: return request
    m = re.search(r'(rtsp://[^\s]+)\s+RTSP/1.0', txt)
    return txt.replace(m.group(1), location).encode('utf-8') if m else request

def describe(firstrequest):
    new_ip_port = f"{rtsp_source_ip}:{rtsp_source_port}"
    txt = _safe_decode(firstrequest)
    if not txt: return firstrequest
    try:
        t = re.sub(r'rtsp://\b[a-zA-Z0-9_.-]+\.[a-zA-Z]{2,}\b:\d+', f'rtsp://{new_ip_port}', txt)
        t = re.sub(r'rtsp://\d+\.\d+\.\d+\.\d+:\d+', f'rtsp://{new_ip_port}', t)
        lines = t.split('\n')
        lines[0] = lines[0].replace('OPTIONS', 'DESCRIBE')
        if len(lines) > 1: lines[1] = lines[1].replace('CSeq: 1', 'CSeq: 2')
        lines.insert(1, 'Accept: application/sdp')
        return '\n'.join(lines).encode('utf-8')
    except: return firstrequest

def getlocation(response):
    txt = _safe_decode(response)
    if not txt: return ""
    m = re.search(r'Location:\s*([^\s]+)', txt, re.IGNORECASE)
    return m.group(1) if m else ""

def newoptions(location):
    return (f"OPTIONS {location} RTSP/1.0\r\nCSeq: 1\r\nUser-Agent: Lavf62.1.100\r\n\r\n").encode()

def Translator(source):
    """RTSP URL 翻译：回看(playseek)→直播格式，直播→sdp格式"""
    txt = _safe_decode(source)
    if not txt: return source
    try:
        if 'playseek' in txt:
            playseek = re.search(r'playseek=\d{14}-\d{14}', txt)
            if playseek:
                ps = playseek.group(0)
                pt = ps.replace("playseek", "programbegin").replace("-", "+08&programend=") + "+08"
                # 回看日志：记录频道与时间区间，便于排查
                ch_match = re.search(r'/PLTV/(.+?)\.smil', txt)
                ch_name = ch_match.group(1) if ch_match else 'unknown'
                ts_match = re.search(r'playseek=(\d{14})-(\d{14})', txt)
                if ts_match:
                    log(f"代理: 回看 {ch_name} | {ts_match.group(1)}~{ts_match.group(2)}")
                return txt.replace("TVOD", "live").replace("smil?", "mpg?vcdnid=001&boid=001&contname=&").replace(ps, pt).encode('utf-8')
        else:
            return txt.replace("PLTV", "live").replace("smil", "sdp?vcdnid=001").encode('utf-8')
        return source
    except: return source

_clients_lock = threading.Lock()   # 客户端档案并发写保护（每个代理线程都会记录）

def record_client(ip, ua, channel):
    """记录回看客户端档案（IP + 设备标识 UA + 频道），供 LuCI 状态页"连接的客户端"展示"""
    try:
        with _clients_lock:
            data = {}
            try:
                with open(CLIENTS_FILE) as f:
                    data = json.load(f)
            except Exception:
                data = {}
            if not isinstance(data, dict):
                data = {}
            ent = data.get(ip)
            if not isinstance(ent, dict):
                ent = {}
            if ua:
                ent['ua'] = ua
            if channel:
                ent['channel'] = channel
            ent['last'] = time.time()
            ent['count'] = int(ent.get('count', 0)) + 1
            data[ip] = ent
            cutoff = time.time() - CLIENTS_KEEP_DAYS * 86400
            for k in list(data.keys()):
                v = data[k]
                if isinstance(v, dict):
                    try:
                        if float(v.get('last', 0)) < cutoff:
                            del data[k]
                    except Exception:
                        del data[k]
                else:
                    del data[k]
            with open(CLIENTS_FILE, 'w') as f:
                json.dump(data, f)
    except Exception as e:
        log(f"客户端档案写入失败: {e}", error=True)

def handle_fwd(src, dst, direction):
    log(f"代理: 开始{direction}转发")
    try:
        while True:
            data = src.recv(PROXY_RECV_BUF)
            if not data: break
            dst.sendall(data)
    except OSError as e:
        if e.errno not in (9, 32, 104, 107):
            log(f"代理: {direction}转发错误: {e}", error=True)
    except Exception as e:
        log(f"代理: {direction}转发错误: {e}", error=True)
    finally:
        try: src.close()
        except: pass
        try: dst.close()
        except: pass

def handle_entrance(client_socket, addr):
    global proxy_listening
    server_socket = None
    client_ip = addr[0] if addr else ''
    client_ua = ''
    client_ch = ''
    try:
        # 守卫：RTSP 代理线程在首次鉴权完成前就已监听，此时来的连接需等待源站 IP 就绪
        if not rtsp_source_ip:
            deadline = time.time() + 60
            while not rtsp_source_ip and time.time() < deadline:
                time.sleep(0.5)
            if not rtsp_source_ip:
                log("代理: 源站 IP 未就绪（鉴权未完成），关闭连接", error=True)
                return
        client_socket.settimeout(SOCK_TIMEOUT)
        _tune_socket(client_socket)
        targetaddress = rtsp_source_ip
        targetport = rtsp_source_port
        location = ""

        # 连接源站（先连源站再进入四轮握手；出站绑定上游接口）
        server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_socket.settimeout(SOCK_TIMEOUT)
        _tune_socket(server_socket)
        _bind_upstream(server_socket)
        server_socket.connect((targetaddress, targetport))

        for idx, once in enumerate('1234'):
            request = client_socket.recv(PROXY_RECV_BUF)
            if not request:
                if idx == 0:
                    log("代理: 客户端未发送请求即断开")
                    return
                break
            if location == "":
                toserver = replaceip(request, targetaddress, targetport)
            else:
                toserver = replacelocation(request, location)
            # 解析客户端设备标识（UA）与回看频道，供状态页"连接的客户端"展示
            if client_ip and (not client_ua or not client_ch):
                try:
                    if not client_ua:
                        mua = re.search(rb'User-Agent:\s*([^\r\n]+)', request, re.IGNORECASE)
                        if mua:
                            client_ua = mua.group(1).decode('utf-8', 'replace').strip()[:80]
                    if not client_ch:
                        mch = re.search(rb'/PLTV/(ch\w+)\.smil', request)
                        if mch:
                            client_ch = mch.group(1).decode('ascii', 'replace')
                except Exception:
                    pass
            toserver = Translator(toserver)
            server_socket.sendall(toserver)
            response = server_socket.recv(PROXY_RECV_BUF)
            if not response: break
            status = _parse_rtsp_status(response)
            if once == '1':
                # DESCRIBE + 302 跳转处理（DESCRIBE 基于已翻译的请求构造，
                # 源站只认 live/xxx.mpg?vcdnid=...&programbegin=... 格式）
                twotoserver = describe(toserver)
                server_socket.sendall(twotoserver)
                response = server_socket.recv(PROXY_RECV_BUF)
                if response:
                    addr, port = getaddress(response)
                    loc = getlocation(response)
                    if loc:
                        log(f"代理: 302跳转 {addr}:{port}")
                        server_socket.close()
                        server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                        server_socket.settimeout(SOCK_TIMEOUT)
                        _tune_socket(server_socket)
                        _bind_upstream(server_socket)
                        server_socket.connect((addr, port))
                        server_socket.sendall(newoptions(loc))
                        response = server_socket.recv(PROXY_RECV_BUF)
                        targetaddress, targetport = addr, port
                        location = loc
                    status = _parse_rtsp_status(response)
            log(f"代理: {[ 'OPTIONS','DESCRIBE','SETUP','PLAY'][idx]} {status}")
            toclient = replaceip(response, *client_socket.getsockname()[:2])
            client_socket.sendall(toclient)
        log(f"代理: 握手完成 {targetaddress}:{targetport}")
        if client_ip:
            record_client(client_ip, client_ua, client_ch)
        try: server_socket.settimeout(None)
        except: pass
        try: client_socket.settimeout(None)
        except: pass
        t1 = threading.Thread(target=handle_fwd, args=(server_socket, client_socket, 'S→C'), daemon=True)
        t2 = threading.Thread(target=handle_fwd, args=(client_socket, server_socket, 'C→S'), daemon=True)
        t1.start(); t2.start()
        t1.join(); t2.join()
    except Exception as e:
        log(f"代理: 连接异常: {e}", error=True)
    finally:
        try: client_socket.close()
        except: pass
        try: server_socket.close()
        except: pass

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
        resp = requests.get(ota_url, timeout=15)
        if resp.status_code != 200:
            return
        info = resp.json()
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

def start_rtsp_proxy():
    global proxy_listening
    replay_port = int(config.get('ReplayPort', 554))
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    _tune_socket(sock)
    sock.bind(('0.0.0.0', replay_port))
    sock.listen(32)
    sock.settimeout(3)
    proxy_listening = True
    log(f"RTSP 代理已启动: 0.0.0.0:{replay_port}, 源站: {rtsp_source_ip or '待首次鉴权确定'}:{rtsp_source_port}")
    while proxy_listening:
        try:
            client, addr = sock.accept()
            log(f"代理: 新连接 {addr}")
            threading.Thread(target=handle_entrance, args=(client, addr), daemon=True).start()
        except socket.timeout:
            continue
        except OSError:
            break

# ===================== 主任务 =====================
def run_task():
    now_str = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    log("=== 开始执行 IPTV 鉴权任务 ===")
    save_status(last_run=now_str, auth_ok=False)
    session = authenticate()
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
    # 台标自动下载（跳过已存在的，只下载新增频道）
    download_logos(channels)
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
    global proxy_listening
    load_config()
    # 启动 RTSP 代理线程（rtp2httpd 参数由 init.d 直接读 UCI，无需中转文件）
    threading.Thread(target=start_rtsp_proxy, daemon=True).start()
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
    main_loop()
