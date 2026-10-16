#!/bin/bash
# Build iptv-replayd static musl binaries for x86_64 and aarch64.
# Usage: packaging/iptv-replayd/build.sh
#
# 复用 cross-tools/musl-cross 官方工具链（与 rtp2httpd 同版本，避免重复下载）。
# 产物落盘到 packages/iptv-replayd/，供 packaging/build-apks.sh 打进 iptv-auth apk。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/src/iptv-replayd/iptv-replayd.c"
OUT="$ROOT/packages/iptv-replayd"
DATE_STR="$(date +%Y-%m-%d)"

TOOLCHAIN_RELEASE="20260823"
TOOLCHAIN_BASE_URL="https://github.com/cross-tools/musl-cross/releases/download"
WORK="/tmp/opencode/iptv-replayd-build"
TOOLCHAIN_ROOT="$WORK/toolchain"
# 已存在的 rtp2httpd 工具链可直接复用
ALT_TOOLCHAIN="/tmp/opencode/rtp2httpd-build/3.17.2/rtp2httpd-3.17.2/toolchain"

REPLAYD_VER="${REPLAYD_VER:-1.0.2}"

if [ ! -f "$SRC" ]; then
	echo "ERROR: source not found: $SRC" >&2
	exit 1
fi

mkdir -p "$OUT" "$TOOLCHAIN_ROOT"

resolve_toolchain() {
	# $1 = prefix（x86_64-unknown-linux-musl 等）
	local prefix="$1"
	local dir
	for dir in "$TOOLCHAIN_ROOT/$prefix" "$ALT_TOOLCHAIN/$prefix"; do
		if [ -x "$dir/bin/$prefix-gcc" ]; then
			echo "$dir"
			return 0
		fi
	done
	# 本地没有则下载官方工具链
	local archive="$prefix.tar.xz"
	echo "download toolchain $prefix" >&2
	curl -fL --connect-timeout 20 --max-time 600 -o "$TOOLCHAIN_ROOT/$archive" \
		"$TOOLCHAIN_BASE_URL/$TOOLCHAIN_RELEASE/$archive" >&2
	tar -xf "$TOOLCHAIN_ROOT/$archive" -C "$TOOLCHAIN_ROOT"
	rm -f "$TOOLCHAIN_ROOT/$archive"
	echo "$TOOLCHAIN_ROOT/$prefix"
}

build_one() {
	local prefix="$1" suffix="$2"
	local tc bin
	tc="$(resolve_toolchain "$prefix")"
	bin="$OUT/iptv-replayd-${REPLAYD_VER}-${suffix}"
	echo "build ${suffix} (${prefix})"
	"$tc/bin/$prefix-gcc" -O2 -static -pthread -Wall -Wextra \
		-o "$bin" "$SRC"
	file "$bin"
}

build_one "x86_64-unknown-linux-musl" "x86_64"
build_one "aarch64-unknown-linux-musl" "aarch64"

cat > "$OUT/version.json" <<EOF
{
  "version": "${REPLAYD_VER}",
  "date": "${DATE_STR}",
  "changelog": "iptv-replayd：独立 C 回看 RTSP 代理（无 Python 依赖），静态 musl；1.0.2 将 playseek programend 收敛到当前时刻前 2 秒（修复上游对未来窗口返回 562 导致的回看失败），转发阶段提前释放握手缓冲区并复用入口线程转发 S→C，运行时状态单次读盘、listen backlog 提升。",
  "url_x86_64": "iptv-replayd-${REPLAYD_VER}-x86_64",
  "url_aarch64": "iptv-replayd-${REPLAYD_VER}-aarch64"
}
EOF

echo "wrote $OUT/version.json"
ls -l "$OUT"
