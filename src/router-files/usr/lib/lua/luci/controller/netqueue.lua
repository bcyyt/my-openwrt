module("luci.controller.netqueue", package.seeall)

function index()
	if not require("nixio.fs").access("/usr/bin/netqueue-apply.sh") then
		return
	end
	entry({"admin", "network", "netqueue"}, cbi("netqueue"), _("转发优化"), 90).dependent = false
end
