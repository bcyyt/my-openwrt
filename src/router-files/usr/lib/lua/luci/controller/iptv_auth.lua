-- iptv_auth.lua — LuCI 控制器
module("luci.controller.iptv_auth", package.seeall)

local function sys_exec(cmd)
    local sys = require "luci.sys"
    return (sys.exec(cmd) or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("\n", "")
end

-- ===================== 版本工具（get_info 与 OTA 共用） =====================

local function get_current_version()
    -- 兼容 apk（iStoreOS 25.12+）与 opkg（传统 OpenWrt）双包管理器
    if sys_exec("command -v apk") ~= "" then
        local raw = sys_exec("apk list --installed 2>/dev/null | grep '^iptv-auth-' | head -1")
        return raw:match("^iptv%-auth%-(%S+)%s") or ""
    end
    local raw = sys_exec("opkg list-installed 2>/dev/null | grep '^iptv-auth ' | head -1")
    return raw:match("^iptv%-auth%s+%-%s+(%S+)") or ""
end

local function parse_ver(v)
    local major, minor, patch = v:match("(%d+)%.(%d+)%.(%d+)")
    return tonumber(major) or 0, tonumber(minor) or 0, tonumber(patch) or 0
end

local function is_newer(latest, current)
    local lmaj, lmin, lpat = parse_ver(latest)
    local cmaj, cmin, cpat = parse_ver(current)
    if lmaj ~= cmaj then return lmaj > cmaj end
    if lmin ~= cmin then return lmin > cmin end
    return lpat > cpat
end

function index()
    if not require("nixio.fs").access("/usr/bin/iptv-auth.py") then
        return
    end
    local e = entry({"admin", "services", "iptv_auth"}, firstchild(), _("IPTV 代理"), 25)
    e.dependent = false
    entry({"admin", "services", "iptv_auth", "status"}, template("iptv_auth/status"), _("运行状态与日志"), 10)
    entry({"admin", "services", "iptv_auth", "rtp2httpd"}, template("iptv_auth/rtp2httpd"), _("rtp2httpd 状态"), 20)
    entry({"admin", "services", "iptv_auth", "config"}, template("iptv_auth/config"), _("鉴权与代理配置"), 30)
    entry({"admin", "services", "iptv_auth", "log"}, call("get_log")).leaf = true
    entry({"admin", "services", "iptv_auth", "info"}, call("get_info")).leaf = true
    entry({"admin", "services", "iptv_auth", "history_list"}, call("get_history_list")).leaf = true
    entry({"admin", "services", "iptv_auth", "history_log"}, call("get_history_log")).leaf = true
    entry({"admin", "services", "iptv_auth", "restart_services"}, call("restart_services")).leaf = true
    entry({"admin", "services", "iptv_auth", "service_switch"}, call("service_switch")).leaf = true
    entry({"admin", "services", "iptv_auth", "clear_log"}, call("clear_log")).leaf = true
    entry({"admin", "services", "iptv_auth", "clear_history"}, call("clear_history")).leaf = true
    entry({"admin", "services", "iptv_auth", "run_now"}, call("run_now")).leaf = true
    entry({"admin", "services", "iptv_auth", "get_config"}, call("get_config")).leaf = true
    entry({"admin", "services", "iptv_auth", "save_config"}, call("save_config")).leaf = true
    entry({"admin", "services", "iptv_auth", "interfaces"}, call("get_interfaces")).leaf = true
    entry({"admin", "services", "iptv_auth", "clients"}, call("get_clients")).leaf = true
    entry({"admin", "services", "iptv_auth", "rtp2httpd_check"}, call("get_rtp2httpd_versions")).leaf = true
    entry({"admin", "services", "iptv_auth", "rtp2httpd_update"}, call("do_rtp2httpd_update")).leaf = true
    entry({"admin", "services", "iptv_auth", "rtp2httpd_update_status"}, call("get_rtp2httpd_update_status")).leaf = true
    entry({"admin", "services", "iptv_auth", "ota_check"}, call("check_ota_update")).leaf = true
    entry({"admin", "services", "iptv_auth", "ota_do"}, call("do_ota_update")).leaf = true
    entry({"admin", "services", "iptv_auth", "ota_status"}, call("get_ota_status")).leaf = true
    entry({"admin", "services", "iptv_auth", "ota_auto_check"}, call("run_ota_auto_check")).leaf = true
end

function get_log()
    local http = require "luci.http"
    local fs = require "nixio.fs"
    http.prepare_content("text/plain; charset=utf-8")
    local log_file = "/var/log/iptv-auth/iptv-auth.log"
    if fs.access(log_file) then
        local content = fs.readfile(log_file)
        if content then
            -- 活跃日志由 iptv-auth.py 维护为最近 500 条，直接全量返回
            http.write(content)
            return
        end
    end
    http.write("暂无日志")
end

function run_now()
    -- 手动立即执行：写标志文件，iptv-auth.py 主循环 5 秒内检测并执行
    local http = require "luci.http"
    local sys = require "luci.sys"
    http.prepare_content("application/json")
    local json = require "luci.jsonc"
    local ok = sys.call("touch /tmp/iptv-auth-runnow")
    http.write(json.stringify({ok = (ok == 0), message = "已触发执行，将在 5 秒内开始（EPG 抓取需数分钟）"}))
end

function clear_log()
    -- 清除实时日志（活跃日志文件）
    local http = require "luci.http"
    local sys = require "luci.sys"
    http.prepare_content("application/json")
    local json = require "luci.jsonc"
    local ok = sys.call(": > /var/log/iptv-auth/iptv-auth.log 2>/dev/null")
    http.write(json.stringify({ok = (ok == 0), message = "实时日志已清除"}))
end

function clear_history()
    -- 清除指定日期历史日志
    local http = require "luci.http"
    local sys = require "luci.sys"
    http.prepare_content("application/json")
    local json = require "luci.jsonc"
    local date = http.formvalue("date") or ""
    if not date:match("^%d%d%d%d%-%d%d%-%d%d$") then
        http.write(json.stringify({ok = false, message = "日期非法"}))
        return
    end
    local f = "/mnt/data/iptv-auth/logs/history-" .. date .. ".log"
    local ok = sys.call(string.format("rm -f %q", f))
    http.write(json.stringify({ok = (ok == 0), message = ("已清除 %s 的历史日志"):format(date)}))
end

function restart_services()
    -- 重启全部 IPTV 服务（iptv-auth 鉴权 + rtp2httpd 直播代理）
    local http = require "luci.http"
    local sys = require "luci.sys"
    http.prepare_content("application/json")
    local json = require "luci.jsonc"
    local ok = sys.call("/etc/init.d/iptv-auth restart >/dev/null 2>&1")
    http.write(json.stringify({ok = (ok == 0), message = (ok == 0) and "所有服务已重启" or "重启失败"}))
end

function service_switch()
    -- 服务总开关：on 开启（写 UCI + 启动服务），off 关闭（写 UCI + 停止服务）
    local http = require "luci.http"
    local sys = require "luci.sys"
    http.prepare_content("application/json")
    local json = require "luci.jsonc"
    local op = http.formvalue("op") or ""
    if op == "on" then
        sys.call("uci set iptv-auth.main.enabled='1'")
        sys.call("uci commit iptv-auth")
        local ok = sys.call("/etc/init.d/iptv-auth start >/dev/null 2>&1")
        http.write(json.stringify({ok = (ok == 0), enabled = true, message = "服务已开启"}))
    elseif op == "off" then
        sys.call("uci set iptv-auth.main.enabled='0'")
        sys.call("uci commit iptv-auth")
        sys.call("/etc/init.d/iptv-auth stop >/dev/null 2>&1")
        http.write(json.stringify({ok = true, enabled = false, message = "服务已关闭"}))
    else
        http.write(json.stringify({ok = false, message = "参数非法"}))
    end
end

function get_history_list()
    -- 列出历史日志日期（/mnt/data/iptv-auth/logs/history-YYYY-MM-DD.log）
    local http = require "luci.http"
    local sys = require "luci.sys"
    http.prepare_content("application/json")
    local json = require "luci.jsonc"
    local out = sys.exec("ls -1 /mnt/data/iptv-auth/logs/history-*.log 2>/dev/null | sed 's/.*history-//; s/\\.log$//'") or ""
    local dates = {}
    for d in out:gmatch("[%d%-]+") do
        table.insert(dates, d)
    end
    -- 倒序（最新在前）
    for i = 1, math.floor(#dates / 2) do
        dates[i], dates[#dates - i + 1] = dates[#dates - i + 1], dates[i]
    end
    http.write(json.stringify(dates))
end

function get_history_log()
    local http = require "luci.http"
    local fs = require "nixio.fs"
    http.prepare_content("text/plain; charset=utf-8")
    local date = http.formvalue("date") or ""
    -- 严格格式校验：仅允许 YYYY-MM-DD
    if not date:match("^%d%d%d%d%-%d%d%-%d%d$") then
        http.write("日期格式非法")
        return
    end
    local f = "/mnt/data/iptv-auth/logs/history-" .. date .. ".log"
    if fs.access(f) then
        local content = fs.readfile(f)
        if content then
            -- 历史文件可能较大，返回最后 1000 行
            local lines = {}
            for line in content:gmatch("[^\n]+") do
                table.insert(lines, line)
            end
            local start = math.max(1, #lines - 999)
            for i = start, #lines do
                http.write(lines[i] .. "\n")
            end
            return
        end
    end
    http.write("该日期无历史日志")
end

function get_info()
    local http = require "luci.http"
    local fs = require "nixio.fs"
    http.prepare_content("application/json")

    -- 读取状态文件
    local status_file = "/var/log/iptv-auth/status.json"
    local info = {last_run = "", next_run = "", channels = 0, auth_ok = false}
    if fs.access(status_file) then
        local content = fs.readfile(status_file)
        if content then
            local json = require "luci.jsonc"
            local parsed = json.parse(content)
            if parsed then
                info = parsed
            end
        end
    end

    -- 服务状态：以 procd 为唯一事实来源（pgrep -x/-f 在 busybox 上不可靠，
    -- -f 会自匹配 shell 包装进程）
    info.iptv_auth_running = instance_running("iptv-auth")
    info.rtp2httpd_running = instance_running("rtp2httpd")

    -- 总开关状态
    local enabled = require("luci.sys").exec("uci -q get iptv-auth.main.enabled 2>/dev/null") or ""
    info.enabled = (enabled:match("^%s*0%s*$") == nil)

    -- 插件版本（OpenWrt 25.12 用 apk，24.10 及以下回退 opkg）
    local ver = require("luci.sys").exec("apk list --installed 2>/dev/null | grep '^iptv-auth-' | head -1") or ""
    info.version = ver:match("^iptv%-auth%-(%S+)%s") or ""
    if info.version == "" then
        ver = require("luci.sys").exec("opkg list-installed 2>/dev/null | grep '^iptv-auth ' | head -1") or ""
        info.version = ver:match("%-%s+(%S+)") or "unknown"
    end

    -- OTA 更新检测（cron 每 12h 由 iptv-auth-ota-check.sh 抓取缓存，此处读缓存判断，
    -- 判断逻辑复用 is_newer，与手动「检查更新」保持单一逻辑源）
    local json = require "luci.jsonc"
    local ota = { available = false, has_update = false, latest = "", current = info.version,
                  date = "", changelog = "", url = "", ipk_url = "", last_check = "" }
    local ota_cache = "/tmp/iptv-auth-ota-version.json"
    if fs.access(ota_cache) then
        local c = fs.readfile(ota_cache)
        if c and #c > 0 then
            local parsed = json.parse(c)
            if parsed and parsed.version then
                ota.available = true
                ota.latest = parsed.version
                ota.date = parsed.date or ""
                ota.changelog = parsed.changelog or ""
                ota.url = parsed.url or ""
                ota.ipk_url = parsed.ipk_url or ""
                ota.has_update = is_newer(parsed.version, info.version or "")
            end
        end
    end
    ota.last_check = sys_exec("uci -q get iptv-auth.main.ota_last_check 2>/dev/null")
    info.ota = ota

    http.write(json.stringify(info))
end

function instance_running(instance)
    -- 查询 procd 中 iptv-auth 服务的指定实例运行状态
    local fh = io.popen('ubus call service list \'{"name":"iptv-auth"}\' 2>/dev/null')
    if not fh then return false end
    local out = fh:read("*a")
    fh:close()
    if not out or out == "" then return false end
    local ok, json = pcall(require, "luci.jsonc")
    if not ok then return false end
    local parsed = json.parse(out)
    if not (parsed and parsed["iptv-auth"] and parsed["iptv-auth"].instances
        and parsed["iptv-auth"].instances[instance]) then
        return false
    end
    return (parsed["iptv-auth"].instances[instance].running == true)
end

-- ===================== rtp2httpd 在线更新 =====================
local UPDATE_STATUS_FILE = "/tmp/rtp2httpd-update.json"

function get_rtp2httpd_versions()
    local http = require "luci.http"
    local sys = require "luci.sys"
    http.prepare_content("application/json")
    local json = require "luci.jsonc"

    -- 当前版本：从二进制 --help 横幅解析（手动换二进制后也能如实显示）
    local current = sys.exec("/usr/bin/rtp2httpd --help 2>&1 | grep -oE '[0-9]+\\.[0-9]+\\.[0-9]+' | head -1") or ""
    current = current:gsub("%s+", "")

    local mirror = sys.exec("uci -q get iptv-auth.main.update_mirror 2>/dev/null") or ""
    mirror = mirror:gsub("%s+", "")

    local api = "https://api.github.com/repos/stackia/rtp2httpd/releases/latest"
    if mirror ~= "" then api = mirror .. api end

    local latest = ""
    local err = ""
    local out = sys.exec(string.format("curl -s -m 15 %q 2>/dev/null", api)) or ""
    if out ~= "" then
        latest = out:match('"tag_name"%s*:%s*"([^"]+)"') or ""
        latest = latest:gsub("^v", "")
    end
    if latest == "" then
        err = "无法访问 GitHub API（网络受限？可在本页设置镜像前缀后重试）"
    end
    http.write(json.stringify({current = current, latest = latest, error = err}))
end

function do_rtp2httpd_update()
    local http = require "luci.http"
    local fs = require "nixio.fs"
    http.prepare_content("application/json")
    local json = require "luci.jsonc"

    local ver = http.formvalue("version") or "latest"
    -- 严格消毒：只允许 latest 或 纯数字点号版本串
    if ver ~= "latest" and not ver:match("^[%d%.]+$") then
        http.write(json.stringify({started = false, error = "版本号格式非法"}))
        return
    end
    -- 并发保护：状态为 running 且未过期（10分钟）则拒绝
    if fs.access(UPDATE_STATUS_FILE) then
        local c = fs.readfile(UPDATE_STATUS_FILE)
        if c and c:find('"state":"running"', 1, true) then
            local mtime = fs.stat(UPDATE_STATUS_FILE, "mtime")
            if mtime and (os.time() - mtime <= 600) then
                http.write(json.stringify({started = false, error = "已有更新任务在进行中"}))
                return
            end
        end
    end
    -- 不预写占位状态：脚本启动后立即接管（避免与脚本自身的并发检查互踩）
    require("luci.sys").call(string.format(
        "/usr/bin/rtp2httpd-update.sh %q >/tmp/rtp2httpd-update.log 2>&1 &", ver))
    http.write(json.stringify({started = true}))
end

function get_rtp2httpd_update_status()
    local http = require "luci.http"
    local fs = require "nixio.fs"
    http.prepare_content("application/json")
    local json = require "luci.jsonc"
    local info = {state = "idle", message = "", version = ""}
    if fs.access(UPDATE_STATUS_FILE) then
        local c = fs.readfile(UPDATE_STATUS_FILE)
        if c then
            local parsed = json.parse(c)
            if parsed then info = parsed end
        end
        -- 陈旧 running 检测：状态文件超过 10 分钟未变化则视为失败（脚本被杀等异常）
        if info.state == "running" then
            local mtime = fs.stat(UPDATE_STATUS_FILE, "mtime")
            if mtime and (os.time() - mtime > 600) then
                info.state = "failed"
                info.message = "更新任务超时未完成（状态10分钟无变化），请重试；详情见 /tmp/rtp2httpd-update.log"
            end
        end
    end
    http.write(json.stringify(info))
end

-- ===================== 配置读写（自定义模板用） =====================
local CONFIG_KEYS = {
    "iptv_server", "userid", "authenticator", "stbip", "lasttermno",
    "usergroupnmb", "epggroupnmb", "usertoken", "stbid", "stbinfo",
    "live_port", "replay_port", "upstream_interface",
    "rtp2h_workers", "rtp2h_rcvbuf", "rtp2h_bufpool",
    "rtp2h_if_multicast", "rtp2h_if_fcc", "rtp2h_if_rtsp", "rtp2h_if_http",
    "filter_pip", "filter_keywords", "interval", "epg_enabled",
    "update_mirror",
    "ota_url",
    "wan_domain"
}

function get_config()
    local http = require "luci.http"
    local sys = require "luci.sys"
    http.prepare_content("application/json")
    local json = require "luci.jsonc"
    local result = {}
    for _, key in ipairs(CONFIG_KEYS) do
        local val = sys.exec(string.format("uci -q get iptv-auth.main.%s 2>/dev/null", key)) or ""
        result[key] = val:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\n", "")
    end
    http.write(json.stringify(result))
end

function save_config()
    local http = require "luci.http"
    local sys = require "luci.sys"
    http.prepare_content("application/json")
    local json = require "luci.jsonc"
    for _, key in ipairs(CONFIG_KEYS) do
        local val = http.formvalue(key) or ""
        sys.exec(string.format("uci set iptv-auth.main.%s=%q", key, val))
    end
    sys.call("uci commit iptv-auth")
    sys.call("/etc/init.d/iptv-auth restart >/dev/null 2>&1")
    http.write(json.stringify({ok = true, message = "配置已保存，服务已重启"}))
end

-- ===================== 连接的客户端（IP + 设备标识） =====================
-- 常见厂商 OUI 前缀（小写），覆盖 IPTV 播放场景常见设备；识别不到显示 MAC
local OUI_VENDORS = {
    ["dc:4f:22"] = "小米", ["84:f3:eb"] = "小米", ["64:09:80"] = "小米",
    ["f8:2f:b2"] = "小米", ["34:ce:00"] = "小米", ["68:db:87"] = "小米",
    ["0c:1d:af"] = "小米", ["50:ec:50"] = "小米", ["8c:be:be"] = "小米",
    ["00:1b:63"] = "苹果", ["ac:de:48"] = "苹果", ["f0:18:98"] = "苹果",
    ["98:10:e8"] = "苹果", ["a4:83:e7"] = "苹果", ["d8:96:95"] = "苹果",
    ["14:99:e2"] = "苹果", ["dc:2b:61"] = "苹果", ["f4:06:69"] = "苹果",
    ["3c:07:54"] = "苹果", ["88:66:a5"] = "苹果", ["b0:48:1a"] = "苹果",
    ["18:c5:8a"] = "华为", ["34:6b:d3"] = "华为", ["58:2f:40"] = "华为",
    ["c4:0b:cb"] = "华为", ["00:9a:cd"] = "华为", ["10:1b:54"] = "华为",
    ["88:28:b3"] = "华为", ["28:6e:d4"] = "华为", ["04:33:89"] = "华为",
    ["50:01:bb"] = "三星", ["8c:77:12"] = "三星", ["14:7d:c5"] = "三星",
    ["4c:bc:a5"] = "三星", ["78:47:1d"] = "三星", ["b4:79:a7"] = "三星",
    ["e4:12:1d"] = "三星", ["f0:25:b7"] = "三星", ["30:fc:68"] = "三星",
    ["a4:50:46"] = "OPPO", ["3c:bd:d8"] = "OPPO", ["7c:1c:4e"] = "一加",
    ["8c:1d:96"] = "vivo", ["88:53:2d"] = "vivo", ["20:82:c0"] = "vivo",
    ["94:db:c9"] = "vivo", ["34:ce:fa"] = "荣耀", ["50:8f:4c"] = "荣耀",
    ["28:3c:e4"] = "荣耀", ["50:2b:73"] = "TP-Link", ["d8:07:b6"] = "TP-Link",
    ["a4:2b:b0"] = "TP-Link", ["00:e0:4c"] = "Realtek", ["52:54:00"] = "QEMU/KVM",
    ["00:25:9c"] = "海康威视", ["c0:56:e3"] = "海康威视", ["20:76:93"] = "天猫精灵",
}

function get_clients()
    -- 当前连接的客户端（IP + 设备标识）：
    -- netstat 解析 ESTABLISHED（排除本机自连接），MAC/厂商来自 ip neigh，
    -- 回看的 UA 与频道来自 iptv-auth.py 维护的 clients.json 档案
    local http = require "luci.http"
    local sys = require "luci.sys"
    local fs = require "nixio.fs"
    http.prepare_content("application/json")
    local json = require "luci.jsonc"

    local live_port = (sys.exec("uci -q get iptv-auth.main.live_port 2>/dev/null") or "23234"):gsub("%s", "")
    local lan_ip = (sys.exec("uci -q get network.lan.ipaddr 2>/dev/null") or ""):gsub("%s", "")
    local port_label = { [live_port] = "直播", ["554"] = "回看", ["2000"] = "网页" }

    -- 1. 活跃连接
    local conns, order = {}, {}
    local ns = sys.exec("netstat -tn 2>/dev/null") or ""
    for line in ns:gmatch("[^\r\n]+") do
        if line:match("ESTABLISHED") then
            local laddr, raddr = line:match("%s+(%S+:%d+)%s+(%S+:%d+)%s+")
            if laddr and raddr then
                local lport = laddr:match(":(%d+)$")
                local rip = raddr:match("^::ffff:(%d+%.%d+%.%d+%.%d+):%d+$")
                             or raddr:match("^(%d+%.%d+%.%d+%.%d+):%d+$")
                if rip and rip ~= "127.0.0.1" and rip ~= lan_ip and port_label[lport] then
                    local c = conns[rip]
                    if not c then
                        c = { count = 0, tset = {} }
                        conns[rip] = c
                        order[#order + 1] = rip
                    end
                    c.count = c.count + 1
                    c.tset[port_label[lport]] = true
                end
            end
        end
    end

    -- 2. MAC 地址（ip neigh）
    local macs = {}
    local nb = sys.exec("ip neigh show 2>/dev/null") or ""
    for line in nb:gmatch("[^\r\n]+") do
        local ip, mac = line:match("^(%S+)%s+dev%s+%S+%s+lladdr%s+(%S+)")
        if ip and mac then macs[ip] = mac:lower() end
    end

    -- 3. 回看客户端档案（UA/频道/最近时间，由 iptv-auth.py 记录）
    local profiles = {}
    local raw = fs.readfile("/var/log/iptv-auth/clients.json")
    if raw and #raw > 0 then
        local parsed = json.parse(raw)
        if type(parsed) == "table" then profiles = parsed end
    end

    -- 4. 组装（类型固定顺序：直播 > 回看 > 网页）
    local out = {}
    for _, ip in ipairs(order) do
        local c = conns[ip]
        local mac = macs[ip] or ""
        local vendor = ""
        if mac ~= "" then
            local second = mac:sub(2, 2)
            if second == "2" or second == "6" or second == "a" or second == "e" then
                vendor = "随机 MAC（隐私标识）"
            else
                vendor = OUI_VENDORS[mac:sub(1, 8)] or ""
            end
        end
        local p = profiles[ip]
        if type(p) ~= "table" then p = {} end
        local types = {}
        if c.tset["直播"] then types[#types + 1] = "直播" end
        if c.tset["回看"] then types[#types + 1] = "回看" end
        if c.tset["网页"] then types[#types + 1] = "网页" end
        out[#out + 1] = {
            ip = ip,
            conns = c.count,
            types = types,
            mac = mac,
            vendor = vendor,
            ua = p.ua or "",
            channel = p.channel or "",
            last = p.last or 0
        }
    end
    http.write(json.stringify({ ok = true, clients = out }))
end

-- ===================== OTA 在线热更新 =====================

function run_ota_auto_check()
    -- 手动触发自动检测（与 cron 同逻辑：更新缓存与检测时间戳）
    local http = require "luci.http"
    http.prepare_content("application/json")
    local json = require "luci.jsonc"
    local rc = require("luci.sys").call("/usr/bin/iptv-auth-ota-check.sh >/dev/null 2>&1")
    http.write(json.stringify({ ok = (rc == 0), message = (rc == 0 and "检测完成，已更新缓存" or "检测失败（无法访问 OTA 服务器）") }))
end

function check_ota_update()
    -- 检查是否有新版本：fetch version.json → 解析 → 版本比对
    local http = require "luci.http"
    local sys = require "luci.sys"
    http.prepare_content("application/json")
    local json = require "luci.jsonc"

    local ota_url = (sys.exec("uci -q get iptv-auth.main.ota_url 2>/dev/null") or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if ota_url == "" then
        http.write(json.stringify({ ok = false, error = "未配置 OTA 更新地址" }))
        return
    end

    local resp = sys.exec(string.format("curl -s -m 15 %q 2>/dev/null", ota_url)) or ""
    if resp == "" then
        http.write(json.stringify({ ok = false, error = "无法访问 OTA 服务器" }))
        return
    end

    local parsed = json.parse(resp)
    if not parsed or not parsed.version then
        http.write(json.stringify({ ok = false, error = "version.json 格式无效" }))
        return
    end

    local current = get_current_version()
    local latest = parsed.version
    local has_update = is_newer(latest, current)
    http.write(json.stringify({
        ok = true,
        current = current,
        latest = latest,
        has_update = has_update,
        url = parsed.url or "",
        ipk_url = parsed.ipk_url or "",
        date = parsed.date or "",
        changelog = parsed.changelog or ""
    }))
end

function do_ota_update()
    -- 执行在线更新：后台启动 ota 脚本下载安装
    local http = require "luci.http"
    local fs = require "nixio.fs"
    local sys = require "luci.sys"
    http.prepare_content("application/json")
    local json = require "luci.jsonc"

    local apk_url = http.formvalue("url") or ""
    local ipk_url = http.formvalue("ipk_url") or ""
    local ver = http.formvalue("version") or ""
    if ver == "" then
        http.write(json.stringify({ ok = false, error = "缺少版本号" }))
        return
    end
    if apk_url == "" and ipk_url == "" then
        http.write(json.stringify({ ok = false, error = "缺少下载地址" }))
        return
    end

    -- 并发保护
    local status_file = "/tmp/iptv-auth-ota.json"
    if fs.access(status_file) then
        local c = fs.readfile(status_file)
        if c and c:find('"state":"running"', 1, true) then
            local mtime = fs.stat(status_file, "mtime")
            if mtime and (os.time() - mtime <= 300) then
                http.write(json.stringify({ ok = false, error = "已有更新任务在进行中" }))
                return
            end
        end
    end

    -- 严格消毒 URL：只允许 http/https
    if apk_url ~= "" and not apk_url:match("^https?://") then
        http.write(json.stringify({ ok = false, error = "APK URL 协议非法" }))
        return
    end
    if ipk_url ~= "" and not ipk_url:match("^https?://") then
        http.write(json.stringify({ ok = false, error = "IPK URL 协议非法" }))
        return
    end

    sys.call(string.format("/usr/bin/iptv-auth-ota.sh %q %q %q >/tmp/iptv-auth-ota.log 2>&1 &", apk_url, ipk_url, ver))
    http.write(json.stringify({ ok = true, message = "更新任务已启动" }))
end

function get_ota_status()
    -- 轮询 OTA 更新进度
    local http = require "luci.http"
    local fs = require "nixio.fs"
    http.prepare_content("application/json")
    local json = require "luci.jsonc"
    local info = { state = "idle", message = "", version = "" }
    local status_file = "/tmp/iptv-auth-ota.json"
    if fs.access(status_file) then
        local c = fs.readfile(status_file)
        if c then
            local parsed = json.parse(c)
            if parsed then info = parsed end
        end
        if info.state == "running" then
            local mtime = fs.stat(status_file, "mtime")
            if mtime and (os.time() - mtime > 300) then
                info.state = "failed"
                info.message = "更新任务超时（5分钟无变化），请重试"
            end
        end
    end
    http.write(json.stringify(info))
end

function get_interfaces()
    -- 本机网络接口列表（供“上游接口”下拉选择）：
    -- nixio.getifaddrs 的 packet 族枚举全部接口，inet 族取 IPv4，
    -- /sys/class/net/<if>/operstate 取连接状态；过滤回环/容器/隧道等虚拟接口
    local http = require "luci.http"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"
    local nixio = require "nixio"
    local seen, names, ip4 = {}, {}, {}
    for _, v in ipairs(nixio.getifaddrs()) do
        if v.name then
            if v.family == "packet" and not seen[v.name] then
                seen[v.name] = true
                names[#names + 1] = v.name
            elseif v.family == "inet" then
                ip4[v.name] = v.addr or ""
            end
        end
    end
    table.sort(names)
    local list = {}
    for _, name in ipairs(names) do
        -- 排除回环 / Docker / 隧道 / 虚拟接口，避免干扰 IPTV 线路选择
        if not (name == "lo" or name:match("^docker") or name:match("^veth")
            or name:match("^dummy") or name:match("^tun") or name:match("^tap")
            or name:match("^wg") or name:match("^sit") or name:match("^gre")
            or name:match("^erspan") or name:match("^ip6tnl") or name:match("^ip6gre")
            or name:match("^siit") or name:match("^teql") or name:match("^ifb")) then
            local st = fs.readfile("/sys/class/net/" .. name .. "/operstate") or ""
            list[#list + 1] = { name = name, ip = ip4[name] or "", state = st:gsub("%s+", "") }
        end
    end
    http.prepare_content("application/json")
    http.write(json.stringify(list))
end
