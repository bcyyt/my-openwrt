#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mediahub-cms.py v1.5 — 多网盘自动挂载 + 小雅 PG 完整订阅（融合 CMS 采集 + AList 网盘）
- 地址跟随访问来源：APP/浏览器用内网地址访问 → 所有返回地址（tvbox.json/播放直链）均为内网地址；
  用外网域名访问 → 返回外网地址。不再强制使用 ext_domain。
- 播放流直连 AList 公网 5244：115 走 /d/（302 CDN直链），夸克走 /p/（web_proxy 中继）
  —— 不再经 8901 反代视频流，消除 python 转发瓶颈与 127.0.0.1 重定向问题
- 8901 仅承载轻量 API：tvbox.json / cms.php 聚合搜索 / cloudcms.php 网盘适配 / cmproxy CMS 加速
- 网盘文件列表缓存（30分钟TTL）：搜索秒回，避免频繁扫描网盘触发风控
- m3u8 播放缓存带大小上限（UCI mediahub.main.cache_mb），超限逐出最旧，/cache/clear 一键清理
- sign 内存缓存（1小时TTL）
- 混合搜索：本地全量库 + 9站并行实时搜索合并，实时结果自动补全播放地址
- 详情三级查找：缓存 → 本地库 → 并行回源
"""
import json, os, sys, time, threading, urllib.request, urllib.parse, urllib.error
import signal
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from concurrent.futures import ThreadPoolExecutor, wait as _cf_wait
import subprocess, re, base64, mimetypes

# 部署版本（LuCI 状态页显示）
CMS_VERSION = '1.5'

# ============================================================
# 配置
# ============================================================
def uci_get(key, default=""):
    try:
        r = subprocess.run(['uci', '-q', 'get', key], capture_output=True, text=True, timeout=5)
        return r.stdout.strip() or default
    except:
        return default

def uci_get_list(key):
    try:
        r = subprocess.run(['uci', '-q', 'get', key], capture_output=True, text=True, timeout=5)
        val = r.stdout.strip()
        if not val:
            return []
        parts = val.split()
        items = [p for p in parts if p.startswith('http')]
        return items if items else [val]
    except:
        return []

DEFAULT_SITES = [
    # 精选 20+ CMS 采集源（影视/动漫/综艺/短剧全覆盖）
    'https://api.juliang.live/api/provide/vod/',
    'https://caiji.maotaizy.cc/api.php/provide/vod/',
    'https://api.wujinapi.com/api.php/provide/vod/',
    'https://api.xinlangapi.com/xinlangapi.php/provide/vod/',
    'https://jyzyapi.com/provide/vod/',
    'https://api.guangsuapi.com/api.php/provide/vod/',
    'https://www.hongniuzy2.com/api.php/provide/vod/',
    'https://api.ukuapi88.com/api.php/provide/vod/',
    'https://api.apibdzy.com/api.php/provide/vod/',
    'https://api.suxun.site/api.php/provide/vod/',
    'https://api.lieapi.com/api.php/provide/vod/',
    'https://api.heimuer.tv/api.php/provide/vod/',
    'https://json.ichum.eu.org/api.php/provide/vod/',
    'https://www.dmwid.com/api.php/provide/vod/',
    'https://api.haohan110.com/api.php/provide/vod/',
    'https://collect.wolong.cc/api.php/provide/vod/',
    'https://api.zcvj.net/api.php/provide/vod/',
    'https://collect.wolongzy.cc/api.php/provide/vod/',
    'https://api.caiji05.com/api.php/provide/vod/',
    'https://api.vodxs.com/api.php/provide/vod/',
    'https://collect.xlmfz.cc/api.php/provide/vod/',
    'https://api.ccpsoj.com/api.php/provide/vod/',
]

def load_config():
    sites = uci_get_list('mediahub.main.cms_site')
    if not sites or len(sites) < 2:
        sites = uci_get_list('moviebox.main.cms_site')
    if not sites or len(sites) < 2:
        sites = DEFAULT_SITES
    sites = [s.strip("'\" ") for s in sites if s.strip()]
    token = uci_get('mediahub.main.token') or uci_get('moviebox.main.token') or 'mb-c077d20e07e28c60'
    ol_port = int(uci_get('mediahub.main.alist_port') or uci_get('mediahub.main.alist_port') or '5244')
    # 外网域名
    ext_domain = uci_get('mediahub.main.ext_domain') or ''
    # m3u8 播放缓存上限（MB）
    try:
        cache_mb = int(uci_get('mediahub.main.cache_mb') or '64')
    except ValueError:
        cache_mb = 64
    # 播放直连端口（AList 公网端口，默认 5244）
    play_port = int(uci_get('mediahub.main.play_port') or '5244')
    # 定时爬取间隔（小时）：0=关闭定时爬取（仅启动时爬一次），默认 6
    try:
        crawl_interval = int(uci_get('mediahub.main.crawl_interval') or '6')
    except ValueError:
        crawl_interval = 6
    return {'sites': sites, 'token': token, 'ol_port': ol_port, 'ext_domain': ext_domain, 'cache_mb': cache_mb, 'play_port': play_port, 'crawl_interval': crawl_interval}

CFG = load_config()
LISTEN_PORT = 8901
MAX_PAGES = 1000     # 每站最多爬 1000 页（深度翻倍，覆盖更多老片）
PAGE_SIZE = 20       # CMS 每页 20 条
PARALLEL = 30        # 并发拉取线程数
CACHE_TTL = 600      # 全量缓存 10 分钟
CACHE_LIMIT_MB = CFG.get('cache_mb', 64)  # m3u8 播放缓存上限（MB）
_log_lock = threading.Lock()
_logs = []

# 全量片源库（去重后的所有片源）
_all_vods = []           # [{vod_id, vod_name, vod_pic, vod_play_url, vod_remarks, type_name, ...}]
_all_vods_lock = threading.Lock()
_all_vods_loaded = False  # 是否已完成全量爬取

# 持久化存储路径（与 CMS 脚本同目录或 /tmp）
import tempfile
_PERSIST_DIR = '/tmp/mediahub-cache'  # 默认 /tmp（重启丢失），下面会根据 UCI data_dir 覆盖
_VOD_DB_FILE = os.path.join(_PERSIST_DIR, 'vods.json.gz')
_SEARCH_DB_FILE = os.path.join(_PERSIST_DIR, 'search_cache.json.gz')

# 持久化目录自适应：优先 UCI mediahub.main.data_dir（数据盘），回退 /tmp
def _init_persist_dir():
    global _PERSIST_DIR, _VOD_DB_FILE, _SEARCH_DB_FILE, _PG_DIR
    dd = uci_get('mediahub.main.data_dir') or ''
    if dd and os.path.isdir(dd):
        _PERSIST_DIR = os.path.join(dd, 'cache')
    elif os.path.isdir('/mnt/sda4'):
        _PERSIST_DIR = '/mnt/sda4/mediahub-cache'
    elif os.path.isdir('/mnt/data') and os.path.ismount('/mnt/data'):
        _PERSIST_DIR = '/mnt/data/mediahub-cache'
    _VOD_DB_FILE = os.path.join(_PERSIST_DIR, 'vods.json.gz')
    _SEARCH_DB_FILE = os.path.join(_PERSIST_DIR, 'search_cache.json.gz')
    # v1.5: 小雅 PG 资源目录（jsm.json/pg.jar/lib/js，/sub/pg 完整订阅用）
    _PG_DIR = os.path.join(os.path.dirname(_PERSIST_DIR.rstrip('/')), 'pg')

_init_persist_dir()
_POSTER_EXTRA_FILE = os.path.join(_PERSIST_DIR, 'poster_extra.json.gz')

def _save_vods_to_disk():
    """将全量库持久化到 gzip JSON 文件（后台线程调用，7万部约 15MB）"""
    try:
        os.makedirs(_PERSIST_DIR, exist_ok=True)
        with _all_vods_lock:
            data = list(_all_vods)
        tmp = _VOD_DB_FILE + '.tmp'
        import gzip
        with gzip.open(tmp, 'wb') as f:
            f.write(json.dumps({'vods': data, 'saved_at': int(time.time()), 'count': len(data)}, ensure_ascii=False).encode('utf-8'))
        os.replace(tmp, _VOD_DB_FILE)
        _log(f'vods persisted: {len(data)} items -> {_VOD_DB_FILE} ({os.path.getsize(_VOD_DB_FILE)//1024}KB)')
    except Exception as e:
        _log(f'persist vods error: {e}')

def _load_vods_from_disk():
    """启动时从 gzip JSON 加载全量库（命中则跳过首次爬取，后台增量更新）"""
    global _all_vods, _all_vods_loaded
    try:
        if os.path.exists(_VOD_DB_FILE):
            import gzip
            with gzip.open(_VOD_DB_FILE, 'rb') as f:
                d = json.loads(f.read().decode('utf-8'))
            vods = d.get('vods', [])
            if vods:
                with _all_vods_lock:
                    _all_vods = vods
                    _stats['cms_total'] = len(vods)
                _all_vods_loaded = True
                _stats['crawl_status'] = 'done'
                _stats['last_refresh'] = d.get('saved_at', 0)
                _build_pic_index()
                _log(f'vods loaded from disk: {len(vods)} items (saved at {time.strftime("%H:%M", time.localtime(d.get("saved_at", 0)))})')
                return True
    except Exception as e:
        _log(f'load vods error: {e}')
    return False

_stats = {
    'cms_sites': len(CFG['sites']),
    'cms_total': 0,        # CMS 去重后总数
    'cloud_115': 0,        # 115 网盘文件数
    'cloud_quark': 0,      # 夸克网盘文件数
    'cloud_mounts': {},    # v1.5: 各网盘挂载文件数（多网盘自动挂载）
    'search_count': 0,
    'last_refresh': 0,
    'crawl_status': 'idle',
    'next_crawl': 0,       # 下次定时爬取时间（epoch，0=无计划）
}
_cache = {}
_cache_lock = threading.Lock()

# 实时搜索结果缓存（id -> (ts, item)）：detail 请求优先匹配，避免跨站撞 id 错片
_remote_cache = {}
_remote_cache_lock = threading.Lock()
_REMOTE_CACHE_TTL = 600  # 10 分钟

# m3u8 播放缓存（模块级，带大小上限）
_m3u8_cache = {}
_m3u8_lock = threading.Lock()
_m3u8_cache_bytes = 0

# 网盘文件列表缓存（30 分钟）
_cloud_files_cache = {'ts': 0, 'files': []}
_cloud_files_lock = threading.Lock()
_cloud_scan_lock = threading.Lock()  # 互斥扫描，防并发重复扫描
_CLOUD_CACHE_TTL = 1800

# sign 缓存（path -> (ts, sign)，1 小时）
_sign_cache = {}
_sign_cache_lock = threading.Lock()
_SIGN_CACHE_TTL = 3600

# m3u8 缓存操作
def m3u8_cache_get(url, ttl=60):
    with _m3u8_lock:
        hit = _m3u8_cache.get(url)
        if hit and time.time() - hit[0] < ttl:
            return hit[1]
    return None

def m3u8_cache_put(url, data):
    global _m3u8_cache_bytes
    with _m3u8_lock:
        now = time.time()
        # 过期清理
        for k in [k for k, v in _m3u8_cache.items() if now - v[0] > 120]:
            _m3u8_cache_bytes -= len(_m3u8_cache.pop(k)[1])
        # 覆盖写入时先扣旧值
        if url in _m3u8_cache:
            _m3u8_cache_bytes -= len(_m3u8_cache[url][1])
        _m3u8_cache[url] = (now, data)
        _m3u8_cache_bytes += len(data)
        # 超限逐出最旧
        limit = CACHE_LIMIT_MB * 1024 * 1024
        while _m3u8_cache and _m3u8_cache_bytes > limit:
            oldest = min(_m3u8_cache, key=lambda k: _m3u8_cache[k][0])
            _m3u8_cache_bytes -= len(_m3u8_cache.pop(oldest)[1])

def m3u8_cache_clear():
    """清空 m3u8 缓存，返回 (条数, 释放字节数)"""
    global _m3u8_cache_bytes
    with _m3u8_lock:
        n = len(_m3u8_cache)
        freed = _m3u8_cache_bytes
        _m3u8_cache.clear()
        _m3u8_cache_bytes = 0
        return n, freed

def _log(msg):
    ts = time.strftime('%H:%M:%S')
    with _log_lock:
        _logs.append(f'[{ts}] {msg}')
        if len(_logs) > 200:
            _logs[:] = _logs[-100:]

UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'

def fetch_json(url, timeout=12):
    try:
        req = urllib.request.Request(url, headers={'User-Agent': UA})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode('utf-8', errors='replace'))
    except Exception as e:
        _log(f'fetch err: {url[:50]} -> {e}')
        return None

# ============================================================
# CMS 全量爬取
# ============================================================
def crawl_all():
    """全量爬取所有 CMS 站点的所有页面，去重后存入 _all_vods"""
    global _all_vods, _all_vods_loaded
    _stats['crawl_status'] = 'running'
    _log(f'crawl started: {len(CFG["sites"])} sites, up to {MAX_PAGES} pages each')

    all_items = []
    seen_names = {}  # vod_name -> item（去重，保留首次出现）

    def fetch_page(site, pg):
        """拉取单页"""
        sep = '&' if '?' in site else '?'
        url = f'{site}{sep}ac=detail&pg={pg}'
        data = fetch_json(url, timeout=8)
        if not data or data.get('code') != 1:
            return []
        return data.get('list') or []

    def crawl_site(site):
        """爬取单个站点的所有页（页面级并发）"""
        site_items = []
        # 先拉第1页确定总页数
        first = fetch_page(site, 1)
        if not first:
            return []
        total_pages = min(MAX_PAGES, 1000)  # 上限
        # 并发拉所有页
        page_results = {}
        def _fetch_pg(pg):
            return pg, fetch_page(site, pg)
        with ThreadPoolExecutor(max_workers=20) as ppool:
            futures = [ppool.submit(_fetch_pg, pg) for pg in range(1, total_pages + 1)]
            for f in futures:
                try:
                    pg, items = f.result(timeout=60)
                    if items:
                        page_results[pg] = items
                except:
                    pass
        # 按页顺序合并去重
        for pg in sorted(page_results.keys()):
            for item in page_results[pg]:
                name = item.get('vod_name', '')
                if name and name not in seen_names:
                    seen_names[name] = item
                    site_items.append(item)
        return site_items

    # 高并发爬取所有站点
    with ThreadPoolExecutor(max_workers=PARALLEL) as pool:
        futures = []
        for site in CFG['sites']:
            futures.append(pool.submit(crawl_site, site))
        for i, f in enumerate(futures):
            try:
                items = f.result(timeout=300)
                all_items.extend(items)
                _log(f'site {i+1}/{len(CFG["sites"])} done: +{len(items)} (total unique: {len(all_items)})')
            except Exception as e:
                _log(f'site {i+1} error: {e}')

    with _all_vods_lock:
        _all_vods = all_items
        _stats['cms_total'] = len(all_items)
    _all_vods_loaded = True
    _stats['crawl_status'] = 'done'
    _stats['last_refresh'] = int(time.time())
    _log(f'crawl done: {len(all_items)} unique vods from {len(CFG["sites"])} sites')
    # 持久化到磁盘
    threading.Thread(target=_save_vods_to_disk, daemon=True).start()
    # 重建海报索引（网盘片源海报墙数据源）
    _build_pic_index()

def crawl_loop(skip_if_disk=False):
    """定时全量爬取（间隔从 UCI mediahub.main.crawl_interval 读取，小时；0=关闭）；
    启动时如果磁盘有缓存则延后 30 分钟"""
    interval_h = CFG.get('crawl_interval', 6)
    if skip_if_disk:
        _log('disk cache loaded, deferring first crawl by 30 min')
        _stats['next_crawl'] = int(time.time()) + 30 * 60
        time.sleep(30 * 60)
    while True:
        try:
            crawl_all()
            # 爬完更新网盘文件数
            update_cloud_counts()
        except Exception as e:
            _log(f'crawl error: {e}')
            _stats['crawl_status'] = 'error'
        if interval_h <= 0:
            # 定时爬取已关闭：只爬这一次，无后续计划
            _stats['next_crawl'] = 0
            _log('scheduled crawl disabled (crawl_interval=0), no further crawl planned')
            break
        _stats['next_crawl'] = int(time.time()) + interval_h * 3600
        _log(f'next crawl scheduled in {interval_h}h')
        time.sleep(interval_h * 3600)

# ============================================================
# v1.5: 多网盘自动挂载（UCI 凭证 → AList storage，10+ 网盘）
# ============================================================
# 凭证配置（UCI mediahub.main.*，LuCI 网盘配置或命令行设置）：
#   cookie_115     115 Cookie       cookie_quark   夸克 Cookie
#   cookie_uc      UC 网盘 Cookie   token_ali      阿里云盘 Open refresh_token
#   token_189      天翼云盘 账号:密码  token_yidong   移动云盘 authorization
#   token_123      123云盘 账号:密码  token_baidu    百度网盘 refresh_token
#   thunder_auth   迅雷云盘 账号:密码  pikpak_auth    PikPak 账号:密码
# 配好任一项：服务启动/每次云刷新时自动在 AList 创建挂载并纳入扫描（幂等自愈）。
CLOUD_DRIVE_DEFS = [
    {'key': '115', 'mount': '/115', 'driver': '115 Cloud', 'cred': 'cookie_115', 'kind': 'cookie',
     'addition': lambda v: {'cookie': v, 'qrcode_token': '', 'qrcode_source': 'linux',
                            'page_size': 1000, 'limit_rate': 2, 'root_folder_id': '0'},
     'web_proxy': False, 'webdav_policy': '302_redirect'},
    {'key': 'quark', 'mount': '/quark', 'driver': 'Quark', 'cred': 'cookie_quark', 'kind': 'cookie',
     'addition': lambda v: {'cookie': v, 'root_folder_id': '0',
                            'use_transcoding_address': False, 'only_list_video_file': False},
     'web_proxy': True, 'webdav_policy': 'use_proxy_url'},
    {'key': 'uc', 'mount': '/uc', 'driver': 'UC', 'cred': 'cookie_uc', 'kind': 'cookie',
     'addition': lambda v: {'cookie': v, 'root_folder_id': '0',
                            'use_transcoding_address': False, 'only_list_video_file': False},
     'web_proxy': True, 'webdav_policy': 'use_proxy_url'},
    {'key': 'aliyun', 'mount': '/aliyun', 'driver': 'AliyundriveOpen', 'cred': 'token_ali', 'kind': 'token',
     'addition': lambda v: {'refresh_token': v, 'root_folder_id': 'root',
                            'order_by': 'name', 'order_direction': 'asc'},
     'web_proxy': False, 'webdav_policy': '302_redirect'},
    {'key': '189', 'mount': '/189', 'driver': '189CloudPC', 'cred': 'token_189', 'kind': 'userpass',
     'addition': lambda u, p: {'username': u, 'password': p, 'validate_code': '',
                               'family_transfer_mode': False},
     'web_proxy': False, 'webdav_policy': '302_redirect'},
    {'key': 'yidong', 'mount': '/yidong', 'driver': '139Yun', 'cred': 'token_yidong', 'kind': 'token',
     'addition': lambda v: {'authorization': v},
     'web_proxy': False, 'webdav_policy': '302_redirect'},
    {'key': '123', 'mount': '/123', 'driver': '123Pan', 'cred': 'token_123', 'kind': 'userpass',
     'addition': lambda u, p: {'username': u, 'password': p, 'root_folder': '/'},
     'web_proxy': False, 'webdav_policy': '302_redirect'},
    {'key': 'baidu', 'mount': '/baidu', 'driver': 'BaiduNetdisk', 'cred': 'token_baidu', 'kind': 'token',
     'addition': lambda v: {'refresh_token': v, 'root_folder_id': '/'},
     'web_proxy': True, 'webdav_policy': 'use_proxy_url'},
    {'key': 'thunder', 'mount': '/thunder', 'driver': 'Thunder', 'cred': 'thunder_auth', 'kind': 'userpass',
     'addition': lambda u, p: {'username': u, 'password': p, 'root_folder_id': '', 'user_agent': ''},
     'web_proxy': False, 'webdav_policy': '302_redirect'},
    {'key': 'pikpak', 'mount': '/pikpak', 'driver': 'PikPak', 'cred': 'pikpak_auth', 'kind': 'userpass',
     'addition': lambda u, p: {'username': u, 'password': p, 'root_folder_id': ''},
     'web_proxy': False, 'webdav_policy': '302_redirect'},
]

_MOUNT_META = {'ts': 0, 'bases': [], 'routes': {}}
_MOUNT_META_LOCK = threading.Lock()
_MOUNT_META_TTL = 600

def _refresh_mount_meta(force=False):
    """刷新 AList 挂载元数据（扫描基准 + web_proxy→播放路由映射），缓存 10 分钟"""
    try:
        with _MOUNT_META_LOCK:
            if not force and _MOUNT_META['ts'] and time.time() - _MOUNT_META['ts'] < _MOUNT_META_TTL:
                return _MOUNT_META
        bases, routes = [], {}
        r = ol_api('/api/admin/storage/list')
        if r and r.get('code') == 200:
            for s in (r.get('data') or {}).get('content') or []:
                mp = s.get('mount_path') or ''
                if not mp or mp == '/' or s.get('disabled'):
                    continue
                bases.append(mp)
                routes[mp] = 'p' if s.get('web_proxy') else 'd'
        if not bases:
            # fallback：admin 接口不可用时按根目录一级子目录（未知驱动按名字特判 115）
            r2 = ol_api('/api/fs/list', {'path': '/', 'page': 1, 'per_page': 200})
            if r2 and r2.get('code') == 200:
                for it in (r2.get('data') or {}).get('content') or []:
                    if it.get('is_dir'):
                        name = (it.get('name') or '').strip('/')
                        mp = '/' + name
                        bases.append(mp)
                        routes[mp] = 'd' if name == '115' else 'p'
        if bases:
            with _MOUNT_META_LOCK:
                _MOUNT_META.update({'ts': time.time(), 'bases': bases, 'routes': routes})
        return _MOUNT_META
    except Exception as e:
        _log(f'mount meta error: {e}')
        return _MOUNT_META

def cloud_mount_bases():
    """云扫描基准：AList 全部已启用挂载点（多网盘自动发现，不再硬编码 115/夸克）"""
    m = _refresh_mount_meta()
    return m['bases'] or ['/115', '/quark']

def _mount_route(path):
    """播放路由：web_proxy 挂载走 /p/（服务器中继），302 挂载走 /d/（CDN 直链）"""
    routes = _refresh_mount_meta()['routes']
    best = ''
    for mp in routes:
        if path.startswith(mp + '/') and len(mp) > len(best):
            best = mp
    if best:
        return routes[best]
    return 'd' if path.startswith('/115/') else 'p'

def _update_cloud_stats(files):
    """按挂载前缀统计各网盘文件数（cloud_115/cloud_quark 保留，新增 cloud_mounts 全量）"""
    _stats['cloud_115'] = sum(1 for f in files if f['path'].startswith('/115/'))
    _stats['cloud_quark'] = sum(1 for f in files if f['path'].startswith('/quark/'))
    mounts = {}
    for f in files:
        parts = (f.get('path') or '').split('/')
        if len(parts) > 1 and parts[1]:
            mounts[parts[1]] = mounts.get(parts[1], 0) + 1
    _stats['cloud_mounts'] = mounts
    return mounts

def update_cloud_counts():
    """从网盘文件缓存获取文件数（顺便预热缓存，多网盘统计）"""
    try:
        files = get_cloud_files()
        mounts = _update_cloud_stats(files)
        _log(f'cloud counts: {json.dumps(mounts, ensure_ascii=False)} total={len(files)}')
    except Exception as e:
        _log(f'cloud count error: {e}')

# ============================================================
# CMS 搜索/列表/详情
# ============================================================
def _host_only(host):
    """从 'host:port' 剥出纯 hostname。
    v1.5 起 _get_host() 返回含端口的完整 Host（如 192.168.10.1:8901）；
    拼接 AList 播放端口(:5244)前必须先剥掉 CMS 端口，
    否则拼出 http://ip:8901:5244/ 双端口畸形地址（播放器报“播放地址解析失败”）。
    """
    if not host:
        return host
    if host.startswith('[') and ']' in host:      # [IPv6]:port
        return host.split(']', 1)[0][1:]
    return host.rsplit(':', 1)[0]

def _rewrite_play_url(play_url, host):
    """把 CMS 直链 m3u8/mp4 改为经过 /cmproxy/ 代理（加速+缓存）
    苹果CMS 标准格式：播放组间 $$$ 分隔，组内剧集 # 分隔，每集 标签$url
    """
    if not play_url or '$' not in play_url:
        return play_url
    groups = play_url.split('$$$')
    out_groups = []
    for group in groups:
        eps = group.split('#')
        out_eps = []
        for ep in eps:
            if '$' not in ep:
                out_eps.append(ep)
                continue
            label, url = ep.split('$', 1)
            # 非常规分隔（如 $$ 多集串联）：保持原样不改写，避免破坏
            if '$' in url:
                out_eps.append(ep)
                continue
            if url.startswith('http') and ('.m3u8' in url or '.mp4' in url or '.ts' in url):
                url_b64 = base64.b64encode(url.encode()).decode()
                url = f'http://{host}/cmproxy/m3u8?url={url_b64}'
            out_eps.append(f'{label}${url}')
        out_groups.append('#'.join(out_eps))
    return '$$$'.join(out_groups)

def _rewrite_vod_play(item, host):
    """改写 vod_play_url"""
    item = dict(item)  # 不修改原始数据
    item['vod_play_url'] = _rewrite_play_url(item.get('vod_play_url', ''), host)
    return item

# 搜索结果缓存：wd -> (ts, merged_items)，命中直接秒回（播放地址走 cmproxy 实时回源，缓存安全）
_search_result_cache = {}
_search_cache_lock = threading.Lock()
_SEARCH_CACHE_TTL = 6 * 3600   # 6 小时
_SEARCH_CACHE_MAX = 500        # 最多缓存 500 个关键词，超出清最旧

def _save_search_cache_to_disk():
    """将搜索结果缓存持久化到 gzip JSON 文件"""
    try:
        os.makedirs(_PERSIST_DIR, exist_ok=True)
        with _search_cache_lock:
            data = {wd: [ts, items] for wd, (ts, items) in _search_result_cache.items()}
        tmp = _SEARCH_DB_FILE + '.tmp'
        import gzip
        with gzip.open(tmp, 'wb') as f:
            f.write(json.dumps(data, ensure_ascii=False).encode('utf-8'))
        os.replace(tmp, _SEARCH_DB_FILE)
    except Exception as e:
        _log(f'persist search cache error: {e}')

def _load_search_cache_from_disk():
    """启动时从 gzip JSON 加载搜索结果缓存"""
    try:
        if os.path.exists(_SEARCH_DB_FILE):
            import gzip
            with gzip.open(_SEARCH_DB_FILE, 'rb') as f:
                data = json.loads(f.read().decode('utf-8'))
            now = time.time()
            loaded = 0
            with _search_cache_lock:
                for wd, (ts, items) in data.items():
                    if now - ts < _SEARCH_CACHE_TTL:
                        _search_result_cache[wd] = (ts, items)
                        loaded += 1
            if loaded:
                _log(f'search cache loaded from disk: {loaded} keywords')
    except Exception as e:
        _log(f'load search cache error: {e}')

def _search_cache_put(wd, items):
    with _search_cache_lock:
        if wd not in _search_result_cache and len(_search_result_cache) >= _SEARCH_CACHE_MAX:
            oldest = min(_search_result_cache, key=lambda k: _search_result_cache[k][0])
            _search_result_cache.pop(oldest, None)
        _search_result_cache[wd] = (time.time(), items)
    # 异步持久化（节流：最多每 30 秒写一次磁盘）
    now = time.time()
    if not hasattr(_search_cache_put, '_last_save') or now - _search_cache_put._last_save > 30:
        _search_cache_put._last_save = now
        threading.Thread(target=_save_search_cache_to_disk, daemon=True).start()

def _remote_search_fetch(wd, local_results):
    """并行实时搜索所有站点并与本地结果合并去重；远端结果同步写入 _remote_cache 供 detail 使用。
    动态等待：本地命中充足时远端只快速补充（3.5s），冷门/老片词多等做全库检索（6.5s），
    慢站超时自动放弃——9 站里最慢站不再拖累整体耗时（原固定 8s+detail 10s → 搜索 10~14s）。"""
    remote_items = []
    lock = threading.Lock()
    remote_wait = 3.5 if len(local_results) >= 12 else 4.0
    def _search_one(site):
        sep = '&' if '?' in site else '?'
        data = fetch_json(f'{site}{sep}wd={urllib.parse.quote(wd)}&pg=1', timeout=remote_wait)
        if data and data.get('code') == 1:
            items = data.get('list') or []
            # 简略列表无播放地址 → 按 ids 批量拉详情补全
            if items and not any(v.get('vod_play_url') for v in items):
                ids = ','.join(str(v.get('vod_id')) for v in items if v.get('vod_id'))
                if ids:
                    d2 = fetch_json(f'{site}{sep}ac=detail&ids={ids}', timeout=remote_wait + 2)
                    if d2 and d2.get('code') == 1 and d2.get('list'):
                        detail_map = {str(v.get('vod_id')): v for v in d2['list']}
                        items = [detail_map.get(str(v.get('vod_id')), v) for v in items]
            with lock:
                remote_items.extend(items)
    with ThreadPoolExecutor(max_workers=len(CFG['sites'])) as pool:
        futs = [pool.submit(_search_one, s) for s in CFG['sites']]
        _cf_wait(futs, timeout=remote_wait + 1.5)

    # 合并去重（本地优先）+ 缓存实时详情（供 detail 匹配）
    results = list(local_results)
    seen = {v.get('vod_name', '') for v in results}
    added = 0
    now = time.time()
    with _remote_cache_lock:
        for item in remote_items:
            vid = str(item.get('vod_id', ''))
            if vid and item.get('vod_play_url'):
                _remote_cache[vid] = (now, item)
        if len(_remote_cache) > 3000:
            expired = [k for k, v in _remote_cache.items() if now - v[0] > _REMOTE_CACHE_TTL]
            for k in expired:
                del _remote_cache[k]
    for item in remote_items:
        name = item.get('vod_name', '')
        if name and name not in seen:
            seen.add(name)
            results.append(item)
            added += 1
    _log(f'search "{wd}" -> {len(results)} results (local {len(local_results)}, remote +{added})')
    # Tag each result with source for multi-route display
    for item in results:
        if not item.get('vod_remarks', '').startswith('['):
            item['vod_remarks'] = item.get('vod_remarks', '') or ''
    return results
    return results

def cms_search(wd):
    """秒收搜索（三层）：
    1. 结果缓存命中 → 0.05s 秒回（覆盖绝大多数日常搜索，6 小时 TTL）
    2. 本地全量库命中 ≥1 条 → 0.1s 立即返回本地结果，远端搜索后台异步补全进缓存
       （本地库 3.7 万部覆盖各站更新时间前 500 页，新片/热门片全有）
    3. 本地 0 条（冷门/老片，如阿甘正传）→ 同步远端全库检索（最多 4s）找回，结果写缓存
    第二次搜同一词 → 缓存命中 0.05s 秒回。播放地址经 cmproxy 实时回源，缓存不会导致链接过期。"""
    _stats['search_count'] += 1
    now = time.time()
    with _search_cache_lock:
        hit = _search_result_cache.get(wd)
        if hit and now - hit[0] < _SEARCH_CACHE_TTL:
            return list(hit[1])
    # 本地全量库即时匹配（0 网络延迟）
    with _all_vods_lock:
        if _all_vods_loaded and _all_vods:
            local_results = [v for v in _all_vods if wd.lower() in v.get('vod_name', '').lower()]
        else:
            local_results = []
    # 本地有 ≥1 条命中 → 立即返回，远端结果后台异步补全进缓存（下次搜同词即缓存秒回）
    if local_results:
        def _bg_fill():
            try:
                merged = _remote_search_fetch(wd, local_results)
                _search_cache_put(wd, merged)
            except Exception as e:
                _log(f'search bg fill "{wd}" error: {e}')
        threading.Thread(target=_bg_fill, daemon=True).start()
        return list(local_results)
    # 本地 0 条（冷门/老片）→ 同步远端全库检索（最多 4s），写缓存
    results = _remote_search_fetch(wd, local_results)
    _search_cache_put(wd, results)
    return results

TYPE_KEYWORDS = {
    '1': ('电影', '动作片', '喜剧片', '爱情片', '科幻片', '恐怖片', '剧情片', '战争片', '犯罪片', '冒险片', '悬疑片', '惊悚片', '奇幻片', '纪录片', '动画电影', '灾难片', '武侠片', '古装片', '历史片', '传记片', '音乐片', '西部片', '记录片'),
    '2': ('电视剧', '连续剧', '剧集', '短剧', '国产剧', '港剧', '台剧', '日剧', '韩剧', '欧美剧', '泰国剧', '海外剧', '东南亚剧', '日本剧', '韩国剧', '美剧', '英剧'),
    '3': ('综艺', '大陆综艺', '日韩综艺', '港台综艺', '欧美综艺', '综艺片', '体育赛事', '演唱会'),
    '4': ('动漫', '动画', '国产动漫', '日韩动漫', '欧美动漫', '港台动漫', '海外动漫', '动画片', '动漫片'),
}

def cms_list(pg=1, t=''):
    """从全量库分页返回（支持 t 分类尽力过滤）"""
    with _all_vods_lock:
        if not _all_vods_loaded or not _all_vods:
            return {'code': 1, 'limit': PAGE_SIZE, 'list': [], 'pagecount': 1, 'total': 0}
        pool_items = _all_vods
        if t:
            kws = TYPE_KEYWORDS.get(str(t), ())
            if kws:
                filtered = [v for v in _all_vods
                            if any(k in str(v.get('type_name', '')) for k in kws)]
                if filtered:
                    pool_items = filtered
        total = len(pool_items)
        pagecount = (total + PAGE_SIZE - 1) // PAGE_SIZE
        if pagecount and (pg < 1 or pg > pagecount):
            pg = 1
        start = (pg - 1) * PAGE_SIZE
        end = start + PAGE_SIZE
        items = pool_items[start:end]
    return {
        'code': 1, 'limit': PAGE_SIZE, 'list': items,
        'pagecount': pagecount, 'total': total,
        'class': [{'type_id': '1', 'type_name': '电影'}, {'type_id': '2', 'type_name': '电视剧'},
                  {'type_id': '3', 'type_name': '综艺'}, {'type_id': '4', 'type_name': '动漫'}]
    }

def cms_detail(ids):
    """三级查找：实时搜索缓存 → 本地全量库 → 并行回源各站
    缓存优先：APP 刚搜到的条目（可能本地库不存在或跨站撞 id），必须先命中缓存。
    """
    id_list = [i.strip() for i in ids.split(',') if i.strip()]
    if not id_list:
        return {'code': 1, 'list': []}
    result_map = {}
    # 0) 实时搜索缓存
    now = time.time()
    with _remote_cache_lock:
        for vid in id_list:
            hit = _remote_cache.get(vid)
            if hit and now - hit[0] < _REMOTE_CACHE_TTL:
                result_map[vid] = hit[1]
    # 1) 本地全量库
    with _all_vods_lock:
        for vid in id_list:
            if vid in result_map:
                continue
            for v in _all_vods:
                if str(v.get('vod_id', '')) == vid:
                    result_map[vid] = v
                    break
    # 2) 本地与缓存都未命中 → 并行回源
    missing = [i for i in id_list if i not in result_map]
    if missing:
        remote = []
        lock = threading.Lock()
        def _fetch_one(site):
            sep = '&' if '?' in site else '?'
            data = fetch_json(f'{site}{sep}ac=detail&ids={",".join(missing)}', timeout=6)
            if data and data.get('code') == 1:
                with lock:
                    remote.extend(data.get('list') or [])
        with ThreadPoolExecutor(max_workers=len(CFG['sites'])) as pool:
            futs = [pool.submit(_fetch_one, s) for s in CFG['sites']]
            _cf_wait(futs, timeout=7)
        for item in remote:
            vid = str(item.get('vod_id', ''))
            # 每个 id 只取第一条带播放地址的回源结果
            if vid in missing and vid not in result_map and item.get('vod_play_url'):
                result_map[vid] = item
    # 3) 按请求顺序组装
    results = [result_map[i] for i in id_list if i in result_map]
    return {'code': 1, 'list': results}

# ============================================================
# AList 网盘 → CMS 格式适配
# ============================================================
VID_EXTS = ('.mkv', '.mp4', '.ts', '.avi', '.iso', '.mov', '.flv', '.m4v', '.rmvb', '.wmv')

def ol_api(path, body=None, timeout=15):
    """调用 AList API（带 admin token，适配 meta 密码保护后的内部调用）"""
    try:
        url = f'http://127.0.0.1:{CFG["ol_port"]}{path}'
        if body:
            req = urllib.request.Request(url, data=json.dumps(body).encode(), method='POST')
            req.add_header('Content-Type', 'application/json')
        else:
            req = urllib.request.Request(url)
        token = _get_ol_admin_token()
        if token:
            req.add_header('Authorization', token)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode('utf-8', errors='replace'))
    except Exception as e:
        _log(f'ol_api error: {e}')
        return None

_ol_token_cache = {'token': '', 'ts': 0}
_ol_token_lock = threading.Lock()

def _get_ol_admin_token():
    """登录 AList 获取 admin token（缓存 1 小时，失败自动重试）"""
    now = time.time()
    with _ol_token_lock:
        if _ol_token_cache['token'] and now - _ol_token_cache['ts'] < 3600:
            return _ol_token_cache['token']
    pw = uci_get('mediahub.main.alist_pw') or uci_get('mediahub.main.alist_pw')
    if not pw:
        return ''
    try:
        body = json.dumps({'username': 'admin', 'password': pw}).encode()
        req = urllib.request.Request(
            f'http://127.0.0.1:{CFG["ol_port"]}/api/auth/login',
            data=body, method='POST')
        req.add_header('Content-Type', 'application/json')
        with urllib.request.urlopen(req, timeout=10) as resp:
            d = json.loads(resp.read().decode('utf-8', errors='replace'))
        token = (d.get('data') or {}).get('token', '')
        if token:
            with _ol_token_lock:
                _ol_token_cache['token'] = token
                _ol_token_cache['ts'] = now
        return token
    except Exception:
        return ''

def ol_list_videos(base_path, depth=6, max_count=8000):
    """递归列出网盘视频文件（完整翻页 + 并发扫描子目录）
    v2.6: 旧版每目录只拉第一页 200 条，目录超过 200 个文件时被截断（丢失约500个）；
    现改为翻页拉全 + 层级并发扫描，加速全盘索引。
    """
    results = []
    lock = threading.Lock()
    stop = threading.Event()

    def _list_all_pages(path):
        """拉取目录全部条目（翻页直到拿完）"""
        items = []
        page = 1
        while not stop.is_set():
            r = ol_api('/api/fs/list', {'path': path, 'page': page, 'per_page': 500})
            if not r or r.get('code') != 200:
                break
            d = r.get('data') or {}
            content = d.get('content') or []
            if not content:
                break
            items.extend(content)
            if page * 500 >= (d.get('total') or 0):
                break
            page += 1
        return items

    def _scan_dir(path, lvl):
        """扫描单个目录，返回 (视频列表, 子目录列表)；记录父目录名供中文搜索匹配
        v2.8.1: 修复 elif 缩进错位——视频判断被误嵌进 is_dir 分支导致扫描永远收集不到文件
        """
        vids = []
        subs = []
        items = _list_all_pages(path)
        if not items and lvl == 0:
            # 根目录列取失败 = 整个网盘扫不到，必须留痕（此前静默 break 无法排查）
            _log(f'cloud scan: root list EMPTY for {path} (check mount/cookie)')
        for item in items:
            if stop.is_set():
                break
            name = item.get('name', '')
            if item.get('is_dir'):
                if lvl < depth:
                    subs.append((path + '/' + name, lvl + 1))
            elif name.lower().endswith(VID_EXTS):
                # v2.8: fs/list 文件条目自带 sign，扫描时顺手携带（播放签名零远程获取）
                vids.append({'path': path + '/' + name, 'name': name, 'size': item.get('size', 0),
                             'dir': path.rsplit('/', 1)[-1], 'sign': item.get('sign') or ''})
        return vids, subs

    # BFS 逐层并发扫描
    level = [(base_path, 0)]
    with ThreadPoolExecutor(max_workers=8) as pool:
        while level and not stop.is_set():
            futs = [pool.submit(_scan_dir, p, l) for p, l in level]
            level = []
            for f in futs:
                try:
                    vids, subs = f.result(timeout=180)
                except Exception:
                    continue
                with lock:
                    results.extend(vids)
                    if len(results) >= max_count:
                        stop.set()
                level.extend(subs)
    return results[:max_count]

_cloud_bg_pending = False

def _kick_bg_cloud_refresh():
    """后台刷新网盘文件缓存（去重：已有刷新线程在跑则跳过）"""
    global _cloud_bg_pending
    with _cloud_files_lock:
        if _cloud_bg_pending:
            return
        _cloud_bg_pending = True
    def _bg():
        global _cloud_bg_pending
        try:
            sync_uci_mounts()   # v1.5: 每次云刷新前做多网盘挂载自愈（幂等）
            files = get_cloud_files(force=True)
            _update_cloud_stats(files)
        except Exception as e:
            _log(f'cloud bg refresh error: {e}')
        finally:
            with _cloud_files_lock:
                _cloud_bg_pending = False
    threading.Thread(target=_bg, daemon=True).start()

def get_cloud_files(force=False):
    """获取网盘全部视频文件
    v2.7: SWR（stale-while-revalidate）——缓存过期时立即返回旧数据并后台刷新，
    避免请求线程阻塞在全盘扫描上（冷缓存扫描可达数十秒，是“进源/点开”偶发卡顿的主因）；
    仅当缓存为空（服务刚启动）或显式 force 时才同步扫描。
    """
    with _cloud_files_lock:
        files = _cloud_files_cache['files']
        fresh = _cloud_files_cache['ts'] and \
            time.time() - _cloud_files_cache['ts'] < _CLOUD_CACHE_TTL
    if not force and files and fresh:
        return files
    if not force and files:
        # 过期但有旧数据：先回旧数据，后台异步刷新
        _kick_bg_cloud_refresh()
        return files
    with _cloud_scan_lock:
        # 双重检查：等锁期间其他线程可能已完成扫描
        with _cloud_files_lock:
            files = _cloud_files_cache['files']
            fresh = _cloud_files_cache['ts'] and \
                time.time() - _cloud_files_cache['ts'] < _CLOUD_CACHE_TTL
        if not force and files and fresh:
            return files
        if not force and files:
            # 刚被其他线程扫完（如启动线程）：直接返回
            return files
        files = []
        for base in cloud_mount_bases():
            try:
                files.extend(ol_list_videos(base, depth=5, max_count=5000))
            except Exception as e:
                _log(f'cloud scan error {base}: {e}')
        with _cloud_files_lock:
            _cloud_files_cache['ts'] = time.time()
            _cloud_files_cache['files'] = files
        # v2.8: 扫描时 fs/list 自带的签名统一入缓存（list/search/detail 全部本地查签名）
        now = time.time()
        with _sign_cache_lock:
            for f in files:
                sv = f.get('sign')
                if sv:
                    _sign_cache[f['path']] = (now, sv)
            if len(_sign_cache) > 12000:
                expired = [k for k, v in _sign_cache.items() if now - v[0] > 7200]
                for k in expired:
                    del _sign_cache[k]
        _log(f'cloud files refreshed: {len(files)} files')
        return files

_cloud_refresh_lock = threading.Lock()

def trigger_cloud_refresh():
    """异步触发网盘文件缓存强制刷新（保存网盘 CK 后由 LuCI 调用，避免空缓存锁定 30 分钟）"""
    def _bg():
        try:
            files = get_cloud_files(force=True)
            _update_cloud_stats(files)
            _log(f'cloud refresh done: {json.dumps(_stats.get("cloud_mounts", {}), ensure_ascii=False)}')
        except Exception as e:
            _log(f'cloud refresh error: {e}')
    with _cloud_refresh_lock:
        threading.Thread(target=_bg, daemon=True).start()

# ============================================================
# 网盘片源海报匹配（用 CMS 聚合库自带海报，零外部依赖）
# ============================================================
# 思路：网盘文件/目录名 → 归一化片名 → 查 CMS 库（5.8万+部，自带 vod_pic）
# 索引在爬取完成/磁盘加载后构建（后台，不阻塞请求）；未命中则无海报（占位图）
_PIC_INDEX = {}
_PIC_INDEX_LOCK = threading.Lock()
# 刮削结果（豆瓣/CMS远端补全），独立于 _PIC_INDEX：
# 爬取重建本地索引不会覆盖它；持久化到 poster_extra.json.gz，重启不丢
_PIC_EXTRA = {}
_PIC_FILL_RUNNING = False
# 海报刮削实时进度（LuCI 状态页显示）：running/total/done/scraped(匹配成功)/framed(截帧兑底)/started(开始时间)
_POSTER_FILL_STATUS = {'running': False, 'total': 0, 'done': 0, 'scraped': 0, 'framed': 0, 'started': 0}

_PIC_MARK_RE = re.compile(
    r'2160p|1080[pi]|720p|480p|4k|8k|hdr10?|dolby|vision|web[-\s]?dl|web-?rip|blu-?ray|remux|'
    r'x26[45]|h26[45]|hevc|avc|aac\d?|dts(-hd)?|truehd|atmos|flac|multi|repack|proper|extended|'
    r'unrated|remastered|complete|国[语英粤]|粤语|中[文字英]|简体|繁体|双字|双语|字幕|'
    r'无水印|完整版|未删减|加长版|导演剪辑|高清|蓝光|首发|典藏版|修复版|国语版', re.I)

def _extract_title(s):
    """提取片名本体：书名号 → 首个含中文的方括号段 → 原名"""
    m = re.search(r'《([^》]{1,40})》', s)
    if m:
        return m.group(1)
    segs = re.findall(r'\[([^\[\]]{1,60})\]', s)
    cjk_segs = [b for b in segs if re.search(r'[\u4e00-\u9fff]', b)]
    if cjk_segs:
        return cjk_segs[0]
    return s

def _norm_title(s):
    """片名归一化：去扩展名/季集/年份/质量标记 → 匹配 key
    例: 'The.Last.of.Us.S02E04.1080p.WEB.x264-老K.mkv' → 'the last of us'
        '最后生还者 第二季 4K' → '最后生还者'
        '《凡人修仙传》虚天战纪 导演剪辑版' → '凡人修仙传'
        '[致命弯道 2003][4K 德版原盘 简英双字]' → '致命弯道'
    """
    if not s:
        return ''
    s = s.strip()
    s = re.sub(r'\.(mp4|mkv|iso|ts|m2ts|avi|rmvb|wmv|flv|mov|mpg|mpeg|rm)$', '', s, flags=re.I)
    # 网盘目录命名习惯：片名本体常被书名号/首个含中文的方括号包裹，其后是版本注释；
    # 只取含中文的段，避免 [tmdbid=51533] 这类标记段劫持（如 '让子弹飞 (2010) [tmdbid=...]')
    s = _extract_title(s)
    s = s.replace('.', ' ').replace('_', ' ').replace('【', ' ').replace('】', ' ')
    # 季集截断：S02E04 / E04 / S02 / 第x季部集卷 / CD1 / Disc1
    s = re.split(r'[Ss]\d{1,2}\s?[Ee]\d{1,3}|\b[Ee]\d{1,3}\b|\b[Ss]\d{1,2}\b|'
                 r'第\s*[\d一二三四五六七八九十百]+\s*[季部集卷]|\b[Cc][Dd]\s?\d\b|\b[Dd]isc\s?\d\b', s)[0]
    # 年份截断（纯数字片名如 1917 兑底：截后为空则回退）
    before_year = s
    s = re.split(r'[（(]\s*(19|20)\d{2}\s*[)）]|\b(19|20)\d{2}\b', s)[0]
    if not s.strip():
        s = before_year
    s = _PIC_MARK_RE.sub(' ', s)
    s = re.sub(r'[^\w\u4e00-\u9fff]+', ' ', s)
    s = re.sub(r'\s+', ' ', s).strip().lower()
    return s

def _cjk_key(s):
    """提取纯中文段候选 key（处理 '三傻大闹宝莱坞 3 Idiots' 中英混合名：英文残留会污染主 key）
    必须传入括号提取后的干净名，否则版本注释段（'DIY国粤语 简繁特效字幕'）会被拼入
    例: '三傻大闹宝莱坞 3 Idiots 2009' → '三傻大闹宝莱坞'"""
    parts = re.findall(r'[\u4e00-\u9fff]{2,}', s or '')
    if not parts:
        return ''
    return ''.join(parts)

def _build_pic_index():
    """CMS 库变化后重建 片名→(海报,年份) 索引（网盘片源海报墙数据源）
    每部片注册两个 key：完整归一化 key + 纯中文段 key（中英混合名兑底）"""
    global _PIC_INDEX
    try:
        with _all_vods_lock:
            snapshot = list(_all_vods)
        idx = {}
        for v in snapshot:
            pic = v.get('vod_pic') or ''
            if not pic:
                continue
            clean = _extract_title(v.get('vod_name') or '')
            year = v.get('vod_year') or ''
            for k in (_norm_title(clean), _cjk_key(clean)):
                if k and k not in idx:
                    idx[k] = (pic, year)
        with _PIC_INDEX_LOCK:
            _PIC_INDEX = idx
        _log(f'poster index built: {len(idx)} entries')
    except Exception as e:
        _log(f'poster index error: {e}')

def _pic_lookup(name):
    """片名 → (海报URL, 年份)：刮削结果优先（豆瓣质量高）→ 本地 CMS 库索引；未命中返回 None"""
    if not name:
        return None
    clean = _extract_title(name.strip())
    for k in (_cjk_key(clean), _norm_title(clean)):
        if k and k in _PIC_EXTRA:
            return _PIC_EXTRA[k]
    for k in (_norm_title(clean), _cjk_key(clean)):
        if k and k in _PIC_INDEX:
            return _PIC_INDEX[k]
    return None

def _pic_register(name, pic, year):
    """注册片名 → 海报到刮削结果表（双 key：完整归一化 + 中文段）"""
    if not name or not pic:
        return
    clean = _extract_title(name.strip())
    for k in (_norm_title(clean), _cjk_key(clean)):
        if k:
            _PIC_EXTRA[k] = (pic, year or '')

def _wrap_pic(pic, host):
    """包装海报 URL：豆瓣（Referer 防盗链）与 TMDb（国内访问不稳）走本地代理；
    thumb:// 是片源截帧的本地文件路径 → 转为 /thumb/ 端点 URL"""
    if not pic:
        return ''
    if pic.startswith('thumb://'):
        # v1.5.4 修复：thumb:// 后存的是 thumbs 文件绝对路径，文件名即 <hash>.jpg；
        # 旧版对文件路径重算 md5 生成错位 hash，导致 /thumb/ 全部 404（TVBox 封面丢失）
        import os as _os
        return f'http://{host}/thumb/{_os.path.basename(pic[8:])}'
    if 'doubanio.com' in pic or 'tmdb.org' in pic or 'thetvdb.com' in pic:
        b64 = base64.b64encode(pic.encode()).decode()
        return f'http://{host}/picproxy?u={b64}'
    return pic

