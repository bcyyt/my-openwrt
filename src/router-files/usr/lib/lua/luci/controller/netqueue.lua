module("luci.controller.netqueue", package.seeall)

local function uci_cur()
	return require("luci.model.uci").cursor()
end

local function sys_exec(cmd)
	local sys = require "luci.sys"
	local s = (sys.exec(cmd) or ""):gsub("^%s+", ""):gsub("%s+$", "")
	return s
end

local function as_list(v)
	if v == nil or v == false then
		return {}
	end
	if type(v) == "table" then
		local out, i, x = {}
		for i, x in ipairs(v) do
			out[#out + 1] = tostring(x)
		end
		if #out > 0 then
			return out
		end
		for i, x in pairs(v) do
			out[#out + 1] = tostring(x)
		end
		return out
	end
	return { tostring(v) }
end

local function first_str(v)
	if type(v) == "table" then
		return tostring(v[1] or v[0] or "")
	end
	return tostring(v or "")
end

local function has_val(v)
	if v == nil or v == "" then
		return false
	end
	if type(v) == "table" then
		return next(v) ~= nil
	end
	return true
end

local function flag(v)
	return v == "1" or v == true or v == 1
end

local function bit(v)
	return flag(v) and 1 or 0
end

local function dns_names(uci)
	local names = {}
	uci:foreach("dhcp", "dnsmasq", function(s)
		names[#names + 1] = s[".name"]
	end)
	return names
end

local function option6(uci)
	local i, o
	for i, o in ipairs(as_list(uci:get("dhcp", "lan", "dhcp_option"))) do
		if type(o) == "string" and o:match("^6,") then
			return o:sub(3)
		end
	end
	return ""
end

local function set_option6(uci, val)
	local keep, i, o = {}
	for i, o in ipairs(as_list(uci:get("dhcp", "lan", "dhcp_option"))) do
		if not (type(o) == "string" and o:match("^6,")) then
			keep[#keep + 1] = o
		end
	end
	if val and val ~= "" then
		keep[#keep + 1] = "6," .. val
	end
	uci:delete("dhcp", "lan", "dhcp_option")
	if #keep > 0 then
		uci:set("dhcp", "lan", "dhcp_option", keep)
	end
end

local function wan_dns()
	return sys_exec("awk '/^nameserver/{print $2}' /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null | awk 'NF && !a[$0]++' | tr '\\n' ' '"):gsub("%s+$", "")
end

function collect_info()
	local uci = uci_cur()
	local dns = dns_names(uci)[1]
	local server = dns and uci:get("dhcp", dns, "server") or nil
	local noresolv = dns and uci:get("dhcp", dns, "noresolv") or "0"
	local opt6 = option6(uci)
	return {
		fwd = {
			enabled = bit(uci:get("netqueue", "main", "enabled")),
			nic_queues = bit(uci:get("netqueue", "main", "nic_queues")),
			cpu_performance = bit(uci:get("netqueue", "main", "cpu_performance")),
			flow_offload = bit(uci:get("netqueue", "main", "flow_offload")),
			pppoe_qlen = bit(uci:get("netqueue", "main", "pppoe_qlen")),
			udp_gro = bit(uci:get("netqueue", "main", "udp_gro")),
			rx_backlog = bit(uci:get("netqueue", "main", "rx_backlog"))
		},
		dhcp = {
			enable = (uci:get("dhcp", "lan", "ignore") == "1") and 0 or 1,
			start = first_str(uci:get("dhcp", "lan", "start")),
			limit = first_str(uci:get("dhcp", "lan", "limit")),
			leasetime = first_str(uci:get("dhcp", "lan", "leasetime")),
			sequential = dns and bit(uci:get("dhcp", dns, "sequential_ip")) or 0,
			client_dns = (opt6 ~= "") and "custom" or "router",
			client_dns_addr = opt6,
			lan = first_str(uci:get("network", "lan", "ipaddr"))
		},
		dns = {
			mode = (noresolv == "1" and has_val(server)) and "custom" or "wan",
			servers = as_list(server),
			cachesize = first_str(dns and uci:get("dhcp", dns, "cachesize") or ""),
			wan = wan_dns()
		},
		leases = tonumber(sys_exec("grep -c . /tmp/dhcp.leases 2>/dev/null")) or 0,
		status = sys_exec("/usr/bin/netqueue-apply.sh status 2>/dev/null")
	}
end

function index()
	if not require("nixio.fs").access("/usr/bin/netqueue-apply.sh") then
		return
	end
	entry({"admin", "network", "netqueue"}, call("action_page"), _("系统优化"), 90).dependent = false
end

function action_page()
	local http = require "luci.http"
	local act = http.formvalue("act")
	if act == "info" then
		action_info()
		return
	end
	if act == "save" then
		action_save()
		return
	end
	require("luci.template").render("netqueue/index")
end

function action_info()
	local http = require "luci.http"
	local jsonc = require "luci.jsonc"
	http.prepare_content("application/json")
	local ok, data = pcall(collect_info)
	if not ok then
		http.write(string.format('{"ok":false,"error":%s}', jsonc.stringify(tostring(data)) or '""'))
		return
	end
	http.write(jsonc.stringify(data) or "{}")
end

function action_save()
	local http = require "luci.http"
	local jsonc = require "luci.jsonc"
	local sys = require "luci.sys"
	local raw = http.content and http.content() or ""
	local req = jsonc.parse(raw or "") or {}
	local ok, err = pcall(function()
	local uci = uci_cur()
	local fwd = req.fwd or {}
	local dhcp = req.dhcp or {}
	local dns = req.dns or {}

	uci:set("netqueue", "main", "enabled", flag(fwd.enabled) and "1" or "0")
	uci:set("netqueue", "main", "nic_queues", flag(fwd.nic_queues) and "1" or "0")
	uci:set("netqueue", "main", "cpu_performance", flag(fwd.cpu_performance) and "1" or "0")
	uci:set("netqueue", "main", "flow_offload", flag(fwd.flow_offload) and "1" or "0")
	uci:set("netqueue", "main", "pppoe_qlen", flag(fwd.pppoe_qlen) and "1" or "0")
	uci:set("netqueue", "main", "udp_gro", flag(fwd.udp_gro) and "1" or "0")
	uci:set("netqueue", "main", "rx_backlog", flag(fwd.rx_backlog) and "1" or "0")
	uci:commit("netqueue")

	if flag(dhcp.enable) then
		uci:delete("dhcp", "lan", "ignore")
	else
		uci:set("dhcp", "lan", "ignore", "1")
	end
	if dhcp.start and tostring(dhcp.start) ~= "" then
		uci:set("dhcp", "lan", "start", tostring(dhcp.start))
	end
	if dhcp.limit and tostring(dhcp.limit) ~= "" then
		uci:set("dhcp", "lan", "limit", tostring(dhcp.limit))
	end
	if dhcp.leasetime and tostring(dhcp.leasetime) ~= "" then
		uci:set("dhcp", "lan", "leasetime", tostring(dhcp.leasetime))
	end
	if dhcp.client_dns == "custom" and dhcp.client_dns_addr and dhcp.client_dns_addr ~= "" then
		set_option6(uci, tostring(dhcp.client_dns_addr):gsub("%s+", ","))
	else
		set_option6(uci, "")
	end

	local names = dns_names(uci)
	local servers, i, s, n = {}
	for i, s in ipairs(as_list(dns.servers)) do
		s = tostring(s or ""):gsub("%s+", "")
		if s ~= "" then
			servers[#servers + 1] = s
		end
	end
	for i, n in ipairs(names) do
		uci:set("dhcp", n, "sequential_ip", flag(dhcp.sequential) and "1" or "0")
		if dns.cachesize and tostring(dns.cachesize) ~= "" then
			uci:set("dhcp", n, "cachesize", tostring(dns.cachesize))
		end
		if dns.mode == "custom" and #servers > 0 then
			uci:set("dhcp", n, "server", servers)
			uci:set("dhcp", n, "noresolv", "1")
		else
			uci:delete("dhcp", n, "server")
			uci:set("dhcp", n, "noresolv", "0")
			uci:set("dhcp", n, "resolvfile", "/tmp/resolv.conf.d/resolv.conf.auto")
		end
	end
	uci:commit("dhcp")
	sys.call("/etc/init.d/netqueue reload >/dev/null 2>&1")
	sys.call("/etc/init.d/dnsmasq restart >/dev/null 2>&1")
	end)
	http.prepare_content("application/json")
	if not ok then
		http.write(string.format('{"ok":false,"error":%s}', jsonc.stringify(tostring(err)) or '""'))
		return
	end
	local info_ok, info = pcall(collect_info)
	if info_ok and info then
		http.write(string.format('{"ok":true,"info":%s}', jsonc.stringify(info) or "{}"))
	else
		http.write('{"ok":true}')
	end
end
