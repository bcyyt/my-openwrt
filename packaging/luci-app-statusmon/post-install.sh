#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -n "${IPKG_INSTROOT}" ] && exit 0

mkdir -p /etc/statusmon
chmod 755 /etc/statusmon
chmod 755 /www/cgi-bin/statusmon /etc/init.d/statusmon-acct 2>/dev/null || true

if [ -x /etc/init.d/statusmon-acct ]; then
	/etc/init.d/statusmon-acct enable 2>/dev/null || true
	/etc/init.d/statusmon-acct start 2>/dev/null || true
fi

need_fm=0
apk info --installed luci-app-filemanager >/dev/null 2>&1 || need_fm=1
need_zh=0
apk info --installed luci-i18n-filemanager-zh-cn >/dev/null 2>&1 || need_zh=1

if [ "$need_fm" = "1" ] || [ "$need_zh" = "1" ]; then
	SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
	for d in "$SELF_DIR" /usr/share/statusmon/vendor /tmp; do
		[ -d "$d" ] || continue
		if [ "$need_fm" = "1" ]; then
			for f in "$d"/luci-app-filemanager-*.apk; do
				[ -f "$f" ] || continue
				apk add --allow-untrusted "$f" >/dev/null 2>&1 && need_fm=0 && break
			done
		fi
		if [ "$need_zh" = "1" ]; then
			for f in "$d"/luci-i18n-filemanager-zh-cn-*.apk; do
				[ -f "$f" ] || continue
				apk add --allow-untrusted "$f" >/dev/null 2>&1 && need_zh=0 && break
			done
		fi
	done
	if [ "$need_fm" = "1" ] || [ "$need_zh" = "1" ]; then
		apk update >/dev/null 2>&1 || true
		pkgs=""
		[ "$need_fm" = "1" ] && pkgs="$pkgs luci-app-filemanager"
		[ "$need_zh" = "1" ] && pkgs="$pkgs luci-i18n-filemanager-zh-cn"
		apk add --allow-untrusted $pkgs >/dev/null 2>&1 || \
			apk add $pkgs >/dev/null 2>&1 || true
	fi
fi

rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload 2>/dev/null || true
exit 0
