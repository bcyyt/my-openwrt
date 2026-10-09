#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -n "${IPKG_INSTROOT}" ] && [ "${IPKG_INSTROOT}" != "/" ] && exit 0

if [ -x /etc/uci-defaults/netqueue-setup ]; then
	sh /etc/uci-defaults/netqueue-setup >/dev/null 2>&1 || true
	rm -f /etc/uci-defaults/netqueue-setup
fi

chmod 755 /etc/init.d/netqueue /usr/bin/netqueue-apply.sh 2>/dev/null || true

if [ -f /etc/config/netqueue ]; then
	[ -n "$(uci -q get netqueue.main.pppoe_qlen)" ] || uci -q set netqueue.main.pppoe_qlen='1'
	[ -n "$(uci -q get netqueue.main.udp_gro)" ] || uci -q set netqueue.main.udp_gro='1'
	[ -n "$(uci -q get netqueue.main.rx_backlog)" ] || uci -q set netqueue.main.rx_backlog='1'
	[ -n "$(uci -q get netqueue.main.neigh_gc)" ] || uci -q set netqueue.main.neigh_gc='60'
	uci -q commit netqueue
fi

if [ -x /etc/init.d/igc-queues ]; then
	/etc/init.d/igc-queues disable >/dev/null 2>&1 || true
	/etc/init.d/igc-queues stop >/dev/null 2>&1 || true
fi

if [ -x /etc/init.d/netqueue ]; then
	/etc/init.d/netqueue enable >/dev/null 2>&1 || true
	/etc/init.d/netqueue restart >/dev/null 2>&1 || true
fi

rm -f /tmp/luci-indexcache.*
rm -rf /tmp/luci-modulecache/
/etc/init.d/rpcd reload >/dev/null 2>&1 || true
exit 0
