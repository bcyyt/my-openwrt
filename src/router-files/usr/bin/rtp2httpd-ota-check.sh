#!/bin/sh
# rtp2httpd-ota-check.sh — rtp2httpd 更新定时检测（cron 每 12 小时调用 + 开机后延时一次）
# 职责：仅抓取本仓库 version.json 的最新版本号并缓存到 /tmp，记录检测时间到 uci。
# 「是否有更新」的判断由状态页模板完成（读缓存 + --help 当前版本比较），
# 与 rtp2httpd 页「检查更新」按钮逻辑保持一致。
# 失败时保留旧缓存（下次检测重试），仅成功时更新缓存与时间戳。

CACHE=/tmp/rtp2httpd-version.json
TMP="${CACHE}.new"

API="https://raw.githubusercontent.com/bcyyt/my-openwrt/main/packages/rtp2httpd/version.json"
MIRROR=$(uci -q get iptv-auth.main.update_mirror 2>/dev/null)
[ -n "$MIRROR" ] && API="$MIRROR$API"

if ! curl -s -m 20 -o "$TMP" "$API" 2>/dev/null; then
    rm -f "$TMP"
    exit 1
fi

# 提取 version（如 "3.17.2"）
VER=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TMP" | head -1)
[ -z "$VER" ] && { rm -f "$TMP"; exit 1; }

echo "{\"latest\":\"$VER\"}" > "$TMP"
grep -q '"latest"' "$TMP" 2>/dev/null || { rm -f "$TMP"; exit 1; }

mv "$TMP" "$CACHE"
uci set iptv-auth.main.rtp2_last_check="$(date '+%Y-%m-%d %H:%M')"
uci commit iptv-auth
exit 0
