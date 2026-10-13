#!/bin/sh
# Apply or report NIC queue / CPU / firewall flow-offload tuning.

ncpus=$(grep -c ^processor /proc/cpuinfo 2>/dev/null)
[ -n "$ncpus" ] && [ "$ncpus" -gt 0 ] || ncpus=1
last=$((ncpus - 1))

uci_get() {
	uci -q get "$1"
}

load_cfg() {
	enabled=$(uci_get netqueue.main.enabled)
	nic=$(uci_get netqueue.main.nic_queues)
	cpu=$(uci_get netqueue.main.cpu_performance)
	flow=$(uci_get netqueue.main.flow_offload)
	pppoe_qlen=$(uci_get netqueue.main.pppoe_qlen)
	udp_gro=$(uci_get netqueue.main.udp_gro)
	rx_backlog=$(uci_get netqueue.main.rx_backlog)
	[ "$enabled" = "1" ] || {
		nic=0
		cpu=0
		flow=0
		pppoe_qlen=0
		udp_gro=0
		rx_backlog=0
	}
}

list_eth() {
	ls -d /sys/class/net/eth* 2>/dev/null | sed 's|.*/||'
}

is_pppoe_lower() {
	local dev="$1" sec proto device
	for sec in $(uci -q show network | sed -n 's/^network\.\([^.]*\)=interface$/\1/p'); do
		proto=$(uci -q get "network.$sec.proto")
		[ "$proto" = "pppoe" ] || continue
		device=$(uci -q get "network.$sec.device")
		[ -z "$device" ] && device=$(uci -q get "network.$sec.ifname")
		[ "$device" = "$dev" ] && return 0
	done
	return 1
}

all_cpu_mask() {
	printf '%x' $(((1 << ncpus) - 1))
}

apply_irq() {
	local iface="$1" restore="$2" i irq
	i=0
	while [ "$i" -lt 8 ]; do
		[ -d "/sys/class/net/$iface/queues/rx-$i" ] || break
		irq=$(awk -v n="${iface}-TxRx-${i}" '$0 ~ n { gsub(":", "", $1); print $1; exit }' /proc/interrupts)
		if [ -n "$irq" ]; then
			if [ "$restore" = "1" ]; then
				echo "0-$last" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null || true
			else
				echo "$i" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null || true
			fi
		fi
		i=$((i + 1))
	done
}

apply_xps() {
	local iface="$1" restore="$2" i q mask
	i=0
	for q in /sys/class/net/$iface/queues/tx-*; do
		[ -e "$q/xps_cpus" ] || continue
		if [ "$restore" = "1" ]; then
			echo 0 > "$q/xps_cpus" 2>/dev/null || true
		else
			mask=$(printf '%x' $((1 << i)))
			echo "$mask" > "$q/xps_cpus" 2>/dev/null || true
		fi
		i=$((i + 1))
	done
}

apply_rps() {
	local iface="$1" mask="$2" q
	for q in /sys/class/net/$iface/queues/rx-*; do
		[ -e "$q/rps_cpus" ] || continue
		echo "$mask" > "$q/rps_cpus" 2>/dev/null || true
	done
}

overlay_nic() {
	local d
	for d in $(list_eth); do
		[ -d "/sys/class/net/$d/queues" ] || continue
		apply_irq "$d" 0
		apply_xps "$d" 0
		if is_pppoe_lower "$d"; then
			apply_rps "$d" "$(all_cpu_mask)"
		else
			apply_rps "$d" 0
		fi
	done
}

restore_nic() {
	local d
	for d in $(list_eth); do
		[ -d "/sys/class/net/$d/queues" ] || continue
		apply_irq "$d" 1
		apply_xps "$d" 1
	done
	[ -x /etc/init.d/packet_steering ] && /etc/init.d/packet_steering restart >/dev/null 2>&1 || true
}

