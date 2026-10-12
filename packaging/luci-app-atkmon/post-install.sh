#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -n "${IPKG_INSTROOT}" ] && [ "${IPKG_INSTROOT}" != "/" ] && exit 0

if [ -x /etc/uci-defaults/atkmon-setup ]; then
	sh /etc/uci-defaults/atkmon-setup >/dev/null 2>&1 || true
	rm -f /etc/uci-defaults/atkmon-setup
fi

chmod 755 /etc/init.d/atkmon /usr/bin/atkmon-collect.py /usr/bin/atkmon-nft.sh 2>/dev/null || true

if [ -x /etc/init.d/atkmon ]; then
	/etc/init.d/atkmon enable >/dev/null 2>&1 || true
	/etc/init.d/atkmon restart >/dev/null 2>&1 || true
fi

rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload >/dev/null 2>&1 || true
exit 0
