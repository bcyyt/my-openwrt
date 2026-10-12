#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0

OTA_URL='https://raw.githubusercontent.com/bcyyt/my-openwrt/main/packages/iptv-auth/version.json'

if [ -n "${IPKG_INSTROOT}" ]; then
	exit 0
fi

if [ -f /usr/share/iptv-auth/my-openwrt.rsa.pub ]; then
	mkdir -p /etc/apk/keys
	cp /usr/share/iptv-auth/my-openwrt.rsa.pub /etc/apk/keys/my-openwrt.rsa.pub
	chmod 644 /etc/apk/keys/my-openwrt.rsa.pub
fi

if [ -f /etc/config/iptv-auth ]; then
	uci -q set iptv-auth.main.ota_url="$OTA_URL"
	uci -q commit iptv-auth
fi

if [ -x /etc/uci-defaults/iptv-auth-setup ]; then
	sh /etc/uci-defaults/iptv-auth-setup >/dev/null 2>&1 || true
	rm -f /etc/uci-defaults/iptv-auth-setup
fi

chmod 755 /etc/init.d/iptv-auth /usr/bin/iptv-auth.py \
	/usr/bin/iptv-auth-ota.sh /usr/bin/iptv-auth-ota-check.sh \
	/usr/bin/rtp2httpd-ota-check.sh /usr/bin/rtp2httpd-update.sh 2>/dev/null || true

mkdir -p /etc/sysctl.d

if [ -f /www/IPTV.m3u ] && [ ! -f /www/Lan.m3u ]; then
	cp /www/IPTV.m3u /www/Lan.m3u
fi
cat > /etc/sysctl.d/15-iptv-auth.conf <<'EOF'
net.core.rmem_max=33554432
EOF
sysctl -w net.core.rmem_max=33554432 >/dev/null 2>&1 || true

ensure_pkg() {
	apk info -e "$1" >/dev/null 2>&1 && return 0
	apk add "$1" >/dev/null 2>&1
}
ensure_pkg python3
ensure_pkg python3-pip
if ! python3 -c "import requests" >/dev/null 2>&1; then
	pip3 install requests >/dev/null 2>&1 || apk add python3-requests >/dev/null 2>&1 || true
fi

if [ -x /etc/init.d/iptv-auth ]; then
	/etc/init.d/iptv-auth enable >/dev/null 2>&1 || true
	/etc/init.d/iptv-auth restart >/dev/null 2>&1 || true
fi

# WAN IPv6 放行 rtp2httpd 直播、uhttpd EPG/台标、RTSP 回看
live_port=$(uci -q get iptv-auth.main.live_port)
live_port=${live_port:-23234}
replay_port=$(uci -q get iptv-auth.main.replay_port)
replay_port=${replay_port:-554}
uci -q batch <<-EOF
	set firewall.iptv_auth_ipv6=rule
	set firewall.iptv_auth_ipv6.name='Allow-IPTV-proxy-IPv6'
	set firewall.iptv_auth_ipv6.src='wan'
	set firewall.iptv_auth_ipv6.proto='tcp'
	set firewall.iptv_auth_ipv6.dest_port='${live_port} 2000 ${replay_port}'
	set firewall.iptv_auth_ipv6.family='ipv6'
	set firewall.iptv_auth_ipv6.target='ACCEPT'
	commit firewall
EOF
fw4 reload >/dev/null 2>&1 || /etc/init.d/firewall reload >/dev/null 2>&1 || true

rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload >/dev/null 2>&1 || true
exit 0
