#!/bin/sh
# Reinstall packages after sysupgrade. Lives under /etc so Keep Config retains it.

ETC=/etc/syskeep
WORLD="$ETC/world"
. /etc/syskeep/datadir.sh

log() {
	echo "$(date '+%F %T') $*" | tee -a "$LOG"
}

write_status() {
	local phase="$1" msg="$2"
	printf '{"phase":"%s","message":"%s","fail":[%s]}\n' "$phase" "$msg" "$FAIL_JSON" > "$STATUS"
}

FAIL_JSON=""
add_fail() {
	if [ -z "$FAIL_JSON" ]; then
		FAIL_JSON="\"$1\""
	else
		FAIL_JSON="$FAIL_JSON,\"$1\""
	fi
}

[ -f "$ETC/pending" ] || [ -f "$ETC/restoring" ] || exit 0
mv "$ETC/pending" "$ETC/restoring" 2>/dev/null || true
echo "$(date '+%F %T') restore begin" >> "$ETC/boot.log"

ROOT=$(syskeep_wait_root 30) || ROOT=""
if [ -z "$ROOT" ]; then
	echo "$(date '+%F %T') no data disk" >&2
	mv "$ETC/restoring" "$ETC/pending" 2>/dev/null || true
	exit 1
fi
syskeep_save_datadir "$ROOT"
DATA="$ROOT/syskeep"
STATUS="$DATA/status.json"
LOG="$DATA/restore.log"
[ -f "$WORLD" ] || WORLD="$DATA/world"
mkdir -p "$DATA"

write_status restore "等待网络"
ok=0
i=0
while [ "$i" -lt 90 ]; do
	if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1; then
		ok=1
		break
	fi
	i=$((i + 1))
	sleep 2
done
if [ "$ok" != "1" ]; then
	log "network not ready"
	write_status error "网络未就绪，稍后可在页面点重新恢复"
	mv "$ETC/restoring" "$ETC/pending" 2>/dev/null || true
	exit 1
fi

write_status restore "更新软件源"
apk update >>"$LOG" 2>&1 || log "apk update failed, continue"

write_status restore "安装已备份 APK"
OVERLAY="$ETC/overlay-pkgs"
[ -f "$OVERLAY" ] || OVERLAY="$DATA/overlay-pkgs"
overlay_has() {
	[ -f "$OVERLAY" ] || return 1
	grep -qx "$1" "$OVERLAY"
}

if [ -f "$OVERLAY" ]; then
	total=$(grep -cve '^$' "$OVERLAY" 2>/dev/null || echo 0)
	n=0
	while read -r pkg; do
		[ -n "$pkg" ] || continue
		n=$((n + 1))
		write_status restore "安装 $pkg ($n/$total)"
		ok=0
		for f in "$DATA/apks"/*.apk; do
			[ -f "$f" ] || continue
			base=$(basename "$f")
			syskeep_apk_for_pkg "$(basename "$f" .apk)" "$pkg" || continue
			if apk add --allow-untrusted "$f" >>"$LOG" 2>&1; then
				log "ok $base"
				ok=1
				break
			fi
			log "fail $base"
			add_fail "$base"
		done
	done < "$OVERLAY"
elif [ -d "$DATA/apks" ]; then
	for f in "$DATA/apks"/*.apk; do
		[ -f "$f" ] || continue
		base=$(basename "$f")
		write_status restore "安装 $base"
		if apk add --allow-untrusted "$f" >>"$LOG" 2>&1; then
			log "ok $base"
		else
			log "fail $base"
			add_fail "$base"
		fi
	done
fi

write_status restore "解开文件包"
if [ -d "$DATA/files" ]; then
	for f in "$DATA/files"/*.files.tgz; do
		[ -f "$f" ] || continue
		base=$(basename "$f" .files.tgz)
		if [ -f "$OVERLAY" ] && ! overlay_has "$base"; then
			log "skip files $base"
			continue
		fi
		if apk info -e "$base" >/dev/null 2>&1; then
			continue
		fi
		write_status restore "解开 $base"
		if tar -xzf "$f" -C / >>"$LOG" 2>&1; then
			log "ok files $base"
		else
			log "fail files $base"
			add_fail "$base.files"
		fi
	done
fi

if [ -f "$WORLD" ]; then
	total=$(grep -cve '^#' -e '^$' "$WORLD" 2>/dev/null || echo 0)
	n=0
	while read -r line; do
		[ -z "$line" ] && continue
		case "$line" in \#*) continue ;; esac
		pkg=${line%%=*}
		pkg=${pkg%%[<>]*}
		n=$((n + 1))
		write_status restore "重装 $pkg ($n/$total)"
		if overlay_has "$pkg"; then
			continue
		fi
		if apk info -e "$pkg" >/dev/null 2>&1; then
			continue
		fi
		if apk add "$pkg" >>"$LOG" 2>&1; then
			log "ok $pkg"
		else
			log "fail $pkg"
			add_fail "$pkg"
		fi
	done < "$WORLD"
fi

write_status restore "还原网络、接口和防火墙"
if [ -d "$DATA/uci" ]; then
	syskeep_restore_uci "$DATA/uci"
elif [ -d "$ETC/uci" ]; then
	syskeep_restore_uci "$ETC/uci"
fi
/etc/init.d/network reload >/dev/null 2>&1 || true
/etc/init.d/firewall restart >/dev/null 2>&1 || true
wifi reload >/dev/null 2>&1 || true

write_status restore "卸载刷机前已移除的插件"
REMOVED="$ETC/removed-pkgs"
[ -f "$REMOVED" ] || REMOVED="$DATA/removed-pkgs"
if [ -f "$REMOVED" ]; then
	while read -r line; do
		[ -n "$line" ] || continue
		pkg=$(syskeep_pkg_name "$line")
		[ -n "$pkg" ] || continue
		overlay_has "$pkg" && continue
		apk info -e "$pkg" >/dev/null 2>&1 || continue
		if apk del "$pkg" >>"$LOG" 2>&1; then
			log "del $pkg"
		else
			log "del fail $pkg"
		fi
	done < "$REMOVED"
fi

rm -f "$ETC/restoring"
write_status done "恢复结束"
log "restore finished"
exit 0
