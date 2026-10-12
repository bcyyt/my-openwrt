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
	[ -n "$LOG" ] || return 0
	echo "$(date '+%F %T') $*" >> "$LOG"
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

pkg_installed_id() {
	apk info -v 2>/dev/null | awk -v p="$1" '
		index($0, p "-") == 1 {
			rest = substr($0, length(p) + 2)
			if (rest ~ /^[0-9]/) { print $0; exit }
		}'
}

custom_url() {
	[ -f "$CUSTOM" ] || return 1
	awk -v n="$1" 'NF >= 2 && $1 == n { print $2; exit }' "$CUSTOM"
}

rm_pkg_apks() {
	local pkg="$1" keep="$2" f
	local base
	for f in "$DATA/apks"/*.apk; do
		[ -f "$f" ] || continue
		[ -n "$keep" ] && [ "$f" = "$keep" ] && continue
		base=$(basename "$f" .apk)
		syskeep_apk_for_pkg "$base" "$pkg" || continue
		rm -f "$f"
	done
}

find_pkg_apk() {
	local pkg="$1" id="$2" f base
	for f in "$DATA/apks"/*.apk; do
		[ -f "$f" ] || continue
		base=$(basename "$f" .apk)
		syskeep_apk_for_pkg "$base" "$pkg" || continue
		if [ -n "$id" ]; then
			[ "$base" = "$id" ] && { echo "$f"; return 0; }
			case "$base" in
				"$id"-*) echo "$f"; return 0 ;;
			esac
			continue
		fi
		echo "$f"
		return 0
	done
	return 1
}

fetch_custom_apk() {
	local pkg="$1" id="$2" url ubase out
	url=$(custom_url "$pkg")
	[ -n "$url" ] || return 1
	ubase=$(basename "$url" .apk)
	if [ "$ubase" != "$id" ] && [ "$ubase" != "$pkg" ]; then
		syskeep_apk_for_pkg "$ubase" "$pkg" || {
			log "custom url $pkg is $ubase, installed $id, skip"
			return 1
		}
	fi
	out="$DATA/apks/${ubase}.apk"
	log "fetch $pkg"
	if curl -fsSL --connect-timeout 15 --max-time 120 -o "$out.part" "$url"; then
		mv "$out.part" "$out"
		return 0
	fi
	rm -f "$out.part"
	log "fetch fail $pkg"
	return 1
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
	local pkg n total id want
	mkdir -p "$DATA/apks" "$DATA/files"
	list_overlay_pkgs > "$ETC/overlay-pkgs"
	cp "$ETC/overlay-pkgs" "$DATA/overlay-pkgs"
	[ -f "$CUSTOM" ] && cp "$CUSTOM" "$DATA/custom-apks.txt"
	total=$(wc -l < "$ETC/overlay-pkgs" | tr -d ' ')
	[ "$total" -gt 0 ] || { log "no overlay packages"; return 0; }
	apk update >>"$LOG" 2>&1 || true
	n=0
	while read -r pkg; do
		[ -n "$pkg" ] || continue
		n=$((n + 1))
		write_status backup "备份插件 $pkg ($n/$total)"
		id=$(pkg_installed_id "$pkg")
		want=$(find_pkg_apk "$pkg" "$id") || want=""
		if [ -n "$want" ]; then
			log "have apk $(basename "$want")"
			rm_pkg_apks "$pkg" "$want"
			rm -f "$DATA/files/$pkg.files.tgz"
			continue
		fi
		rm_pkg_apks "$pkg" ""
		if fetch_custom_apk "$pkg" "$id"; then
			rm -f "$DATA/files/$pkg.files.tgz"
			continue
		fi
		if apk fetch -o "$DATA/apks" "$pkg" >>"$LOG" 2>&1; then
			want=$(find_pkg_apk "$pkg" "$id") || want=$(find_pkg_apk "$pkg") || want=""
			if [ -n "$want" ]; then
				log "fetched $(basename "$want")"
				rm_pkg_apks "$pkg" "$want"
				rm -f "$DATA/files/$pkg.files.tgz"
				continue
			fi
			log "repo apk for $pkg is not $id, keep installed files"
			rm_pkg_apks "$pkg" ""
		fi
		if pack_installed "$pkg"; then
			continue
		fi
		log "backup miss $pkg"
	done < "$ETC/overlay-pkgs"
	purge_unlisted_cache
}

purge_unlisted_cache() {
	local f base pkg listed
	[ -f "$ETC/overlay-pkgs" ] || return 0
	for f in "$DATA/apks"/*.apk; do
		[ -f "$f" ] || continue
		base=$(basename "$f" .apk)
		listed=0
		while read -r pkg; do
			[ -n "$pkg" ] || continue
			if syskeep_apk_for_pkg "$base" "$pkg"; then
				listed=1
				break
			fi
		done < "$ETC/overlay-pkgs"
		[ "$listed" = 1 ] || rm -f "$f"
	done
	for f in "$DATA/files"/*.files.tgz; do
		[ -f "$f" ] || continue
		pkg=$(basename "$f" .files.tgz)
		grep -qx "$pkg" "$ETC/overlay-pkgs" 2>/dev/null || rm -f "$f"
	done
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
	log "======== 备份开始 ========"
	cp /etc/apk/world "$ETC/world"
	cp /etc/apk/world "$DATA/world"
	awk '{gsub(/[=<>].*/,""); print}' /rom/etc/apk/world 2>/dev/null | sort -u > "$ETC/rom-world"
	cp "$ETC/rom-world" "$DATA/rom-world" 2>/dev/null || true
	awk '{gsub(/[=<>].*/,""); print}' /etc/apk/world | sort -u > /tmp/syskeep.world.$$
	awk 'NR==FNR {a[$1]=1; next} !a[$1]' /tmp/syskeep.world.$$ "$ETC/rom-world" > "$ETC/removed-pkgs"
	cp "$ETC/removed-pkgs" "$DATA/removed-pkgs"
	rm -f /tmp/syskeep.world.$$
	syskeep_backup_uci "$ETC/uci"
	syskeep_backup_uci "$DATA/uci"
	date '+%F %T' > "$ETC/saved_at"
	chmod 755 "$ETC/restore.sh" 2>/dev/null || true
	log "配置已保存，开始备份自装插件"
	backup_overlay_apks
	log "正在打包 sysupgrade.tgz"
	if sysupgrade -c -k -u -b "$DATA/sysupgrade.tgz" >>"$LOG" 2>&1; then
		log "备份完成 $DATA/sysupgrade.tgz"
		write_status idle "备份完成"
		return 0
	fi
	write_status error "备份失败"
	log "备份失败"
	return 1
}

