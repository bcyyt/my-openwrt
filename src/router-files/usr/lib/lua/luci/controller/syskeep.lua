module("luci.controller.syskeep", package.seeall)

local function sys_exec(cmd)
	local sys = require "luci.sys"
	return (sys.exec(cmd) or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function index()
	if not require("nixio.fs").access("/usr/bin/syskeep-upgrade.sh") then
		return
	end
	entry({"admin", "system", "syskeep"}, template("syskeep/index"), _("保留升级"), 88).dependent = false
	entry({"admin", "system", "syskeep", "info"}, call("action_info")).leaf = true
	entry({"admin", "system", "syskeep", "backup"}, call("action_backup")).leaf = true
	entry({"admin", "system", "syskeep", "download"}, call("action_download")).leaf = true
	entry({"admin", "system", "syskeep", "upload"}, call("action_upload")).leaf = true
	entry({"admin", "system", "syskeep", "test"}, call("action_test")).leaf = true
	entry({"admin", "system", "syskeep", "flash"}, call("action_flash")).leaf = true
	entry({"admin", "system", "syskeep", "restore"}, call("action_restore")).leaf = true
	entry({"admin", "system", "syskeep", "log"}, call("action_log")).leaf = true
	entry({"admin", "system", "syskeep", "clearlog"}, call("action_clearlog")).leaf = true
end

local function json_ok(extra)
	local http = require "luci.http"
	http.prepare_content("application/json")
	http.write(extra or '{"ok":true}')
end

function action_info()
	local http = require "luci.http"
	local fs = require "nixio.fs"
	http.prepare_content("application/json")
	local home = data_home()
	local st = '{"phase":"idle","message":"","fail":[]}'
	if home then
		st = fs.readfile(home .. "/status.json") or st
	end
	local release = sys_exec(". /etc/openwrt_release; echo \"$DISTRIB_DESCRIPTION\"")
	local root = data_root()
	local world = sys_exec("wc -l < /etc/apk/world 2>/dev/null")
	local overlay = sys_exec("wc -l < /etc/syskeep/overlay-pkgs 2>/dev/null")
	local apks, filepacks, fw = "0", "0", "0"
	if home then
		apks = sys_exec("ls " .. home .. "/apks/*.apk 2>/dev/null | wc -l")
		filepacks = sys_exec("ls " .. home .. "/files/*.tgz 2>/dev/null | wc -l")
		fw = sys_exec("wc -c < " .. home .. "/firmware.img.gz 2>/dev/null")
	end
	local pending = fs.access("/etc/syskeep/pending") and true or false
	http.write(string.format(
		'{"release":%s,"data_path":%s,"data_mounted":%s,"world":%s,"overlay":%s,"apks":%s,"filepacks":%s,"firmware_bytes":%s,"pending":%s,"status":%s}',
		quote(release), quote(root), root ~= "" and "true" or "false", tonumber(world) or 0,
		tonumber(overlay) or 0, tonumber(apks) or 0, tonumber(filepacks) or 0,
		tonumber(fw) or 0, pending and "true" or "false", st
	))
end

function data_root()
	return sys_exec("/usr/bin/syskeep-upgrade.sh datadir")
end

function data_home()
	local root = data_root()
	if root == "" then
		return nil
	end
	return root .. "/syskeep"
end

function quote(s)
	s = s or ""
	s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", " ")
	return '"' .. s .. '"'
end

local function sh_quote(s)
	return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function bg_exec(bin, ...)
	local cmd = "start-stop-daemon -S -b -x " .. sh_quote(bin) .. " --"
	local n = select("#", ...)
	local i = 1
	while i <= n do
		cmd = cmd .. " " .. sh_quote((select(i, ...)))
		i = i + 1
	end
	os.execute(cmd .. " >/dev/null 2>&1")
end

local function append_log(msg)
	local home = data_home()
	if not home then
		return
	end
	os.execute("mkdir -p " .. sh_quote(home))
	local f = io.open(home .. "/upgrade.log", "a")
	if f then
		f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. msg .. "\n")
		f:flush()
		f:close()
	end
end

function action_backup()
	append_log("收到备份请求")
	bg_exec("/usr/bin/syskeep-upgrade.sh", "backup")
	json_ok()
end

function action_download()
	local http = require "luci.http"
	local url = http.formvalue("url") or ""
	if url == "" then
		http.status(400, "Bad Request")
		json_ok('{"ok":false,"error":"缺少 URL"}')
		return
	end
	append_log("收到下载请求")
	bg_exec("/usr/bin/syskeep-upgrade.sh", "download", url)
	json_ok()
end

function action_upload()
	local http = require "luci.http"
	local home = data_home()
	if not home then
		http.status(400, "Bad Request")
		json_ok('{"ok":false,"error":"未检测到数据盘"}')
		return
	end
	require("luci.sys").call("mkdir -p " .. home)
	local fp
	http.setfilehandler(function(meta, chunk, eof)
		if not fp then
			fp = io.open(home .. "/firmware.img.gz", "w")
		end
		if fp and chunk then fp:write(chunk) end
		if fp and eof then fp:close() end
	end)
	http.formvalue("firmware")
	json_ok()
end

function action_test()
	append_log("收到校验请求")
	bg_exec("/usr/bin/syskeep-upgrade.sh", "test")
	json_ok()
end

function action_flash()
	append_log("收到升级请求")
	bg_exec("/usr/bin/syskeep-upgrade.sh", "flash")
	json_ok()
end

function action_restore()
	append_log("收到恢复请求")
	os.execute("touch /etc/syskeep/pending")
	bg_exec("/etc/syskeep/restore.sh")
	json_ok()
end

function action_log()
	local http = require "luci.http"
	local fs = require "nixio.fs"
	http.prepare_content("text/plain; charset=utf-8")
	local home = data_home()
	local a, b = "", ""
	if home then
		a = fs.readfile(home .. "/upgrade.log") or ""
		b = fs.readfile(home .. "/restore.log") or ""
	end
	http.write(a)
	if b ~= "" then
		http.write("\n---- restore ----\n")
		http.write(b)
	end
end

function action_clearlog()
	local fs = require "nixio.fs"
	local home = data_home()
	if home then
		fs.writefile(home .. "/upgrade.log", "")
		fs.writefile(home .. "/restore.log", "")
	end
	json_ok()
end
