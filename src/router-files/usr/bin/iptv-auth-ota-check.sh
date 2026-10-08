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

if ! curl -s -m 20 -o "$TMP" "$OTA_URL" 2>/dev/null; then
    rm -f "$TMP"
    exit 1
fi

# 有效性校验：必须包含 "version" 字段（防止把 404 页面等错误响应当缓存）
grep -q '"version"' "$TMP" 2>/dev/null || { rm -f "$TMP"; exit 1; }

mv "$TMP" "$CACHE"
uci set iptv-auth.main.ota_last_check="$(date '+%Y-%m-%d %H:%M')"
uci commit iptv-auth
exit 0
