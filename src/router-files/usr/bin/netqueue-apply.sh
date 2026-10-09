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
	if command -v fw4 >/dev/null 2>&1; then
		fw4 reload >/dev/null 2>&1 || true
	else
		/etc/init.d/firewall reload >/dev/null 2>&1 || true
	fi
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
	sysctl -w net.core.netdev_max_backlog="$val" >/dev/null 2>&1 || true
	mkdir -p /etc/sysctl.d
	echo "net.core.netdev_max_backlog=$val" > /etc/sysctl.d/11-netqueue.conf
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
		apply_pppoe_qlen
		apply_udp_gro
		apply_backlog
		;;
	apply-nic)
		if [ "$nic" = "1" ]; then
			overlay_nic
		fi
		apply_pppoe_qlen
		apply_udp_gro
		;;
	status)
		print_status
		;;
	*)
		echo "usage: $0 apply|apply-nic|status" >&2
		exit 1
		;;
esac
exit 0
