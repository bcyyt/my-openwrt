#!/bin/sh
# Apply inet statusmon_attack table: INPUT reject for blocked addresses.

NFT=/usr/sbin/nft
[ -x "$NFT" ] || NFT=nft

$NFT delete table inet statusmon_attack 2>/dev/null || true

if ! $NFT -f - <<EOF
table inet statusmon_attack {
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
	}
}
EOF
then
	echo "statusmon-attack-nft: table apply failed" >&2
	exit 1
fi

add_ip() {
	ip="$1"
	[ -n "$ip" ] || return 0
	case "$ip" in
		*:*) $NFT add element inet statusmon_attack block6 "{ $ip }" 2>/dev/null || return 1 ;;
		*) $NFT add element inet statusmon_attack block4 "{ $ip }" 2>/dev/null || return 1 ;;
	esac
}

rc=0
for ip in $(uci -q get statusmon.attack.block); do
	add_ip "$ip" || rc=1
done

exit $rc
