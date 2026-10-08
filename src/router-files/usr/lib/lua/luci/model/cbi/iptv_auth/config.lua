-- config.lua — LuCI CBI 配置页（鉴权 + rtp2httpd 合并）
-- 保存即自动执行：检测到 cbi 表单提交（保存/保存&应用）时重启服务，
-- init.d 会以新 UCI 参数拉起 rtp2httpd + iptv-auth，iptv-auth 启动即执行
-- 鉴权 + 频道获取（不依赖 cbi 内部 autoapply 机制，兼容 luci-compat）
local http0 = require "luci.http"
if http0.formvalue("cbi.submit") ~= nil or http0.formvalue("cbi.apply") ~= nil then
    require("luci.sys").call("/etc/init.d/iptv-auth restart >/dev/null 2>&1")
end

local sys = require "luci.sys"
local pkg_ver_raw = sys.exec("apk list --installed 2>/dev/null | grep '^iptv-auth-' | head -1") or ""
local pkg_ver = pkg_ver_raw:match("^iptv%-auth%-(%S+)%s") or ""
if pkg_ver == "" then
    pkg_ver_raw = sys.exec("opkg list-installed 2>/dev/null | grep '^iptv-auth ' | head -1") or ""
    pkg_ver = pkg_ver_raw:match("%-%s+(%S+)") or "unknown"
end

local m = Map("iptv-auth", translate("IPTV 代理配置"),
    translate("中兴 IPTV 鉴权 + 频道抓取 + M3U 生成 + rtp2httpd 直播/回看/FCC 代理。所有设置在此页面统一配置。保存后自动执行一次鉴权与频道获取。"))

-- ============ 鉴权信息 ============
local s1 = m:section(NamedSection, "main", "iptv-auth", translate("鉴权信息"))
s1.addremove = false

local o_ver = s1:option(DummyValue, "_pkg_version", translate("插件版本"))
o_ver.rawhtml = true
o_ver.cfgvalue = function()
    return '<span style="display:inline-block;background:linear-gradient(135deg,#4a90d9,#357abd);color:#fff;font-size:12px;font-weight:600;padding:3px 12px;border-radius:12px;box-shadow:0 2px 6px rgba(74,144,217,0.25);">v' .. pkg_ver .. '</span>'
end
s1:option(Value, "iptv_server", translate("IPTV 鉴权服务器"))
s1:option(Value, "userid", translate("UserID"))
s1:option(Value, "authenticator", translate("Authenticator"))
s1:option(Value, "stbip", translate("StbIP"))
s1:option(Value, "lasttermno", translate("LastTermno"))
s1:option(Value, "usergroupnmb", translate("UserGroupNMB"))
s1:option(Value, "epggroupnmb", translate("EPGGroupNMB"))
s1:option(Value, "usertoken", translate("UserToken"))
s1:option(Value, "stbid", translate("STBID"))
s1:option(Value, "stbinfo", translate("stbinfo"))

-- ============ 网络与代理配置 ============
local s2 = m:section(NamedSection, "main", "iptv-auth", translate("网络与代理配置"))
s2.addremove = false
o_lp = s2:option(Value, "live_port", translate("直播端口（rtp2httpd 监听）"))
o_lp.datatype = "port"
o_lp.placeholder = "23234"
o_rp = s2:option(Value, "replay_port", translate("回看端口（RTSP 代理监听）"))
o_rp.datatype = "port"
o_rp.placeholder = "554"
s2:option(Value, "upstream_interface", translate("上游接口（IPTV 线路）")).placeholder = "eth1"
s2:option(Flag, "bind_wan2", translate("绑定 wan2（策略路由，不改主表）"))

-- ============ rtp2httpd 参数 ============
local s3 = m:section(NamedSection, "main", "iptv-auth", translate("rtp2httpd 参数"))
s3.addremove = false
o_w = s3:option(Value, "rtp2h_workers", translate("工作线程数"))
o_w.datatype = "range(1,16)"
o_w.placeholder = "4"
o_rb = s3:option(Value, "rtp2h_rcvbuf", translate("UDP 接收缓冲（字节）"))
o_rb.datatype = "integer"
o_rb.placeholder = "1572864"
o_bp = s3:option(Value, "rtp2h_bufpool", translate("缓冲池大小"))
o_bp.datatype = "integer"
o_bp.placeholder = "32768"

-- ============ 频道过滤 ============
local s4 = m:section(NamedSection, "main", "iptv-auth", translate("频道过滤"))
s4.addremove = false
s4:option(Flag, "filter_pip", translate("过滤 PIP 频道"))
s4:option(Value, "filter_keywords", translate("过滤关键词（逗号分隔）"))

-- ============ 定时与节目单 ============
local s5 = m:section(NamedSection, "main", "iptv-auth", translate("定时任务与节目单"))
s5.addremove = false
o_int = s5:option(Value, "interval", translate("执行间隔（小时）"))
o_int.datatype = "range(1,24)"
o_int.placeholder = "10"
s5:option(Flag, "epg_enabled", translate("获取节目单（EPG）"))

-- ============ rtp2httpd 更新 ============
local s6 = m:section(NamedSection, "main", "iptv-auth", translate("rtp2httpd 更新"))
s6.addremove = false

local cur_ver = sys.exec("/usr/bin/rtp2httpd --help 2>&1 | grep -oE '[0-9]+\\.[0-9]+\\.[0-9]+' | head -1") or ""
cur_ver = cur_ver:gsub("%s+", "")

local o_cur = s6:option(DummyValue, "_r2h_current_ver", translate("当前版本"))
o_cur.rawhtml = true
o_cur.cfgvalue = function() return cur_ver end

