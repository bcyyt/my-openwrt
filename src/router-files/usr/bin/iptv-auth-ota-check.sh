#!/bin/sh
# iptv-auth-ota-check.sh — OTA 更新定时检测（cron 每 12 小时调用 + 开机后延时一次）
# 职责：仅抓取并缓存 OTA 服务器的 version.json，并记录检测时间到 uci。
# 「是否有更新」的判断由 LuCI controller 统一完成（is_newer），保持单一逻辑源，
# 与状态页「检查更新」按钮、配置页逻辑完全一致。
# 失败时保留旧缓存（下次检测重试），仅成功时更新缓存与时间戳。

CACHE=/tmp/iptv-auth-ota-version.json
TMP="${CACHE}.new"

OTA_URL=$(uci -q get iptv-auth.main.ota_url 2>/dev/null)
[ -z "$OTA_URL" ] && exit 1

MIRROR=$(uci -q get iptv-auth.main.update_mirror 2>/dev/null)
FETCH_URL="$OTA_URL"
[ -n "$MIRROR" ] && case "$OTA_URL" in
	"$MIRROR"*) ;;
	http://*|https://*) FETCH_URL="$MIRROR$OTA_URL" ;;
esac

ok=0
if curl -s -m 20 -o "$TMP" "$FETCH_URL" 2>/dev/null && grep -q '"version"' "$TMP" 2>/dev/null; then
	ok=1
fi
if [ "$ok" != "1" ] && [ -z "$MIRROR" ]; then
	case "$OTA_URL" in
		*githubusercontent.com*|*github.com*)
			if curl -s -m 20 -o "$TMP" "https://gh-proxy.com/$OTA_URL" 2>/dev/null && grep -q '"version"' "$TMP" 2>/dev/null; then
				ok=1
			fi
			;;
	esac
fi
[ "$ok" = "1" ] || { rm -f "$TMP"; exit 1; }

mv "$TMP" "$CACHE"
uci set iptv-auth.main.ota_last_check="$(date '+%Y-%m-%d %H:%M')"
uci commit iptv-auth
exit 0
