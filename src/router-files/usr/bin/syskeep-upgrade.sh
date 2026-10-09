#!/bin/sh
# Keep-config firmware upgrade: backup, safe flash, status.

ETC=/etc/syskeep
CUSTOM="$ETC/custom-apks.txt"
. /etc/syskeep/datadir.sh

DATA=""
STATUS=""
LOG=""
FW=""

log() {
	echo "$(date '+%F %T') $*" | tee -a "$LOG"
}

write_status() {
	printf '{"phase":"%s","message":"%s","fail":[]}\n' "$1" "$2" > "$STATUS"
}

need_data() {
	local root
	root=$(syskeep_detect_root) || root=""
	if [ -z "$root" ]; then
		echo "未检测到数据盘" >&2
		return 1
	fi
	syskeep_save_datadir "$root"
	DATA="$root/syskeep"
	STATUS="$DATA/status.json"
	LOG="$DATA/upgrade.log"
	FW="$DATA/firmware.img.gz"
	mkdir -p "$DATA/apks" "$DATA/files" "$ETC"
	return 0
}

pkg_base() {
	echo "$1" | sed 's/[=<>].*//'
}

list_overlay_pkgs() {
	awk '{gsub(/[=<>].*/,""); print}' /etc/apk/world 2>/dev/null | sort -u > /tmp/syskeep.world
	awk '{gsub(/[=<>].*/,""); print}' /rom/etc/apk/world 2>/dev/null | sort -u > /tmp/syskeep.rom
	awk 'NR==FNR {a[$1]=1; next} !a[$1]' /tmp/syskeep.rom /tmp/syskeep.world
}

pack_installed() {
	local pkg="$1" list="/tmp/syskeep.$pkg.list"
	apk info -L "$pkg" 2>/dev/null | awk 'NR>1 && $0 !~ /contains:/ && $0 !~ /^etc\/config(\/|$)/ {print}' | while read -r f; do
		[ -e "/$f" ] && echo "$f"
	done > "$list"
	[ -s "$list" ] || return 1
	mkdir -p "$DATA/files"
	if tar -czf "$DATA/files/$pkg.files.tgz" -C / -T "$list" 2>>"$LOG"; then
		log "packed files $pkg"
		return 0
	fi
	rm -f "$DATA/files/$pkg.files.tgz"
	log "pack fail $pkg"
	return 1
}

backup_overlay_apks() {
	local pkg n total
	mkdir -p "$DATA/apks" "$DATA/files"
	list_overlay_pkgs > "$ETC/overlay-pkgs"
	cp "$ETC/overlay-pkgs" "$DATA/overlay-pkgs"
	total=$(wc -l < "$ETC/overlay-pkgs" | tr -d ' ')
	[ "$total" -gt 0 ] || { log "no overlay packages"; return 0; }
	apk update >>"$LOG" 2>&1 || true
	n=0
	while read -r pkg; do
		[ -n "$pkg" ] || continue
		n=$((n + 1))
		write_status backup "备份插件 $pkg ($n/$total)"
		if [ -f "$DATA/apks/$pkg.apk" ] || ls "$DATA/apks/$pkg"-*.apk >/dev/null 2>&1; then
			log "have apk $pkg"
			continue
		fi
		if apk fetch -o "$DATA/apks" "$pkg" >>"$LOG" 2>&1; then
			log "fetched $pkg"
			continue
		fi
		if pack_installed "$pkg"; then
			continue
		fi
		log "backup miss $pkg"
	done < "$ETC/overlay-pkgs"
}

fetch_custom() {
	[ -f "$CUSTOM" ] || return 0
	while read -r name url; do
		[ -z "$name" ] && continue
		case "$name" in \#*) continue ;; esac
		[ -n "$url" ] || continue
		ls "$DATA/apks/${name}"-*.apk "$DATA/apks/${name}.apk" >/dev/null 2>&1 && continue
		[ -f "$DATA/files/${name}.files.tgz" ] && continue
		out="$DATA/apks/${name}.apk"
		log "fetch $name"
		if curl -fsSL --connect-timeout 15 --max-time 120 -o "$out.part" "$url"; then
			mv "$out.part" "$out"
		else
			rm -f "$out.part"
			log "fetch fail $name"
		fi
	done < "$CUSTOM"
}

