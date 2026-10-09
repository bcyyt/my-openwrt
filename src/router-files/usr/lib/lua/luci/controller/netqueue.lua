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

local function norm_mac(m)
	m = first_str(m):lower():gsub("-", ":"):gsub("%s+", "")
	if not m:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
		return ""
	end
	return m
end

local function parse_ip(ip)
	local a, b, c, d = tostring(ip or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a then
		return nil
	end
	a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
	if a > 255 or b > 255 or c > 255 or d > 255 then
		return nil
	end
	return a * 16777216 + b * 65536 + c * 256 + d
end

local function mask_num(mask)
	local n = parse_ip(mask)
	if n then
		return n
	end
	local bits = tonumber(mask)
	if bits and bits >= 0 and bits <= 32 then
		if bits == 0 then
			return 0
		end
		return 4294967295 - (2 ^ (32 - bits) - 1)
	end
	return parse_ip("255.255.255.0")
end

local function lan_net()
	local uci = uci_cur()
	local raw = first_str(uci:get("network", "lan", "ipaddr"))
	local ip, cidr = raw:match("^([^/]+)/(%d+)$")
	if not ip then
		ip = raw
	end
	local mask = first_str(uci:get("network", "lan", "netmask"))
	if cidr then
		mask = cidr
	end
	if mask == "" then
		mask = "255.255.255.0"
	end
	return parse_ip(ip), mask_num(mask), ip
end

local function ip_in_lan(ip)
	local ipn = parse_ip(ip)
	local lan, mask, lanip = lan_net()
	if not ipn or not lan or not mask then
		return false, "地址无效"
	end
	if ipn == lan then
		return false, "不能用网关地址"
	end
	local function band(a, b)
		local r, p = 0, 1
		while a > 0 and b > 0 do
			if a % 2 == 1 and b % 2 == 1 then
				r = r + p
			end
			a = math.floor(a / 2)
			b = math.floor(b / 2)
			p = p * 2
		end
		return r
	end
	if band(ipn, mask) ~= band(lan, mask) then
		return false, "不在 LAN 网段"
	end
	local bcast = band(lan, mask) + (4294967295 - mask)
	if ipn == band(lan, mask) or ipn == bcast then
		return false, "不能用网络号或广播地址"
	end
	return true, lanip
end

local function collect_clients()
	local uci = uci_cur()
	local now = os.time()
	local bymac, order = {}, {}
	local function ensure(mac)
		if not bymac[mac] then
			bymac[mac] = {mac = mac, ip = "", name = "", exp = 0, remain = 0, static = 0, sip = "", neigh = ""}
			order[#order + 1] = mac
		end
		return bymac[mac]
	end
	local f = io.open("/tmp/dhcp.leases", "r")
	if f then
		for line in f:lines() do
			local exp, mac, ip, name = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
			mac = norm_mac(mac)
			if mac ~= "" then
				local expn = tonumber(exp) or 0
				if expn >= now then
					local c = ensure(mac)
					c.ip = ip or ""
					c.exp = expn
					c.remain = expn - now
					if name and name ~= "*" then
						c.name = name
					end
				end
			end
		end
		f:close()
	end
	uci:foreach("dhcp", "host", function(s)
		local mac = norm_mac(s.mac)
		if mac == "" then
			return
		end
		local c = ensure(mac)
		c.static = 1
		c.sip = first_str(s.ip)
		if c.ip == "" then
			c.ip = c.sip
		end
		if c.name == "" and s.name then
			c.name = first_str(s.name)
		end
	end)
	local p = io.popen("ip -4 neigh show dev br-lan 2>/dev/null")
	if p then
		for line in p:lines() do
			local ip = line:match("^(%S+)")
			local mac = norm_mac(line:match("lladdr%s+(%S+)"))
			local st = line:match("(%S+)$") or ""
			if mac ~= "" and ip and st ~= "FAILED" then
				local c = ensure(mac)
				if st == "REACHABLE" or st == "DELAY" or st == "PROBE" then
					c.neigh = st
					if c.ip == "" then
						c.ip = ip
					end
				elseif c.neigh == "" then
					c.neigh = st
					if c.ip == "" then
						c.ip = ip
					end
				end
			end
		end
		p:close()
	end
	local list, i, mac = {}
	for i, mac in ipairs(order) do
		list[#list + 1] = bymac[mac]
	end
	return list
end

local function find_host_section(uci, mac)
	local found = nil
	uci:foreach("dhcp", "host", function(s)
		if found then
			return
		end
		if norm_mac(s.mac) == mac then
			found = s[".name"]
		end
	end)
	return found
end

local function ip_used_by_other(uci, ip, mac)
	local used = false
	uci:foreach("dhcp", "host", function(s)
		if first_str(s.ip) == ip and norm_mac(s.mac) ~= mac then
			used = true
		end
	end)
	return used
end

local function lease_ip_for_mac(mac)
	local f = io.open("/tmp/dhcp.leases", "r")
	if not f then
		return ""
	end
	local old = ""
	for line in f:lines() do
		local exp, m, ip = line:match("^(%S+)%s+(%S+)%s+(%S+)")
		if norm_mac(m) == mac then
			old = ip or ""
			break
		end
	end
	f:close()
	return old
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
	local data = {
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
			lan = first_str(uci:get("network", "lan", "ipaddr")),
			neigh_gc = first_str(uci:get("netqueue", "main", "neigh_gc"))
		},
		dns = {
			mode = (noresolv == "1" and has_val(server)) and "custom" or "wan",
			servers = as_list(server),
			cachesize = first_str(dns and uci:get("dhcp", dns, "cachesize") or ""),
			wan = wan_dns()
		},
		clients = collect_clients(),
		leases = 0,
		status = sys_exec("/usr/bin/netqueue-apply.sh status 2>/dev/null")
	}
	local n = 0
	local i, c
	for i, c in ipairs(data.clients or {}) do
		if (tonumber(c.remain) or 0) > 0 then
			n = n + 1
		end
	end
	data.leases = n
	if data.dhcp.neigh_gc == "" then
		data.dhcp.neigh_gc = "60"
	end
	return data
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
	if act == "static" then
		action_static()
		return
	end
	if act == "dynamic" then
		action_dynamic()
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
	local gc = tonumber(tostring(dhcp.neigh_gc or ""):match("^%d+"))
	if not gc then
		gc = 60
	end
	if gc < 5 then gc = 5 end
	if gc > 86400 then gc = 86400 end
	uci:set("netqueue", "main", "neigh_gc", tostring(gc))
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

local function write_action_result(ok, err)
	local http = require "luci.http"
	local jsonc = require "luci.jsonc"
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

function action_static()
	local http = require "luci.http"
	local jsonc = require "luci.jsonc"
	local sys = require "luci.sys"
	local raw = http.content and http.content() or ""
	local req = jsonc.parse(raw or "") or {}
	local mac = norm_mac(req.mac)
	local ip = tostring(req.ip or ""):gsub("%s+", "")
	local name = tostring(req.name or ""):gsub("[%c\"'\\]", "")
	if #name > 32 then
		name = name:sub(1, 32)
	end
	if mac == "" then
		write_action_result(false, "MAC 无效")
		return
	end
	local ok_ip, why = ip_in_lan(ip)
	if not ok_ip then
		write_action_result(false, why or "地址无效")
		return
	end
	local ok, err = pcall(function()
		local uci = uci_cur()
		if ip_used_by_other(uci, ip, mac) then
			error("该 IP 已被其他终端绑定")
		end
		local old = lease_ip_for_mac(mac)
		local sec = find_host_section(uci, mac)
		if not sec then
			sec = uci:add("dhcp", "host")
		end
		uci:set("dhcp", sec, "mac", mac)
		uci:set("dhcp", sec, "ip", ip)
		uci:set("dhcp", sec, "dns", "1")
		if name ~= "" then
			uci:set("dhcp", sec, "name", name)
		end
		uci:commit("dhcp")
		if old == "" then
			old = "-"
		end
		sys.exec("/usr/bin/netqueue-apply.sh dhcp-kick '" .. mac .. "' '" .. old .. "' '" .. ip .. "'")
	end)
	write_action_result(ok, err)
end

function action_dynamic()
	local http = require "luci.http"
	local jsonc = require "luci.jsonc"
	local sys = require "luci.sys"
	local raw = http.content and http.content() or ""
	local req = jsonc.parse(raw or "") or {}
	local mac = norm_mac(req.mac)
	if mac == "" then
		write_action_result(false, "MAC 无效")
		return
	end
	local ok, err = pcall(function()
		local uci = uci_cur()
		local old = lease_ip_for_mac(mac)
		local sec = find_host_section(uci, mac)
		if sec then
			uci:delete("dhcp", sec)
			uci:commit("dhcp")
		end
		if old == "" then
			old = "-"
		end
		sys.exec("/usr/bin/netqueue-apply.sh dhcp-kick '" .. mac .. "' '" .. old .. "' '-'")
	end)
	write_action_result(ok, err)
end
