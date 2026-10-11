#!/bin/sh
# rtp2httpd-ota-check.sh — rtp2httpd 更新定时检测（cron 每 12 小时调用 + 开机后延时一次）
# 职责：抓取本仓库 version.json 的 latest，并查询官方 GitHub Release 的 tag。
# 状态页用 latest 判断能否 OTA；用 official 判断是否需要重新编译。
# 失败时保留旧缓存（下次检测重试），仅成功拿到仓库 latest 时更新缓存与时间戳。

CACHE=/tmp/rtp2httpd-version.json
TMP="${CACHE}.new"

REPO="https://raw.githubusercontent.com/bcyyt/my-openwrt/main/packages/rtp2httpd/version.json"
OFFICIAL_API="https://api.github.com/repos/stackia/rtp2httpd/releases/latest"
MIRROR=$(uci -q get iptv-auth.main.update_mirror 2>/dev/null)
REPO_URL="$REPO"
OFFICIAL_URL="$OFFICIAL_API"
[ -n "$MIRROR" ] && REPO_URL="$MIRROR$REPO"
[ -n "$MIRROR" ] && OFFICIAL_URL="$MIRROR$OFFICIAL_API"

if ! curl -s -m 20 -o "$TMP" "$REPO_URL" 2>/dev/null; then
    rm -f "$TMP"
    exit 1
fi

VER=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TMP" | head -1)
[ -z "$VER" ] && { rm -f "$TMP"; exit 1; }

OFFICIAL=""
OFF_JSON=$(curl -s -m 20 "$OFFICIAL_URL" 2>/dev/null)
if [ -n "$OFF_JSON" ]; then
    OFFICIAL=$(printf '%s\n' "$OFF_JSON" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/p' | head -1)
fi
if [ -z "$OFFICIAL" ] && [ -f "$CACHE" ]; then
    OFFICIAL=$(sed -n 's/.*"official"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CACHE" | head -1)
fi

if [ -n "$OFFICIAL" ]; then
    echo "{\"latest\":\"$VER\",\"official\":\"$OFFICIAL\"}" > "$TMP"
else
    echo "{\"latest\":\"$VER\"}" > "$TMP"
fi

grep -q '"latest"' "$TMP" 2>/dev/null || { rm -f "$TMP"; exit 1; }

mv "$TMP" "$CACHE"
uci set iptv-auth.main.rtp2_last_check="$(date '+%Y-%m-%d %H:%M')"
uci commit iptv-auth
exit 0
