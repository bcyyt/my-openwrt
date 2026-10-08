#!/bin/sh
# rtp2httpd-update.sh — 手动更新 rtp2httpd 二进制（由 LuCI 配置页调用）
# 用法: rtp2httpd-update.sh <版本号|latest>
# 流程: 解析版本 → 下载到 /usr/bin/rtp2httpd.new（同文件系统）→ 验证可执行
#       → mv 原子替换（运行中的旧进程持有原 inode，不受影响）
#       → killall 触发 procd 按 respawn 策略自动拉起新版（python/鉴权不受影响）
# 状态写入 /tmp/rtp2httpd-update.json 供 LuCI 轮询
STATUS=/tmp/rtp2httpd-update.json
API="https://api.github.com/repos/stackia/rtp2httpd/releases/latest"

set_status() {
    # $1=state $2=message $3=version
    echo "{\"state\":\"$1\",\"message\":\"$2\",\"version\":\"$3\"}" > "$STATUS"
}

ARCH=$(grep DISTRIB_ARCH /etc/openwrt_release 2>/dev/null | cut -d"'" -f2)
[ -n "$ARCH" ] || ARCH=x86_64

VER="$1"
[ -n "$VER" ] || VER=latest

# 并发保护：已有任务运行时静默退出（不写状态，避免覆盖正在进行任务的进度）
if [ -f "$STATUS" ] && grep -q '"state":"running"' "$STATUS" 2>/dev/null; then
    echo "concurrent update detected, exiting" >&2
    exit 1
fi

# 立即占位，缩小并发窗口
set_status "running" "正在准备更新 (v$VER)" "$VER"

MIRROR=$(uci -q get iptv-auth.main.update_mirror 2>/dev/null)

# latest → 查询 GitHub API（支持镜像前缀）
if [ "$VER" = "latest" ]; then
    API_URL="$API"
    [ -n "$MIRROR" ] && API_URL="$MIRROR$API"
    VER=$(curl -s -m 15 "$API_URL" 2>/dev/null | grep -oE '"tag_name": *"[^"]+"' | cut -d'"' -f4 | sed 's/^v//')
    if [ -z "$VER" ]; then
        set_status "failed" "无法查询最新版本（GitHub 不可达，可在 LuCI 设置镜像前缀后重试）" ""
        exit 1
    fi
fi

case "$ARCH" in
    x86_64)   BIN="rtp2httpd-$VER-x86_64" ;;
    aarch64*) BIN="rtp2httpd-$VER-aarch64" ;;
    *)        BIN="rtp2httpd-$VER-$ARCH" ;;
esac
URL="https://github.com/stackia/rtp2httpd/releases/download/v$VER/$BIN"
[ -n "$MIRROR" ] && URL="$MIRROR$URL"

set_status "running" "正在下载 v$VER（$BIN）" "$VER"
NEW=/usr/bin/rtp2httpd.new.$$
rm -f "$NEW"
if ! curl -sL -m 90 -o "$NEW" "$URL"; then
    set_status "failed" "下载失败: $URL" "$VER"
    rm -f "$NEW"
    exit 1
fi
if [ ! -s "$NEW" ]; then
    set_status "failed" "下载失败（文件为空）: $URL" "$VER"
    rm -f "$NEW"
    exit 1
fi
chmod 755 "$NEW"

# 验证：新文件必须能执行且输出版本号（防止架构不符/文件损坏）
NEWVER=$("$NEW" --help 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [ -z "$NEWVER" ]; then
    set_status "failed" "下载的文件无法执行（架构不符或已损坏）" "$VER"
    rm -f "$NEW"
    exit 1
fi

# 同文件系统 mv = rename，原子替换；旧进程继续持有原 inode 正常运行
if ! mv -f "$NEW" /usr/bin/rtp2httpd; then
    set_status "failed" "替换 /usr/bin/rtp2httpd 失败" "$VER"
    rm -f "$NEW"
    exit 1
fi
chmod 755 /usr/bin/rtp2httpd

# killall 全部 rtp2httpd 进程（supervisor+workers），procd 在 respawn 超时(5s)后拉起新版
set_status "running" "正在重启 rtp2httpd (v$VER)" "$VER"
killall rtp2httpd 2>/dev/null
sleep 7

if [ -n "$(pidof rtp2httpd 2>/dev/null)" ]; then
    set_status "done" "更新完成，rtp2httpd 已运行 v$NEWVER" "$NEWVER"
    exit 0
else
    set_status "failed" "rtp2httpd 未能自动拉起，请手动执行 /etc/init.d/iptv-auth restart" "$VER"
    exit 1
fi
