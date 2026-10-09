local m = Map("netqueue", translate("转发优化"),
	translate("网卡队列、CPU、PPPoE 发送队列、UDP GRO、接收积压、软件流量分载。保存后立即生效；WAN 重拨后会自动再套网卡相关项。关闭总开关会恢复系统默认。"))

local s = m:section(TypedSection, "main", translate("开关"))
s.addremove = false
s.anonymous = true

local en = s:option(Flag, "enabled", translate("启用转发优化"))
en.rmempty = false

local nic = s:option(Flag, "nic_queues", translate("网卡队列绑定"))
nic.rmempty = false
nic.description = translate("IRQ/XPS 按队列绑核。PPPoE 物理口用 RPS 打到全部 CPU；其它多队列网卡关闭 RPS，走硬件 RSS。")
nic:depends("enabled", "1")

local cpu = s:option(Flag, "cpu_performance", translate("CPU 性能模式"))
cpu.rmempty = false
cpu.description = translate("全部 CPU 使用 performance 调速，降低小包突发时的爬频延迟。")
cpu:depends("enabled", "1")

local flow = s:option(Flag, "flow_offload", translate("软件流量分载"))
flow.rmempty = false
flow.description = translate("打开防火墙 Software flow offload，减轻 conntrack 转发开销。硬件分载保持关闭。")
flow:depends("enabled", "1")

local pq = s:option(Flag, "pppoe_qlen", translate("PPPoE 发送队列"))
pq.rmempty = false
pq.description = translate("把 pppoe-wan 的 txqueuelen 从默认 3 提到 1000，减轻突发上传卡住。")
pq:depends("enabled", "1")

local ug = s:option(Flag, "udp_gro", translate("UDP GRO 转发"))
ug.rmempty = false
ug.description = translate("打开网卡 rx-udp-gro-forwarding，降低 QUIC / IPTV UDP 转发 CPU。")
ug:depends("enabled", "1")

local bl = s:option(Flag, "rx_backlog", translate("加大接收积压"))
bl.rmempty = false
bl.description = translate("net.core.netdev_max_backlog 从 1000 提到 4096，小包突发少丢。")
bl:depends("enabled", "1")

local st = s:option(DummyValue, "_status", translate("当前生效"))
st.rawhtml = true
function st.cfgvalue()
	local sys = require "luci.sys"
	local util = require "luci.util"
	local t = sys.exec("/usr/bin/netqueue-apply.sh status 2>/dev/null") or ""
	t = util.pcdata(t)
	return "<pre style=\"white-space:pre-wrap;margin:0;font-size:12px;line-height:1.45\">" .. t .. "</pre>"
end

function m.on_after_commit(self)
	require("luci.sys").call("/etc/init.d/netqueue reload >/dev/null 2>&1")
end

return m