local o_mirror = s6:option(Value, "update_mirror", translate("下载镜像前缀（可选）"))
o_mirror.placeholder = "留空直连 GitHub；如 https://ghproxy.net/"
o_mirror.rmempty = true

local o_ui = s6:option(DummyValue, "_r2h_update_ui", translate("检查并更新"))
o_ui.rawhtml = true
o_ui.cfgvalue = function()
return [==[
<div id="r2h-box">
  <div>
    <button type="button" class="cbi-button cbi-button-apply" id="r2h-btn-check" disabled>检查更新</button>
    <button type="button" class="cbi-button cbi-button-positive" id="r2h-btn-update" onclick="r2hUpdate()" disabled>立即更新</button>
    <span id="r2h-msg" style="margin-left:10px;color:#888;">正在检查版本…</span>
  </div>
  <div id="r2h-detail" style="margin-top:8px;color:#666;font-size:13px;"></div>
</div>
<script type="text/javascript">
var R2H_BASE = '/cgi-bin/luci/admin/services/iptv_auth/';
var R2H = { latest: '', current: '', timer: null };
function r2hEl(id) { return document.getElementById(id); }
function r2hMsg(t, c) { var el = r2hEl('r2h-msg'); el.textContent = t || ''; el.style.color = c || '#888'; }
function r2hButtons(check, update) { r2hEl('r2h-btn-check').disabled = !check; r2hEl('r2h-btn-update').disabled = !update; }
function r2hCmpVer(a, b) {
    var pa = (a || '0').split('.'), pb = (b || '0').split('.');
    for (var i = 0; i < 3; i++) {
        var x = parseInt(pa[i] || '0', 10), y = parseInt(pb[i] || '0', 10);
        if (x !== y) return x - y;
    }
    return 0;
}
function r2hCheck() {
    r2hButtons(false, false);
    r2hMsg('正在查询最新版本…');
    fetch(R2H_BASE + 'rtp2httpd_check', { credentials: 'same-origin' })
        .then(function(r) { return r.json(); })
        .then(function(d) {
            R2H.current = d.current; R2H.latest = d.latest;
            if (d.error) {
                r2hMsg(d.error, '#d9534f');
                r2hButtons(true, false);
                return;
            }
            r2hButtons(true, true);
            if (r2hCmpVer(d.latest, d.current) <= 0) {
                r2hMsg('已是最新版本 v' + d.current + '（如遇异常可点“立即更新”重装修复）', '#2eb872');
            } else {
                r2hMsg('发现新版本 v' + d.latest + '（当前 v' + d.current + '）', '#f0ad4e');
            }
        })
        .catch(function(e) { r2hMsg('查询失败: ' + e, '#d9534f'); r2hButtons(true, false); });
}
function r2hUpdate() {
    var same = R2H.latest && r2hCmpVer(R2H.latest, R2H.current) <= 0;
    var tip = same
        ? '当前已是最新版本 v' + R2H.current + '，仍要重新下载并安装吗？（用于修复异常，直播约中断 5-8 秒）'
        : '确认更新 rtp2httpd 到 v' + (R2H.latest || '最新') + '？更新期间直播约中断 5-8 秒';
    if (!confirm(tip)) return;
    r2hButtons(false, false);
    r2hMsg('正在启动更新…');
    var qs = R2H.latest ? ('?version=' + R2H.latest) : '?version=latest';
    fetch(R2H_BASE + 'rtp2httpd_update' + qs, { credentials: 'same-origin' })
        .then(function(r) { return r.json(); })
        .then(function(d) {
            if (!d.started) { r2hMsg(d.error || '启动失败', '#d9534f'); r2hButtons(true, true); return; }
            r2hPoll();
        })
        .catch(function(e) { r2hMsg('请求失败: ' + e, '#d9534f'); r2hButtons(true, true); });
}
function r2hPoll() {
    var idleCount = 0;
    R2H.timer = setInterval(function() {
        fetch(R2H_BASE + 'rtp2httpd_update_status', { credentials: 'same-origin' })
            .then(function(r) { return r.json(); })
            .then(function(d) {
                r2hEl('r2h-detail').textContent = d.message || '';
                if (d.state == 'running') {
                    idleCount = 0;
                    r2hMsg('更新进行中：' + (d.message || ''), '#888');
                } else if (d.state == 'idle') {
                    // 启动间隙容错：脚本尚未写入首个状态，短暂等待；连续3次仍无状态才判失败
                    idleCount++;
                    if (idleCount >= 3) {
                        clearInterval(R2H.timer);
                        r2hButtons(true, true);
                        r2hMsg('更新失败：任务未能启动', '#d9534f');
                    } else {
                        r2hMsg('正在启动更新任务…', '#888');
                    }
                } else {
                    clearInterval(R2H.timer);
                    r2hButtons(true, true);
                    if (d.state == 'done') {
                        r2hMsg('更新成功：' + (d.message || ''), '#2eb872');
                        setTimeout(function() { location.reload(); }, 1500);
                    } else {
                        r2hMsg('更新失败：' + (d.message || ''), '#d9534f');
                    }
                }
            })
            .catch(function(e) {
                clearInterval(R2H.timer);
                r2hMsg('状态查询失败: ' + e, '#d9534f');
                r2hButtons(true, true);
            });
    }, 2000);
}
r2hEl('r2h-btn-check').onclick = r2hCheck;
r2hCheck();
</script>
]==]
end

-- 保存后自动执行已由文件顶部处理（兼容 luci-compat，不依赖 autoapply）
return m
