#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -n "${IPKG_INSTROOT}" ] && exit 0

mkdir -p /etc/statusmon
chmod 755 /etc/statusmon
chmod 755 /www/cgi-bin/statusmon /etc/init.d/statusmon-acct /etc/init.d/statusmon-sampler /usr/bin/statusmon-sampler 2>/dev/null || true
chmod 755 /etc/init.d/statusmon-attack /usr/bin/statusmon-attack.py /usr/bin/statusmon-attack-nft.sh 2>/dev/null || true

# 攻击记录采集依赖 dnsmasq 之外的 syslog；此处仅修复“重复 log-facility 导致 dnsmasq 崩溃”的历史问题
if [ -f /etc/dnsmasq.conf ] && grep -qE '^[[:space:]]*log-facility=/dev/null' /etc/dnsmasq.conf; then
	sed -i 's|^[[:space:]]*log-facility=/dev/null|# log-facility=/dev/null|' /etc/dnsmasq.conf
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
fi
# 「日志」页需要 DHCP 事件；开启 dnsmasq 的 log-dhcp（仅 DHCP，不含 DNS 查询）
if [ "$(uci -q get dhcp.@dnsmasq[0].logdhcp 2>/dev/null)" != "1" ]; then
	uci set dhcp.@dnsmasq[0].logdhcp='1'
	uci commit dhcp
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
fi

if [ -x /etc/init.d/statusmon-attack ]; then
	/etc/init.d/statusmon-attack enable 2>/dev/null || true
	/etc/init.d/statusmon-attack restart 2>/dev/null || true
fi

# 并入迁移：旧「安全监测」(luci-app-atkmon) 的采集数据搬过来，并清掉已废弃的旧服务
if [ -d /var/lib/atkmon ] && [ ! -f /var/lib/statusmon-attack/snapshot.json ]; then
	mkdir -p /var/lib/statusmon-attack
	cp -a /var/lib/atkmon/. /var/lib/statusmon-attack/ 2>/dev/null || true
fi
if [ -x /etc/init.d/atkmon ] && ! apk info --installed luci-app-atkmon >/dev/null 2>&1; then
	/etc/init.d/atkmon stop 2>/dev/null || true
	/etc/init.d/atkmon disable 2>/dev/null || true
	rm -f /etc/init.d/atkmon
fi
# 迁移旧拉黑名单，并清掉遗留的旧 nft 表（否则 atkmon: 日志与旧拦截残留）
if uci -q get atkmon.main.block >/dev/null 2>&1; then
	_old="$(uci -q get atkmon.main.block)"
	if [ -n "$_old" ] && [ -z "$(uci -q get statusmon.attack.block)" ]; then
		uci set statusmon.attack.block="$_old"
		uci commit statusmon
	fi
fi
nft delete table inet atkmon 2>/dev/null || true

if [ -x /etc/init.d/statusmon-acct ]; then
	/etc/init.d/statusmon-acct enable 2>/dev/null || true
	/etc/init.d/statusmon-acct start 2>/dev/null || true
fi

if [ -x /etc/init.d/statusmon-sampler ]; then
	/etc/init.d/statusmon-sampler enable 2>/dev/null || true
	/etc/init.d/statusmon-sampler restart 2>/dev/null || true
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
