#!/bin/bash
# Build patched rtp2httpd static musl binaries for x86_64 and aarch64.
# Usage: packaging/rtp2httpd/build.sh [upstream-version]
# Example: packaging/rtp2httpd/build.sh 3.17.2

set -euo pipefail

VER="${1:-3.17.2}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PATCH="$ROOT/packaging/rtp2httpd/buffer-pool-1024.patch"
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
grep -q 'BUFFER_POOL_INITIAL_SIZE 1024' "$SRC/src/buffer_pool.h"

build_one() {
	local prefix="$1" suffix="$2"
	echo "build ${suffix} (${prefix})"
	(
		cd "$SRC"
		RELEASE_VERSION="$VER" TOOLCHAIN_PREFIX="$prefix" bash scripts/build-static.sh
	)
	local bin="$SRC/build-${prefix}-static/dist/usr/bin/rtp2httpd"
	install -m 755 "$bin" "$OUT/rtp2httpd-${VER}-${suffix}"
	file "$OUT/rtp2httpd-${VER}-${suffix}"
}

build_one "x86_64-unknown-linux-musl" "x86_64"
build_one "aarch64-unknown-linux-musl" "aarch64"

cat > "$OUT/version.json" <<EOF
{
  "version": "${VER}",
  "date": "${DATE_STR}",
  "changelog": "自编译：BUFFER_POOL_INITIAL_SIZE=1024，EXPAND_SIZE=1024。",
  "url": "${OTA_BASE}/rtp2httpd-${VER}-x86_64",
  "url_aarch64": "${OTA_BASE}/rtp2httpd-${VER}-aarch64"
}
EOF

echo "wrote $OUT/version.json"
ls -l "$OUT"