cmd_status() {
	local root
	root=$(syskeep_detect_root) || root=""
	DATA="${root:+$root/syskeep}"
	STATUS="$DATA/status.json"
	FW="$DATA/firmware.img.gz"
	[ -n "$root" ] && syskeep_save_datadir "$root"
	echo "release=$(. /etc/openwrt_release; echo "$DISTRIB_DESCRIPTION")"
	echo "board=$(cat /tmp/sysinfo/board_name 2>/dev/null)"
	echo "data_path=$root"
	echo "data_mounted=$([ -n "$root" ] && echo 1 || echo 0)"
	echo "world=$(wc -l < /etc/apk/world 2>/dev/null)"
	echo "overlay=$(wc -l < $ETC/overlay-pkgs 2>/dev/null | tr -d ' ')"
	echo "apks=$(ls $DATA/apks/*.apk 2>/dev/null | wc -l | tr -d ' ')"
	echo "filepacks=$(ls $DATA/files/*.tgz 2>/dev/null | wc -l | tr -d ' ')"
	echo "pending=$([ -f $ETC/pending ] && echo 1 || echo 0)"
	echo "firmware=$([ -n "$FW" ] && [ -f "$FW" ] && wc -c < "$FW" || echo 0)"
	if [ -n "$STATUS" ] && [ -f "$STATUS" ]; then
		echo "json=$(cat "$STATUS")"
	fi
	echo "boot=$(findmnt -no SOURCE /boot 2>/dev/null)"
	echo "root=$(findmnt -no SOURCE /rom 2>/dev/null)"
	lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT -n 2>/dev/null | sed 's/^/disk /'
}

cmd_backup() {
	need_data || return 1
	write_status backup "备份配置和已装插件"
	cp /etc/apk/world "$ETC/world"
	cp /etc/apk/world "$DATA/world"
	date '+%F %T' > "$ETC/saved_at"
	chmod 755 "$ETC/restore.sh" 2>/dev/null || true
	backup_overlay_apks
	fetch_custom
	if sysupgrade -c -k -u -b "$DATA/sysupgrade.tgz"; then
		write_status backup "备份完成"
		log "backup $DATA/sysupgrade.tgz"
		return 0
	fi
	write_status error "备份失败"
	return 1
}

cmd_download() {
	need_data || return 1
	url="$1"
	[ -n "$url" ] || { echo "usage: $0 download <url>" >&2; return 1; }
	write_status backup "下载固件"
	if curl -fL --connect-timeout 15 --max-time 600 -o "$FW.part" "$url"; then
		mv "$FW.part" "$FW"
		write_status idle "固件已下载"
		ls -l "$FW"
		return 0
	fi
	rm -f "$FW.part"
	write_status error "固件下载失败"
	return 1
}

cmd_test() {
	need_data || return 1
	img="${1:-$FW}"
	[ -f "$img" ] || { echo "没有固件文件" >&2; return 1; }
	write_status backup "校验固件"
	if sysupgrade -T -c -k "$img"; then
		write_status idle "校验通过"
		return 0
	fi
	write_status error "固件校验失败"
	return 1
}

cmd_flash() {
	need_data || return 1
	img="${1:-$FW}"
	[ -f "$img" ] || { echo "没有固件文件" >&2; return 1; }
	[ -x /lib/upgrade/syskeep-hook.sh ] || {
		echo "缺少 /lib/upgrade/syskeep-hook.sh" >&2
		return 1
	}
	cmd_backup || return 1
	cmd_test "$img" || return 1
	touch "$ETC/pending"
	write_status flash "开始刷写 boot 与 rootfs，数据盘不改"
	log "flash $img"
	# SAVE_PARTITIONS stays 1. Do not pass -p.
	sysupgrade -c -k "$img"
}

cmd=${1:-status}
shift $(( $# > 0 ? 1 : 0 ))
case "$cmd" in
	status) cmd_status ;;
	backup) cmd_backup ;;
	download) cmd_download "$@" ;;
	test) cmd_test "$@" ;;
	flash) cmd_flash "$@" ;;
	restore) exec /etc/syskeep/restore.sh ;;
	datadir)
		root=$(syskeep_detect_root) || exit 1
		syskeep_save_datadir "$root"
		echo "$root"
		;;
	*)
		echo "usage: $0 status|backup|download <url>|test [file]|flash [file]|restore|datadir" >&2
		exit 1
		;;
esac
