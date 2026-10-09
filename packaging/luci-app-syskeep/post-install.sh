#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -n "${IPKG_INSTROOT}" ] && [ "${IPKG_INSTROOT}" != "/" ] && exit 0

if [ -x /etc/uci-defaults/syskeep-setup ]; then
	sh /etc/uci-defaults/syskeep-setup >/dev/null 2>&1 || true
	rm -f /etc/uci-defaults/syskeep-setup
fi

chmod 755 /etc/init.d/syskeep /usr/bin/syskeep-upgrade.sh /etc/syskeep/restore.sh /lib/upgrade/syskeep-hook.sh 2>/dev/null || true
[ -x /etc/init.d/syskeep ] && /etc/init.d/syskeep enable >/dev/null 2>&1 || true

if [ -f /etc/syskeep/datadir.sh ]; then
	. /etc/syskeep/datadir.sh
	root=$(syskeep_detect_root) || root=""
	if [ -n "$root" ]; then
		syskeep_save_datadir "$root"
		mkdir -p "$root/syskeep/apks"
	fi
fi
mkdir -p /etc/syskeep 2>/dev/null || true

rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload >/dev/null 2>&1 || true
exit 0
