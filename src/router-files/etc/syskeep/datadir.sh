#!/bin/sh
# Pick a writable real-disk mount for syskeep backups.

SYSKEEP_CFGDIR="${SYSKEEP_CFGDIR:-/etc/syskeep}"
SYSKEEP_SAVED="$SYSKEEP_CFGDIR/datadir"
SYSKEEP_MIN_KB=65536

syskeep_fstype_ok() {
	case "$1" in
		ext4|ext3|ext2|btrfs|xfs|f2fs|ntfs|exfat) return 0 ;;
	esac
	return 1
}

syskeep_mp_skip() {
	case "$1" in
		/|/overlay|/rom|/boot|/tmp|/dev|/proc|/sys|/run|/var/run)
			return 0 ;;
		/overlay/*|/rom/*|/boot/*|/tmp/*|/dev/*|/proc/*|/sys/*)
			return 0 ;;
	esac
	return 1
}

syskeep_writable() {
	[ -d "$1" ] || return 1
	touch "$1/.syskeep-w" 2>/dev/null || return 1
	rm -f "$1/.syskeep-w"
	return 0
}

syskeep_kb() {
	df -k "$1" 2>/dev/null | awk 'NR==2 {print int($2)}'
}

syskeep_label() {
	local lab
	lab=$(block info "$1" 2>/dev/null | sed -n 's/.*LABEL="\([^"]*\)".*/\1/p')
	[ -n "$lab" ] && { echo "$lab"; return 0; }
	blkid -s LABEL -o value "$1" 2>/dev/null
}

syskeep_score() {
	local mp="$1" dev="$2" kb="$3" score="$3" lab
	[ -d "$mp/syskeep" ] && score=$((score + 100000000))
	case "$mp" in
		*data*|*Data*|*DATA*) score=$((score + 50000000)) ;;
	esac
	lab=$(syskeep_label "$dev")
	case "$lab" in
		data|DATA|Data) score=$((score + 40000000)) ;;
	esac
	echo "$score"
}

syskeep_consider() {
	local mp="$1" dev="$2" fstype="$3" list="$4" kb
	syskeep_mp_skip "$mp" && return 1
	syskeep_fstype_ok "$fstype" || return 1
	syskeep_writable "$mp" || return 1
	kb=$(syskeep_kb "$mp")
	[ -n "$kb" ] && [ "$kb" -ge "$SYSKEEP_MIN_KB" ] 2>/dev/null || return 1
	echo "$mp $dev $fstype $kb" >> "$list"
}

syskeep_best_from_list() {
	local list="$1" best_mp="" best=0 mp dev fstype kb score nested mp2
	while read -r mp dev fstype kb; do
		[ -n "$mp" ] || continue
		nested=0
		while read -r mp2 _; do
			[ "$mp" = "$mp2" ] && continue
			case "$mp" in
				"$mp2"/*) nested=1; break ;;
			esac
		done < "$list"
		[ "$nested" = 1 ] && continue
		score=$(syskeep_score "$mp" "$dev" "$kb")
		if [ "$score" -gt "$best" ]; then
			best="$score"
			best_mp="$mp"
		fi
	done < "$list"
	echo "$best_mp"
}

syskeep_detect_root() {
	local saved mp fstype i enabled list dev
	list="/tmp/syskeep.mounts.$$"
	rm -f "$list"
	touch "$list"

	if [ -f "$SYSKEEP_SAVED" ]; then
		saved=$(sed -n '1p' "$SYSKEEP_SAVED" | tr -d '\r')
		if [ -n "$saved" ] && syskeep_writable "$saved"; then
			fstype=$(df -T "$saved" 2>/dev/null | awk 'NR==2 {print $2}')
			if syskeep_fstype_ok "$fstype"; then
				rm -f "$list"
				echo "$saved"
				return 0
			fi
		fi
	fi

	i=0
	while uci -q get "fstab.@mount[$i]" >/dev/null 2>&1; do
		enabled=$(uci -q get "fstab.@mount[$i].enabled")
		mp=$(uci -q get "fstab.@mount[$i].target")
		if [ "$enabled" = "1" ] && [ -n "$mp" ] && grep -q " $mp " /proc/mounts; then
			dev=$(awk -v m="$mp" '$2==m {print $1; exit}' /proc/mounts)
			fstype=$(awk -v m="$mp" '$2==m {print $3; exit}' /proc/mounts)
			syskeep_consider "$mp" "$dev" "$fstype" "$list"
		fi
		i=$((i + 1))
	done

	while read -r dev mp fstype _; do
		syskeep_consider "$mp" "$dev" "$fstype" "$list"
	done < /proc/mounts

	mp=$(syskeep_best_from_list "$list")
	rm -f "$list"
	[ -n "$mp" ] || return 1
	echo "$mp"
}

syskeep_save_datadir() {
	mkdir -p "$SYSKEEP_CFGDIR"
	echo "$1" > "$SYSKEEP_SAVED"
}

syskeep_wait_root() {
	local tries="${1:-30}" i=0 mp
	while [ "$i" -lt "$tries" ]; do
		mp=$(syskeep_detect_root) || mp=""
		if [ -n "$mp" ]; then
			echo "$mp"
			return 0
		fi
		command -v block >/dev/null 2>&1 && block mount >/dev/null 2>&1 || true
		sleep 2
		i=$((i + 1))
	done
	return 1
}
