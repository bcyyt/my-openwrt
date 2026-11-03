#!/bin/bash
# Build patched rtp2httpd static musl binaries for x86_64 and aarch64.
# Usage: packages/rtp2httpd/source/build.sh [upstream-version] [release-version]
# Example: packages/rtp2httpd/source/build.sh 3.17.2 3.17.2-r4
#
# Current baseline: 3.17.2-r4 = upstream v3.17.2 + the 4 small patches in this
# directory (buffer-pool-1024 / catchup-keep-seek-mode / client-hup-and-timeout
# / logo-rewrite-host). TCP_USER_TIMEOUT stays at the upstream 10s.
#
# Applies the 4 patches onto the upstream tarball, then builds both
# architectures via upstream's scripts/build-static.sh (musl-cross 20260823
# toolchains auto-downloaded).

set -euo pipefail

VER="${1:-3.17.2}"
REL="${2:-3.17.2-r4}"
HERE="$(cd "$(dirname "$0")" && pwd)"   # packages/rtp2httpd/source
OUT="$(cd "$HERE/.." && pwd)"           # packages/rtp2httpd
PATCHES=(buffer-pool-1024.patch catchup-keep-seek-mode.patch
         client-hup-and-timeout.patch logo-rewrite-host.patch)
WORK="/tmp/r2h-build-${VER}"
SRC="$WORK/rtp2httpd-${VER}"

mkdir -p "$WORK" "$OUT"

if [ ! -f "$SRC/scripts/build-static.sh" ]; then
        if [ ! -f "$HERE/upstream-rtp2httpd-${VER}.tar.gz" ]; then
                curl -fL -o "$HERE/upstream-rtp2httpd-${VER}.tar.gz" \
                        "https://github.com/stackia/rtp2httpd/archive/refs/tags/v${VER}.tar.gz"
        fi
        rm -rf "$SRC"
        tar -xzf "$HERE/upstream-rtp2httpd-${VER}.tar.gz" -C "$WORK"
fi

for p in "${PATCHES[@]}"; do
        patch -d "$SRC" -p1 --forward < "$HERE/$p"
done
# Sanity: withdrawn recovery/pause symbols must not appear in this baseline
if grep -q 'stalled_ticks' "$SRC/src/stream.h" "$SRC/src/stream.c" 2>/dev/null; then
        echo "unexpected stalled_ticks in baseline" >&2
        exit 1
fi

build_one() {
        local prefix="$1" suffix="$2"
        echo "build ${suffix} (${prefix})"
        (
                cd "$SRC"
                RELEASE_VERSION="$REL" TOOLCHAIN_PREFIX="$prefix" bash scripts/build-static.sh
        )
        local bin="$SRC/build-${prefix}-static/dist/usr/bin/rtp2httpd"
        install -m 755 "$bin" "$OUT/rtp2httpd-${REL}-${suffix}"
        ls -l "$OUT/rtp2httpd-${REL}-${suffix}"
}

build_one "x86_64-unknown-linux-musl" "x86_64"
build_one "aarch64-unknown-linux-musl" "aarch64"

echo "done. refresh md5/sha256 in $HERE/SOURCE.md before publishing."