cmd_download() {
	need_data || return 1
	url="$1"
	[ -n "$url" ] || { echo "usage: $0 download <url>" >&2; return 1; }
	write_status backup "下载固件"
	log "======== 下载固件 ========"
	log "url $url"
	if curl -fL --connect-timeout 15 --max-time 600 -o "$FW.part" "$url"; then
		mv "$FW.part" "$FW"
		write_status idle "固件已下载"
		log "固件已下载 $FW"
		ls -l "$FW"
		return 0
	fi
	rm -f "$FW.part"
	write_status error "固件下载失败"
	log "固件下载失败"
	return 1
}

cmd_test() {
	need_data || return 1
	img="${1:-$FW}"
	[ -f "$img" ] || { echo "没有固件文件" >&2; return 1; }
	write_status backup "校验固件"
	log "校验固件 $img"
	if sysupgrade -T -c -k "$img" >>"$LOG" 2>&1; then
		write_status idle "校验通过"
		log "校验通过"
		return 0
	fi
	write_status error "固件校验失败"
	log "固件校验失败"
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
	log "======== 升级开始 ========"
	cmd_backup || return 1
	cmd_test "$img" || return 1
	touch "$ETC/pending"
	write_status flash "开始刷写 boot 与 rootfs，数据盘不改"
	log "开始刷写 $img"
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
