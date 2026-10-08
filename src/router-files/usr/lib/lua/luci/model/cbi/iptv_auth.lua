-- iptv_auth.lua — LuCI CBI 模型（中兴 IPTV 鉴权配置页）
-- 菜单：系统 → 服务 → IPTV 鉴权
local m = Map("iptv-auth", translate("IPTV 鉴权配置"),
    translate("中兴 IPTV 三步鉴权 + 频道抓取 + M3U 生成。rtp2httpd 读取生成的 M3U 文件提供直播/回看/FCC 代理。"))

local s = m:section(TypedSection, "main", translate("鉴权信息"))
s.addremove = false
s:option(Value, "iptv_server", translate("IPTV 鉴权服务器"))
s:option(Value, "userid", translate("UserID"))
s:option(Value, "authenticator", translate("Authenticator"))
s:option(Value, "stbip", translate("StbIP"))
s:option(Value, "lasttermno", translate("LastTermno"))
s:option(Value, "usergroupnmb", translate("UserGroupNMB"))
s:option(Value, "epggroupnmb", translate("EPGGroupNMB"))
s:option(Value, "usertoken", translate("UserToken"))
s:option(Value, "stbid", translate("STBID"))
s:option(Value, "stbinfo", translate("stbinfo"))

local s2 = m:section(TypedSection, "main", translate("网络配置"))
s2.addremove = false
s2:option(Value, "live_port", translate("直播端口")).datatype = "port"
s2:option(Value, "replay_port", translate("回看端口")).datatype = "port"
s2:option(Value, "upstream_interface", translate("上游接口（选后自动走该口，不改主路由）"))

local s3 = m:section(TypedSection, "main", translate("频道过滤"))
s3.addremove = false
s3:option(Flag, "filter_pip", translate("过滤 PIP 频道"))
s3:option(Value, "filter_keywords", translate("过滤关键词（逗号分隔）"))

local s4 = m:section(TypedSection, "main", translate("定时与节目单"))
s4.addremove = false
s4:option(Value, "interval", translate("间隔（小时）")).datatype = "range(1,24)"
s4:option(Flag, "epg_enabled", translate("获取节目单"))

m.on_after_commit = function(self)
    require("luci.sys").call("/etc/init.d/iptv-auth restart >/dev/null 2>&1")
end

return m
