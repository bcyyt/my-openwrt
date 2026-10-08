-- statusmon.lua — LuCI controller: 状态监控（独立一级菜单）
-- 部署到 /usr/lib/lua/luci/controller/statusmon.lua
-- v2: 菜单从 状态→状态监控(admin/status/monitor) 二级目录提升为一级菜单 admin/statusmon，
--     order=3 —— 位于 首页(quickstart=1)/网络向导(2) 之后、状态(10) 之前；
--     旧路径 admin/status/monitor 保留 302 跳转（兼容历史书签），无标题不在菜单中显示。

module("luci.controller.statusmon", package.seeall)

function index()
    -- 一级叶子页面（注册模式与 quickstart 首页一致）
    entry({"admin", "statusmon"}, template("statusmon/status"), "状态监控", 3).leaf = true
    -- 旧路径兼容：仅作跳转，不注册标题（避免在 状态 菜单里重复出现）
    entry({"admin", "status", "monitor"}, call("redirect_legacy")).dependent = false
end

function redirect_legacy()
    local http = require "luci.http"
    local disp = require "luci.dispatcher"
    http.redirect(disp.build_url("admin", "statusmon"))
end