_DOUBAN_FAILS = 0
_DOUBAN_BROKEN = False

# ==========================================================================
# 刮削匹配模式（UCI mediahub.main.scrape_mode，LuCI「海报刮削设置」可配）：
#   strict   严格：候选片名须与源一致 + 年份一致（双方可知时）——最准，弱匹配转截帧
#   balanced 均衡：候选片名须与源一致（归一化/中文段/英文词任一相等）——推荐
#   rapid    急速：不校验，沿用第一个有图结果（旧行为）——命中快但易错配
# 不论哪种模式，刮削失败一律由片源截帧兜底（cloud_path 提供时）
_SCRAPE_MODE = None

def _get_scrape_mode():
    """读取匹配模式（缓存，LuCI 保存时伴随 CMS 重启 → 缓存自动刷新）"""
    global _SCRAPE_MODE
    if _SCRAPE_MODE is None:
        m = (uci_get('mediahub.main.scrape_mode') or '').strip().lower()
        _SCRAPE_MODE = m if m in ('strict', 'balanced', 'rapid') else 'balanced'
    return _SCRAPE_MODE

def _src_year(s):
    """从文件名提取年份（(2010)/2010 形态），用于严格模式校验；失败返回 ''"""
    m = re.search(r'[（(]\s*((?:19|20)\d{2})\s*[)）]', s or '')
    if not m:
        m = re.search(r'(?<!\d)((?:19|20)\d{2})(?!\d)', s or '')
    return m.group(1) if m else ''