apply_nic() {
	if [ "$nic" = "1" ]; then
		uci -q set network.globals.packet_steering='2'
		uci -q set network.globals.steering_flows='256'
		uci -q commit network
		[ -x /etc/init.d/packet_steering ] && /etc/init.d/packet_steering restart >/dev/null 2>&1 || true
		overlay_nic
	else
		restore_nic
	fi
}

apply_cpu() {
	local g p
	if [ "$cpu" = "1" ]; then
		for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
			echo performance > "$g" 2>/dev/null || true
		done
		for p in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
			echo performance > "$p" 2>/dev/null || true
		done
	else
		for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
			echo powersave > "$g" 2>/dev/null || true
		done
		for p in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
			echo balance_power > "$p" 2>/dev/null || true
		done
	fi
}

fw_defaults() {
	uci -q show firewall | sed -n 's/^\(firewall\.[^=]*\)=defaults$/\1/p' | head -n 1
}

fw_wan_zone() {
	local z name
	for z in $(uci -q show firewall | sed -n 's/^\(firewall\.[^=]*\)=zone$/\1/p'); do
		name=$(uci -q get "$z.name")
		[ "$name" = "wan" ] && echo "$z" && return 0
	done
	return 1
}

fw_reload() {
	if command -v fw4 >/dev/null 2>&1; then
		fw4 reload >/dev/null 2>&1 || true
	else
		/etc/init.d/firewall reload >/dev/null 2>&1 || true
	fi
}

nat_nft_kind() {
	local r
	r=$(nft list chain inet fw4 srcnat_wan 2>/dev/null || true)
	echo "$r" | grep -q 'fullcone' && { echo fullcone; return 0; }
	echo "$r" | grep -q 'fully-random' && { echo fully-random; return 0; }
	echo "$r" | grep -q 'masquerade' && { echo masquerade; return 0; }
	echo none
}

patch_nat4() {
	nft flush chain inet fw4 srcnat_wan 2>/dev/null || return 0
	nft add rule inet fw4 srcnat_wan meta nfproto ipv4 masquerade fully-random comment netqueue-nat4 2>/dev/null && return 0
	nft add rule inet fw4 srcnat_wan masquerade fully-random comment netqueue-nat4 2>/dev/null && return 0
	nft add rule inet fw4 srcnat_wan meta nfproto ipv4 masquerade 2>/dev/null || true
}

apply_nat_mode() {
	local mode def z want cur changed=0
	mode=$(uci_get netqueue.main.nat_mode)
	case "$mode" in
		nat1|nat3|nat4) ;;
		*) return 0 ;;
	esac
	def=$(fw_defaults)
	[ -n "$def" ] || return 0
	z=$(fw_wan_zone)
	if [ "$mode" = "nat1" ]; then
		want=1
	else
		want=0
	fi
	cur=$(uci -q get "$def.fullcone")
	[ "$cur" = "$want" ] || { uci -q set "$def.fullcone=$want"; changed=1; }
	if [ -n "$z" ]; then
		cur=$(uci -q get "$z.fullcone")
		[ "$cur" = "$want" ] || { uci -q set "$z.fullcone=$want"; changed=1; }
		cur=$(uci -q get "$z.masq")
		[ "$cur" = "1" ] || { uci -q set "$z.masq=1"; changed=1; }
	fi
	if [ "$changed" = "1" ]; then
		uci -q commit firewall
		fw_reload
	fi
	# fw4 has no symmetric NAT; replace masquerade after reload.
	if [ "$mode" = "nat4" ]; then
		patch_nat4
	fi
}

apply_flow() {
	local def
	def=$(fw_defaults)
	[ -n "$def" ] || return 0
	if [ "$flow" = "1" ]; then
		uci -q set "$def.flow_offloading=1"
		uci -q set "$def.flow_offloading_hw=0"
	else
		uci -q set "$def.flow_offloading=0"
		uci -q set "$def.flow_offloading_hw=0"
	fi
	uci -q commit firewall
	fw_reload
}

