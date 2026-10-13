#!/bin/sh
# Apply inet atkmon table: WAN NEW log + INPUT reject for blocked addresses.

NFT=/usr/sbin/nft
[ -x "$NFT" ] || NFT=nft

WAN=$(uci -q get atkmon.main.wan_if)
if [ -z "$WAN" ]; then
	WAN=$(ifstatus wan 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
fi
if [ -z "$WAN" ]; then
	WAN=$(ifstatus wan 2>/dev/null | jsonfilter -e '@.device' 2>/dev/null)
fi
[ -n "$WAN" ] || WAN=pppoe-wan
WAN=$(printf '%s' "$WAN" | tr -cd 'A-Za-z0-9._-')
[ -n "$WAN" ] || WAN=pppoe-wan

$NFT delete table inet atkmon 2>/dev/null || true

if ! $NFT -f - <<EOF
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
then
	echo "atkmon-nft: table apply failed" >&2
	exit 1
fi

add_ip() {
	ip="$1"
	[ -n "$ip" ] || return 0
	case "$ip" in
		*:*) $NFT add element inet atkmon block6 "{ $ip }" 2>/dev/null || return 1 ;;
		*) $NFT add element inet atkmon block4 "{ $ip }" 2>/dev/null || return 1 ;;
	esac
}

rc=0
for ip in $(uci -q get atkmon.main.block); do
	add_ip "$ip" || rc=1
done

exit $rc