def _accept_match(clean, cand_title, cand_year, src_year, mode):
    """校验刮削候选是否真匹配源片（防近似名/注释段污染导致的海报错配）。
    返回 False 时调用方继续尝试下一候选，全部不过 → 截帧兜底。
    标题一致性三选一：归一化相等 / 纯中文段相等 / 英文词序列相等
    （候选标题常为 '中文名 English Name'，拼在一起比对三种 key）"""
    if mode == 'rapid':
        return True
    if not cand_title:
        return False
    sn, sc = _norm_title(clean), _cjk_key(clean)
    se = ' '.join(re.findall(r'[A-Za-z]{2,}', clean)).lower()
    cn, cc = _norm_title(cand_title), _cjk_key(cand_title)
    ce = ' '.join(re.findall(r'[A-Za-z]{2,}', cand_title)).lower()
    ok = (cn and sn and cn == sn) or (cc and sc and cc == sc) or (ce and se and ce == se)
    # cjk key 匹配时额外校验数字序列：'流浪地球' vs '流浪地球2' 的 cjk key 相同
    # 但数字部分不同（[] vs ['2']），是不同的片（续集/原作），须拒
    if ok and cc and sc and cc == sc:
        def _not_year(n):
            return not (len(n) == 4 and 1900 <= int(n) <= 2035)
        src_nums = [n for n in re.findall(r'\d+', clean) if _not_year(n)]
        cand_nums = [n for n in re.findall(r'\d+', cand_title) if _not_year(n)]
        if src_nums != cand_nums:
            ok = False
    # 严格模式加年份校验：双方年份可知且不一致 → 拒（区分同名重拍/续作）。
    # 片名本身含该数字（如电影《1917》）时跳过，避免把片名当年份误杀
    if mode == 'strict' and ok and src_year and cand_year and src_year not in cand_title:
        cy = str(cand_year)[:4]
        if cy and cy != src_year:
            ok = False
    return bool(ok)

