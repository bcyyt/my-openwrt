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

if [ -x /etc/init.d/iptv-auth ]; then
	/etc/init.d/iptv-auth enable >/dev/null 2>&1 || true
	/etc/init.d/iptv-auth restart >/dev/null 2>&1 || true
fi

rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload >/dev/null 2>&1 || true
exit 0
