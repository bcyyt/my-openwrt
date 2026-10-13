module("luci.controller.atkmon", package.seeall)

local SNAP = "/var/lib/atkmon/snapshot.json"

local function sys_exec(cmd)
	local sys = require "luci.sys"
	return (sys.exec(cmd) or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function index()
	if not require("nixio.fs").access("/usr/bin/atkmon-collect.py") then
		return
	end
	-- First-level leaf, same pattern as 状态监控 (admin/statusmon).
	-- Parent aliases to the page so APIs under admin/atkmon/* still dispatch.
	entry({"admin", "atkmon"}, alias("admin", "atkmon", "overview"), _("安全监测"), 4).dependent = false
	entry({"admin", "atkmon", "overview"}, template("atkmon/status")).leaf = true
	entry({"admin", "atkmon", "data"}, call("action_data")).leaf = true
	entry({"admin", "atkmon", "events"}, call("action_events")).leaf = true
	entry({"admin", "atkmon", "block"}, call("action_block")).leaf = true
	entry({"admin", "atkmon", "unblock"}, call("action_unblock")).leaf = true
end

local function json_write(obj)
	local http = require "luci.http"
	local jsonc = require "luci.jsonc"
	http.prepare_content("application/json")
	http.write(jsonc.stringify(obj) or "{}")
end

local function read_snap()
	local fs = require "nixio.fs"
	local jsonc = require "luci.jsonc"
	local raw = fs.readfile(SNAP) or ""
	if raw == "" then
		return { ts = 0, cards = {}, series = {}, attack_summary = {}, pppoe = {}, dns = {}, iptv = {}, dhcp = {}, blocked = {} }
	end
	return jsonc.parse(raw) or {}
end

local function valid_ip(s)
	s = tostring(s or "")
	if s:match("^%d+%.%d+%.%d+%.%d+$") then
		return true
	end
	if s:match(":") and s:match("^[%x:]+$") then
		return true
	end
	return false
end

local function is_lan_ip(ip)
	if ip:match("^127%.") or ip == "::1" then
		return true
	end
	if ip:match("^192%.168%.") or ip:match("^10%.") then
		return true
	end
	local a = ip:match("^172%.(%d+)%.")
	a = tonumber(a)
	if a and a >= 16 and a <= 31 then
		return true
	end
	local low = ip:lower()
	if low:match("^fe80:") or low:match("^fd") or low:match("^fc") then
		return true
	end
	return false
end

function action_data()
	json_write(read_snap())
end

function action_events()
	local http = require "luci.http"
	local fs = require "nixio.fs"
	local jsonc = require "luci.jsonc"
	local ip = http.formvalue("ip") or ""
	local out = {}
	local raw = fs.readfile("/var/lib/atkmon/events.jsonl") or ""
	for line in raw:gmatch("[^\n]+") do
		local ev = jsonc.parse(line)
		if ev and ev.type ~= "probe" and ev.type ~= "scan" and (ip == "" or ev.ip == ip) then
			out[#out + 1] = ev
		end
	end
	local n = #out
	if n > 50 then
		local sliced = {}
		for i = n - 49, n do
			sliced[#sliced + 1] = out[i]
		end
		out = sliced
	end
	json_write({ ok = true, events = out })
end

local function block_list()
	local uci = require("luci.model.uci").cursor()
	local v = uci:get("atkmon", "main", "block")
	local out = {}
	if type(v) == "table" then
		for _, x in ipairs(v) do
			out[#out + 1] = tostring(x)
		end
	elseif v and v ~= "" then
		for x in tostring(v):gmatch("%S+") do
			out[#out + 1] = x
		end
	end
	return out, uci
end

local function save_block(uci, list)
	uci:delete("atkmon", "main", "block")
	if #list > 0 then
		if uci.set_list then
			uci:set_list("atkmon", "main", "block", list)
		else
			for _, x in ipairs(list) do
				uci:add_list("atkmon", "main", "block", x)
			end
		end
	end
	uci:commit("atkmon")
end

local function apply_nft()
	local out = sys_exec("/usr/bin/atkmon-nft.sh; echo EXIT:$?")
	if out:match("EXIT:[1-9]") then
		return false, out
	end
	return true, out
end

local function read_ip()
	local http = require "luci.http"
	local jsonc = require "luci.jsonc"
	local ip = http.formvalue("ip") or ""
	if ip == "" then
		local ok, body = pcall(function()
			return jsonc.parse(http.content() or "")
		end)
		if ok and type(body) == "table" then
			ip = tostring(body.ip or "")
		end
	end
	return ip
end

function action_block()
	local ip = read_ip()
	if not valid_ip(ip) then
		json_write({ ok = false, error = "地址无效" })
		return
	end
	if is_lan_ip(ip) then
		json_write({ ok = false, error = "不能拉黑局域网或本机地址" })
		return
	end
	local list, uci = block_list()
	local found = false
	for _, x in ipairs(list) do
		if x == ip then found = true end
	end
	if not found then
		list[#list + 1] = ip
	end
	save_block(uci, list)
	local ok, detail = apply_nft()
	if not ok then
		json_write({ ok = false, error = "防火墙写入失败", blocked = list, detail = detail })
		return
	end
	json_write({ ok = true, blocked = list })
end

function action_unblock()
	local ip = read_ip()
	local list, uci = block_list()
	local keep = {}
	for _, x in ipairs(list) do
		if x ~= ip then keep[#keep + 1] = x end
	end
	save_block(uci, keep)
	local ok, detail = apply_nft()
	if not ok then
		json_write({ ok = false, error = "防火墙写入失败", blocked = keep, detail = detail })
		return
	end
	json_write({ ok = true, blocked = keep })
end