def _douban_search(kw):
    """豆瓣搜索建议接口（无需 API key）。
    返回候选列表 [(标题(含副题/英文), 年份, 海报URL), ...]（仅有图的），
    由调用方按匹配模式校验——杜绝"第一个有图就用"的近似名误匹配"""
    try:
        url = 'https://movie.douban.com/j/subject_suggest?q=' + urllib.parse.quote(kw)
        req = urllib.request.Request(url, headers={
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'})
        with urllib.request.urlopen(req, timeout=6) as resp:
            arr = json.loads(resp.read().decode('utf-8', errors='replace'))
        out = []
        for it in arr or []:
            pic = it.get('img') or ''
            if not pic:
                continue
            title = ' '.join(x for x in (it.get('title') or '', it.get('sub') or '', it.get('en') or '') if x)
            out.append((title, str(it.get('year') or ''), pic))
        return out
    except Exception:
        return []

_TMDB_KEY = ''
_TMDB_API = ''
_TMDB_FAILS = 0        # 连续失败计数（熔断用）
_TMDB_BROKEN_UNTIL = 0  # 熔断截止时间（epoch，0=正常）
_TVDB_KEY = ''
_TVDB_API = ''
_TVDB_TOKEN = ''
_TVDB_TOKEN_TS = 0
_TVDB_FAILS = 0
_TVDB_BROKEN_UNTIL = 0

def _tmdb_search(kw):
    """TMDb 搜索（需 API key，国内官方 API 被墙需配反代地址）。
    UCI: mediahub.main.tmdb_key / mediahub.main.tmdb_api（默认官方，可填自建反代）
    熔断机制：连续 3 次失败（超时/错误）自动跳过 TMDb 30 分钟，避免每次 8s 超时拖慢刮削
    返回候选列表 [(标题(含原名), 年份, 海报URL), ...]，由调用方按模式校验"""
    global _TMDB_KEY, _TMDB_API, _TMDB_FAILS, _TMDB_BROKEN_UNTIL
    if not _TMDB_KEY:
        _TMDB_KEY = (uci_get('mediahub.main.tmdb_key') or '').strip()
        _TMDB_API = (uci_get('mediahub.main.tmdb_api') or '').strip() or 'https://api.themoviedb.org/3'
    if not _TMDB_KEY or not kw or len(kw) < 2:
        return []
    # 熔断检查：API 不可达（被墙）时跳过，30 分钟后重试
    if _TMDB_BROKEN_UNTIL and time.time() < _TMDB_BROKEN_UNTIL:
        return []
    if _TMDB_BROKEN_UNTIL and time.time() >= _TMDB_BROKEN_UNTIL:
        _TMDB_BROKEN_UNTIL = 0
        _TMDB_FAILS = 0
    try:
        out = []
        # movie 与 tv 都搜、合并候选：movie 有结果不代表就对（'Breaking Bad' 电影纪录片
        # 会占满候选挡住 tv 绝命毒师），由 _accept_match 逐个校验决定
        for kind in ('movie', 'tv'):
            url = (f'{_TMDB_API}/search/{kind}?api_key={_TMDB_KEY}'
                   f'&query={urllib.parse.quote(kw)}&language=zh-CN')
            req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
            with urllib.request.urlopen(req, timeout=5) as resp:
                d = json.loads(resp.read().decode('utf-8', errors='replace'))
            for it in (d.get('results') or [])[:5]:
                pp = it.get('poster_path') or ''
                if not pp:
                    continue
                title = ' '.join(x for x in (it.get('title') or it.get('name') or '',
                                             it.get('original_title') or it.get('original_name') or '') if x)
                year = (it.get('release_date') or it.get('first_air_date') or '')[:4]
                out.append((title, year, 'https://image.tmdb.org/t/p/w500' + pp))
        _TMDB_FAILS = 0
        return out
    except Exception:
        _TMDB_FAILS += 1
        if _TMDB_FAILS >= 3:
            _TMDB_BROKEN_UNTIL = time.time() + 1800
            _log(f'tmdb circuit breaker: 3 consecutive fails, skip for 30min')
        return []

def _tvdb_search(kw):
    """TheTVDB 搜索（需 API key，专注电视剧/剧集海报）。
    UCI: mediahub.main.tvdb_key / mediahub.main.tvdb_api（默认官方，可填自建反代）
    API v2 流程：POST /login 获取 token → GET /search/series?name= 搜索
    图片在 art.thetvdb.com，走 picproxy 代理（国内访问不稳）
    熔断机制：连续 3 次失败自动跳过 30 分钟
    返回候选列表 [(标题(含别名), 年份, 海报URL), ...]，由调用方按模式校验"""
    global _TVDB_KEY, _TVDB_API, _TVDB_TOKEN, _TVDB_TOKEN_TS, _TVDB_FAILS, _TVDB_BROKEN_UNTIL
    if not _TVDB_KEY:
        _TVDB_KEY = (uci_get('mediahub.main.tvdb_key') or '').strip()
        _TVDB_API = (uci_get('mediahub.main.tvdb_api') or '').strip() or 'https://api.thetvdb.com'
    if not _TVDB_KEY or not kw or len(kw) < 2:
        return []
    # 熔断检查
    if _TVDB_BROKEN_UNTIL and time.time() < _TVDB_BROKEN_UNTIL:
        return []
    if _TVDB_BROKEN_UNTIL and time.time() >= _TVDB_BROKEN_UNTIL:
        _TVDB_BROKEN_UNTIL = 0
        _TVDB_FAILS = 0
    try:
        # token 缓存 50 分钟（TheTVDB token 有效期约 1 小时）
        now = time.time()
        if not _TVDB_TOKEN or (now - _TVDB_TOKEN_TS) > 3000:
            login_url = f'{_TVDB_API}/login'
            req = urllib.request.Request(login_url,
                                         data=json.dumps({'apikey': _TVDB_KEY}).encode(),
                                         headers={'Content-Type': 'application/json'},
                                         method='POST')
            with urllib.request.urlopen(req, timeout=5) as resp:
                d = json.loads(resp.read().decode('utf-8', errors='replace'))
            _TVDB_TOKEN = d.get('token') or ''
            _TVDB_TOKEN_TS = now
        if not _TVDB_TOKEN:
            return []
        search_url = f'{_TVDB_API}/search/series?name={urllib.parse.quote(kw)}'
        req = urllib.request.Request(search_url,
                                     headers={'Authorization': f'Bearer {_TVDB_TOKEN}',
                                              'Accept': 'application/json'})
        with urllib.request.urlopen(req, timeout=5) as resp:
            d = json.loads(resp.read().decode('utf-8', errors='replace'))
        out = []
        for it in (d.get('data') or [])[:5]:
            poster = it.get('poster') or ''
            if not poster:
                continue
            title = ' '.join(x for x in (it.get('seriesName') or '',
                                         it.get('aliasName') or '') if x)
            year = (it.get('firstAired') or '')[:4]
            pic = 'https://art.thetvdb.com' + poster if poster.startswith('/') else poster
            out.append((title, year, pic))
        _TVDB_FAILS = 0
        return out
    except Exception:
        _TVDB_FAILS += 1
        if _TVDB_FAILS >= 3:
            _TVDB_BROKEN_UNTIL = time.time() + 1800
            _log(f'tvdb circuit breaker: 3 consecutive fails, skip for 30min')
        return []

def _ffmpeg_path():
    """静态 ffmpeg 路径自适应：主路由 /mnt/data/ffmpeg，IPK 机器数据盘 /mnt/sda4/ffmpeg。
    系统自带 ffmpeg 是精简构建（--disable-decoder=h264/hevc），无法软解截帧，必须静态版；
    找不到返回 ''（截帧兑底自动跳过，不影响其他刮削源）"""
    for p in ('/mnt/data/ffmpeg/ffmpeg', '/mnt/sda4/ffmpeg/ffmpeg'):
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return ''

# 115 UA 绑定：AList 115 驱动 Link() 用“发起请求的客户端 UA”去 115 换下载链接，
# CDN 会校验同一 UA（2026-09 起 115 收紧了校验，UA 不匹配 → 403 invalid signature）。
# 因此 fs/get 拿链接与 curl 下载必须带同一个 UA
_GRAB_UA = ('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36')

def _ffprobe_duration(src, FF):
    """用 ffmpeg -i 解析时长（stderr 'Duration: hh:mm:ss'），URL/本地文件通用。
    解析失败返回 0（moov 在尾部只下头部时常见），由调用方兑底。"""
    try:
        import subprocess as _sp
        p = _sp.run([FF, '-hide_banner', '-i', src], capture_output=True, timeout=60)
        m = re.search(rb'Duration:\s*(\d+):(\d+):(\d+)', p.stderr or b'')
        if m and m.group(1) != b'N/A':
            return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
    except Exception:
        pass
    return 0

def _calc_thumb_seek(duration, size=0):
    """计算正片截帧时间点（v1.5.5 分级策略）：
    - <30min → 中间帧（50%）——短视频无长片头，中间即内容主体
    - 30min~1h → 50%→30% 线性插值
    - 1h~2h → 30%→15% 线性插值
    - ≥2h → 15%（比例延续，不封顶秒数）
    - 时长未知 + 小文件（≤500MB）→ 按 2.5Mbps 粗估：估时≤30min 取中点，否则 90s
    - 兕底 90s（多数片头 <1.5min）"""
    try:
        if duration and duration > 0:
            if duration <= 1800:
                return max(2, int(duration * 0.5))
            if duration <= 3600:
                pct = 0.5 - (duration - 1800) * (0.5 - 0.3) / 1800.0
                return max(45, int(duration * pct))
            if duration <= 7200:
                pct = 0.3 - (duration - 3600) * (0.3 - 0.15) / 3600.0
                return max(45, int(duration * pct))
            return int(duration * 0.15)
        if size and 0 < size <= 500 * 1048576:
            est = int(size * 8 / (2.5 * 1024 * 1024))
            if est <= 1800:
                return max(2, int(est * 0.5))
            return 90
        return 90
    except Exception:
        return 90

def _grab_head_and_thumb(path, out_jpg, mb=16):
    """fs/get 拿 raw_url → 截帧出海报图。
    两种路径（自动选择）：
    1) raw_url 是 AList 本地代理（127.0.0.1）→ ffmpeg 直读 URL 流式截帧
       （MP4 moov atom 可能在文件尾部，只下载头部 16MB 读不到元数据；
        本地代理无 DNS/UA 问题，ffmpeg HTTP protocol 自动 seek 到 moov + 指定时间点）
    2) raw_url 是外部 CDN（如 115cdn.net）→ curl 下载头部 16MB + ffmpeg 本地截帧
       （静态 ffmpeg 对 CDN 域名 DNS 解析异常 + 115 UA 绑定，必须 curl 中转）
    """
    FF = _ffmpeg_path()
    if not FF:
        return False
    try:
        token = _get_ol_admin_token()
        if not token:
            return False
        req = urllib.request.Request('http://127.0.0.1:%d/api/fs/get' % CFG['ol_port'],
                                     data=json.dumps({'path': path}).encode(),
                                     headers={'Content-Type': 'application/json',
                                              'Authorization': token,
                                              'User-Agent': _GRAB_UA},
                                     method='POST')
        with urllib.request.urlopen(req, timeout=15) as resp:
            d = json.loads(resp.read().decode('utf-8', errors='replace'))
        ru = (d.get('data') or {}).get('raw_url') or ''
        if not ru.startswith('http'):
            return False
        import subprocess as _sp

        # 本地代理 URL：ffmpeg 直读（流式 seek，不怕 moov atom 在文件尾部）
        # v1.5.4：跳片头截正片——先解析总时长，seek 到 15% 处（clamp 45s~15min）
        if '127.0.0.1' in ru or 'localhost' in ru:
            dur = _ffprobe_duration(ru, FF)
            seek = _calc_thumb_seek(dur, int((d.get('data') or {}).get('size') or 0))
            p = _sp.run([FF, '-y', '-ss', str(seek), '-i', ru, '-frames:v', '1', '-q:v', '4', out_jpg],
                        capture_output=True, timeout=120)
            if not (os.path.exists(out_jpg) and os.path.getsize(out_jpg) > 2048) and seek > 3:
                # 正片位截帧失败（流异常/越界/时长错）→ 回退头部 3s，保证不劣化
                try:
                    os.remove(out_jpg)
                except Exception:
                    pass
                _sp.run([FF, '-y', '-ss', '3', '-i', ru, '-frames:v', '1', '-q:v', '4', out_jpg],
                        capture_output=True, timeout=120)
            return os.path.exists(out_jpg) and os.path.getsize(out_jpg) > 2048

        # 外部 CDN：curl 下载头部 + ffmpeg 本地截帧
        # v1.5.4：跳片头截正片——16MB 头部只够开头几十秒，按 seek 点动态加大下载量
        import tempfile
        part = tempfile.NamedTemporaryFile(suffix='.part', delete=False)
        part.close()
        size = int((d.get('data') or {}).get('size') or 0)
        _sp.run(['curl', '-sL', '-m', '120', '-A', _GRAB_UA, '-r', '0-%d' % (mb * 1048576 - 1), '-o', part.name, ru],
                timeout=150)
        ok = False
        if os.path.exists(part.name) and os.path.getsize(part.name) > 1048576:
            dur = _ffprobe_duration(part.name, FF)
            seek = _calc_thumb_seek(dur, size)
            need = mb
            if dur > 0 and size > 0:
                # seek 点 +30s 帧数据 + 12MB 余量（按平均码率线性估算，moov 开销兑在余量里）
                need = int(size * (seek + 30) / dur / 1048576) + 12
                if need > 96:
                    # 下载上限 96MB 约束下，seek 联动反推到可覆盖位置（保底 45s）
                    need = 96
                    seek = max(45, int((96 - 12) * 1048576 * dur / size) - 30)
                need = min(max(need, mb), 96)
            else:
                # 时长未知：保守 5 分钟内（92 年代估算下 96MB@≥2Mbps 能覆盖）
                seek = min(seek, 300)
            if need > mb:
                _sp.run(['curl', '-sL', '-m', '240', '-A', _GRAB_UA, '-r', '0-%d' % (need * 1048576 - 1), '-o', part.name, ru],
                        timeout=280)
            p = _sp.run([FF, '-y', '-ss', str(seek), '-i', part.name, '-frames:v', '1', '-q:v', '4', out_jpg],
                        capture_output=True, timeout=120)
            ok = os.path.exists(out_jpg) and os.path.getsize(out_jpg) > 2048
            if not ok and seek > 3:
                # 正片位失败（估算不足/moov 尾部读不到时长）→ 回退头部 3s
                try:
                    os.remove(out_jpg)
                except Exception:
                    pass
                _sp.run([FF, '-y', '-ss', '3', '-i', part.name, '-frames:v', '1', '-q:v', '4', out_jpg],
                        capture_output=True, timeout=120)
                ok = os.path.exists(out_jpg) and os.path.getsize(out_jpg) > 2048
        try:
            os.remove(part.name)
        except Exception:
            pass
        return ok
    except Exception:
        return False

def _thumb_file_path(path):
    """网盘路径 → 海报缓存文件路径（<data_dir>/thumbs/）"""
    import hashlib
    h = hashlib.md5(path.encode()).hexdigest()[:16]
    return os.path.join(_PERSIST_DIR, 'thumbs', h + '.jpg')

def _cms_remote_search(kw):
    """CMS 远端站点搜索兜底（轮询前 3 个站，取首个有结果的）。
    返回候选列表 [(片名, 年份, 海报URL), ...]，由调用方按模式校验——
    远端 wd= 是模糊搜索，不校验极易拿到近似名（不同片）的海报"""
    out = []
    for site in CFG['sites'][:3]:
        sep = '&' if '?' in site else '?'
        try:
            data = fetch_json(f'{site}{sep}ac=detail&wd={urllib.parse.quote(kw)}', timeout=6)
            for v in (data or {}).get('list') or []:
                pic = v.get('vod_pic') or ''
                if pic:
                    out.append((v.get('vod_name') or '', v.get('vod_year') or '', pic))
            if out:
                return out
        except Exception:
            continue
    return out

def _scrape_one(name, cloud_path=None, info=None):
    """单片刮削，优先级：TMDb → TheTVDB → 豆瓣 → CMS 远端 → 片源截帧兜底。
    TMDb/TheTVDB 需配置 Key（LuCI 刮削设置），未配置自动跳过；豆瓣无需配置。
    匹配模式见 _get_scrape_mode()（严格/均衡/急速），不论哪种模式，
    刮削失败/校验不过都由片源截帧兜底（cloud_path 提供时）。
    info 传入 dict 时回填 matched(命中的候选标题)/source(来源)，供前端展示与调试。
    命中注册进 _PIC_EXTRA（持久化）"""
    mode = _get_scrape_mode()
    clean = _extract_title((name or '').strip())
    cjk = _cjk_key(clean)
    norm = _norm_title(clean)
    eng = ' '.join(w for w in re.findall(r'[A-Za-z]{2,}', clean))
    kws = [k for k in (cjk, norm, eng) if k and len(k) >= 2]
    if not kws:
        return None
    sy = _src_year(name or '')

    def _pick(cands, label):
        """在候选列表里按模式挑出可信匹配，返回 (pic, year, matched) 或 None"""
        for (t, y, pic) in cands or []:
            if _accept_match(clean, t, y, sy, mode):
                return (pic, y, t, label)
        return None

    hit = None
    for kw in kws:
        got = _pick(_tmdb_search(kw), 'TMDb')
        if got:
            hit = (got[0], got[1])
            if info is not None:
                info['matched'], info['source'] = got[2], got[3]
            break
    if not hit:
        for kw in kws:
            got = _pick(_tvdb_search(kw), 'TheTVDB')
            if got:
                hit = (got[0], got[1])
                if info is not None:
                    info['matched'], info['source'] = got[2], got[3]
                break
    if not hit:
        for kw in kws:
            got = _pick(_douban_search(kw), '豆瓣')
            if got:
                hit = (got[0], got[1])
                if info is not None:
                    info['matched'], info['source'] = got[2], got[3]
                break
    if not hit:
        # CMS 远端同样逐 key 回退：中文段 key 常被注释段污染（'泰坦尼克号国语中字'），
        # 必须再试归一化 key（'泰坦尼克号'），否则白丢命中
        for kw in kws:
            got = _pick(_cms_remote_search(kw), '采集站')
            if got:
                hit = (got[0], got[1])
                if info is not None:
                    info['matched'], info['source'] = got[2], got[3]
                break
    if not hit and cloud_path:
        # 最后兜底：从片源截帧做海报（所有模式共用）
        tf = _thumb_file_path(cloud_path)
        if not os.path.exists(tf):
            os.makedirs(os.path.dirname(tf), exist_ok=True)
            if not _grab_head_and_thumb(cloud_path, tf):
                return None
        else:
            return None  # 已有截帧但仍未命中（前次截过），不再重截
        # 截帧成功：注册为本地相对路径（响应时再拼 host）
        _pic_register(name, 'thumb://' + tf, '')
        if info is not None:
            info['matched'], info['source'] = '片源截帧', '截帧'
        return ('thumb://' + tf, '')
    if hit:
        _pic_register(name, hit[0], hit[1])
    return hit

def _save_pic_index():
    """持久化刮削结果，重启不丢"""
    try:
        import gzip
        # v1.5.4 防护：内存为空但磁盘非空时跳过保存——load 静默失败（异常被吞）会让
        # 服务带空 _PIC_EXTRA 运行，stop 时把几小时刮削成果一次清零，此防护拦住覆盖
        if not _PIC_EXTRA and os.path.exists(_POSTER_EXTRA_FILE) and os.path.getsize(_POSTER_EXTRA_FILE) > 100:
            _log('poster extra save SKIPPED: empty memory would overwrite non-empty file')
            return
        os.makedirs(_PERSIST_DIR, exist_ok=True)
        tmp = _POSTER_EXTRA_FILE + '.tmp'
        with gzip.open(tmp, 'wb') as f:
            f.write(json.dumps(_PIC_EXTRA, ensure_ascii=False).encode('utf-8'))
        os.replace(tmp, _POSTER_EXTRA_FILE)
        _log(f'poster extra saved: {len(_PIC_EXTRA)} entries -> {_POSTER_EXTRA_FILE}')
    except Exception as e:
        _log(f'save poster extra error: {e}')

def _load_pic_index():
    """启动时加载持久化的刮削结果"""
    global _PIC_EXTRA
    try:
        if os.path.exists(_POSTER_EXTRA_FILE):
            import gzip
            with gzip.open(_POSTER_EXTRA_FILE, 'rb') as f:
                d = json.loads(f.read().decode('utf-8'))
            _PIC_EXTRA = {k: tuple(v) for k, v in d.items()}
            _log(f'poster extra loaded: {len(_PIC_EXTRA)} entries')
    except Exception as e:
        _log(f'load poster extra error: {e}')

def _poster_fill_worker(force=False):
    """后台补全网盘片源海报（刮削）：本地索引 miss 的文件名 → 豆瓣优先 → CMS 远端兑底
    背景：本地库只爬各站前 1000 页（按更新时间排序），老片不在库中；
    网盘文件相对静态，一次性补全（限速）后持久化，重启不丢"""
    global _PIC_FILL_RUNNING
    if _PIC_FILL_RUNNING:
        _log('poster fill: already running, skip')
        return
    _PIC_FILL_RUNNING = True
    _log('poster fill thread started')
    _POSTER_FILL_STATUS.update({'running': True, 'total': 0, 'done': 0, 'scraped': 0, 'framed': 0, 'started': int(time.time())})
    try:
        time.sleep(90)  # 等挂载自愈 + 网盘文件索引就绪
        files = []
        for attempt in range(6):
            try:
                files = get_cloud_files()
            except Exception as fe:
                _log(f'poster fill: get_cloud_files error: {fe}')
                files = []
            if files:
                break
            _log(f'poster fill: no cloud files yet, retry {attempt + 1}/6 in 60s')
            time.sleep(60)
        if not files:
            _log('poster fill: no cloud files after retries, skip')
            return
        _has_cjk = lambda s: bool(re.search(r'[\u4e00-\u9fff]', s or ''))
        todo = []
        for f in files:
            fname = f.get('name', '')
            if not _has_cjk(fname[:20]) and _has_cjk(f.get('dir', '')):
                name = f.get('dir', '')
            else:
                name = fname.rsplit('.', 1)[0] if '.' in fname else fname
            if not _pic_lookup(name):
                todo.append((name, f.get('path', '')))
        if not todo:
            _log(f'poster fill: all {len(files)} files already have posters')
            return
        # 片源截帧：刮削全部失败时的兑底（从视频里抽一帧做海报，需静态 ffmpeg）
        _log(f'poster fill: {len(todo)}/{len(files)} files to scrape (mode={_get_scrape_mode()}, tmdb/tvdb/douban/cms/frame)')
        _POSTER_FILL_STATUS['total'] = len(todo)
        ok = 0
        for i, (name, cpath) in enumerate(todo):
            try:
                hit = _scrape_one(name, cloud_path=cpath)
                if hit:
                    ok += 1
                    if hit[0].startswith('thumb://'):
                        _POSTER_FILL_STATUS['framed'] += 1
                    else:
                        _POSTER_FILL_STATUS['scraped'] += 1
            except Exception as se:
                _log(f'poster fill: item error at {i}: {se}')
            _POSTER_FILL_STATUS['done'] = i + 1
            time.sleep(0.3)
            if (i + 1) % 20 == 0:
                _log(f'poster fill: {i + 1}/{len(todo)} done, scraped {ok}')
                try:
                    _save_pic_index()
                except Exception:
                    pass
        _log(f'poster fill complete: {ok}/{len(todo)} scraped')
    except Exception as e:
        _log(f'poster fill error: {e}')
    finally:
        _PIC_FILL_RUNNING = False
        _POSTER_FILL_STATUS['running'] = False
        _save_pic_index()

def get_sign(path):
    """获取 AList /d/ /p/ 播放签名
    v2.8: 纯本地查询——签名来自扫描时 fs/list 自带的 sign 字段（扫描顺手入缓存，零远程调用）。
    旧实现每次打 /api/fs/get（115 一次 ~3s），是列表/详情加载慢的主因。
    扫描每 30 分钟刷新，签名随之更新；拿不到则返回空串（AList sign_all 关闭时
    空签名的 /d/ /p/ 链接可直接播放，与现状一致）。
    """
    with _sign_cache_lock:
        hit = _sign_cache.get(path)
        if hit:
            return hit[1]
    return ''

def cloud_classes():
    """v1.5: 网盘分类动态化——按 AList 实际挂载生成（多网盘）"""
    names = {'115': '115网盘', 'quark': '夸克网盘', 'uc': 'UC网盘', 'aliyun': '阿里云盘',
             '189': '天翼云盘', 'yidong': '移动云盘', '123': '123云盘', 'baidu': '百度网盘',
             'thunder': '迅雷云盘', 'pikpak': 'PikPak'}
    out = []
    for b in cloud_mount_bases():
        key = b.strip('/').split('/')[0]
        out.append({'type_id': key, 'type_name': names.get(key, key)})
    return out or [{'type_id': '115', 'type_name': '115网盘'},
                   {'type_id': 'quark', 'type_name': '夸克网盘'}]

def cloud_cms_response(params, method, host):
    """将 AList 网盘文件转 CMS JSON 格式（文件列表走缓存，搜索秒回）
    TVBox 端兼容要点：
    - t 参数兼容 type_id 原值(115/quark)、分类名、数字编号(1/2) 等多种形态
    - pg 参数钳制（部分端分页从 0 开始，负切片会返回空列表）
    - 任意分支都返回 class 分类表，避免端上 tab 消失
    """
    ac = (params.get('ac', [''])[0] or '').strip().lower()
    wd = (params.get('wd', [''])[0] or '').strip()
    try:
        pg = int(float(params.get('pg', ['1'])[0] or '1'))
    except Exception:
        pg = 1

    def build_entry(f):
        fname = f['name']
        vod_class = '电视剧' if any(k in fname for k in ['S0', 'E0', '第']) else ('4K' if '4K' in fname or '2160p' in fname else '电影')
        # 播放直连 AList 公网：115 走 /d/（302直链，AList /p/ 对302存储返回403），
        # 夸克等 web_proxy 存储走 /p/（服务器中继，CDN校验UA必须中继）
        # v2.8: 优先用扫描时 fs/list 自带的 sign（零远程），get_sign 纯本地兜底
        sign = f.get('sign') or get_sign(f['path'])
        encoded_path = urllib.parse.quote(f['path'], safe='/')
        ext = fname.rsplit('.', 1)[1].lower() if '.' in fname else ''
        size_gb = f'{f.get("size", 0) / 1073741824:.1f}GB' if f.get('size') else ''
        # 原盘 ISO/超大 REMUX：安卓 APP 播放器基本无法直接播放，标注提醒
        if ext == 'iso':
            extra = ' | 原盘ISO需Kodi/nPlayer'
            vod_class = '4K原盘'
        elif f.get('size', 0) > 30 * 1073741824:
            extra = ' | 超大原盘'
        else:
            extra = ''
        play_host = _host_only(host) or _host_only(CFG.get('ext_domain') or '') or '127.0.0.1'
        route = _mount_route(f['path'])   # v1.5: 按挂载 web_proxy 动态选 /d/ 直链 或 /p/ 中继
        play_port = CFG.get('play_port', 5244)
        play_url = f'http://{play_host}:{play_port}/{route}{encoded_path}'
        if sign:
            play_url += f'?sign={sign}'
        # 片名显示：文件名主体为英文（前20字符无中文）+ 中文目录名 → 用中文目录名
        # （网盘资源目录名通常是中文片名；文件名常为英文+尾部中文发布组名如"-老K"）
        _has_cjk = lambda s: bool(re.search(r'[\u4e00-\u9fff]', s or ''))
        if not _has_cjk(fname[:20]) and _has_cjk(f.get('dir', '')):
            vod_name = f['dir']
        else:
            vod_name = fname.rsplit('.', 1)[0] if '.' in fname else fname
        # 海报：刮削结果/本地库按片名匹配（显示名优先，原始文件名兑底）；
        # 列表阶段不触发截帧（耗时），只有刮削动作（手动/批量）才会截
        hit = _pic_lookup(vod_name) or _pic_lookup(fname)
        return {
            'type_name': vod_class,
            'vod_id': base64.b64encode(f['path'].encode()).decode(),
            'vod_name': vod_name,
            'vod_pic': _wrap_pic(hit[0], host) if hit else '', 'vod_play_from': 'alist',
            'vod_play_url': f'播放${play_url}',
            'vod_remarks': f'{size_gb}{extra}',
            'vod_year': hit[1] if hit else '',
            'vod_cloud_path': f['path']   # 网盘原路径：/scrape 截帧兜底用（TVBox 忽略未知字段）
        }

    if wd:
        response = {'code': 1, 'limit': 20, 'list': []}
        wdl = wd.lower()
        # 匹配文件名或父目录名（网盘资源目录名常含中文片名，文件名常为英文）
        matches = []
        for f in get_cloud_files():
            if wdl in f['name'].lower() or wdl in f.get('dir', '').lower():
                matches.append(f)
                if len(matches) >= 20:
                    break
        response['list'] = [build_entry(f) for f in matches]
        response['page'] = 1
        response['pagecount'] = 1
        response['total'] = len(response['list'])
    elif ac == 'detail' and (params.get('ids', [''])[0] or '').strip():
        ids = params.get('ids', [''])[0]
        response = {'code': 1, 'list': []}

        def _b64_path(vid):
            # base64 里的 '+' 在 URL 查询串中会被解析成空格，兜底还原
            for cand in (vid, vid.replace(' ', '+')):
                try:
                    p = base64.b64decode(cand).decode()
                    if p.startswith('/'):
                        return p
                except Exception:
                    continue
            return None

        # v2.7: 优先从网盘文件缓存直取（点击详情零远程调用，~50ms）；
        # 旧实现每次点击都打 1-2 次 AList fs/get，冷缓存时要 2-6s+
        cache_map = {f['path']: f for f in get_cloud_files()}
        for vid_id in ids.split(','):
            vid_id = vid_id.strip()
            if not vid_id:
                continue
            fpath = _b64_path(vid_id)
            if not fpath:
                continue
            f = cache_map.get(fpath)
            if f:
                response['list'].append(build_entry(f))
                continue
            # 缓存未命中（刚入库的新文件）：单次 fs/get 拿全部信息，sign 写入缓存复用
            r = ol_api('/api/fs/get', {'path': fpath})
            if r and r.get('code') == 200:
                info = r['data']
                with _sign_cache_lock:
                    _sign_cache[fpath] = (time.time(), info.get('sign', ''))
                pdir = info.get('parent') or (fpath.rsplit('/', 1)[0] if '/' in fpath else '')
                response['list'].append(build_entry(
                    {'path': fpath, 'name': info.get('name', ''),
                     'size': info.get('size', 0), 'dir': pdir.rsplit('/', 1)[-1]}))
        response['page'] = 1
        response['total'] = len(response['list'])
    else:
        # 列表（t 分类过滤，兼容 type_id 原值 / 分类名 / 数字编号）
        all_files = get_cloud_files()
        t_raw = (params.get('t', [''])[0] or '').strip()
        tl = t_raw.lower()
        t_filter = ''
        if tl and tl not in ('0', 'all', 'home'):
            # v1.5: 按实际挂载动态匹配（key/中文名/序号），天然兼容 115/quark/夸克/1/2
            cls = cloud_classes()
            keys = [c['type_id'] for c in cls]
            for c in cls:
                if tl == (c.get('type_id') or '').lower() or (c.get('type_name') and c['type_name'] in t_raw):
                    t_filter = c['type_id']
                    break
            if not t_filter and tl.isdigit():
                idx = int(tl) - 1
                if 0 <= idx < len(keys):
                    t_filter = keys[idx]
        if t_filter:
            prefix = '/' + t_filter + '/'
            all_files = [f for f in all_files if f['path'].startswith(prefix)]
        total = len(all_files)
        pagecount = (total + 19) // 20
        # pg 钳制：部分端分页从 0 开始或超界，回退到第 1 页，避免负切片返回空列表
        if pagecount and (pg < 1 or pg > pagecount):
            pg = 1
        start = (pg - 1) * 20
        items = all_files[start:start + 20]
        response = {
            'code': 1, 'limit': 20, 'list': [build_entry(f) for f in items],
            'page': pg, 'pagecount': pagecount, 'total': total,
            'class': cloud_classes()
        }
        _log(f'cloudcms list: t={t_raw or "-"} -> {t_filter or "全部"}, '
             f'{len(items)}/{total} (pg={pg}, ac={ac or "-"})')

    response['class'] = cloud_classes()  # 所有分支统一携带分类表
    body = json.dumps(response, ensure_ascii=False).encode('utf-8')
    return body

# ============================================================
# v1.5: 小雅 PG 完整订阅（jsm.json 动态改写 + tokenm.json 凭证注入）
# ============================================================
def _pg_rewrite_ext(ext, base, host):
    """jsm.json 站点 ext 相对路径 → 绝对 URL；tokenm.json → 动态接口（注入 UCI 凭证）"""
    tok_url = f'http://{host}/pg/tokenm.json'
    def _rw_str(s):
        s = s.strip()
        if not s.startswith('./'):
            return s
        rel = s[2:]
        if rel in ('lib/tokenm.json', 'lib/tokentemplate.json'):
            return tok_url
        return base + rel
    if isinstance(ext, str):
        return '$$$'.join(_rw_str(p) for p in ext.split('$$$'))
    if isinstance(ext, dict):
        out = {}
        for k, v in ext.items():
            if isinstance(v, str) and v.startswith('./'):
                rel = v[2:]
                if rel in ('lib/tokenm.json', 'lib/tokentemplate.json'):
                    out[k] = tok_url
                else:
                    out[k] = base + rel
            else:
                out[k] = v
        return out
    return ext

def _build_tokenm():
    """动态 tokenm.json：模板 + UCI 多网盘凭证注入（PG 网盘站免手填 token）"""
    try:
        with open(os.path.join(_PG_DIR, 'lib', 'tokentemplate.json'), 'r', encoding='utf-8') as f:
            tm = json.load(f)
    except Exception:
        tm = {}
    c115 = (uci_get('mediahub.main.cookie_115') or '').strip()
    cq = (uci_get('mediahub.main.cookie_quark') or '').strip()
    cuc = (uci_get('mediahub.main.cookie_uc') or '').strip()
    tal = (uci_get('mediahub.main.token_ali') or '').strip()
    t189 = (uci_get('mediahub.main.token_189') or '').strip()
    t123 = (uci_get('mediahub.main.token_123') or '').strip()
    tyd = (uci_get('mediahub.main.token_yidong') or '').strip()
    tbd = (uci_get('mediahub.main.token_baidu') or '').strip()
    th = (uci_get('mediahub.main.thunder_auth') or '').strip()
    pp = (uci_get('mediahub.main.pikpak_auth') or '').strip()
    if c115: tm['pan115_cookie'] = c115
    if cq: tm['quark_cookie'] = cq
    if cuc: tm['uc_cookie'] = cuc
    if tal: tm['token'] = tal; tm['open_token'] = tal
    if tyd: tm['yd_auth'] = tyd
    if tbd: tm['baidu_cookie'] = tbd
    def _up(u_field, p_field, cred):
        if ':' in cred:
            u, p = cred.split(':', 1)
            tm[u_field] = u
            tm[p_field] = p
    if t189: _up('pan189_username', 'pan189_password', t189)
    if t123: _up('pan123_username', 'pan123_password', t123)
    if th: _up('thunder_username', 'thunder_password', th)
    if pp: _up('pikpak_username', 'pikpak_password', pp)
    return tm

# ============================================================
# HTTP Handler
# ============================================================
class CMSHandler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send_json(self, data, code=200):
        body = json.dumps(data, ensure_ascii=False).encode('utf-8') if isinstance(data, (dict, list)) else data
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def _get_host(self):
        """请求方主机:端口（跟随访问来源，含端口——经反代/映射端口访问时订阅内地址自洽回链）"""
        rh = (self.headers.get('Host', '') or '').strip()
        if rh:
            if ':' not in rh:
                rh = f'{rh}:{LISTEN_PORT}'
            return rh
        return f"{CFG.get('ext_domain') or '127.0.0.1'}:{LISTEN_PORT}"

    def _merge_post_params(self, params):
        """GET 查询参数 + POST 表单/JSON 体合并（部分 TVBox 端以 POST 请求 CMS 接口）
        仅在 vod 路由内调用；其余请求（代理到 AList）保持 body 原样转发。
        """
        if self.command not in ('POST', 'PUT', 'PATCH'):
            return params
        try:
            cl = int(self.headers.get('Content-Length') or 0)
            if cl <= 0 or cl > 65536:
                return params
            raw = self.rfile.read(cl).decode('utf-8', 'replace')
            if not raw.strip():
                return params
            ctype = (self.headers.get('Content-Type') or '').lower()
            if 'json' in ctype or raw.lstrip()[:1] == '{':
                try:
                    j = json.loads(raw)
                    if isinstance(j, dict):
                        for k, v in j.items():
                            params.setdefault(k, [str(v)])
                except Exception:
                    pass
            else:
                for k, v in urllib.parse.parse_qs(raw, keep_blank_values=True).items():
                    params.setdefault(k, v)
        except Exception:
            pass
        return params

    def _send_tvbox_json(self):
        host = self._get_host()
        tvbox = {
            'ads': [],
            'flags': ['youku','qq','iqiyi','qiyi','letv','sohu','tudou','pptv','mgtv','wasu'],
            'ijk': [
                {'group': '软解', 'options': [
                    {'category':4,'name':'opensles','value':'0'},
                    {'category':4,'name':'overlay-format','value':'842225234'},
                    {'category':4,'name':'framedrop','value':'1'},
                    {'category':4,'name':'soundtouch','value':'0'},
                    {'category':2,'name':'skip_loop_filter','value':'0'},
                    {'category':2,'name':'skip_frame','value':'0'},
                ]},
                {'group': '硬解', 'options': [
                    {'category':4,'name':'opensles','value':'0'},
                    {'category':4,'name':'overlay-format','value':'842225234'},
                    {'category':4,'name':'framedrop','value':'1'},
                    {'category':4,'name':'soundtouch','value':'0'},
                    {'category':1,'name':'mediacodec','value':'1'},
                    {'category':1,'name':'mediacodec-auto-rotate','value':'1'},
                    {'category':1,'name':'mediacodec-handle-resolution-change','value':'1'},
                    {'category':2,'name':'skip_loop_filter','value':'0'},
                    {'category':2,'name':'skip_frame','value':'0'},
                ]},
            ],
            'lives': [],
            'parses': [],
            'sites': [
                {
                    'key': 'cms_aggregate',
                    'name': 'CMS聚合影院',
                    'type': 1,
                    'api': f'http://{host}/cms.php/provide/vod',
                    'searchable': 1, 'quickSearch': 1, 'filterable': 1, 'changeable': 1,
                },
                {
                    'key': 'alist_cloud',
                    'name': '网盘影视',
                    'type': 1,
                    'api': f'http://{host}/cloudcms.php/provide/vod',
                    'searchable': 1, 'quickSearch': 1, 'filterable': 1, 'changeable': 1,
                },
            ],
            'spider': '',
        }
        self._send_json(tvbox)



    def _build_sub_pg_full(self, host):
        """v1.5: 小雅 PG 完整订阅（jsm.json 79 站点 + pg.jar spider）+ mediahub 自有源合并
        需 <data_dir>/pg/ 部署小雅 PG 资源（jsm.json/pg.jar/lib/js）；未部署自动回退精简版"""
        jsm_path = os.path.join(_PG_DIR, 'jsm.json')
        if not os.path.isfile(jsm_path):
            return self._build_sub_pg(host)
        try:
            with open(jsm_path, 'r', encoding='utf-8') as f:
                jsm = json.load(f)
        except Exception as e:
            _log(f'sub_pg jsm load error: {e}')
            return self._build_sub_pg(host)
        base = f'http://{host}/pg/'
        sp = jsm.get('spider')
        if isinstance(sp, str) and sp.startswith('./'):
            jsm['spider'] = base + sp[2:]
        for site in jsm.get('sites', []):
            if 'ext' in site:
                try:
                    site['ext'] = _pg_rewrite_ext(site['ext'], base, host)
                except Exception:
                    pass
        # 追加 mediahub 自有源（CMS聚合/网盘影视/网盘搜索 + 直播）
        jsm.setdefault('sites', []).extend([
            {'key': 'mediahub_cms', 'name': 'CMS聚合影院', 'type': 1,
             'api': f'http://{host}/cms.php/provide/vod',
             'searchable': 1, 'quickSearch': 1, 'filterable': 1, 'changeable': 1},
            {'key': 'mediahub_cloud', 'name': '网盘影视', 'type': 1,
             'api': f'http://{host}/cloudcms.php/provide/vod',
             'searchable': 1, 'quickSearch': 1, 'filterable': 1, 'changeable': 1},
            {'key': 'mediahub_search', 'name': '网盘资源搜索', 'type': 1,
             'api': f'http://{host}/cloudsearch.php/provide/vod',
             'searchable': 1, 'quickSearch': 1, 'filterable': 0, 'changeable': 1},
        ])
        jsm.setdefault('lives', []).extend([
            {'name': '国内直播(央视频道)', 'type': 0,
             'url': f'http://{host}/live/ytv.m3u',
             'epg': f'http://{host}/live/epg'},
            {'name': '国内直播(卫视)', 'type': 0,
             'url': f'http://{host}/live/ws.m3u',
             'epg': f'http://{host}/live/epg'},
        ])
        return jsm

    def _serve_pg_static(self, path, host):
        """v1.5: /pg/* 小雅 PG 静态资源（pg.jar/lib/js）+ tokenm.json 动态注入"""
        rel = path[4:] if path.startswith('/pg/') else ''
        if not rel or rel in ('tokenm.json', 'tokentemplate.json'):
            self._send_json(_build_tokenm())
            return True
        if '..' in rel.split('/'):
            self._send_json({'code': 403, 'message': 'forbidden'}, 403)
            return True
        fp = os.path.normpath(os.path.join(_PG_DIR, rel))
        root = os.path.normpath(_PG_DIR)
        if fp != root and not fp.startswith(root + os.sep):
            self._send_json({'code': 403, 'message': 'forbidden'}, 403)
            return True
        if not os.path.isfile(fp):
            self._send_json({'code': 404, 'message': f'not found: {rel}'}, 404)
            return True
        try:
            with open(fp, 'rb') as f:
                data = f.read()
            ct = mimetypes.guess_type(fp)[0] or 'application/octet-stream'
            self.send_response(200)
            self.send_header('Content-Type', ct)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Cache-Control', 'public, max-age=3600')
            self.end_headers()
            if self.command != 'HEAD':
                self.wfile.write(data)
        except Exception as e:
            self._send_json({'code': 500, 'message': str(e)}, 500)
        return True

    def _build_sub_pg(self, host):
        """完整订阅配置：CMS聚合 + 网盘影视 + 网盘搜索（纯自有，无外部依赖）"""
        return {
            'ads': [],
            'flags': ['youku','qq','iqiyi','qiyi','letv','sohu','tudou','pptv','mgtv','wasu'],
            'ijk': [
                {'group': '软解', 'options': [
                    {'category':4,'name':'opensles','value':'0'},
                    {'category':4,'name':'overlay-format','value':'842225234'},
                    {'category':4,'name':'framedrop','value':'1'},
                    {'category':4,'name':'soundtouch','value':'0'},
                    {'category':2,'name':'skip_loop_filter','value':'0'},
                    {'category':2,'name':'skip_frame','value':'0'},
                ]},
                {'group': '硬解', 'options': [
                    {'category':4,'name':'opensles','value':'0'},
                    {'category':4,'name':'overlay-format','value':'842225234'},
                    {'category':4,'name':'framedrop','value':'1'},
                    {'category':4,'name':'soundtouch','value':'0'},
                    {'category':1,'name':'mediacodec','value':'1'},
                    {'category':1,'name':'mediacodec-auto-rotate','value':'1'},
                    {'category':1,'name':'mediacodec-handle-resolution-change','value':'1'},
                    {'category':2,'name':'skip_loop_filter','value':'0'},
                    {'category':2,'name':'skip_frame','value':'0'},
                ]},
            ],
            'lives': [
                {'name': '国内直播(央视频道)', 'type': 0,
                 'url': f'http://{host}/live/ytv.m3u',
                 'epg': f'http://{host}/live/epg'},
                {'name': '国内直播(卫视)', 'type': 0,
                 'url': f'http://{host}/live/ws.m3u',
                 'epg': f'http://{host}/live/epg'},
            ],
            'parses': [],
            'sites': [
                {
                    'key': 'cms_aggregate',
                    'name': 'CMS聚合影院',
                    'type': 1,
                    'api': f'http://{host}/cms.php/provide/vod',
                    'searchable': 1, 'quickSearch': 1, 'filterable': 1, 'changeable': 1,
                },
                {
                    'key': 'alist_cloud',
                    'name': '网盘影视',
                    'type': 1,
                    'api': f'http://{host}/cloudcms.php/provide/vod',
                    'searchable': 1, 'quickSearch': 1, 'filterable': 1, 'changeable': 1,
                },
                {
                    'key': 'cloud_search',
                    'name': '网盘资源搜索',
                    'type': 1,
                    'api': f'http://{host}/cloudsearch.php/provide/vod',
                    'searchable': 1, 'quickSearch': 1, 'filterable': 0, 'changeable': 1,
                },
            ],
            'spider': '',
            'wallpaper': '',
        }

    def _send_cloud_json(self):
        """只含网盘影视源的精简 TVBox 配置（不含 CMS 采集站）"""
        host = self._get_host()
        tvbox = {
            'ads': [],
            'flags': ['youku','qq','iqiyi','qiyi','letv','sohu','tudou','pptv','mgtv','wasu'],
            'ijk': [
                {'group': '软解', 'options': [
                    {'category':4,'name':'opensles','value':'0'},
                    {'category':4,'name':'overlay-format','value':'842225234'},
                    {'category':4,'name':'framedrop','value':'1'},
                    {'category':4,'name':'soundtouch','value':'0'},
                    {'category':2,'name':'skip_loop_filter','value':'0'},
                    {'category':2,'name':'skip_frame','value':'0'},
                ]},
                {'group': '硬解', 'options': [
                    {'category':4,'name':'opensles','value':'0'},
                    {'category':4,'name':'overlay-format','value':'842225234'},
                    {'category':4,'name':'framedrop','value':'1'},
                    {'category':4,'name':'soundtouch','value':'0'},
                    {'category':1,'name':'mediacodec','value':'1'},
                    {'category':1,'name':'mediacodec-auto-rotate','value':'1'},
                    {'category':1,'name':'mediacodec-handle-resolution-change','value':'1'},
                    {'category':2,'name':'skip_loop_filter','value':'0'},
                    {'category':2,'name':'skip_frame','value':'0'},
                ]},
            ],
            'lives': [],
            'parses': [],
            'sites': [
                {
                    'key': 'alist_cloud',
                    'name': '网盘影视',
                    'type': 1,
                    'api': f'http://{host}/cloudcms.php/provide/vod',
                    'searchable': 1, 'quickSearch': 1, 'filterable': 1, 'changeable': 1,
                },
            ],
            'spider': '',
        }
        self._send_json(tvbox)

    def do_GET(self):
        self.do_request('GET')
    def do_HEAD(self):
        self.do_request('HEAD')
    def do_POST(self):
        self.do_request('POST')

    def do_request(self, method):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        path = parsed.path
        # 尾斜杠规范化：部分 TVBox 端请求 /cloudcms.php/provide/vod/ 时
        # 原实现会落入 AList 代理返回 HTML，APP 解析失败导致分类列表为空
        rpath = path.rstrip('/') or path
        host = self._get_host()

        # /tvbox.json
        if path == '/tvbox.json':
            self._send_tvbox_json()
            return

        # /cloud.json — 只含网盘影视源的精简配置
        if path == '/cloud.json':
            self._send_cloud_json()
            return

        # /stats
        if path == '/stats':
            self._send_json({
                'code': 200,
                'data': {
                    'cms_sites': _stats['cms_sites'],
                    'version': CMS_VERSION, 'cms_total': _stats['cms_total'],
                    'cloud_115': _stats['cloud_115'],
                    'cloud_quark': _stats['cloud_quark'],
                    'cloud_mounts': _stats.get('cloud_mounts', {}),
                    'search_count': _stats['search_count'],
                    'last_refresh': _stats['last_refresh'],
                    'crawl_status': _stats['crawl_status'],
                    'next_crawl': _stats['next_crawl'],
                    'crawl_interval': CFG.get('crawl_interval', 6),
                    'scrape_mode': _get_scrape_mode(),
                    'tmdb_key': bool((uci_get('mediahub.main.tmdb_key') or '').strip()),
                    'tvdb_key': bool((uci_get('mediahub.main.tvdb_key') or '').strip()),
                    'poster_extra': len(_PIC_EXTRA),
                    'pf_running': _POSTER_FILL_STATUS['running'],
                    'pf_total': _POSTER_FILL_STATUS['total'],
                    'pf_done': _POSTER_FILL_STATUS['done'],
                    'pf_scraped': _POSTER_FILL_STATUS['scraped'],
                    'pf_framed': _POSTER_FILL_STATUS['framed'],
                    'pf_started': _POSTER_FILL_STATUS['started'],
                    'thumbs': len([n for n in os.listdir(os.path.join(_PERSIST_DIR, 'thumbs'))]) if os.path.isdir(os.path.join(_PERSIST_DIR, 'thumbs')) else 0,
                    'cache': {
                        'entries': len(_m3u8_cache),
                        'bytes': _m3u8_cache_bytes,
                        'limit_mb': CACHE_LIMIT_MB,
                        'cloud_files': len(_cloud_files_cache['files']),
                        'cloud_age': int(time.time() - _cloud_files_cache['ts']) if _cloud_files_cache['ts'] else 0,
                    },
                    'logs': _logs[-60:],
                }
            })
            return



        # /sub/pg — v1.5 小雅完整订阅（PG spider jar + 79 站点 + mediahub 自有源）
        #   需 <data_dir>/pg/ 部署小雅 PG 资源；未部署自动回退精简版
        if path == '/sub/pg':
            self._send_json(self._build_sub_pg_full(host))
            return

        # /pg/* — v1.5 小雅 PG 静态资源（pg.jar/lib/js）+ tokenm.json 动态注入多网盘凭证
        if path == '/pg' or path.startswith('/pg/'):
            if self._serve_pg_static(path, host):
                return

        # /scrape — 手动刮削（未匹配海报的影片）
        #   wd=<片名> [&path=<网盘路径>]：单片刮削（TMDb→TheTVDB→豆瓣→采集站，未匹配用片源截帧兜底），同步返回
        #   ac=all：后台批量刮削所有未匹配的网盘片源，立即返回
        if path == '/scrape':
            ac = (params.get('ac', [''])[0] or '').strip().lower()
            if ac == 'all':
                threading.Thread(target=_poster_fill_worker, daemon=True).start()
                self._send_json({'code': 200, 'message': '后台批量刮削已开始（TMDb/TheTVDB/豆瓣/采集站，未匹配的用片源截帧兜底）'})
                return
            wd = (params.get('wd', [''])[0] or '').strip()
            cpath = (params.get('path', [''])[0] or '').strip()
            if not wd:
                self._send_json({'code': 400, 'message': 'missing wd'})
                return
            info = {}
            hit = _scrape_one(wd, cloud_path=cpath or None, info=info)
            if hit:
                _save_pic_index()
                pic = hit[0] if not hit[0].startswith('thumb://') else _wrap_pic(hit[0], host)
                self._send_json({'code': 200, 'pic': pic, 'year': hit[1],
                                 'matched': info.get('matched', ''), 'source': info.get('source', ''),
                                 'message': '匹配成功' + ('（片源截帧）' if hit[0].startswith('thumb://') else '')})
            else:
                self._send_json({'code': 404, 'message': '未匹配（TMDb/TheTVDB/豆瓣/采集站/截帧均无结果）'})
            return

        # /offline_download — BT 种子/磁力链接离线下载到 115 网盘
        #   POST 或 GET 参数：url=<磁力链接或BT种子URL>&dir=<115网盘子目录(可选)>
        #   转发到 AList /api/fs/add_offline_download（tool=115 Cloud）
        if path == '/offline_download':
            dl_url = (params.get('url', [''])[0] or '').strip()
            dl_dir = (params.get('dir', [''])[0] or '').strip() or '/115'
            if not dl_url:
                self._send_json({'code': 400, 'message': '缺少 url 参数（磁力链接或BT种子URL）'})
                return
            if not (dl_url.startswith('magnet:') or dl_url.startswith('http')):
                self._send_json({'code': 400, 'message': '仅支持磁力链接（magnet:?）或HTTP/HTTPS种子URL'})
                return
            try:
                token = _get_ol_admin_token()
                if not token:
                    self._send_json({'code': 500, 'message': '无法获取 AList admin token'})
                    return
                body = json.dumps({
                    'urls': [dl_url],
                    'path': dl_dir,
                    'tool': '115 Cloud',
                    'delete_policy': 'delete_on_upload_succeed'
                }).encode()
                req = urllib.request.Request(
                    f'http://127.0.0.1:{CFG["ol_port"]}/api/fs/add_offline_download',
                    data=body, method='POST',
                    headers={'Content-Type': 'application/json', 'Authorization': token})
                with urllib.request.urlopen(req, timeout=30) as resp:
                    r = json.loads(resp.read().decode('utf-8', errors='replace'))
                if r.get('code') == 200:
                    tasks = r.get('data', {}).get('tasks', [])
                    task_info = tasks[0] if tasks else {}
                    self._send_json({'code': 200,
                                     'message': f'离线下载任务已提交到 {dl_dir}（115 网盘）',
                                     'task_id': task_info.get('id', ''),
                                     'task_name': task_info.get('name', '')})
                else:
                    self._send_json({'code': 500, 'message': f'AList 返回: {r.get("message", "unknown")}'})
            except Exception as e:
                self._send_json({'code': 500, 'message': f'离线下载请求失败: {e}'})
            return

        # /picproxy — 海报图片代理（豆瓣 Referer 防盗链 / TMDb/TheTVDB 国内访问不稳）
        if path.startswith('/picproxy'):
            u = (params.get('u', [''])[0] or '').strip()
            try:
                raw = base64.b64decode(u.replace(' ', '+')).decode()
            except Exception:
                raw = ''
            if raw.startswith('http') and ('doubanio.com' in raw or 'tmdb.org' in raw or 'thetvdb.com' in raw):
                if 'doubanio.com' in raw:
                    referer = 'https://movie.douban.com/'
                elif 'tmdb.org' in raw:
                    referer = 'https://www.themoviedb.org/'
                else:
                    referer = 'https://thetvdb.com/'
                try:
                    req = urllib.request.Request(raw, headers={
                        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
                        'Referer': referer})
                    with urllib.request.urlopen(req, timeout=15) as resp:
                        body = resp.read()
                        self.send_response(200)
                        self.send_header('Content-Type', resp.headers.get('Content-Type', 'image/jpeg'))
                        self.send_header('Content-Length', str(len(body)))
                        self.send_header('Cache-Control', 'public, max-age=86400')
                        self.end_headers()
                        if method != 'HEAD':
                            self.wfile.write(body)
                except Exception as e:
                    self._send_json({'error': str(e)}, 502)
            else:
                self._send_json({'error': 'bad url'}, 403)
            return

        # /thumb/ — 片源截帧海报服务（<data_dir>/thumbs/ 下的 jpg）
        if path.startswith('/thumb/'):
            h = path[7:].split('?')[0]
            if not re.match(r'^[0-9a-f]{16}\.jpg$', h):
                self._send_json({'error': 'bad thumb'}, 403)
                return
            tf = os.path.join(_PERSIST_DIR, 'thumbs', h)
            if not os.path.exists(tf):
                self._send_json({'error': 'not found'}, 404)
                return
            try:
                with open(tf, 'rb') as f:
                    body = f.read()
                self.send_response(200)
                self.send_header('Content-Type', 'image/jpeg')
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Cache-Control', 'public, max-age=604800')
                self.end_headers()
                if method != 'HEAD':
                    self.wfile.write(body)
            except Exception as e:
                self._send_json({'error': str(e)}, 500)
            return

        # /web/ — Web 管理界面（海报墙 + 搜索 + 播放，不依赖 TVBox APP）
        if path == '/web' or path == '/web/':
            html = _WEB_UI_HTML.replace('__HOST__', host).replace('__PORT__', str(LISTEN_PORT))
            body = html.encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            if method != 'HEAD':
                self.wfile.write(body)
            return


        # /live/ — 直播源 m3u + EPG
        if path == '/live/ytv.m3u':
            body = _LIVE_YTV_M3U.encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'audio/x-mpegurl; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            if method != 'HEAD':
                self.wfile.write(body)
            return
        if path == '/live/ws.m3u':
            body = _LIVE_WS_M3U.encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'audio/x-mpegurl; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            if method != 'HEAD':
                self.wfile.write(body)
            return
        if path.startswith('/live/epg'):
            # EPG 代理：转发到公开 EPG 服务
            import urllib.request as _ur
            ch = params.get('ch', [''])[0]
            epg_url = f'https://epg.cdn.lzmr.com/ePG/api?ch={ch}&date=YESTERDAY'
            try:
                req = _ur.Request(epg_url, headers={'User-Agent': 'Mozilla/5.0'})
                with _ur.urlopen(req, timeout=10) as resp:
                    body = resp.read()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                if method != 'HEAD':
                    self.wfile.write(body)
            except Exception:
                self._send_json({'code': 0, 'msg': 'epg unavailable'})
            return

        # /cache/clear — 清空 m3u8 播放缓存（LuCI 调用）
        if path == '/cache/clear':
            n, freed = m3u8_cache_clear()
            _log(f'm3u8 cache cleared: {n} entries, {freed} bytes')
            self._send_json({'code': 200, 'cleared': n, 'freed_bytes': freed})
            return

        # /logs
        if path == '/logs':
            with _log_lock:
                self._send_json({'logs': list(_logs[-50:])})
            return

        # /cms.php/provide/vod — CMS API（兼容尾斜杠与省略 /provide/vod）
        if rpath in ('/cms.php/provide/vod', '/cms.php'):
            params = self._merge_post_params(params)
            _log('cms req: ' + (parsed.query or '-')[:150])
            ac = params.get('ac', [''])[0]
            wd = params.get('wd', [''])[0]
            pg = int(params.get('pg', ['1'])[0] or '1')
            ids = params.get('ids', [''])[0]
            t = params.get('t', [''])[0]

            if wd:
                results = cms_search(wd)
                # 改写播放地址为代理加速
                results = [_rewrite_vod_play(v, host) for v in results]
                resp = {'code': 1, 'limit': 20, 'list': results,
                        'pagecount': 1, 'total': len(results)}
                self._send_json(resp)
            elif ac == 'detail' and ids:
                resp = cms_detail(ids)
                resp['list'] = [_rewrite_vod_play(v, host) for v in resp.get('list', [])]
                self._send_json(resp)
            else:
                # 列表（支持 t 分类过滤）
                resp = cms_list(pg, t)
                resp['list'] = [_rewrite_vod_play(v, host) for v in resp.get('list', [])]
                self._send_json(resp)
            return

        # /cloudcms.php/provide/vod — 网盘 CMS 适配器（兼容尾斜杠与省略 /provide/vod）
        if rpath in ('/cloudcms.php/provide/vod', '/cloudcms.php'):
            params = self._merge_post_params(params)
            _log('cloudcms req[%s]: %s | UA=%s' % (
                self.command, (parsed.query or '-')[:200],
                (self.headers.get('User-Agent') or '')[:80]))
            body = cloud_cms_response(params, method, host)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            if method != 'HEAD':
                self.wfile.write(body)
            return



        # /cloudsearch.php/provide/vod — 网盘资源搜索 CMS 适配（TVBox type 1 兼容）
        if rpath in ('/cloudsearch.php/provide/vod', '/cloudsearch.php'):
            params = self._merge_post_params(params)
            ac = params.get('ac', [''])[0]
            wd = params.get('wd', [''])[0]
            pg = int(params.get('pg', ['1'])[0] or '1')
            if wd:
                raw = search_cloud_resources(wd, host)
                resp = {'code': 1, 'limit': 20, 'list': raw[:20],
                        'pagecount': 1, 'total': len(raw)}
            elif ac == 'detail' and params.get('ids', [''])[0]:
                # 详情：返回单个条目
                resp = {'code': 1, 'list': []}
            else:
                resp = {'code': 1, 'limit': 20, 'list': [], 'pagecount': 0, 'total': 0}
            self._send_json(resp)
            return

        # /cloudsearch — 全网网盘资源搜索（公共分享索引）
        if path == '/cloudsearch':
            kw = params.get('wd', [''])[0]
            if not kw:
                self._send_json({'code': 1, 'list': [], 'msg': 'empty query'})
                return
            results = search_cloud_resources(kw, host)
            self._send_json({'code': 1, 'list': results, 'total': len(results)})
            return

        # /_internal/cloud-refresh — 保存网盘 CK 后触发缓存强制刷新（异步，立即返回）
        if path == '/_internal/cloud-refresh':
            trigger_cloud_refresh()
            body = json.dumps({'code': 200, 'message': 'refresh triggered'})
            body = body.encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            if method != 'HEAD':
                self.wfile.write(body)
            return

        # /cmproxy/ — CMS 播放代理（缓存 m3u8 + 代理分片，加速播放）
        if path.startswith('/cmproxy/'):
            self._handle_cmproxy(method, params, path)
            return


        # ===== 115 网盘二维码 API（AList v4.2.6 无此接口，由 mediahub-cms 补充）=====
        # 前端尝试多种路径，全部拦截并统一处理
        if path in ('/api/115/qrcode', '/api/admin/115/qrcode',
                     '/api/admin/115_qrcode', '/api/auth/115_qrcode',
                     '/api/fs/115_qrcode', '/api/115/qrcode/start',
                     '/api/admin/115_qrcode/start',
                     '/api/admin/115/qrcode/start') and method == 'GET':
            self._handle_115_qrcode(path, params)
            return

        # 其余请求全部代理到 AList
        self._proxy_to_alist(method)


    def _handle_115_qrcode(self, path, params):
        """115 网盘二维码登录 API：直接调用 115 接口获取二维码/状态/Cookie"""
        import urllib.request as _ur
        UA_115 = "Mozilla/5.0 115Browser/27.0.0.0"
        try:
            if path.endswith('/start'):
                # 获取二维码 token
                req = _ur.Request(
                    'https://qrcodeapi.115.com/api/1.0/web/1.0/token',
                    headers={'User-Agent': UA_115, 'Accept': 'application/json'})
                with _ur.urlopen(req, timeout=15) as resp:
                    data = json.loads(resp.read().decode('utf-8', errors='replace'))
                if data.get('code') == 0 and data.get('data', {}).get('uid'):
                    d = data['data']
                    qr_url = 'https://qrcodeapi.115.com/api/1.0/mac/1.0/qrcode?uid=' + d['uid']
                    result = {
                        'code': 200,
                        'message': 'success',
                        'data': {
                            'uid': d['uid'],
                            'qrcode': d.get('qrcode', ''),
                            'qr_image': qr_url,
                            'sign': d.get('sign', ''),
                            'time': d.get('time', 0),
                        }
                    }
                else:
                    result = {'code': 500, 'message': '获取二维码失败: ' + json.dumps(data)}
                self._send_json(result)
                return

            # 查询二维码扫描状态
            uid = params.get('uid', [''])[0]
            sign = params.get('sign', [''])[0]
            ts = params.get('time', ['0'])[0]
            if not uid:
                self._send_json({'code': 400, 'message': '缺少 uid 参数'})
                return
            status_url = 'https://qrcodeapi.115.com/get/status/?uid=%s&time=%s&sign=%s&_=%d' % (
                uid, ts, sign, int(time.time() * 1000))
            req = _ur.Request(status_url,
                headers={'User-Agent': UA_115, 'Accept': 'application/json'})
            with _ur.urlopen(req, timeout=60) as resp:
                data = json.loads(resp.read().decode('utf-8', errors='replace'))
            status = data.get('data', {}).get('status', -1)
            result = {'code': 200, 'message': 'success', 'data': {
                'status': status,
                'msg': data.get('data', {}).get('msg', ''),
            }}
            # 如果已确认登录，获取 Cookie
            if status == 2:
                try:
                    login_url = 'https://passportapi.115.com/app/1.0/web/1.0/login/qrcode'
                    login_data = urllib.parse.urlencode({
                        'account': uid, 'app': 'web'
                    }).encode()
                    req2 = _ur.Request(login_url, data=login_data, method='POST',
                        headers={'User-Agent': UA_115,
                                 'Content-Type': 'application/x-www-form-urlencoded',
                                 'Accept': 'application/json'})
                    with _ur.urlopen(req2, timeout=15) as resp2:
                        login_resp = json.loads(resp2.read().decode('utf-8', errors='replace'))
                    if login_resp.get('data', {}).get('credential'):
                        cred = login_resp['data']['credential']
                        cookie = 'UID=%s; CID=%s; SEID=%s; KID=%s' % (
                            cred.get('UID', ''), cred.get('CID', ''),
                            cred.get('SEID', ''), cred.get('KID', ''))
                        result['data']['cookie'] = cookie
                        result['data']['status'] = 2
                        _log('115 qrcode login success, cookie obtained')
                    else:
                        result['data']['status'] = 2
                        result['data']['cookie'] = login_resp.get('data', {}).get('cookie', '')
                        _log('115 qrcode login resp: ' + json.dumps(login_resp)[:200])
                except Exception as e:
                    result['data']['status'] = 2
                    result['data']['error'] = str(e)
                    _log('115 qrcode login error: ' + str(e))
            self._send_json(result)
            return
        except Exception as e:
            _log('115 qrcode API error: ' + str(e))
            self._send_json({'code': 500, 'message': '二维码接口错误: ' + str(e)})

    def _handle_cmproxy(self, method, params, path):
        """CMS 播放代理：缓存 m3u8 + 代理分片，加速播放
        路径格式：/cmproxy/m3u8?url=<base64编码的上游URL>
                  /cmproxy/seg?url=<base64编码的分片URL>
        """
        import http.client
        url_b64 = params.get('url', [''])[0]
        if not url_b64:
            self._send_json({'error': 'missing url'}, 400)
            return
        try:
            upstream_url = base64.b64decode(url_b64).decode()
        except:
            self._send_json({'error': 'bad url'}, 400)
            return

        host = self._get_host()

        # 判断是 m3u8 还是分片
        is_m3u8 = '.m3u8' in upstream_url.lower()

        if is_m3u8 and method == 'GET':
            # m3u8 缓存（模块级，带大小上限）
            cached = m3u8_cache_get(upstream_url, ttl=60)
            if cached is not None:
                _log(f'm3u8 cache HIT {upstream_url[:40]}')
                self.send_response(200)
                self.send_header('Content-Type', 'application/vnd.apple.mpegurl')
                self.send_header('Content-Length', str(len(cached)))
                self.send_header('Cache-Control', 'public, max-age=60')
                self.end_headers()
                self.wfile.write(cached)
                return

            # 拉取上游 m3u8
            try:
                req = urllib.request.Request(upstream_url, headers={'User-Agent': UA})
                with urllib.request.urlopen(req, timeout=10) as resp:
                    raw = resp.read()
            except Exception as e:
                _log(f'm3u8 fetch error: {e}')
                self._send_json({'error': str(e)}, 502)
                return

            # 重写 m3u8 中的分片/子列表地址为代理地址
            text = raw.decode('utf-8', errors='replace')
            lines = text.split('\n')
            rewritten = []
            us = urllib.parse.urlsplit(upstream_url)
            upstream_dir = upstream_url.rsplit('/', 1)[0]
            for line in lines:
                stripped = line.strip()
                if stripped and not stripped.startswith('#') and (
                        '.ts' in stripped or '.m4s' in stripped or '.key' in stripped or '.m3u8' in stripped):
                    # 解析为绝对 URL
                    if stripped.startswith('http'):
                        full = stripped
                    elif stripped.startswith('/'):
                        # 根相对路径 → scheme://host + path
                        full = f'{us.scheme}://{us.netloc}{stripped}'
                    else:
                        # 同目录相对路径
                        full = upstream_dir + '/' + stripped
                    # 子 m3u8 走 m3u8 路由（继续重写其内部分片），分片走 seg 路由
                    route = 'm3u8' if '.m3u8' in stripped.lower() else 'seg'
                    seg_b64 = base64.b64encode(full.encode()).decode()
                    rewritten.append(f'http://{host}/cmproxy/{route}?url={seg_b64}')
                else:
                    rewritten.append(line)
            data = '\n'.join(rewritten).encode('utf-8')

            # 缓存（超限自动逐出最旧）
            m3u8_cache_put(upstream_url, data)

            _log(f'm3u8 cache MISS {upstream_url[:40]} -> {len(data)}B')
            self.send_response(200)
            self.send_header('Content-Type', 'application/vnd.apple.mpegurl')
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'public, max-age=60')
            self.end_headers()
            self.wfile.write(data)
            return

        # 代理分片（.ts/.m4s）或直接流代理
        try:
            req = urllib.request.Request(upstream_url, headers={'User-Agent': UA})
            # 透传 Range
            rng = self.headers.get('Range')
            if rng:
                req.add_header('Range', rng)
            with urllib.request.urlopen(req, timeout=30) as resp:
                self.send_response(resp.status)
                ct = resp.headers.get('Content-Type', 'video/mp2t')
                self.send_header('Content-Type', ct)
                cl = resp.headers.get('Content-Length')
                if cl:
                    self.send_header('Content-Length', cl)
                cr = resp.headers.get('Content-Range')
                if cr:
                    self.send_header('Content-Range', cr)
                self.send_header('Accept-Ranges', 'bytes')
                self.send_header('Cache-Control', 'public, max-age=600')
                self.end_headers()
                if method != 'HEAD':
                    while True:
                        chunk = resp.read(256 * 1024)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
        except Exception as e:
            _log(f'cmproxy seg error: {e}')
            self._send_json({'error': str(e)}, 502)

    def _proxy_to_alist(self, method):
        """反向代理到 AList 127.0.0.1:5244"""
        import http.client
        body = None
        if method in ('POST', 'PUT', 'PATCH'):
            cl = int(self.headers.get('Content-Length', 0))
            if cl > 0:
                body = self.rfile.read(cl)
        fwd_headers = {}
        for key in ('Content-Type', 'Authorization', 'Range', 'Accept', 'Cookie', 'If-None-Match', 'If-Modified-Since'):
            val = self.headers.get(key)
            if val:
                fwd_headers[key] = val
        fwd_headers['Host'] = f'127.0.0.1:{CFG["ol_port"]}'
        try:
            conn = http.client.HTTPConnection('127.0.0.1', CFG['ol_port'], timeout=120)
            conn.request(method, self.path, body=body, headers=fwd_headers)
            resp = conn.getresponse()
            self.send_response(resp.status)
            for key, val in resp.getheaders():
                low = key.lower()
                if low in ('transfer-encoding', 'connection', 'host'):
                    continue
                if low == 'location':
                    val = val.replace(f'127.0.0.1:{CFG["ol_port"]}', self.headers.get('Host', ''))
                self.send_header(key, val)
            self.end_headers()
            if method != 'HEAD':
                while True:
                    chunk = resp.read(256 * 1024)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
            conn.close()
        except Exception as e:
            _log(f'proxy error: {e}')
            self._send_json({'error': str(e)}, 502)

class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True

def sync_uci_mounts():
    """v1.5: 多网盘挂载自愈——按 UCI 凭证自动创建/更新 AList 挂载（幂等）
    遍历 CLOUD_DRIVE_DEFS：有凭证且未挂载 → 自动创建；凭证变化 → 自动更新。
    支持 115/夸克/UC/阿里/天翼/移动/123/百度/迅雷/PikPak 等 10 种网盘。"""
    try:
        r = ol_api('/api/admin/storage/list')
        if not r or r.get('code') != 200:
            _log('mount sync: storage list failed, skip')
            return
        mounts = {}
        for s in (r.get('data') or {}).get('content') or []:
            try:
                add = json.loads(s.get('addition') or '{}')
            except Exception:
                add = {}
            mounts[s.get('mount_path')] = {'id': s.get('id'), 'driver': s.get('driver'),
                                           'cookie': add.get('cookie', ''), 'addition': add}
        changed = 0
        for d in CLOUD_DRIVE_DEFS:
            cred = (uci_get('mediahub.main.' + d['cred']) or '').strip()
            if not cred:
                continue
            m = mounts.get(d['mount'])
            need = False
            if not m:
                need = True
            elif (m.get('driver') or '') != d['driver']:
                need = True
            elif d['kind'] == 'cookie' and m.get('cookie') != cred:
                need = True
            elif d['kind'] == 'userpass' and (m.get('addition') or {}).get('username') != cred.split(':', 1)[0]:
                need = True
            if not need:
                continue
            if d['kind'] == 'userpass':
                parts = cred.split(':', 1)
                if len(parts) != 2 or not parts[1]:
                    _log(f'mount sync: {d["key"]} 凭证格式应为 账号:密码，跳过')
                    continue
                add = d['addition'](parts[0], parts[1])
            else:
                add = d['addition'](cred)
            body = {'mount_path': d['mount'], 'driver': d['driver'],
                    'addition': json.dumps(add), 'web_proxy': d['web_proxy'],
                    'webdav_policy': d['webdav_policy'], 'cache_expiration': 30}
            if m and m.get('id'):
                body['id'] = m['id']
                rr = ol_api('/api/admin/storage/update', body)
                if rr and rr.get('code') == 200:
                    changed += 1
                    _log(f'mount sync: {d["mount"]} updated ({d["driver"]})')
                else:
                    _log(f'mount sync: {d["mount"]} update FAIL: {rr}')
            else:
                rr = ol_api('/api/admin/storage/create', body)
                if rr and rr.get('code') == 200:
                    changed += 1
                    _log(f'mount sync: {d["mount"]} created ({d["driver"]})')
                else:
                    _log(f'mount sync: {d["mount"]} create FAIL: {rr}')
        _refresh_mount_meta(force=True)
        if changed:
            trigger_cloud_refresh()
        else:
            _log('mount sync: mounts already consistent')
    except Exception as e:
        _log(f'mount sync error: {e}')


# ============================================================
# 直播源 m3u 播放列表（央视/卫视）
# ============================================================
_LIVE_YTV_M3U = """#EXTM3U
#EXTINF:-1 tvg-id="cctv1" tvg-name="CCTV1" group-title="央视",CCTV-1 综合
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226231/1.m3u8
#EXTINF:-1 tvg-id="cctv2" tvg-name="CCTV2" group-title="央视",CCTV-2 财经
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226232/1.m3u8
#EXTINF:-1 tvg-id="cctv3" tvg-name="CCTV3" group-title="央视",CCTV-3 综艺
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226233/1.m3u8
#EXTINF:-1 tvg-id="cctv4" tvg-name="CCTV4" group-title="央视",CCTV-4 中文国际
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226234/1.m3u8
#EXTINF:-1 tvg-id="cctv5" tvg-name="CCTV5" group-title="央视",CCTV-5 体育
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226235/1.m3u8
#EXTINF:-1 tvg-id="cctv6" tvg-name="CCTV6" group-title="央视",CCTV-6 电影
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226236/1.m3u8
#EXTINF:-1 tvg-id="cctv7" tvg-name="CCTV7" group-title="央视",CCTV-7 国防军事
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226237/1.m3u8
#EXTINF:-1 tvg-id="cctv8" tvg-name="CCTV8" group-title="央视",CCTV-8 电视剧
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226238/1.m3u8
#EXTINF:-1 tvg-id="cctv9" tvg-name="CCTV9" group-title="央视",CCTV-9 纪录
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226239/1.m3u8
#EXTINF:-1 tvg-id="cctv10" tvg-name="CCTV10" group-title="央视",CCTV-10 科教
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226240/1.m3u8
#EXTINF:-1 tvg-id="cctv11" tvg-name="CCTV11" group-title="央视",CCTV-11 戏曲
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226241/1.m3u8
#EXTINF:-1 tvg-id="cctv12" tvg-name="CCTV12" group-title="央视",CCTV-12 社会与法
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226242/1.m3u8
#EXTINF:-1 tvg-id="cctv13" tvg-name="CCTV13" group-title="央视",CCTV-13 新闻
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226243/1.m3u8
#EXTINF:-1 tvg-id="cctv14" tvg-name="CCTV14" group-title="央视",CCTV-14 少儿
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226244/1.m3u8
#EXTINF:-1 tvg-id="cctv15" tvg-name="CCTV15" group-title="央视",CCTV-15 音乐
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226245/1.m3u8
#EXTINF:-1 tvg-id="cctv16" tvg-name="CCTV16" group-title="央视",CCTV-16 奥林匹克
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226230/1.m3u8
#EXTINF:-1 tvg-id="cctv17" tvg-name="CCTV17" group-title="央视",CCTV-17 农业农村
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226246/1.m3u8
"""

_LIVE_WS_M3U = """#EXTM3U
#EXTINF:-1 tvg-id="hunan" tvg-name="湖南卫视" group-title="卫视",湖南卫视
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226260/1.m3u8
#EXTINF:-1 tvg-id="zhejiang" tvg-name="浙江卫视" group-title="卫视",浙江卫视
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226261/1.m3u8
#EXTINF:-1 tvg-id="dongfang" tvg-name="东方卫视" group-title="卫视",东方卫视
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226262/1.m3u8
#EXTINF:-1 tvg-id="beijing" tvg-name="北京卫视" group-title="卫视",北京卫视
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226263/1.m3u8
#EXTINF:-1 tvg-id="jiangsu" tvg-name="江苏卫视" group-title="卫视",江苏卫视
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226264/1.m3u8
#EXTINF:-1 tvg-id="anhui" tvg-name="安徽卫视" group-title="卫视",安徽卫视
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226265/1.m3u8
#EXTINF:-1 tvg-id="guangdong" tvg-name="广东卫视" group-title="卫视",广东卫视
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226266/1.m3u8
#EXTINF:-1 tvg-id="shandong" tvg-name="山东卫视" group-title="卫视",山东卫视
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226267/1.m3u8
#EXTINF:-1 tvg-id="liaoning" tvg-name="辽宁卫视" group-title="卫视",辽宁卫视
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226268/1.m3u8
#EXTINF:-1 tvg-id="hubei" tvg-name="湖北卫视" group-title="卫视",湖北卫视
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226269/1.m3u8
#EXTINF:-1 tvg-id="sichuan" tvg-name="四川卫视" group-title="卫视",四川卫视
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226270/1.m3u8
#EXTINF:-1 tvg-id="tianjin" tvg-name="天津卫视" group-title="卫视",天津卫视
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226271/1.m3u8
#EXTINF:-1 tvg-id="chongqing" tvg-name="重庆卫视" group-title="卫视",重庆卫视
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226272/1.m3u8
#EXTINF:-1 tvg-id="guizhou" tvg-name="贵州卫视" group-title="卫视",贵州卫视
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226273/1.m3u8
#EXTINF:-1 tvg-id="yunnan" tvg-name="云南卫视" group-title="卫视",云南卫视
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226274/1.m3u8
#EXTINF:-1 tvg-id="henan" tvg-name="河南卫视" group-title="卫视",河南卫视
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226275/1.m3u8
#EXTINF:-1 tvg-id="hebei" tvg-name="河北卫视" group-title="卫视",河北卫视
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226276/1.m3u8
#EXTINF:-1 tvg-id="jiangxi" tvg-name="江西卫视" group-title="卫视",江西卫视
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226277/1.m3u8
#EXTINF:-1 tvg-id="shandong2" tvg-name="深圳卫视" group-title="卫视",深圳卫视
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226278/1.m3u8
#EXTINF:-1 tvg-id=" Heilongjiang" tvg-name="黑龙江卫视" group-title="卫视",黑龙江卫视
http://dbiptv.sn.chinamobile.com/PLTV/88888890/224/3221226279/1.m3u8
"""


# ============================================================
# Phase 2: Web UI HTML (embedded SPA, no external dependencies)
# ============================================================
_WEB_UI_HTML = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>影视中心</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0f1117;color:#e1e1e1;min-height:100vh}
.header{position:sticky;top:0;z-index:100;background:rgba(15,17,23,.95);backdrop-filter:blur(10px);padding:12px 20px;display:flex;gap:12px;align-items:center;border-bottom:1px solid #1e2128}
.header h1{font-size:18px;white-space:nowrap}
.search-box{flex:1;display:flex;gap:8px}
.search-box input{flex:1;padding:8px 14px;border:1px solid #2a2d35;border-radius:8px;background:#16181d;color:#e1e1e1;font-size:14px;outline:none}
.search-box input:focus{border-color:#4a90d9}
.search-box button{padding:8px 18px;border:none;border-radius:8px;background:#4a90d9;color:#fff;cursor:pointer;font-size:14px;white-space:nowrap}
.search-box button:hover{background:#357abd}
.tabs{display:flex;gap:4px}
.tab{padding:6px 14px;border-radius:6px;cursor:pointer;font-size:13px;color:#8a8a8a;transition:.2s}
.tab.active{background:#4a90d9;color:#fff}
.tab:hover:not(.active){background:#1e2128;color:#ccc}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:14px;padding:16px 20px}
.card{background:#16181d;border-radius:10px;overflow:hidden;cursor:pointer;transition:.2s;border:1px solid #1e2128;position:relative}
.card:hover{transform:translateY(-2px);border-color:#4a90d9;box-shadow:0 4px 12px rgba(74,144,217,.15)}
.card img{width:100%;aspect-ratio:2/3;object-fit:cover;background:#1a1c22}
.scrape-btn{position:absolute;top:8px;right:8px;padding:3px 10px;background:rgba(74,144,217,.92);color:#fff;border-radius:12px;font-size:11px;cursor:pointer;user-select:none;box-shadow:0 2px 6px rgba(0,0,0,.4)}
.scrape-btn:hover{background:#357abd}
.scrape-btn.busy{background:#555;cursor:wait}
.card-body{padding:8px 10px}
.card-title{font-size:12px;line-height:1.4;height:34px;overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}
.card-tag{font-size:11px;color:#5a8db5;margin-top:3px}
.empty{text-align:center;padding:60px;color:#555;font-size:14px}
.loading{text-align:center;padding:40px;color:#555}
.player-overlay{position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.9);z-index:999;display:flex;flex-direction:column;align-items:center;justify-content:center}
.player-overlay video{max-width:90%;max-height:80%;border-radius:8px}
.player-close{position:fixed;top:16px;right:20px;font-size:24px;color:#fff;cursor:pointer;z-index:1001;background:#333;border-radius:50%;width:36px;height:36px;display:flex;align-items:center;justify-content:center}
.routes{background:#16181d;border-radius:8px;padding:12px;margin:10px 20px;display:flex;gap:8px;flex-wrap:wrap}
.route-btn{padding:6px 14px;border:1px solid #2a2d35;border-radius:6px;background:#1a1c22;color:#ccc;cursor:pointer;font-size:13px}
.route-btn.active{border-color:#4a90d9;background:#4a90d9;color:#fff}
.detail{padding:16px 20px;display:none}
.detail-back{color:#4a90d9;cursor:pointer;font-size:14px;margin-bottom:12px}
.detail-content{display:flex;gap:16px}
.detail-pic{width:120px;aspect-ratio:2/3;border-radius:8px;object-fit:cover}
.detail-info{flex:1}
.detail-title{font-size:18px;margin-bottom:8px}
.detail-desc{font-size:13px;color:#888;line-height:1.6}
.play-list{margin-top:12px;display:flex;flex-wrap:wrap;gap:6px}
.play-item{padding:5px 12px;border:1px solid #2a2d35;border-radius:6px;cursor:pointer;font-size:12px;color:#ccc}
.play-item:hover{border-color:#4a90d9}
.play-item.active{background:#4a90d9;color:#fff;border-color:#4a90d9}
@media(max-width:600px){.grid{grid-template-columns:repeat(auto-fill,minmax(110px,1fr));gap:10px;padding:10px}.header{padding:8px 12px}.search-box input{font-size:13px}}
</style>
</head>
<body>
<div class="header">
<h1>🎬 影视中心</h1>
<div class="search-box">
<input id="wd" placeholder="搜索影片..." onkeydown="if(event.key==='Enter')doSearch()">
<button onclick="doSearch()">搜索</button>
</div>
<div class="tabs">
<span class="tab active" onclick="listTab()">首页</span>
<span class="tab" onclick="cloudTab()">网盘</span>
</div>
<button id="scrape-all" style="display:none;padding:6px 14px;border:1px solid #2a2d35;border-radius:6px;background:#1a1c22;color:#ccc;cursor:pointer;font-size:13px;white-space:nowrap" onclick="scrapeAll()">刮削未匹配</button>
</div>
<div class="loading" id="loading">加载中...</div>
<div class="grid" id="grid" style="display:none"></div>
<div class="detail" id="detail">
<div class="detail-back" onclick="backToList()">← 返回</div>
<div class="detail-content" id="detailContent"></div>
</div>
<div class="player-overlay" id="player" style="display:none">
<div class="player-close" onclick="closePlayer()">✕</div>
<video id="video" controls autoplay></video>
</div>
<script>
const API='http://__HOST__:__PORT__';
let curTab='cms',curWd='';
async function api(path){const r=await fetch(API+path);return r.json()}
async function init(){
try{const d=await api('/cms.php/provide/vod?ac=list&pg=1');renderGrid(d.list||[])}catch(e){document.getElementById('loading').textContent='加载失败'}
}
async function doSearch(){
const wd=document.getElementById('wd').value.trim();if(!wd)return;curWd=wd;
document.getElementById('loading').style.display='block';document.getElementById('grid').style.display='none';
try{
if(curTab==='cms'){const d=await api('/cms.php/provide/vod?wd='+encodeURIComponent(wd));renderGrid(d.list||[])}
else{const d=await api('/cloudcms.php/provide/vod?wd='+encodeURIComponent(wd));renderGrid(d.list||[])}
}catch(e){document.getElementById('loading').textContent='搜索失败'}
}
function listTab(){curTab='cms';document.querySelectorAll('.tab').forEach(t=>t.classList.remove('active'));event.target.classList.add('active');document.getElementById('scrape-all').style.display='none';init()}
function cloudTab(){curTab='cloud';document.querySelectorAll('.tab').forEach(t=>t.classList.remove('active'));event.target.classList.add('active');document.getElementById('scrape-all').style.display='block';
document.getElementById('loading').style.display='block';document.getElementById('grid').style.display='none';
api('/cloudcms.php/provide/vod?ac=list&pg=1').then(d=>renderGrid(d.list||[])).catch(()=>document.getElementById('loading').textContent='加载失败')}
function renderGrid(list){
document.getElementById('loading').style.display='none';const g=document.getElementById('grid');g.style.display='grid';g.innerHTML='';
if(!list.length){g.innerHTML='<div class="empty">暂无结果</div>';return}
list.forEach(v=>{
const pic=v.vod_pic||'';const name=v.vod_name||'';const tag=v.vod_remarks||'';
const c=document.createElement('div');c.className='card';
const scrapeHtml=pic?'':`<div class="scrape-btn" onclick="event.stopPropagation();doScrape(this,'${encodeURIComponent(name)}','${encodeURIComponent(v.vod_cloud_path||'')}')">刮削</div>`;
c.innerHTML=`<img src="${pic||'data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg viewBox=%220 0 2 3%22><rect width=%222%22 height=%223%22 fill=%22%231a1c22%22/></svg>'}" loading="lazy" onerror="this.style.opacity=0.3">${scrapeHtml}<div class="card-body"><div class="card-title">${name}</div>${tag?'<div class="card-tag">'+tag+'</div>':''}</div>`;
c.onclick=()=>showDetail(v);g.appendChild(c)})}
async function doScrape(btn,encName,encPath){
if(!encName)return;btn.classList.add('busy');btn.textContent='刮削中';
try{
const r=await fetch(API+'/scrape?wd='+encName+(encPath?'&path='+encPath:'')).then(r=>r.json());
if(r.code===200&&r.pic){
const card=btn.closest('.card');const img=card&&card.querySelector('img');
if(img){img.src=r.pic;img.style.opacity=1;img.onerror=()=>{img.style.opacity=0.3}}
if(card&&r.matched)card.title='海报来源：'+(r.source||'')+' · 匹配：'+r.matched;
btn.remove();
}else{btn.textContent='未匹配';setTimeout(()=>btn.remove(),1500)}
}catch(e){btn.classList.remove('busy');btn.textContent='重试'}
}
function scrapeAll(){
if(!confirm('对网盘中尚未匹配海报的影片批量刮削？\n（按当前匹配模式：TMDb/TheTVDB/豆瓣/采集站，未匹配的用片源截帧兜底；后台进行，已匹配的不受影响）'))return;
fetch(API+'/scrape?ac=all').then(r=>r.json()).then(d=>{alert(d.message||'已开始')}).catch(()=>alert('请求失败'))
}
async function showDetail(v){
document.getElementById('grid').style.display='none';document.getElementById('detail').style.display='block';
const id=v.vod_id||'';let detail=v;
if(id){try{const d=curTab==='cms'?await api('/cms.php/provide/vod?ac=detail&ids='+id):await api('/cloudcms.php/provide/vod?ac=detail&ids='+id);if(d.list&&d.list[0])detail=d.list[0]}catch(e){}}
renderDetail(detail)}
function renderDetail(v){
const c=document.getElementById('detailContent');
c.innerHTML=`<img class="detail-pic" src="${v.vod_pic||''}" onerror="this.style.opacity=0.2"><div class="detail-info"><div class="detail-title">${v.vod_name||''}</div><div class="detail-desc">${v.vod_remarks||''} · ${(v.vod_year||'')}</div><div class="detail-desc">${(v.vod_content||v.vod_blurb||'').substring(0,200)}</div></div>`;
const playUrl=v.vod_play_url||'';if(playUrl){const groups=playUrl.split('$$$');let allItems=[];
groups.forEach(g=>{const items=g.split('#');items.forEach((it,idx)=>{const parts=it.split('$');if(parts.length>=2)allItems.push({name:parts[0],url:parts[1]})})});
if(allItems.length){const pl=document.createElement('div');pl.className='play-list';
allItems.forEach((it,idx)=>{const e=document.createElement('div');e.className='play-item';e.textContent=it.name;e.onclick=()=>{document.querySelectorAll('.play-item').forEach(p=>p.classList.remove('active'));e.classList.add('active');play(it.url)};pl.appendChild(e)});c.querySelector('.detail-info').appendChild(pl)}}}
function play(url){
if(!url)return;
const v=document.getElementById('video');
if(url.includes('.m3u8')||url.includes('cmproxy')){v.src=url;document.getElementById('player').style.display='flex'}
else{window.open(url,'_blank')}}
function closePlayer(){document.getElementById('player').style.display='none';document.getElementById('video').src='';document.getElementById('video').pause()}
function backToList(){document.getElementById('detail').style.display='none';document.getElementById('grid').style.display='grid'}
init()
</script>
</body></html>"""

# ============================================================
# Phase 3: Cloud resource search function
# ============================================================
_CLOUD_SEARCH_CACHE = {}
_CLOUD_SEARCH_CACHE_TTL = 600

def search_cloud_resources(kw, host):
    """搜索全网网盘公共分享资源（聚合多个资源站索引）
    目前支持：115 网盘分享搜索 + 夸克资源站搜索
    返回 CMS 格式结果，播放链接指向 AList /d/ 或 /p/ 直链。"""
    now = time.time()
    if kw in _CLOUD_SEARCH_CACHE:
        ts, cached = _CLOUD_SEARCH_CACHE[kw]
        if now - ts < _CLOUD_SEARCH_CACHE_TTL:
            return cached

    results = []

    # 1. 搜索自己网盘已有的文件（cloudcms 数据源）
    try:
        cloud_files = get_cloud_files()
        kw_lower = kw.lower()
        for f in cloud_files:
            if kw_lower in f.get('name', '').lower():
                fname = f['name']
                sign = f.get('sign') or get_sign(f['path'])
                encoded_path = urllib.parse.quote(f['path'], safe='/')
                route = _mount_route(f['path'])   # v1.5: 多网盘动态路由
                play_port = CFG.get('play_port', 5244)
                play_url = f'http://{_host_only(host)}:{play_port}/{route}{encoded_path}'
                if sign:
                    play_url += f'?sign={sign}'
                size_str = f'{f.get("size", 0) / 1073741824:.1f}GB' if f.get('size') else ''
                _name = fname.rsplit('.', 1)[0] if '.' in fname else fname
                _hit = _pic_lookup(_name) or _pic_lookup(f.get('dir', ''))
                results.append({
                    'vod_name': _name,
                    'vod_id': base64.b64encode(f['path'].encode()).decode(),
                    'vod_pic': _wrap_pic(_hit[0], host) if _hit else '',
                    'vod_play_from': 'alist',
                    'vod_play_url': f'播放${play_url}',
                    'vod_remarks': f'网盘·{size_str}',
                    'vod_year': _hit[1] if _hit else '',
                })
    except Exception as e:
        _log(f'cloudsearch local error: {e}')

    # 2. 搜索 115 网盘公开分享（通过 115 搜索 API）
    try:
        c115 = uci_get('mediahub.main.cookie_115')
        if c115:
            search_url = 'https://proapi.115.com/android/2.0/search/search'
            headers = {'User-Agent': 'Mozilla/5.0', 'Cookie': c115}
            data = urllib.parse.urlencode({'search_value': kw, 'type': 0, 'page': 1, 'count': 20}).encode()
            req = urllib.request.Request(search_url, data=data, headers=headers, method='POST')
            with urllib.request.urlopen(req, timeout=10) as resp:
                sd = json.loads(resp.read().decode('utf-8', errors='replace'))
            if sd.get('data') and sd['data'].get('list'):
                for item in sd['data']['list'][:20]:
                    _n115 = item.get('file_name', item.get('n', 'unknown'))
                    _hit115 = _pic_lookup(_n115)
                    results.append({
                        'vod_name': _n115,
                        'vod_id': str(item.get('fid', '')),
                        'vod_pic': _wrap_pic(_hit115[0], host) if _hit115 else '',
                        'vod_play_from': '115share',
                        'vod_play_url': f'转存${item.get("share_url", item.get("pc", ""))}',
                        'vod_remarks': f'115分享·{item.get("s", 0)/1073741824:.1f}GB' if item.get('s') else '115分享',
                        'vod_year': _hit115[1] if _hit115 else '',
                    })
    except Exception as e:
        _log(f'cloudsearch 115 error: {e}')

    _CLOUD_SEARCH_CACHE[kw] = (now, results)
    _log(f'cloudsearch "{kw}" -> {len(results)} results')
    return results



def main():
    _log(f'mediahub-cms v2 starting on 0.0.0.0:{LISTEN_PORT}')
    _log(f'CMS sites: {len(CFG["sites"])}, parallel: {PARALLEL}, max_pages: {MAX_PAGES}')
    _log(f'AList port: {CFG["ol_port"]}, ext_domain: {CFG.get("ext_domain", "auto")}')

    # 启动时从磁盘加载持久化缓存（命中则跳过首次爬取，后台增量更新）
    _load_search_cache_from_disk()
    disk_loaded = _load_vods_from_disk()
    _load_pic_index()   # 刮削结果（豆瓣/远端补全），独立持久化，重启不丢

    # 启动挂载自愈线程（延迟 8 秒等 AList 就绪；UCI cookie 与挂载不一致时自动同步）
    def _mount_heal():
        time.sleep(8)
        for attempt in range(3):
            token = _get_ol_admin_token()
            if token:
                sync_uci_mounts()
                return
            _log(f'mount heal: AList not ready, retry {attempt + 1}/3')
            time.sleep(10)
    threading.Thread(target=_mount_heal, daemon=True).start()

    # 启动时立即刷新网盘文件计数（不等爬取延迟，确保状态页启动即显示正确数量）
    def _cloud_count_init():
        time.sleep(12)
        files = []
        # v2.8.1: 扫描返回 0 时重试（最多 3 次，间隔 60s）——
        # 启动初期挂载自愈可能正在重载存储，首个扫描窗口可能撞上瞬时故障
        for attempt in range(3):
            try:
                files = get_cloud_files(force=True)
                if files:
                    break
                _log(f'cloud boot scan #{attempt + 1} got 0 files, will retry in 60s')
            except Exception as e:
                _log(f'cloud count init error: {e}')
            time.sleep(60)
        _update_cloud_stats(files)
        _log(f'cloud counts on boot: {json.dumps(_stats.get("cloud_mounts", {}), ensure_ascii=False)} total={len(files)}')
    threading.Thread(target=_cloud_count_init, daemon=True).start()

    # 启动全量爬取线程（磁盘有缓存则延后 30 分钟再增量爬取，避免重启就重爬）
    crawl_t = threading.Thread(target=crawl_loop, daemon=True, kwargs={'skip_if_disk': disk_loaded})
    crawl_t.start()

    # 启动海报补全线程（延迟 90 秒等挂载同步；本地索引 miss 的网盘文件去远端站点搜索）
    threading.Thread(target=_poster_fill_worker, daemon=True).start()

    # SIGTERM 优雅退出：procd stop/restart 发 SIGTERM，默认直接杀进程会丢
    # 内存中未到保存点的刮削结果；注册 handler 先保存 poster_extra 再退出
    def _graceful_shutdown(signum, frame):
        _log(f'shutdown: signal {signum}, saving poster index...')
        try:
            _save_pic_index()
        except Exception as se:
            _log(f'shutdown save error: {se}')
        try:
            _save_search_cache_to_disk()
        except Exception:
            pass
        sys.exit(0)
    signal.signal(signal.SIGTERM, _graceful_shutdown)

    # v1.5.1: 第二监听端口（uci mediahub.main.port2）——公网运营商端口限速场景换端口用；留空不启用
    _port2 = uci_get('mediahub.main.port2', '')
    if _port2.isdigit() and int(_port2) > 0 and int(_port2) != LISTEN_PORT:
        try:
            _s2 = ThreadingHTTPServer(('0.0.0.0', int(_port2)), CMSHandler)
            threading.Thread(target=_s2.serve_forever, daemon=True).start()
            _log(f'extra listen on 0.0.0.0:{_port2}')
        except Exception as e:
            _log(f'port2 {_port2} listen failed: {e}')

    server = ThreadingHTTPServer(('0.0.0.0', LISTEN_PORT), CMSHandler)
    server.serve_forever()

if __name__ == '__main__':
    main()