apply_pppoe_qlen() {
	local d qlen
	qlen=3
	[ "$pppoe_qlen" = "1" ] && qlen=1000
	for d in /sys/class/net/pppoe-*; do
		[ -e "$d/tx_queue_len" ] || continue
		echo "$qlen" > "$d/tx_queue_len" 2>/dev/null || true
	done
}

apply_udp_gro() {
	local d state
	state=off
	[ "$udp_gro" = "1" ] && state=on
	for d in $(list_eth); do
		ethtool -K "$d" rx-udp-gro-forwarding "$state" >/dev/null 2>&1 || true
	done
}

apply_backlog() {
	local val
	val=1000
	[ "$rx_backlog" = "1" ] && val=4096
	apply_sysctl "$val"
}

apply_sysctl() {
	local backlog="$1" t
	[ -n "$backlog" ] || backlog=1000
	t=$(uci_get netqueue.main.neigh_gc)
	case "$t" in
		''|*[!0-9]*) t=60 ;;
	esac
	[ "$t" -ge 5 ] 2>/dev/null || t=5
	[ "$t" -le 86400 ] 2>/dev/null || t=86400
	mkdir -p /etc/sysctl.d
	cat > /etc/sysctl.d/11-netqueue.conf <<EOF
net.core.netdev_max_backlog=$backlog
net.ipv4.neigh.default.gc_stale_time=$t
net.ipv6.neigh.default.gc_stale_time=$t
EOF
	sysctl -w net.core.netdev_max_backlog="$backlog" >/dev/null 2>&1 || true
	sysctl -w net.ipv4.neigh.default.gc_stale_time="$t" >/dev/null 2>&1 || true
	sysctl -w net.ipv6.neigh.default.gc_stale_time="$t" >/dev/null 2>&1 || true
	if [ -d /sys/class/net/br-lan ]; then
		sysctl -w net.ipv4.neigh.br-lan.gc_stale_time="$t" >/dev/null 2>&1 || true
		sysctl -w net.ipv6.neigh.br-lan.gc_stale_time="$t" >/dev/null 2>&1 || true
	fi
}

dhcp_kick() {
	local mac="$1" oldip="$2" newip="$3" lf=/tmp/dhcp.leases now tmp=/tmp/netqueue-leases.new
	mac=$(echo "$mac" | tr 'A-F' 'a-f')
	now=$(date +%s)
	if [ -f "$lf" ]; then
		awk -v mac="$mac" -v now="$now" '
			BEGIN { mac = tolower(mac) }
			{
				m = tolower($2)
				if (m == mac) next
				if (($1 + 0) > 0 && ($1 + 0) < now) next
				print
			}
		' "$lf" > "$tmp"
		cat "$tmp" > "$lf"
	fi
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
	[ -n "$oldip" ] && [ "$oldip" != "-" ] && ip neigh del "$oldip" dev br-lan 2>/dev/null || true
	[ -n "$newip" ] && [ "$newip" != "-" ] && [ "$newip" != "$oldip" ] && ip neigh del "$newip" dev br-lan 2>/dev/null || true
}

neigh_keep_ips() {
	local now lf=/tmp/dhcp.leases
	now=$(date +%s)
	if [ -f "$lf" ]; then
		awk -v now="$now" 'NF>=3 { ts=$1+0; if (ts==0 || ts>=now) print $3 }' "$lf"
	fi
	uci show dhcp 2>/dev/null | sed -n "s/^dhcp\\.@host\\[[0-9][0-9]*\\]\\.ip='\\([^']*\\)'$/\\1/p"
	uci -q get network.lan.ipaddr 2>/dev/null | awk -F/ '{print $1}'
}

