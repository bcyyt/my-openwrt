-- statusmon.lua — LuCI controller: 状态监控（独立一级菜单）
-- 部署到 /usr/lib/lua/luci/controller/statusmon.lua
-- v3: 并入原「安全监测」的攻击记录/日志与手动拉黑接口，统一挂到 admin/statusmon/attack/*；
--     状态页改为 admin/statusmon/overview，父节点 admin/statusmon 用 alias 保持旧地址可用；
--     旧路径 admin/status/monitor 保留 302 跳转（兼容历史书签）。

module("luci.controller.statusmon", package.seeall)

local SNAP = "/var/lib/statusmon-attack/snapshot.json"
local EVENTS = "/var/lib/statusmon-attack/events.jsonl"
local CMD = "/var/lib/statusmon-attack/cmd.json"

local function sys_exec(cmd)
	local sys = require "luci.sys"
	return (sys.exec(cmd) or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function index()
	-- 一级叶子页面：父节点 alias 到 overview，保持 admin/statusmon 可直接访问
	entry({"admin", "statusmon"}, alias("admin", "statusmon", "overview"), "状态监控", 3).dependent = false
	entry({"admin", "statusmon", "overview"}, template("statusmon/status")).leaf = true
	-- 旧路径兼容：仅作跳转，不注册标题（避免在 状态 菜单里重复出现）
	entry({"admin", "status", "monitor"}, call("redirect_legacy")).dependent = false

	if require("nixio.fs").access("/usr/bin/statusmon-attack.py") then
		entry({"admin", "statusmon", "attack", "data"}, call("action_attack_data")).leaf = true
		entry({"admin", "statusmon", "attack", "events"}, call("action_attack_events")).leaf = true
		entry({"admin", "statusmon", "attack", "block"}, call("action_attack_block")).leaf = true
		entry({"admin", "statusmon", "attack", "unblock"}, call("action_attack_unblock")).leaf = true
		entry({"admin", "statusmon", "attack", "clear"}, call("action_attack_clear")).leaf = true
		entry({"admin", "statusmon", "attack", "logs"}, call("action_attack_logs")).leaf = true
	end
end

function redirect_legacy()
	local http = require "luci.http"
	local disp = require "luci.dispatcher"
	http.redirect(disp.build_url("admin", "statusmon"))
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
		return { ts = 0, cards = {}, series = {}, attack_summary = {}, blocked = {} }
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

function action_attack_data()
	json_write(read_snap())
end

function action_attack_events()
	local http = require "luci.http"
	local fs = require "nixio.fs"
	local jsonc = require "luci.jsonc"
	local ip = http.formvalue("ip") or ""
	local out = {}
	local raw = fs.readfile(EVENTS) or ""
	for line in raw:gmatch("[^\n]+") do
		local ev = jsonc.parse(line)
		if ev and ev.cat == "attack" and ev.type ~= "probe" and ev.type ~= "scan" and (ip == "" or ev.ip == ip) then
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

-- 「日志」页：按类别返回（pppoe / dhcp / luci / ssh），单次最多最近 2000 条
local LOG_KINDS = { pppoe = true, dhcp = true, luci = true, ssh = true }

function action_attack_logs()
	local http = require "luci.http"
	local fs = require "nixio.fs"
	local jsonc = require "luci.jsonc"
	local kind = http.formvalue("kind") or "pppoe"
	if not LOG_KINDS[kind] then
		json_write({ ok = false, error = "参数无效" })
		return
	end
	local raw = fs.readfile(EVENTS) or ""
	local out = {}
	for line in raw:gmatch("[^\n]+") do
		local ev = jsonc.parse(line)
		if ev then
			local cat, svc = ev.cat, ev.svc
			local hit = false
			if kind == "pppoe" then
				hit = (cat == "pppoe")
			elseif kind == "dhcp" then
				hit = (cat == "dhcp")
			elseif kind == "luci" or kind == "ssh" then
				hit = (svc == kind and cat == "login")
			end
			if hit then
				out[#out + 1] = ev
			end
		end
	end
	local total = #out
	local limit = 2000
	if total > limit then
		local sliced = {}
		for i = total - limit + 1, total do
			sliced[#sliced + 1] = out[i]
		end
		out = sliced
	end
	json_write({ ok = true, kind = kind, total = total, events = out })
end

local function block_list()
	local uci = require("luci.model.uci").cursor()
	local v = uci:get("statusmon", "attack", "block")
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
	uci:delete("statusmon", "attack", "block")
	if #list > 0 then
		if uci.set_list then
			uci:set_list("statusmon", "attack", "block", list)
		else
			for _, x in ipairs(list) do
				uci:add_list("statusmon", "attack", "block", x)
			end
		end
	end
	uci:commit("statusmon")
end

local function apply_nft()
	local out = sys_exec("/usr/bin/statusmon-attack-nft.sh; echo EXIT:$?")
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

function action_attack_block()
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

function action_attack_unblock()
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

-- 手动清除：写命令文件，采集器在下一轮消费后自行清空对应数据并落盘
function action_attack_clear()
	local http = require "luci.http"
	local fs = require "nixio.fs"
	local jsonc = require "luci.jsonc"
	local sys = require "luci.sys"
	local what = http.formvalue("what") or ""
	if what ~= "records" and what ~= "log" then
		json_write({ ok = false, error = "参数无效" })
		return
	end
	fs.writefile(CMD, jsonc.stringify({ [what] = true }))
	local consumed = false
	for _ = 1, 8 do
		if not fs.access(CMD) then
			consumed = true
			break
		end
		-- busybox sleep 不支持小数秒
		sys.call("sleep 1")
	end
	json_write({ ok = true, consumed = consumed })
end
