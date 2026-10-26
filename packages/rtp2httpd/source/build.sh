#!/bin/bash
# Build patched rtp2httpd static musl binaries for x86_64 and aarch64.
# Usage: packaging/rtp2httpd/build.sh [upstream-version] [release-version]
# Example: packaging/rtp2httpd/build.sh 3.17.2 3.17.2-r1

set -euo pipefail

VER="${1:-3.17.2}"
REL="${2:-${REL_VER:-$VER}}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PATCH="$ROOT/packaging/rtp2httpd/buffer-pool-1024.patch"
SEEK_PATCH="$ROOT/packaging/rtp2httpd/catchup-keep-seek-mode.patch"
HUP_PATCH="$ROOT/packaging/rtp2httpd/client-hup-and-timeout.patch"
OUT="$ROOT/packages/rtp2httpd"
OTA_BASE="https://raw.githubusercontent.com/bcyyt/my-openwrt/main/packages/rtp2httpd"
WORK="/tmp/opencode/rtp2httpd-build/${VER}"
SRC="$WORK/rtp2httpd-${VER}"
DATE_STR="$(date +%Y-%m-%d)"

mkdir -p "$WORK" "$OUT"

if [ ! -f "$SRC/scripts/build-static.sh" ]; then
	echo "download rtp2httpd v${VER}"
	curl -fL --connect-timeout 20 --max-time 180 -o "$WORK/src.tar.gz" \
		"https://github.com/stackia/rtp2httpd/archive/refs/tags/v${VER}.tar.gz"
	tar -xzf "$WORK/src.tar.gz" -C "$WORK"
fi

if grep -q 'BUFFER_POOL_INITIAL_SIZE 128' "$SRC/src/buffer_pool.h"; then
	patch -p1 -d "$SRC" < "$PATCH"
fi
if grep -q 'BUFFER_POOL_INITIAL_SIZE 512' "$SRC/src/buffer_pool.h"; then
	sed -i 's/BUFFER_POOL_INITIAL_SIZE 512/BUFFER_POOL_INITIAL_SIZE 1024/; s/BUFFER_POOL_EXPAND_SIZE 512/BUFFER_POOL_EXPAND_SIZE 1024/' "$SRC/src/buffer_pool.h"
fi
if ! grep -q 'append_catchup_control_params' "$SRC/src/m3u.c"; then
	patch -p1 -d "$SRC" < "$SEEK_PATCH"
fi
grep -q 'append_catchup_control_params' "$SRC/src/m3u.c"
if grep -q 'CONNECTION_TCP_USER_TIMEOUT_MS 10000' "$SRC/src/connection.c"; then
	patch -p1 -d "$SRC" < "$HUP_PATCH"
fi
grep -q 'CONNECTION_TCP_USER_TIMEOUT_MS 600000' "$SRC/src/connection.c"

build_one() {
	local prefix="$1" suffix="$2"
	echo "build ${suffix} (${prefix})"
	(
		cd "$SRC"
		RELEASE_VERSION="$REL" TOOLCHAIN_PREFIX="$prefix" bash scripts/build-static.sh
	)
	local bin="$SRC/build-${prefix}-static/dist/usr/bin/rtp2httpd"
	install -m 755 "$bin" "$OUT/rtp2httpd-${REL}-${suffix}"
	file "$OUT/rtp2httpd-${REL}-${suffix}"
}

build_one "x86_64-unknown-linux-musl" "x86_64"
build_one "aarch64-unknown-linux-musl" "aarch64"

SRC_OUT="$OUT/source"
mkdir -p "$SRC_OUT"
if [ -f "$WORK/src.tar.gz" ]; then
	cp -f "$WORK/src.tar.gz" "$SRC_OUT/upstream-rtp2httpd-${VER}.tar.gz"
fi
cp -f "$PATCH" "$SEEK_PATCH" "$HUP_PATCH" "$SRC_OUT/"
cp -f "$ROOT/packaging/rtp2httpd/build.sh" "$SRC_OUT/build.sh"
if [ -f "$SRC_OUT/upstream-rtp2httpd-${VER}.tar.gz" ]; then
	SRC_SHA="$(sha256sum "$SRC_OUT/upstream-rtp2httpd-${VER}.tar.gz" | awk '{print $1}')"
	sed -e "s|__SRC_SHA__|$SRC_SHA|g" \
	    -e "s|__VER__|${VER}|g" \
	    -e "s|__REL__|${REL}|g" \
	    -e "s|__X86_MD5__|$(md5sum "$OUT/rtp2httpd-${REL}-x86_64" | awk '{print $1}')|g" \
	    -e "s|__ARM_MD5__|$(md5sum "$OUT/rtp2httpd-${REL}-aarch64" | awk '{print $1}')|g" \
	    -e "s|__X86_SHA__|$(sha256sum "$OUT/rtp2httpd-${REL}-x86_64" | awk '{print $1}')|g" \
	    -e "s|__ARM_SHA__|$(sha256sum "$OUT/rtp2httpd-${REL}-aarch64" | awk '{print $1}')|g" \
	    "$ROOT/packaging/rtp2httpd/SOURCE.md.in" > "$SRC_OUT/SOURCE.md"
fi

cat > "$OUT/version.json" <<EOF
{
  "version": "${REL}",
  "date": "${DATE_STR}",
  "changelog": "自编译：BUFFER_POOL_INITIAL_SIZE=1024，EXPAND_SIZE=1024；导出 playlist.m3u 时保留 r2h-seek-mode / r2h-seek-offset / r2h-ifname；客户端半关闭不主动断流，TCP_USER_TIMEOUT 600s。GPL-2.0，修改后完整源码见同目录 source/。",
  "license": "GPL-2.0",
  "notice": "${OTA_BASE}/NOTICE.md",
  "source": "${OTA_BASE}/source/SOURCE.md",
  "url": "${OTA_BASE}/rtp2httpd-${REL}-x86_64",
  "url_aarch64": "${OTA_BASE}/rtp2httpd-${REL}-aarch64"
}
EOF

echo "wrote $OUT/version.json"
ls -l "$OUT"