neigh_clean() {
	local auto t stamp=/tmp/netqueue-neigh-clean.stamp keep=/tmp/netqueue-neigh-keep now last addr st force="$1"
	auto=$(uci_get netqueue.main.neigh_auto)
	[ "$auto" = "0" ] && return 0
	[ -d /sys/class/net/br-lan ] || return 0
	t=$(uci_get netqueue.main.neigh_gc)
	case "$t" in
		''|*[!0-9]*) t=60 ;;
	esac
	[ "$t" -ge 5 ] 2>/dev/null || t=5
	now=$(date +%s)
	if [ "$force" != "1" ] && [ -f "$stamp" ]; then
		last=$(cat "$stamp" 2>/dev/null || echo 0)
		[ "$((now - last))" -lt "$t" ] && return 0
	fi
	neigh_keep_ips | awk 'NF{print}' | sort -u > "$keep"
	ip -4 neigh show dev br-lan 2>/dev/null | while read -r line; do
		addr=$(echo "$line" | awk '{print $1}')
		st=$(echo "$line" | awk '{print $NF}')
		case "$addr" in
			*.*.*.*) ;;
			*) continue ;;
		esac
		case "$st" in
			REACHABLE|PERMANENT) continue ;;
		esac
		grep -qx "$addr" "$keep" 2>/dev/null && continue
		ip neigh del "$addr" dev br-lan 2>/dev/null || true
	done
	echo "$now" > "$stamp"
}

apply_neigh_cron() {
	local auto line='* * * * * /usr/bin/netqueue-apply.sh neigh-clean' tmp=/tmp/netqueue-cron.new
	auto=$(uci_get netqueue.main.neigh_auto)
	mkdir -p /etc/crontabs
	touch /etc/crontabs/root
	grep -vF 'netqueue-apply.sh neigh-clean' /etc/crontabs/root > "$tmp" 2>/dev/null || true
	if [ "$auto" != "0" ]; then
		echo "$line" >> "$tmp"
	fi
	cat "$tmp" > /etc/crontabs/root
	/etc/init.d/cron restart >/dev/null 2>&1 || true
}

