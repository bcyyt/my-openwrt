-- mediahub.lua — 影视中心 LuCI 控制器 v2（不依赖 moviebox）
module("luci.controller.mediahub", package.seeall)

local function esc(s)
    return (s or ""):gsub("'", "'\\''")
end

local function sys_exec(cmd)
    local sys = require "luci.sys"
    return (sys.exec(cmd) or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("\n", "")
end

-- 通知 mediahub-cms 强制刷新网盘文件缓存（保存 CK 后调用，避免空缓存锁定 30 分钟）
local function trigger_cloud_refresh()
    local sys = require "luci.sys"
    sys.exec('curl -s -m 3 http://127.0.0.1:8901/_internal/cloud-refresh >/dev/null 2>&1')
end

-- 内网 IP（LuCI 页面所有显示地址统一用内网地址）
local function lan_ip()
    local ip = sys_exec("uci -q get network.lan.ipaddr 2>/dev/null")
    ip = ip:gsub("/%d+$", "")  -- 剥 CIDR 后缀（ImmortalWrt 返回 192.168.10.1/24）
    if ip == "" then
        local http = require "luci.http"
        ip = (http.getenv("HTTP_HOST") or ""):match("^([^:]+)") or ""
        ip = ip:gsub("/%d+$", "")
    end
    if ip == "" then ip = "192.168.10.1" end
    return ip
end

-- 影视中心版本号（从 mediahub-cms.py 头部取，供页面徽章显示）
local function mh_ver()
    local v = sys_exec("head -3 /usr/bin/mediahub-cms.py 2>/dev/null | grep -oE 'v[0-9]+\\.[0-9]+' | head -1")
    if v == "" then v = "v2.6" end
    return v
end

function index()
    if not require("nixio.fs").access("/usr/bin/alist") then return end
    local e = entry({"admin", "services", "mediahub"}, firstchild(), _("影视中心"), 20)
    e.dependent = false
    entry({"admin", "services", "mediahub", "status"}, template("mediahub/status"), _("运行状态"), 10)
    entry({"admin", "services", "mediahub", "cookies"}, template("mediahub/cookies"), _("网盘登录"), 20)
    entry({"admin", "services", "mediahub", "cms"}, template("mediahub/cms"), _("CMS配置"), 25)
    entry({"admin", "services", "mediahub", "tvbox"}, template("mediahub/tvbox"), _("TVBox配置"), 30)
    entry({"admin", "services", "mediahub", "api"}, call("api_handler")).leaf = true
    -- 公开端点：tvbox.json（APP 直接拉取，无需登录）
    entry({"mediahub", "tvbox.json"}, call("serve_tvbox_json")).leaf = true
end

function api_handler()
    local http = require "luci.http"
    local action = http.formvalue("action") or ""
    local actions = {
        get_status = get_status, get_cookies = get_cookies, save_cookies = save_cookies,
        qr_115_start = qr_115_start, qr_115_poll = qr_115_poll,
        qr_quark_start = qr_quark_start, qr_quark_poll = qr_quark_poll,
        qr_uc_start = qr_uc_start, qr_uc_poll = qr_uc_poll,
        update_alist = update_alist, restart_services = restart_services,
        get_ol_mirror = get_ol_mirror, save_ol_mirror = save_ol_mirror,
        get_cms_sites = get_cms_sites, add_cms_site = add_cms_site, delete_cms_site = delete_cms_site,
        toggle_cms_site = toggle_cms_site,
        speedtest_cms_sites = speedtest_cms_sites,
        get_cache = get_cache, set_cache = set_cache, clear_cache = clear_cache,
        get_crawl_schedule = get_crawl_schedule, set_crawl_schedule = set_crawl_schedule,
        get_scrape_config = get_scrape_config, set_scrape_config = set_scrape_config,
        reset_scrape = reset_scrape,
        add_offline_download = add_offline_download,
        get_offline_tasks = get_offline_tasks,
        get_logs = get_logs,
    }
    local fn = actions[action]
    if fn then fn() else
        http.prepare_content("application/json")
        http.write_json({code = 400, message = "unknown action"})
    end
end

-- ============================================================
-- AList API 辅助
-- ============================================================
local function ol_token()
    local sys = require "luci.sys"
    local pw = sys_exec("uci -q get mediahub.main.alist_pw 2>/dev/null || uci -q get mediahub.main.alist_pw 2>/dev/null")
    if pw == "" then return "" end
    local r = sys.exec('curl -s -m 10 http://127.0.0.1:5244/api/auth/login -X POST -H "Content-Type: application/json" -d \'{"username":"admin","password":"' .. esc(pw) .. '"}\' 2>/dev/null') or ""
    return r:match('"token":"([^"]+)"') or ""
end

local function ol_update_storage(token, mount, driver, addition_json, web_proxy)
    local sys = require "luci.sys"
    local sl = sys.exec('curl -s -m 10 http://127.0.0.1:5244/api/admin/storage/list -H "Authorization: ' .. token .. '" 2>/dev/null') or ""
    -- 从 list 中找 mount_path 对应的 id
    local sid = ""
    for id, mp in sl:gmatch('"id":(%d+)[^}]-"mount_path":"([^"]*)"') do
        if mp == mount then sid = id; break end
    end
    if sid == "" then
        -- 存储不存在，创建（addition 必须是 JSON 字符串，不能是嵌套对象）
        local add_str = addition_json:gsub('"', '\\"')
        local body = '{"mount_path":"' .. mount .. '","driver":"' .. driver .. '","addition":"' .. add_str .. '","web_proxy":' .. (web_proxy and "true" or "false") .. ',"webdav_policy":"' .. (web_proxy and "use_proxy_url" or "302_redirect") .. '","cache_expiration":30}'
        sys.exec('curl -s -m 15 http://127.0.0.1:5244/api/admin/storage/create -X POST -H "Content-Type: application/json" -H "Authorization: ' .. token .. '" -d \'' .. body .. '\' 2>/dev/null')
    else
        -- 更新（addition 必须是 JSON 字符串）
        local add_str = addition_json:gsub('"', '\\"')
        local body = '{"id":' .. sid .. ',"mount_path":"' .. mount .. '","driver":"' .. driver .. '","addition":"' .. add_str .. '","web_proxy":' .. (web_proxy and "true" or "false") .. ',"webdav_policy":"' .. (web_proxy and "use_proxy_url" or "302_redirect") .. '","cache_expiration":30}'
        sys.exec('curl -s -m 15 http://127.0.0.1:5244/api/admin/storage/update -X POST -H "Content-Type: application/json" -H "Authorization: ' .. token .. '" -d \'' .. body .. '\' 2>/dev/null')
    end
end

-- ============================================================
-- 状态
-- ============================================================
function get_status()
    local http = require "luci.http"
    local sys = require "luci.sys"

    local ol_pid = sys.exec("pidof alist 2>/dev/null") or ""
    local ol_ver = sys_exec("/usr/bin/alist version 2>/dev/null | grep -m1 '^Version:' | awk '{print $2}'")
    local ol_port = sys.exec("netstat -tln 2>/dev/null | grep 5244") ~= "" and true or false

    local ol_115, ol_quark = "unknown", "unknown"
    -- 登录 AList 获取 token（全新安装 guest 无权限，必须用 admin token 查询）
    local ol_auth = ol_token()
    local auth_hdr = ""
    if ol_auth ~= "" then auth_hdr = ' -H "Authorization: ' .. ol_auth .. '"' end
    local ol_r = sys.exec('curl -s -m 5 http://127.0.0.1:5244/api/fs/list -X POST -H "Content-Type: application/json"' .. auth_hdr .. ' -d \'{"path":"/115","page":1,"per_page":1}\' 2>/dev/null') or ""
    if ol_r:match('"code":200') then ol_115 = "ok" elseif ol_r:match('"code"') then ol_115 = "error" end
    local ol_q = sys.exec('curl -s -m 5 http://127.0.0.1:5244/api/fs/list -X POST -H "Content-Type: application/json"' .. auth_hdr .. ' -d \'{"path":"/quark","page":1,"per_page":1}\' 2>/dev/null') or ""
    if ol_q:match('"code":200') then ol_quark = "ok" elseif ol_q:match('"code"') then ol_quark = "error" end

    local host = (http.getenv("HTTP_HOST") or ""):match("^([^:]+)") or ""
    local token = sys_exec("uci -q get mediahub.main.token 2>/dev/null")
    if token == "" then token = "mb-c077d20e07e28c60" end  -- fallback

    local cms_pid = sys.exec("pgrep -f mediahub-cms 2>/dev/null") or ""
    local cms_port = sys.exec("netstat -tln 2>/dev/null | grep 8901") ~= "" and true or false
    -- CMS 统计数据
    local cms_stats = sys.exec('curl -s -m 5 http://127.0.0.1:8901/stats 2>/dev/null') or ""
    local cms_total = tonumber(cms_stats:match('"cms_total"%s*:%s*(%d+)') or "0")
    local cms_sites = tonumber(cms_stats:match('"cms_sites"%s*:%s*(%d+)') or "0")
    local cms_ver = cms_stats:match('"version"%s*:%s*"([^"]*)"') or ""
    local cms_searches = tonumber(cms_stats:match('"search_count"%s*:%s*(%d+)') or "0")
    local cms_last = tonumber(cms_stats:match('"last_refresh"%s*:%s*(%d+)') or "0")
    local cloud_115 = tonumber(cms_stats:match('"cloud_115"%s*:%s*(%d+)') or "0")
    local cloud_quark = tonumber(cms_stats:match('"cloud_quark"%s*:%s*(%d+)') or "0")
    local crawl_status = cms_stats:match('"crawl_status"%s*:%s*"([^"]*)"') or "idle"
    local last_refresh = tonumber(cms_stats:match('"last_refresh"%s*:%s*(%d+)') or "0")
    -- 下次爬取时间（epoch，0=无计划/已关闭）；实时从 CMS 读，重启后重新计算
    local next_crawl = tonumber(cms_stats:match('"next_crawl"%s*:%s*(%d+)') or "0")
    local crawl_interval = tonumber(cms_stats:match('"crawl_interval"%s*:%s*(%-?%d+)') or "6")
    -- 兑底：CMS 无响应时从 UCI 推算（上次刷新 + 间隔）
    if next_crawl == 0 and crawl_interval > 0 and last_refresh > 0 then
        next_crawl = last_refresh + crawl_interval * 3600
    end

    -- TVBox URL / 网页入口：统一用内网地址
    local lip = lan_ip()
    local tvbox_url = "http://" .. lip .. ":8901/tvbox.json"
    local web_url = "http://" .. lip .. ":5244/"

    -- 播放缓存统计
    local cache_entries = tonumber(cms_stats:match('"entries"%s*:%s*(%d+)') or "0")
    local cache_bytes = tonumber(cms_stats:match('"bytes"%s*:%s*(%d+)') or "0")
    local cache_limit = tonumber(cms_stats:match('"limit_mb"%s*:%s*(%d+)') or "0")
    local cloud_files = tonumber(cms_stats:match('"cloud_files"%s*:%s*(%d+)') or "0")

    -- 海报刮削进度（LuCI 状态页显示）
    local pf_running = cms_stats:match('"pf_running"%s*:%s*true') ~= nil
    local pf_total = tonumber(cms_stats:match('"pf_total"%s*:%s*(%d+)') or "0")
    local pf_done = tonumber(cms_stats:match('"pf_done"%s*:%s*(%d+)') or "0")
    local pf_scraped = tonumber(cms_stats:match('"pf_scraped"%s*:%s*(%d+)') or "0")
    local pf_framed = tonumber(cms_stats:match('"pf_framed"%s*:%s*(%d+)') or "0")
    local pf_started = tonumber(cms_stats:match('"pf_started"%s*:%s*(%d+)') or "0")
    local scrape_mode = cms_stats:match('"scrape_mode"%s*:%s*"([^"]*)"') or "balanced"
    local poster_extra = tonumber(cms_stats:match('"poster_extra"%s*:%s*(%d+)') or "0")
    local thumbs_n = tonumber(cms_stats:match('"thumbs"%s*:%s*(%d+)') or "0")
    local tmdb_set = cms_stats:match('"tmdb_key"%s*:%s*true') ~= nil
    local tvdb_set = cms_stats:match('"tvdb_key"%s*:%s*true') ~= nil

    local data_dir = sys_exec("uci -q get mediahub.main.data_dir 2>/dev/null")
    if data_dir == "" then data_dir = "/mnt/data/alist" end
    local disk = sys.exec("df -h '" .. data_dir .. "' 2>/dev/null | tail -1 | awk '{print $2\" / \"$3\" used \"$5}'") or ""

    -- APP 直连网盘地址（游客免密只读）
    local ol_web_url = "http://" .. lip .. ":5244/"
    local ol_dav_url = "http://" .. lip .. ":5244/dav/"
    local ol_dav_auth = "guest / guest"

    http.prepare_content("application/json")
    http.write_json({
        alist = {running = ol_pid ~= "", version = ol_ver, port = ol_port, c115 = ol_115, cquark = ol_quark},
        cms = {running = cms_pid ~= "", port = cms_port, version = cms_ver, total = cms_total, sites = cms_sites, searches = cms_searches, last_refresh = cms_last, crawl_status = crawl_status, next_crawl = next_crawl, crawl_interval = crawl_interval},
        cloud = {c115 = cloud_115, cquark = cloud_quark},
        cache = {entries = cache_entries, bytes = cache_bytes, limit_mb = cache_limit, cloud_files = cloud_files},
        poster = {running = pf_running, total = pf_total, done = pf_done, scraped = pf_scraped,
                  framed = pf_framed, started = pf_started, mode = scrape_mode,
                  extra = poster_extra, thumbs = thumbs_n, tmdb = tmdb_set, tvdb = tvdb_set},
        tvbox_url = tvbox_url, web_url = web_url,
        ol_web_url = ol_web_url, ol_dav_url = ol_dav_url, ol_dav_auth = ol_dav_auth,
        disk = disk, data_dir = data_dir,
        ver = mh_ver(), lan_ip = lip
    })
end

-- 运行日志（透传 mediahub-cms 的 /logs）
function get_logs()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local r = sys.exec("curl -s -m 6 http://127.0.0.1:8901/logs 2>/dev/null") or ""
    http.prepare_content("application/json")
    if r:match("^%s*{") then
        http.write(r)
    else
        http.write_json({logs = {}})
    end
end

-- ============================================================
-- tvbox.json 公开端点（APP 直接拉取，无需登录 LuCI）
-- ============================================================
function serve_tvbox_json()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local host = (http.getenv("HTTP_HOST") or ""):match("^([^:]+)") or ""
    if host == "" then host = lan_ip() end
    -- 与 mediahub-cms.py 8901/tvbox.json 同构：CMS聚合 + 网盘两个站点
    local json_str = [[{"ads":[],"flags":["youku","qq","iqiyi","qiyi","letv","sohu","tudou","pptv","mgtv","wasu"],"lives":[],"parses":[],"sites":[{"key":"cms_aggregate","name":"CMS聚合影院","type":1,"api":"http://HOST:8901/cms.php/provide/vod","searchable":1,"quickSearch":1,"filterable":1,"changeable":1},{"key":"alist_cloud","name":"网盘影视","type":1,"api":"http://HOST:8901/cloudcms.php/provide/vod","searchable":1,"quickSearch":1,"filterable":1,"changeable":1}],"spider":""}]]
    json_str = json_str:gsub("HOST", host)
    http.prepare_content("application/json")
    http.write(json_str)
end

-- ============================================================
-- Cookie 管理
-- ============================================================
-- ============================================================
-- v1.5: 多网盘挂载定义（与 mediahub-cms CLOUD_DRIVE_DEFS 一致）
-- ============================================================
-- kind: cookie=单凭证 | token=单token | userpass=账号:密码（uci 值格式 "user:pass"）
local CLOUD_MOUNT_DEFS = {
    {key="uc",      mount="/uc",      driver="UC",              uci="cookie_uc",    kind="cookie",   web_proxy=true,
     tmpl='{"cookie":"{V}","root_folder_id":"0","use_transcoding_address":false,"only_list_video_file":false}'},
    {key="aliyun",  mount="/aliyun",  driver="AliyundriveOpen", uci="token_ali",    kind="token",    web_proxy=false,
     tmpl='{"refresh_token":"{V}","root_folder_id":"root","order_by":"name","order_direction":"asc"}'},
    {key="189",     mount="/189",     driver="189CloudPC",      uci="token_189",   kind="userpass", web_proxy=false,
     tmpl='{"username":"{U}","password":"{P}","validate_code":"","family_transfer_mode":false}'},
    {key="yidong",  mount="/yidong",  driver="139Yun",    uci="token_yidong", kind="token",   web_proxy=false,
     tmpl='{"authorization":"{V}"}'},
    {key="123",     mount="/123",     driver="123Pan",          uci="token_123",   kind="userpass", web_proxy=false,
     tmpl='{"username":"{U}","password":"{P}","root_folder":"/"}'},
    {key="baidu",   mount="/baidu",   driver="BaiduNetdisk",    uci="token_baidu", kind="token",    web_proxy=true,
     tmpl='{"refresh_token":"{V}","root_folder_id":"/"}'},
    {key="thunder", mount="/thunder", driver="Thunder",         uci="thunder_auth", kind="userpass", web_proxy=false,
     tmpl='{"username":"{U}","password":"{P}","root_folder_id":"","user_agent":""}'},
    {key="pikpak",  mount="/pikpak",  driver="PikPak",          uci="pikpak_auth", kind="userpass", web_proxy=false,
     tmpl='{"username":"{U}","password":"{P}","root_folder_id":""}'},
}

-- JSON 字符串转义（双引号 -> 反斜杠+双引号；反斜杠用 string.char(92) 规避源码转义）
local BS = string.char(92)
local function json_esc(s)
    return (s or ""):gsub('"', BS .. '"')
end

local function build_addition(d, cred)
    if d.kind == "userpass" then
        local u, p = cred:match("^([^:]+):(.+)$")
        if not u then return nil end
        return d.tmpl:gsub("{U}", json_esc(u)):gsub("{P}", json_esc(p))
    end
    return d.tmpl:gsub("{V}", json_esc(cred))
end

-- 通用：保存凭证到 UCI 并立即挂载到 AList（扫码成功 / 手动保存共用）
function save_cred_and_mount(uci_key, cred)
    local sys = require "luci.sys"
    sys.exec("uci set mediahub.main." .. uci_key .. "='" .. esc(cred) .. "'; uci commit mediahub 2>/dev/null")
    local token = ol_token()
    local ok = false
    if token ~= "" then
        if uci_key == "cookie_115" then
            local add = '{"cookie":"' .. json_esc(cred) .. '","qrcode_token":"","qrcode_source":"linux","page_size":1000,"limit_rate":2,"root_folder_id":"0"}'
            ol_update_storage(token, "/115", "115 Cloud", add, false)
            ok = true
        elseif uci_key == "cookie_quark" then
            local add = '{"cookie":"' .. json_esc(cred) .. '","root_folder_id":"0","use_transcoding_address":false,"only_list_video_file":false}'
            ol_update_storage(token, "/quark", "Quark", add, true)
            ok = true
        else
            for _, d in ipairs(CLOUD_MOUNT_DEFS) do
                if d.uci == uci_key then
                    local add = build_addition(d, cred)
                    if add then
                        ol_update_storage(token, d.mount, d.driver, add, d.web_proxy)
                        ok = true
                    end
                    break
                end
            end
        end
    end
    if ok then trigger_cloud_refresh() end
    return ok
end

function get_cookies()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local KEYS = {"cookie_115", "cookie_quark", "cookie_uc", "token_ali", "token_189",
                  "token_yidong", "token_123", "token_baidu", "thunder_auth", "pikpak_auth"}
    local out = {}
    local function mask(s)
        s = s:gsub("^%s+", ""):gsub("%s+$", "")
        if #s > 40 then return s:sub(1, 20) .. "..." .. s:sub(-10) end
        return s
    end
    for _, k in ipairs(KEYS) do
        local v = sys.exec("uci -q get mediahub.main." .. k .. " 2>/dev/null") or ""
        v = v:gsub("^%s+", ""):gsub("%s+$", "")
        out[k] = mask(v)
        out[k .. "_len"] = #v
    end
    http.prepare_content("application/json")
    http.write_json(out)
end

function save_cookies()
    local http = require "luci.http"
    -- v1.5: 全部网盘凭证统一处理（填了哪个就保存哪个 + 立即自动挂载）
    local FIELDS = {
        {k = "cookie_115",   n = "115"},     {k = "cookie_quark", n = "quark"},
        {k = "cookie_uc",    n = "uc"},      {k = "token_ali",    n = "aliyun"},
        {k = "token_189",    n = "189"},     {k = "token_yidong", n = "yidong"},
        {k = "token_123",    n = "123"},     {k = "token_baidu",  n = "baidu"},
        {k = "thunder_auth", n = "thunder"}, {k = "pikpak_auth",  n = "pikpak"},
    }
    local results = {}
    local any = false
    for _, f in ipairs(FIELDS) do
        local v = http.formvalue(f.k) or ""
        v = v:gsub("^%s+", ""):gsub("%s+$", "")
        if v ~= "" then
            any = true
            results["uci_" .. f.n] = "ok"
            local ok = save_cred_and_mount(f.k, v)
            results["ol_" .. f.n] = ok and "ok" or "sync_fail"
        end
    end
    if any then trigger_cloud_refresh() end
    http.prepare_content("application/json")
    http.write_json({code = 200, results = results})
end

-- ============================================================
-- 115 扫码登录（API 返回 PNG 图片，需要保存+轮询）
-- ============================================================
function qr_115_start()
    local http = require "luci.http"
    local sys = require "luci.sys"
    -- 115 官方 Web 扫码（token -> 图片URL -> 轮询），与 115driver 同款接口
    local UA = "Mozilla/5.0 115Browser/27.0.0.0"
    local r = sys.exec('curl -s -m 15 -H "User-Agent: ' .. UA .. '" "https://qrcodeapi.115.com/api/1.0/web/1.0/token" 2>/dev/null') or ""
    local data = r:match('"data"%s*:%s*({[^}]*})') or ""
    local uid = data:match('"uid"%s*:%s*"([^"]*)"') or r:match('"uid"%s*:%s*"([^"]*)"') or ""
    local sign = data:match('"sign"%s*:%s*"([^"]*)"') or r:match('"sign"%s*:%s*"([^"]*)"') or ""
    local tm = data:match('"time"%s*:%s*(%d+)') or r:match('"time"%s*:%s*(%d+)') or ""
    if uid == "" then
        http.prepare_content("application/json")
        http.write_json({code = 500, message = "获取二维码失败（115 token 接口无响应）", raw = r:sub(1, 300)})
        return
    end
    sys.exec("uci set mediahub.main.qr115_uid='" .. uid .. "'; uci set mediahub.main.qr115_sign='" .. sign .. "'; uci set mediahub.main.qr115_time='" .. tm .. "'; uci commit mediahub 2>/dev/null")
    local img_url = "https://qrcodeapi.115.com/api/1.0/mac/1.0/qrcode?uid=" .. uid
    http.prepare_content("application/json")
    http.write_json({code = 200, uid = uid, qrcode = img_url})
end

function qr_115_poll()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local uid = http.formvalue("uid") or ""
    if uid == "" then uid = sys_exec("uci -q get mediahub.main.qr115_uid 2>/dev/null") end
    if uid == "" then
        http.prepare_content("application/json")
        http.write_json({code = 400, message = "missing uid"})
        return
    end
    local sign = sys_exec("uci -q get mediahub.main.qr115_sign 2>/dev/null")
    local tm = sys_exec("uci -q get mediahub.main.qr115_time 2>/dev/null")
    if sign == "" or tm == "" then
        http.prepare_content("application/json")
        http.write_json({code = 200, status = 0, message = "二维码会话丢失，请重新获取"})
        return
    end
    local UA = "Mozilla/5.0 115Browser/27.0.0.0"
    local url = "https://qrcodeapi.115.com/api/1.0/web/1.0/status?uid=" .. uid .. "&time=" .. tm .. "&sign=" .. sign
    local r = sys.exec('curl -s -m 20 -H "User-Agent: ' .. UA .. '" -H "Referer: https://qrcodeapi.115.com/" "' .. url .. '" 2>/dev/null') or ""
    -- 响应格式: 未扫= {"state":false,"message":"请扫描二维码","code":90038}
    --          已确认= {"state":true,"message":"","code":0,"key":"<uid>"}
    local state_val = r:match('"state"%s*:%s*(%a+)')
    local status = tonumber(r:match('"status"%s*:%s*(%-?%d+)') or "")
    if not status then status = tonumber(r:match('"stat"%s*:%s*(%-?%d+)') or "0") end
    if status == nil then status = 0 end
    -- state=true 表示扫码已确认（新接口无 status 字段，直接用 state 判断）
    if state_val == "true" and status == 0 then
        status = 2
    end
    -- state=false 且没有 status 字段，说明还没扫描
    if state_val == "false" and status == 0 then
        local msg = r:match('"message"%s*:%s*"([^"]*)"') or "等待扫描"
        http.prepare_content("application/json")
        http.write_json({code = 200, status = 0, message = msg})
        return
    end

    if status == 2 then
        local body = "account=" .. uid .. "&app=web"
        local lr = sys.exec('curl -s -m 15 -X POST -H "Content-Type: application/x-www-form-urlencoded" -H "User-Agent: ' .. UA .. '" --data "' .. body .. '" "https://passportapi.115.com/app/1.0/web/1.0/login/qrcode" 2>/dev/null') or ""
        -- 响应格式: {"state":1,"data":{"cookie":{"UID":"...","CID":"...","SEID":"...","KID":"..."},...}}
        local login_state = lr:match('"state"%s*:%s*(%d+)') or ""
        local c_uid = lr:match('"UID"%s*:%s*"([^"]*)"') or ""
        local c_cid = lr:match('"CID"%s*:%s*"([^"]*)"') or ""
        local c_seid = lr:match('"SEID"%s*:%s*"([^"]*)"') or ""
        local c_kid = lr:match('"KID"%s*:%s*"([^"]*)"') or ""
        local cookie = ""
        if c_uid ~= "" and c_cid ~= "" then
            cookie = "UID=" .. c_uid .. "; CID=" .. c_cid .. "; SEID=" .. c_seid .. "; KID=" .. c_kid
        end
        if cookie ~= "" then
            local esc_c = cookie:gsub("'", "'\\''")
            sys.exec("uci set mediahub.main.cookie_115='" .. esc_c .. "'; uci commit mediahub 2>/dev/null")
            local token = ol_token()
            if token ~= "" then
                local add = '{"cookie":"' .. cookie:gsub('"', '\\"') .. '","qrcode_token":"","qrcode_source":"linux","page_size":1000,"limit_rate":2,"root_folder_id":"0"}'
                ol_update_storage(token, "/115", "115 Cloud", add, false)
            end
            http.prepare_content("application/json")
            http.write_json({code = 200, status = 2, message = "115登录成功", cookie = cookie})
            trigger_cloud_refresh()
            return
        end
        local err_msg = lr:match('"error"%s*:%s*"([^"]*)"') or lr:match('"message"%s*:%s*"([^"]*)"') or "获取Cookie失败"
        http.prepare_content("application/json")
        http.write_json({code = 200, status = 2, message = "扫码已确认，但获取Cookie失败：" .. err_msg .. "，请手动填入"})
        return
    elseif status == 1 then
        http.prepare_content("application/json")
        http.write_json({code = 200, status = 1, message = "已扫描，请在手机上确认"})
    elseif status == -1 or status == -2 then
        http.prepare_content("application/json")
        http.write_json({code = 200, status = 0, message = "二维码已失效，请重新获取"})
    else
        local msg = r:match('"msg"%s*:%s*"([^"]*)"') or "等待扫描"
        http.prepare_content("application/json")
        http.write_json({code = 200, status = 0, message = msg})
    end
end

-- ============================================================
-- 夸克扫码登录
-- ============================================================
function qr_quark_start()
    local http = require "luci.http"
    local sys = require "luci.sys"
    -- 夸克新扫码接口（2026）：getTokenForQrcodeLogin -> token
    -- UA 与 QuarkPan（httpx 成功案例）同款，保证服务器行为一致
    local UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36"
    -- 会话 cookie jar：获取token/轮询/换Cookie 三步共享，模拟 httpx 完整会话（__puus 需要累积）
    local CK = "/tmp/quark_ck.txt"
    os.remove(CK)
    -- 生成 request_id（uuid）
    local rid = sys_exec("cat /proc/sys/kernel/random/uuid 2>/dev/null")
    if rid == "" then
        rid = sys.exec('python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null') or ""
    end
    if rid == "" then rid = "req_" .. math.floor(os.time() * 1000) end
    local r = sys.exec('curl -s -m 15 -c "' .. CK .. '" -b "' .. CK .. '" -H "User-Agent: ' .. UA .. '" "https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin?client_id=532&v=1.2&request_id=' .. rid .. '" 2>/dev/null') or ""
    local token = r:match('"token"%s*:%s*"([^"]*)"') or ""
    if token == "" then
        http.prepare_content("application/json")
        http.write_json({code = 500, message = "获取二维码失败（夸克 token 接口无响应）", raw = r:sub(1, 200)})
        return
    end
    -- 二维码内容：su.quark.cn 扫码页（与夸克官方网页版一致）
    local qr_content = "https://su.quark.cn/4_eMHBJ?token=" .. token .. "&client_id=532&ssb=weblogin&uc_param_str=&uc_biz_str=S%3A6456%7COPT%3ASAREA%400%7COPT%3AIMMERSIVE%401%7COPT%3ABACK_BTN_STYLE%400"
    -- 保存 token 和 UA 供轮询复用
    sys.exec("uci set mediahub.main.qrq_token='" .. token .. "'; uci commit mediahub 2>/dev/null")
    http.prepare_content("application/json")
    http.write_json({code = 200, token = token, qrcode_content = qr_content})
end

function qr_quark_poll()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local token = http.formvalue("token") or ""
    if token == "" then token = sys_exec("uci -q get mediahub.main.qrq_token 2>/dev/null") end
    if token == "" then
        http.prepare_content("application/json")
        http.write_json({code = 400, message = "missing token"})
        return
    end
    local UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36"
    local CK = "/tmp/quark_ck.txt"
    local rid = sys_exec("cat /proc/sys/kernel/random/uuid 2>/dev/null")
    if rid == "" then rid = "req" .. math.floor(os.time() * 1000) end
    local url = "https://uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken?client_id=532&v=1.2&request_id=" .. rid .. "&token=" .. token
    local r = sys.exec('curl -s -m 20 -c "' .. CK .. '" -b "' .. CK .. '" -H "User-Agent: ' .. UA .. '" "' .. url .. '" 2>/dev/null') or ""
    local status = tonumber(r:match('"status"%s*:%s*(%d+)') or "0")

    if status == 2000000 then
        -- 已扫码确认，拿到 service_ticket -> 访问 pan.quark.cn/account/info 换取登录 Cookie
        -- （正确流程：GET https://pan.quark.cn/account/info?st=<ticket>&lw=scan，Cookie 在响应 Set-Cookie 中）
        local st = r:match('"service_ticket"%s*:%s*"([^"]*)"') or r:match('"serviceTicket"%s*:%s*"([^"]*)"') or ""
        if st == "" then
            http.prepare_content("application/json")
            http.write_json({code = 200, status = 2, message = "扫码已确认，但未获取到凭证，请重新获取二维码"})
            return
        end
        -- 用 service_ticket 访问 account/info（复用会话 cookie jar：start/轮询/换Cookie 三步共享，
        -- 模拟 httpx 完整会话，__puus 登录态需要跨步骤的 cookie 累积才能下发）
        local cookie_url = "https://pan.quark.cn/account/info?st=" .. st .. "&lw=scan"
        sys.exec('curl -s -L -m 20 -c "' .. CK .. '" -b "' .. CK .. '" -H "User-Agent: ' .. UA .. '" -H "Referer: https://pan.quark.cn/" "' .. cookie_url .. '" -o /dev/null 2>/dev/null')
        -- 从 cookie jar 读取所有 quark.cn 域的 cookie（Netscape 格式 7 字段 tab 分隔）
        local seen = {}
        local f = io.open(CK, "r")
        if f then
            for line in f:lines() do
                if line ~= "" and (line:match("^#HttpOnly_") or not line:match("^#")) then
                    local fields = {}
                    for field in line:gmatch("[^\t]+") do fields[#fields+1] = field end
                    if #fields >= 7 then
                        local domain = fields[1]:gsub("^#HttpOnly_", "")
                        local name, val = fields[6], fields[7]
                        if domain:match("quark%.cn") and name ~= "" and val ~= "" then
                            seen[name] = name .. "=" .. val
                        end
                    end
                end
            end
            f:close()
        end
        local cookies = {}
        for _, v in pairs(seen) do cookies[#cookies+1] = v end
        if #cookies == 0 then
            http.prepare_content("application/json")
            http.write_json({code = 200, status = 2, message = "扫码已确认，但获取Cookie失败（无Set-Cookie响应），请重新扫码"})
            return
        end
        -- 检查主登录态（夸克 2026 新版可能用 _UP_ 系列 Unified Passport 替代 __puus，不拦截，交由 AList 驱动实测验证）
        local warn = ""
        if not seen["__puus"] then
            warn = "（提示：本次 Cookie 为新版登录态，缺少 __puus，若网盘挂载不可用请重新扫码）"
        end
        table.sort(cookies)
        local cookie = table.concat(cookies, "; ")
        local esc_c = cookie:gsub("'", "'\\''")
        sys.exec("uci set mediahub.main.cookie_quark='" .. esc_c .. "'; uci commit mediahub 2>/dev/null")
        local ol_token_val = ol_token()
        if ol_token_val ~= "" then
            local add = '{"cookie":"' .. cookie:gsub('"', '\\"') .. '","root_folder_id":"0","use_transcoding_address":false,"only_list_video_file":false}'
            ol_update_storage(ol_token_val, "/quark", "Quark", add, true)
        end
        http.prepare_content("application/json")
        http.write_json({code = 200, status = 2, message = "夸克登录成功" .. warn, cookie = cookie})
        trigger_cloud_refresh()
        return
    end

    local msg = r:match('"message"%s*:%s*"([^"]*)"') or "等待扫描"
    if status == 50004001 then
        msg = "等待扫描"
        status = 0
    elseif status == 50004002 or status == 50004003 or status == 50004004 then
        http.prepare_content("application/json")
        http.write_json({code = 200, status = 0, message = "二维码已失效（" .. msg .. "），请重新获取"})
        return
    end
    http.prepare_content("application/json")
    http.write_json({code = 200, status = 0, message = msg})
end

-- ============================================================
-- UC 扫码登录（v1.5：与夸克同款阿里通行证 CAS，换 Cookie 走 drive.uc.cn 域）
-- ============================================================
function qr_uc_start()
    local http = require "luci.http"
    local UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36"
    local CK = "/tmp/uc_ck.txt"
    os.remove(CK)
    local rid = sys_exec("cat /proc/sys/kernel/random/uuid 2>/dev/null")
    if rid == "" then rid = "req" .. math.floor(os.time() * 1000) end
    local r = sys.exec('curl -s -m 15 -c "' .. CK .. '" -b "' .. CK .. '" -H "User-Agent: ' .. UA .. '" "https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin?client_id=532&v=1.2&request_id=' .. rid .. '" 2>/dev/null') or ""
    local token = r:match('"token"%s*:%s*"([^"]*)"') or ""
    if token == "" then
        http.prepare_content("application/json")
        http.write_json({code = 500, message = "获取二维码失败（接口无响应），请改用下方手动填入 Cookie"})
        return
    end
    local qr_content = "https://su.quark.cn/4_eMHBJ?token=" .. token .. "&client_id=532&ssb=weblogin&uc_param_str=&uc_biz_str=S%3A6456%7COPT%3ASAREA%400%7COPT%3AIMMERSIVE%401%7COPT%3ABACK_BTN_STYLE%400"
    sys.exec("uci set mediahub.main.qruc_token='" .. token .. "'; uci commit mediahub 2>/dev/null")
    http.prepare_content("application/json")
    http.write_json({code = 200, token = token, qrcode_content = qr_content})
end

function qr_uc_poll()
    local http = require "luci.http"
    local token = http.formvalue("token") or ""
    if token == "" then token = sys_exec("uci -q get mediahub.main.qruc_token 2>/dev/null") end
    if token == "" then
        http.prepare_content("application/json")
        http.write_json({code = 400, message = "missing token"})
        return
    end
    local UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36"
    local CK = "/tmp/uc_ck.txt"
    local rid = sys_exec("cat /proc/sys/kernel/random/uuid 2>/dev/null")
    if rid == "" then rid = "req" .. math.floor(os.time() * 1000) end
    local url = "https://uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken?client_id=532&v=1.2&request_id=" .. rid .. "&token=" .. token
    local r = sys.exec('curl -s -m 20 -c "' .. CK .. '" -b "' .. CK .. '" -H "User-Agent: ' .. UA .. '" "' .. url .. '" 2>/dev/null') or ""
    local status = tonumber(r:match('"status"%s*:%s*(%d+)') or "0")

    if status == 2000000 then
        local st = r:match('"service_ticket"%s*:%s*"([^"]*)"') or r:match('"serviceTicket"%s*:%s*"([^"]*)"') or ""
        if st == "" then
            http.prepare_content("application/json")
            http.write_json({code = 200, status = 2, message = "扫码已确认但未获取凭证，请重新获取二维码"})
            return
        end
        -- UC 网盘换 Cookie：drive.uc.cn 域（与夸克 pan.quark.cn 同流程不同域）
        local cookie_url = "https://drive.uc.cn/account/info?st=" .. st .. "&lw=scan"
        sys.exec('curl -s -L -m 20 -c "' .. CK .. '" -b "' .. CK .. '" -H "User-Agent: ' .. UA .. '" -H "Referer: https://drive.uc.cn/" "' .. cookie_url .. '" -o /dev/null 2>/dev/null')
        local seen = {}
        local TAB = string.char(9)
        local f = io.open(CK, "r")
        if f then
            for line in f:lines() do
                if line ~= "" and (line:match("^#HttpOnly_") or not line:match("^#")) then
                    local fields = {}
                    for field in line:gmatch("[^" .. TAB .. "]+") do fields[#fields+1] = field end
                    if #fields >= 7 then
                        local domain = fields[1]:gsub("^#HttpOnly_", "")
                        local name, val = fields[6], fields[7]
                        if domain:match("uc%.cn$") and name ~= "" and val ~= "" then
                            seen[name] = name .. "=" .. val
                        end
                    end
                end
            end
            f:close()
        end
        local cookies = {}
        for _, v in pairs(seen) do cookies[#cookies+1] = v end
        if #cookies == 0 then
            http.prepare_content("application/json")
            http.write_json({code = 200, status = 2, message = "扫码已确认但获取 UC Cookie 失败，请改用下方手动填入"})
            return
        end
        table.sort(cookies)
        local cookie = table.concat(cookies, "; ")
        local ok = save_cred_and_mount("cookie_uc", cookie)
        http.prepare_content("application/json")
        http.write_json({code = 200, status = 2, message = "UC 登录成功" .. (ok and "，已自动挂载到 AList" or "（AList 同步失败，稍后服务自愈）"), cookie = cookie})
        return
    end

    local msg = r:match('"message"%s*:%s*"([^"]*)"') or "等待扫描"
    if status == 50004001 then
        msg = "等待扫描"
        status = 0
    elseif status == 50004002 or status == 50004003 or status == 50004004 then
        http.prepare_content("application/json")
        http.write_json({code = 200, status = 0, message = "二维码已失效（" .. msg .. "），请重新获取"})
        return
    end
    http.prepare_content("application/json")
    http.write_json({code = 200, status = 0, message = msg})
end

-- ============================================================
-- AList 在线更新
-- ============================================================
-- AList 下载镜像站候选（空串 = GitHub 直连）
local OL_MIRRORS_ALL = {
    "",
    "https://gh-proxy.com/",
    "https://mirror.ghproxy.com/",
    "https://ghfast.top/",
    "https://ghproxy.net/",
    "https://cf.ghproxy.cc/",
    "https://hub.gitmirror.com/",
}

-- 镜像测速：对 gh_path 发 range 请求下载前 64KB，按耗时升序返回镜像前缀列表
local function speed_test_mirrors(mirrors, gh_path)
    local list = {}
    for _, m in ipairs(mirrors) do
        local r = sys_exec('curl -s -m 8 -r 0-65535 -o /dev/null -w "%{http_code}|%{time_total}" "' .. m .. gh_path .. '" 2>/dev/null')
        local code, t = r:match("^(%d+)|([%d%.]+)$")
        if code == "200" or code == "206" then
            list[#list+1] = {mirror = m, time = tonumber(t) or 999}
        end
    end
    table.sort(list, function(a, b) return a.time < b.time end)
    local sorted = {}
    for _, e in ipairs(list) do sorted[#sorted+1] = e.mirror end
    return sorted
end

-- 依据 UCI 配置构造下载顺序（auto=测速 / direct=直连优先 / 具体URL=该镜像优先）
local function ol_mirror_order(gh_path)
    local pref = sys_exec("uci -q get mediahub.main.ol_mirror 2>/dev/null")
    local order = {}
    if pref == "" or pref == "auto" then
        return speed_test_mirrors(OL_MIRRORS_ALL, gh_path), pref
    end
    -- 指定优先项
    order[#order+1] = (pref == "direct") and "" or pref
    for _, m in ipairs(OL_MIRRORS_ALL) do
        if m ~= order[1] then order[#order+1] = m end
    end
    return order, pref
end

-- 读取/保存镜像站选择
function get_ol_mirror()
    local http = require "luci.http"
    local m = sys_exec("uci -q get mediahub.main.ol_mirror 2>/dev/null")
    if m == "" then m = "auto" end
    http.prepare_content("application/json")
    http.write_json({code = 200, mirror = m})
end

function save_ol_mirror()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local m = http.formvalue("mirror") or "auto"
    if m ~= "auto" and m ~= "direct" then
        local valid = false
        for _, v in ipairs(OL_MIRRORS_ALL) do if v == m then valid = true break end end
        if not valid then
            http.prepare_content("application/json")
            http.write_json({code = 400, message = "无效的镜像站"})
            return
        end
    end
    sys.exec("uci set mediahub.main.ol_mirror='" .. m .. "'; uci commit mediahub 2>/dev/null")
    http.prepare_content("application/json")
    http.write_json({code = 200, mirror = m, message = "已保存"})
end

function update_alist()
    local http = require "luci.http"
    local sys = require "luci.sys"

    local cur_ver = sys_exec("/usr/bin/alist version 2>/dev/null | awk '/^Version:/{print $2; exit}'")
    local latest_json = sys.exec('curl -s -m 30 "https://api.github.com/repos/AlistGo/alist/releases/latest" 2>/dev/null') or ""
    local latest_ver = latest_json:match('"tag_name"%s*:%s*"([^"]*)"') or ""

    if latest_ver == "" then
        for _, m in ipairs(OL_MIRRORS_ALL) do
            if m ~= "" then
                latest_json = sys.exec('curl -s -m 20 "' .. m .. 'https://api.github.com/repos/AlistGo/alist/releases/latest" 2>/dev/null') or ""
                latest_ver = latest_json:match('"tag_name"%s*:%s*"([^"]*)"') or ""
                if latest_ver ~= "" then break end
            end
        end
    end
    if latest_ver == "" then
        http.prepare_content("application/json")
        http.write_json({code = 500, message = "无法获取最新版本"})
        return
    end
    if latest_ver == cur_ver then
        http.prepare_content("application/json")
        http.write_json({code = 200, old_version = cur_ver, new_version = cur_ver, latest = latest_ver, message = "已是最新版本，无需更新"})
        return
    end

    local gh_path = "https://github.com/AlistGo/alist/releases/download/" .. latest_ver .. "/alist-linux-musl-amd64.tar.gz"
    -- 按 UCI 镜像配置构造下载顺序（auto=测速选最快 / direct=直连优先 / 指定镜像优先）
    local mirrors, pref = ol_mirror_order(gh_path)
    local used_mirror = ""
    local dl_ok = false
    for _, m in ipairs(mirrors) do
        local r = sys.exec('curl -sL -m 300 -o /tmp/alist-update.tar.gz -w "%{http_code}" "' .. m .. gh_path .. '" 2>/dev/null') or ""
        if r:match("200") or r:match("206") then
            local sz = sys_exec("ls -la /tmp/alist-update.tar.gz 2>/dev/null | awk '{print $5}'")
            if tonumber(sz) and tonumber(sz) > 40000000 then
                dl_ok = true
                used_mirror = (m == "") and "GitHub直连" or m
                break
            end
        end
    end
    if not dl_ok then
        http.prepare_content("application/json")
        http.write_json({code = 500, message = "下载失败（已尝试 " .. #mirrors .. " 个下载源）"})
        return
    end

    sys.exec("cp /usr/bin/alist /usr/bin/alist.bak-update 2>/dev/null")
    sys.exec("rm -f /tmp/alist && tar -xzf /tmp/alist-update.tar.gz -C /tmp/ && mv -f /tmp/alist /usr/bin/alist && chmod +x /usr/bin/alist")
    local new_ver = sys_exec("/usr/bin/alist version 2>/dev/null | awk '/^Version:/{print $2; exit}'")
    sys.exec("/etc/init.d/alist restart 2>/dev/null")
    sys.exec("sleep 3; rm -f /tmp/alist-update.tar.gz")

    http.prepare_content("application/json")
    http.write_json({code = 200, old_version = cur_ver, new_version = new_ver, latest = latest_ver,
        mirror = used_mirror, message = "更新完成（下载源: " .. used_mirror .. "）"})
end

-- ============================================================
-- 重启服务
-- ============================================================
function restart_services()
    local http = require "luci.http"
    local sys = require "luci.sys"
    sys.exec("/etc/init.d/alist restart 2>/dev/null")
    sys.exec("/etc/init.d/mediahub-cms restart 2>/dev/null")
    http.prepare_content("application/json")
    http.write_json({code = 200, message = "所有服务已重启"})
end

-- ============================================================
-- CMS 站点管理
-- ============================================================
local function read_cms_urls(list_name)
    local sys = require "luci.sys"
    list_name = list_name or "cms_site"
    local raw = sys.exec("uci -q get mediahub.main." .. list_name .. " 2>/dev/null") or ""
    local urls = {}
    for url in raw:gmatch("(https?://%S+)") do
        urls[#urls+1] = url:gsub("'%s*$", "")
    end
    -- 仅主列表回退到 moviebox（禁用列表无历史可回退）
    if #urls == 0 and list_name == "cms_site" then
        raw = sys.exec("uci -q get moviebox.main.cms_site 2>/dev/null") or ""
        for url in raw:gmatch("(https?://%S+)") do
            urls[#urls+1] = url:gsub("'%s*$", "")
        end
    end
    return urls
end

local function site_name(url)
    return url:match("^https?://([^/]+)") or url
end

function get_cms_sites()
    local http = require "luci.http"
    local enabled = read_cms_urls()
    local disabled = read_cms_urls("cms_site_disabled")
    local sites = {}
    for _, url in ipairs(enabled) do
        sites[#sites+1] = { url = url, name = site_name(url), disabled = false }
    end
    for _, url in ipairs(disabled) do
        sites[#sites+1] = { url = url, name = site_name(url), disabled = true }
    end
    http.prepare_content("application/json")
    http.write_json({code = 200, sites = sites, count = #sites, enabled = #enabled, disabled = #disabled})
end

-- 启用/禁用切换：禁用 = 从 cms_site 移入 cms_site_disabled（不参与爬取，保留配置）；启用 = 反向
-- 切换后重启 CMS 代理生效（cms.py 启动时读 cms_site）
function toggle_cms_site()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local url = http.formvalue("url") or ""
    if url == "" then
        http.prepare_content("application/json")
        http.write_json({code = 400, message = "缺少URL"})
        return
    end
    local on_list = read_cms_urls()
    local off_list = read_cms_urls("cms_site_disabled")
    local is_on, is_off = false, false
    for _, u in ipairs(on_list) do if u == url then is_on = true end end
    for _, u in ipairs(off_list) do if u == url then is_off = true end end
    if not is_on and not is_off then
        http.prepare_content("application/json")
        http.write_json({code = 404, message = "站点不存在"})
        return
    end
    sys.exec("uci -q delete mediahub.main.cms_site 2>/dev/null")
    sys.exec("uci -q delete mediahub.main.cms_site_disabled 2>/dev/null")
    for _, u in ipairs(on_list) do
        if is_on and u == url then
            sys.exec("uci add_list mediahub.main.cms_site_disabled='" .. u .. "' 2>/dev/null")
        else
            sys.exec("uci add_list mediahub.main.cms_site='" .. u .. "' 2>/dev/null")
        end
    end
    for _, u in ipairs(off_list) do
        if is_off and u == url then
            sys.exec("uci add_list mediahub.main.cms_site='" .. u .. "' 2>/dev/null")
        else
            sys.exec("uci add_list mediahub.main.cms_site_disabled='" .. u .. "' 2>/dev/null")
        end
    end
    sys.exec("uci commit mediahub 2>/dev/null")
    sys.exec("/etc/init.d/mediahub-cms restart 2>/dev/null &")
    http.prepare_content("application/json")
    http.write_json({code = 200, disabled = is_on, message = is_on and "已禁用，CMS 重启中" or "已启用，CMS 重启中"})
end

-- 站点测速：并行 curl 各站点 ac=list 接口，返回 TTFB（首字节延时）
-- 健康标准：HTTP 200 + ttfb>0；站点挂掉/超时显示异常
-- 启用+禁用站点都测（禁用站点的存活信息有助于决定是否重新启用）
function speedtest_cms_sites()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local urls = {}
    local seen = {}
    for _, u in ipairs(read_cms_urls()) do if not seen[u] then seen[u] = true; urls[#urls+1] = u end end
    for _, u in ipairs(read_cms_urls("cms_site_disabled")) do if not seen[u] then seen[u] = true; urls[#urls+1] = u end end
    if #urls == 0 then
        http.prepare_content("application/json")
        http.write_json({code = 200, results = {}, count = 0})
        return
    end
    local tmp = "/tmp/mh_speedtest_" .. tostring(os.time())
    local parts = {}
    for _, u in ipairs(urls) do
        -- 每站点一个后台 curl（-m 6 超时；TTFB 用 time_starttransfer）；
        -- curl 失败（超时/断连）时 -w 仍会输出 code 000，[ -z ] 兑底空结果
        parts[#parts+1] = ('( r=$(curl -s -m 6 -o /dev/null -w "%{http_code}|%{time_starttransfer}" '
            .. '-H "User-Agent: Mozilla/5.0" "' .. u .. '?ac=list" 2>/dev/null); '
            .. '[ -z "$r" ] && r="000|0"; echo "' .. u .. ' $r" >> ' .. tmp .. ' ) &')
    end
    parts[#parts+1] = "wait"
    os.remove(tmp)
    sys.exec(table.concat(parts, "\n"))

    local by_url = {}
    local f = io.open(tmp, "r")
    if f then
        for line in f:lines() do
            local u, code, t = line:match("^(https?://%S+)%s+(%d+)|([%d%.]+)$")
            if u then
                by_url[u] = { code = tonumber(code) or 0, ttfb = math.floor((tonumber(t) or 0) * 1000) }
            end
        end
        f:close()
    end
    os.remove(tmp)

    local results = {}
    for _, u in ipairs(urls) do
        local r = by_url[u] or { code = 0, ttfb = 0 }
        results[#results+1] = { url = u, name = site_name(u), code = r.code, ttfb = r.ttfb }
    end
    http.prepare_content("application/json")
    http.write_json({code = 200, results = results, count = #results})
end

function add_cms_site()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local url = http.formvalue("url") or ""
    if url == "" or not url:match("^https?://") then
        http.prepare_content("application/json")
        http.write_json({code = 400, message = "URL无效"})
        return
    end
    sys.exec("uci add_list mediahub.main.cms_site='" .. url .. "'; uci commit mediahub 2>/dev/null")
    -- 重启 CMS 代理
    sys.exec("/etc/init.d/mediahub-cms restart 2>/dev/null &")
    http.prepare_content("application/json")
    http.write_json({code = 200, message = "已添加"})
end

function delete_cms_site()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local url = http.formvalue("url") or ""
    if url == "" then
        http.prepare_content("application/json")
        http.write_json({code = 400, message = "缺少URL"})
        return
    end
    -- 从启用 + 禁用两个列表同时移除（UCI 删除 list 项：重建列表）
    local raw_on = sys.exec("uci -q get mediahub.main.cms_site 2>/dev/null") or ""
    local raw_off = sys.exec("uci -q get mediahub.main.cms_site_disabled 2>/dev/null") or ""
    sys.exec("uci -q delete mediahub.main.cms_site 2>/dev/null")
    sys.exec("uci -q delete mediahub.main.cms_site_disabled 2>/dev/null")
    for existing in raw_on:gmatch("(https?://%S+)") do
        if existing:gsub("'%s*$", "") ~= url then
            sys.exec("uci add_list mediahub.main.cms_site='" .. existing:gsub("'%s*$", "") .. "' 2>/dev/null")
        end
    end
    for existing in raw_off:gmatch("(https?://%S+)") do
        if existing:gsub("'%s*$", "") ~= url then
            sys.exec("uci add_list mediahub.main.cms_site_disabled='" .. existing:gsub("'%s*$", "") .. "' 2>/dev/null")
        end
    end
    sys.exec("uci commit mediahub 2>/dev/null")
    sys.exec("/etc/init.d/mediahub-cms restart 2>/dev/null &")
    http.prepare_content("application/json")
    http.write_json({code = 200, message = "已删除"})
end

-- ============================================================
-- 定时爬取配置
-- ============================================================
-- 间隔（小时）：0=关闭定时爬取，1/3/6/12/24 常用档；保存后重启 CMS 生效
local CRAWL_INTERVALS = { [0] = true, [1] = true, [2] = true, [3] = true, [6] = true, [12] = true, [24] = true, [48] = true, [72] = true }

function get_crawl_schedule()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local iv = tonumber(sys_exec("uci -q get mediahub.main.crawl_interval 2>/dev/null") or "") or 6
    -- 实际生效值从 CMS stats 读（CMS 未重启时仍是旧值，透出真实状态）
    local stats = sys.exec("curl -s -m 5 http://127.0.0.1:8901/stats 2>/dev/null") or ""
    local live_iv = tonumber(stats:match('"crawl_interval"%s*:%s*(%-?%d+)') or "")
    local next_crawl = tonumber(stats:match('"next_crawl"%s*:%s*(%d+)') or "") or 0
    local pending = (live_iv ~= nil and iv ~= live_iv)
    http.prepare_content("application/json")
    http.write_json({code = 200, interval = iv, live_interval = live_iv or iv,
                     next_crawl = next_crawl, pending_restart = pending})
end

function set_crawl_schedule()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local iv = tonumber(http.formvalue("interval") or "")
    if iv == nil or not CRAWL_INTERVALS[iv] then
        http.prepare_content("application/json")
        http.write_json({code = 400, message = "无效的间隔（可选 0/1/2/3/6/12/24/48/72 小时）"})
        return
    end
    sys.exec("uci set mediahub.main.crawl_interval='" .. tostring(iv) .. "'; uci commit mediahub 2>/dev/null")
    sys.exec("/etc/init.d/mediahub-cms restart 2>/dev/null &")
    http.prepare_content("application/json")
    http.write_json({code = 200, interval = iv,
        message = (iv == 0 and "已关闭定时爬取（仅启动时爬一次）" or "已设置定时爬取间隔 " .. iv .. " 小时") .. "，CMS 重启生效中"})
end

-- ============================================================
-- 海报刮削配置（匹配模式 + 刮削源 Key）
-- ============================================================
local SCRAPE_MODES = { strict = "严格", balanced = "均衡", rapid = "急速" }

function get_scrape_config()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local mode = sys_exec("uci -q get mediahub.main.scrape_mode 2>/dev/null")
    if not SCRAPE_MODES[mode] then mode = "balanced" end
    local tmdb_api = sys_exec("uci -q get mediahub.main.tmdb_api 2>/dev/null")
    local tvdb_api = sys_exec("uci -q get mediahub.main.tvdb_api 2>/dev/null")
    local tmdb_key_set = sys_exec("uci -q get mediahub.main.tmdb_key 2>/dev/null") ~= ""
    local tvdb_key_set = sys_exec("uci -q get mediahub.main.tvdb_key 2>/dev/null") ~= ""
    -- 实际生效值从 CMS stats 读（CMS 未重启时仍是旧值，透出真实状态）
    local stats = sys.exec("curl -s -m 5 http://127.0.0.1:8901/stats 2>/dev/null") or ""
    local live_mode = stats:match('"scrape_mode"%s*:%s*"([^"]*)"')
    local extra_n = tonumber(stats:match('"poster_extra"%s*:%s*(%d+)') or "0")
    local thumbs_n = tonumber(stats:match('"thumbs"%s*:%s*(%d+)') or "0")
    local pending = (live_mode ~= nil and live_mode ~= mode)
    http.prepare_content("application/json")
    http.write_json({code = 200, mode = mode, mode_label = SCRAPE_MODES[mode],
                     live_mode = live_mode or mode,
                     live_label = SCRAPE_MODES[live_mode or mode] or (live_mode or mode),
                     tmdb_key_set = tmdb_key_set, tmdb_api = tmdb_api,
                     tvdb_key_set = tvdb_key_set, tvdb_api = tvdb_api,
                     pending_restart = pending,
                     poster_extra = extra_n, thumbs = thumbs_n})
end

function set_scrape_config()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local mode = http.formvalue("mode") or ""
    if not SCRAPE_MODES[mode] then
        http.prepare_content("application/json")
        http.write_json({code = 400, message = "无效的匹配模式（可选 严格/均衡/急速）"})
        return
    end
    local tmdb_key = http.formvalue("tmdb_key") or ""
    local tmdb_api = http.formvalue("tmdb_api") or ""
    local tvdb_key = http.formvalue("tvdb_key") or ""
    local tvdb_api = http.formvalue("tvdb_api") or ""
    if tmdb_api ~= "" and not tmdb_api:match("^https?://") then
        http.prepare_content("application/json")
        http.write_json({code = 400, message = "TMDb API 地址需以 http:// 或 https:// 开头"})
        return
    end
    if tvdb_api ~= "" and not tvdb_api:match("^https?://") then
        http.prepare_content("application/json")
        http.write_json({code = 400, message = "TheTVDB API 地址需以 http:// 或 https:// 开头"})
        return
    end
    sys.exec("uci set mediahub.main.scrape_mode='" .. mode .. "'")
    -- key 留空保持不变（避免误清）；api 留空即用官方地址
    if tmdb_key ~= "" then sys.exec("uci set mediahub.main.tmdb_key='" .. esc(tmdb_key) .. "'") end
    sys.exec("uci set mediahub.main.tmdb_api='" .. esc(tmdb_api) .. "'")
    if tvdb_key ~= "" then sys.exec("uci set mediahub.main.tvdb_key='" .. esc(tvdb_key) .. "'") end
    sys.exec("uci set mediahub.main.tvdb_api='" .. esc(tvdb_api) .. "'")
    sys.exec("uci commit mediahub 2>/dev/null")
    sys.exec("/etc/init.d/mediahub-cms restart 2>/dev/null &")
    http.prepare_content("application/json")
    http.write_json({code = 200, mode = mode,
        message = "已设置匹配模式：" .. SCRAPE_MODES[mode] .. "，CMS 重启生效中（未匹配的将按新模式刮削）"})
end

function reset_scrape()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local dd = sys_exec("uci -q get mediahub.main.data_dir 2>/dev/null")
    if dd == "" then dd = "/mnt/data/alist" end
    sys.exec("rm -f '" .. dd .. "/cache/poster_extra.json.gz' 2>/dev/null")
    sys.exec("/etc/init.d/mediahub-cms restart 2>/dev/null &")
    http.prepare_content("application/json")
    http.write_json({code = 200,
        message = "已清空刮削库（截帧保留可复用），CMS 重启后约 90 秒自动按当前模式重新批量刮削"})
end

-- ============================================================
-- BT/磁力离线下载到 115 网盘（经 AList 115 Cloud 工具）
-- ============================================================
function add_offline_download()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local dl_url = http.formvalue("url") or ""
    local dl_dir = http.formvalue("dir") or "/115"
    if dl_url == "" then
        http.prepare_content("application/json")
        http.write_json({code = 400, message = "缺少磁力链接或BT种子URL"})
        return
    end
    -- 转发到本地 CMS 代理（CMS 负责拿 AList token + 调 AList API）
    local enc_url = dl_url:gsub("[%s]", ""):gsub("([^%w%-_.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    local enc_dir = dl_dir:gsub("([^%w%-_.~%/])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    local r = sys.exec("curl -s -m 30 'http://127.0.0.1:8901/offline_download?url=" .. enc_url .. "&dir=" .. enc_dir .. "' 2>/dev/null") or ""
    http.prepare_content("application/json")
    if r:match("^%s*{") then
        http.write(r)
    else
        http.write_json({code = 500, message = "CMS 代理无响应"})
    end
end

function get_offline_tasks()
    local http = require "luci.http"
    local sys = require "luci.sys"
    -- 从 AList 获取未完成/最近任务列表
    local pw = sys_exec("uci -q get mediahub.main.alist_pw 2>/dev/null")
    if pw == "" then pw = "admin" end
    local tk = sys.exec("curl -s -m 10 http://127.0.0.1:5244/api/auth/login -X POST " ..
                        "-H 'Content-Type: application/json' " ..
                        "-d '{\"username\":\"admin\",\"password\":\"" .. pw .. "\"}' 2>/dev/null | " ..
                        "grep -o '\"token\":\"[^\"]*\"' | cut -d'\"' -f4") or ""
    tk = tk:gsub("%s", "")
    if tk == "" then
        http.prepare_content("application/json")
        http.write_json({code = 500, message = "无法登录 AList"})
        return
    end
    -- AList 任务列表 API（115 离线下载 + 上传传输）
    local r1 = sys.exec("curl -s -m 10 'http://127.0.0.1:5244/api/task/115/offline_download/undone' -H 'Authorization: " .. tk .. "' 2>/dev/null") or ""
    local r2 = sys.exec("curl -s -m 10 'http://127.0.0.1:5244/api/task/115/offline_download/done' -H 'Authorization: " .. tk .. "' 2>/dev/null") or ""
    http.prepare_content("application/json")
    local undone, done = {}, {}
    if r1:match("^%s*{") then
        undone = r1
    end
    if r2:match("^%s*{") then
        done = r2
    end
    http.write_json({code = 200, undone = undone, done = done})
end

-- ============================================================
-- 播放缓存管理（m3u8 缓存大小设置 + 清理）
-- ============================================================
function get_cache()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local limit_mb = tonumber(sys_exec("uci -q get mediahub.main.cache_mb 2>/dev/null") or "") or 64
    -- 从 CMS 代理 stats 读取缓存实时状态
    local stats = sys.exec("curl -s -m 5 http://127.0.0.1:8901/stats 2>/dev/null") or ""
    local entries = tonumber(stats:match('"entries"%s*:%s*(%d+)') or "0")
    local bytes = tonumber(stats:match('"bytes"%s*:%s*(%d+)') or "0")
    local stats_limit = tonumber(stats:match('"limit_mb"%s*:%s*(%d+)') or "0")
    local cloud_files = tonumber(stats:match('"cloud_files"%s*:%s*(%d+)') or "0")
    if stats_limit > 0 then limit_mb = stats_limit end
    http.prepare_content("application/json")
    http.write_json({code = 200, entries = entries, bytes = bytes, limit_mb = limit_mb, cloud_files = cloud_files})
end

function set_cache()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local mb = tonumber(http.formvalue("mb") or "")
    if not mb or mb < 4 or mb > 2048 then
        http.prepare_content("application/json")
        http.write_json({code = 400, message = "缓存上限需为 4-2048 MB"})
        return
    end
    sys.exec("uci set mediahub.main.cache_mb='" .. tostring(math.floor(mb)) .. "'; uci commit mediahub 2>/dev/null")
    sys.exec("/etc/init.d/mediahub-cms restart 2>/dev/null &")
    http.prepare_content("application/json")
    http.write_json({code = 200, message = "已设置缓存上限 " .. math.floor(mb) .. " MB，CMS 代理重启中"})
end

function clear_cache()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local r = sys.exec("curl -s -m 10 http://127.0.0.1:8901/cache/clear 2>/dev/null") or ""
    local cleared = tonumber(r:match('"cleared"%s*:%s*(%d+)') or "0")
    local freed = tonumber(r:match('"freed_bytes"%s*:%s*(%d+)') or "0")
    if r:match('"code"%s*:%s*200') then
        http.prepare_content("application/json")
        http.write_json({code = 200, cleared = cleared, freed_bytes = freed})
    else
        http.prepare_content("application/json")
        http.write_json({code = 500, message = "清理失败：CMS 代理无响应"})
    end
end
