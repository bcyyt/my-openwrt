#!/bin/sh
# Apply inet atkmon table: WAN NEW log + INPUT reject for blocked addresses.

WAN=$(uci -q get atkmon.main.wan_if)
if [ -z "$WAN" ]; then
	WAN=$(ifstatus wan 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
fi
if [ -z "$WAN" ]; then
	WAN=$(ifstatus wan 2>/dev/null | jsonfilter -e '@.device' 2>/dev/null)
fi
[ -n "$WAN" ] || WAN=pppoe-wan

nft delete table inet atkmon 2>/dev/null || true

nft -f - <<EOF
table inet atkmon {
	set block4 {
		type ipv4_addr
	}
	set block6 {
		type ipv6_addr
	}
	chain input {
		type filter hook input priority -10; policy accept;
		iifname "lo" accept
		iifname "br-lan" accept
		ip saddr @block4 counter reject
		ip6 saddr @block6 counter reject
		iifname "$WAN" ct state new log prefix "atkmon: " limit rate 20/second
	}
}
EOF

add_ip() {
	ip="$1"
	[ -n "$ip" ] || return 0
	case "$ip" in
		*:*) nft add element inet atkmon block6 "{ $ip }" 2>/dev/null || true ;;
		*) nft add element inet atkmon block4 "{ $ip }" 2>/dev/null || true ;;
	esac
}

for ip in $(uci -q get atkmon.main.block); do
	add_ip "$ip"
done

exit 0