print_status() {
	local d q i irq name gov freq epp def lan mask opt6 sec reso
	load_cfg
	echo "总开关: $enabled"
	echo "网卡队列: $nic"
	echo "CPU性能: $cpu"
	echo "软件分载: $flow"
	echo "PPPoE队列: $pppoe_qlen"
	echo "UDP GRO: $udp_gro"
	echo "接收积压: $rx_backlog"
	echo
	for d in $(list_eth); do
		[ -d "/sys/class/net/$d/queues" ] || continue
		echo -n "$d"
		is_pppoe_lower "$d" && echo -n " (PPPoE)"
		echo
		echo -n "  rps:"
		for q in /sys/class/net/$d/queues/rx-*; do
			[ -e "$q/rps_cpus" ] || continue
			echo -n " $(cat "$q/rps_cpus")"
		done
		echo
		echo -n "  xps:"
		for q in /sys/class/net/$d/queues/tx-*; do
			[ -e "$q/xps_cpus" ] || continue
			echo -n " $(cat "$q/xps_cpus")"
		done
		echo
		echo -n "  irq:"
		i=0
		while [ "$i" -lt 8 ]; do
			[ -d "/sys/class/net/$d/queues/rx-$i" ] || break
			irq=$(awk -v n="${d}-TxRx-${i}" '$0 ~ n { gsub(":", "", $1); print $1; exit }' /proc/interrupts)
			if [ -n "$irq" ]; then
				echo -n " TxRx-$i=CPU$(cat /proc/irq/$irq/effective_affinity_list 2>/dev/null)"
			fi
			i=$((i + 1))
		done
		echo
		gro=$(ethtool -k "$d" 2>/dev/null | awk -F: '/rx-udp-gro-forwarding/{gsub(/ /,"",$2); print $2; exit}')
		echo "  udp-gro-fwd: ${gro:-n/a}"
	done
	echo
	for d in /sys/class/net/pppoe-*; do
		[ -e "$d/tx_queue_len" ] || continue
		echo "$(basename "$d") qlen=$(cat "$d/tx_queue_len")"
	done
	echo "netdev_max_backlog=$(sysctl -n net.core.netdev_max_backlog 2>/dev/null)"
	echo
	for g in /sys/devices/system/cpu/cpu[0-9]*; do
		name=$(basename "$g")
		gov=$(cat "$g/cpufreq/scaling_governor" 2>/dev/null || echo n/a)
		freq=$(cat "$g/cpufreq/scaling_cur_freq" 2>/dev/null || echo 0)
		epp=$(cat "$g/cpufreq/energy_performance_preference" 2>/dev/null || echo n/a)
		echo "$name $gov $((freq / 1000))MHz epp=$epp"
	done
	echo
	def=$(fw_defaults)
	if [ -n "$def" ]; then
		echo "flow_offloading=$(uci -q get "$def.flow_offloading")"
		echo "flow_offloading_hw=$(uci -q get "$def.flow_offloading_hw")"
	fi
	echo "NAT模式: $(uci -q get netqueue.main.nat_mode)"
	echo "NAT实际: $(nat_nft_kind)"
	echo
	lan=$(uci -q get network.lan.ipaddr)
	mask=$(uci -q get network.lan.netmask)
	case "$lan" in
		*/*) echo "LAN: $lan" ;;
		*) echo "LAN: ${lan:-n/a}${mask:+/$mask}" ;;
	esac
	if [ "$(uci -q get dhcp.lan.ignore)" = "1" ]; then
		echo "DHCP: 关闭"
	else
		echo "DHCP: 开启 start=$(uci -q get dhcp.lan.start) limit=$(uci -q get dhcp.lan.limit) lease=$(uci -q get dhcp.lan.leasetime)"
	fi
	echo "邻居清理: $(uci -q get netqueue.main.neigh_gc)s auto=$(uci -q get netqueue.main.neigh_auto) gc_stale=$(sysctl -n net.ipv4.neigh.br-lan.gc_stale_time 2>/dev/null || sysctl -n net.ipv4.neigh.default.gc_stale_time 2>/dev/null)"
	opt6=$(uci -q get dhcp.lan.dhcp_option 2>/dev/null | tr ' ' '\n' | sed -n 's/^6,//p' | head -n 1)
	if [ -n "$opt6" ]; then
		echo "终端DNS: $opt6"
	else
		echo "终端DNS: 本机"
	fi
	sec=$(uci -q show dhcp 2>/dev/null | sed -n 's/^\(dhcp\.[^=]*\)=dnsmasq$/\1/p' | head -n 1)
	if [ -n "$sec" ]; then
		echo "顺序分配: $(uci -q get "$sec.sequential_ip")"
		echo "dnsmasq noresolv=$(uci -q get "$sec.noresolv") cache=$(uci -q get "$sec.cachesize") server=$(uci -q get "$sec.server")"
	fi
	reso=/tmp/resolv.conf.d/resolv.conf.auto
	[ -s "$reso" ] || reso=/tmp/resolv.conf.auto
	if [ -s "$reso" ]; then
		echo -n "运营商DNS:"
		awk '/^nameserver/{printf " %s", $2}' "$reso"
		echo
	else
		echo "运营商DNS: -"
	fi
}

load_cfg
cmd=${1:-apply}
case "$cmd" in
	apply)
		apply_nic
		apply_cpu
		apply_flow
		apply_nat_mode
		apply_pppoe_qlen
		apply_udp_gro
		apply_backlog
		apply_neigh_cron
		neigh_clean 1
		;;
	apply-nic)
		if [ "$nic" = "1" ]; then
			overlay_nic
		fi
		apply_pppoe_qlen
		apply_udp_gro
		apply_nat_mode
		;;
	status)
		print_status
		;;
	dhcp-kick)
		dhcp_kick "$2" "$3" "$4"
		;;
	neigh-clean)
		neigh_clean
		;;
	*)
		echo "usage: $0 apply|apply-nic|status|dhcp-kick|neigh-clean" >&2
		exit 1
		;;
esac
exit 0
