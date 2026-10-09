#!/bin/bash
# Build signed OpenWrt APKv3 packages for iptv-auth / mediahub / statusmon / netqueue / syskeep

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src/router-files"
PACK="$ROOT/packaging"
OUT="$ROOT/packages"
KEYS="$ROOT/keys"
APK="${APK:-/tmp/apk-tools/build/src/apk}"
SIGN_KEY="$KEYS/my-openwrt.rsa"
PUB_KEY="$KEYS/my-openwrt.rsa.pub"

IPTV_VER="${IPTV_VER:-2.3.11-r0}"
MEDIA_VER="${MEDIA_VER:-1.5.4-r0}"
STATUS_VER="${STATUS_VER:-4.23}"
NETQ_VER="${NETQ_VER:-1.0.1-r0}"
SYSKEEP_VER="${SYSKEEP_VER:-1.0.2-r0}"
DATE_STR="$(date +%Y-%m-%d)"
OTA_URL_BASE="https://raw.githubusercontent.com/bcyyt/my-openwrt/main/packages"

if [ ! -x "$APK" ]; then
	echo "ERROR: apk-tools binary not found at $APK" >&2
	exit 1
fi
if [ ! -f "$SIGN_KEY" ] || [ ! -f "$PUB_KEY" ]; then
	echo "ERROR: signing keys missing in $KEYS" >&2
	exit 1
fi

mkdir -p "$OUT/iptv-auth" "$OUT/luci-app-mediahub" "$OUT/luci-app-statusmon" "$OUT/luci-app-netqueue" "$OUT/luci-app-syskeep" "$OUT/keys"
cp -a "$PUB_KEY" "$OUT/keys/my-openwrt.rsa.pub"
install -m 600 "$SIGN_KEY" "$OUT/keys/my-openwrt.rsa"

mkpkg() {
	local name="$1" version="$2" arch="$3" desc="$4" origin="$5" license="$6" url="$7"
	local files_dir="$8" out_apk="$9"
	shift 9
	local extra=("$@")
	"$APK" mkpkg --sign-key "$SIGN_KEY" \
		--compat 3.0.0 \
		-I "name:$name" \
		-I "version:$version" \
		-I "arch:$arch" \
		-I "description:$desc" \
		-I "origin:$origin" \
		-I "license:$license" \
		-I "url:$url" \
		-I "maintainer:bcyyt <bcyyt@users.noreply.github.com>" \
		"${extra[@]}" \
		-F "$files_dir" \
		-o "$out_apk"
	echo "built $(basename "$out_apk") ($(du -h "$out_apk" | awk '{print $1}'))"
}

# ---------- IPTV 代理 ----------
IPTV_ROOT="$(mktemp -d /tmp/pkg-iptv.XXXXXX)"
trap 'rm -rf "$IPTV_ROOT" "$MEDIA_ROOT" "$STATUS_ROOT" "$NETQ_ROOT" "$SYSKEEP_ROOT"' EXIT

install -d "$IPTV_ROOT/etc/config" "$IPTV_ROOT/etc/init.d" "$IPTV_ROOT/etc/uci-defaults" \
	"$IPTV_ROOT/etc/hotplug.d/iface" \
	"$IPTV_ROOT/usr/bin" \
	"$IPTV_ROOT/usr/lib/lua/luci/controller" \
	"$IPTV_ROOT/usr/lib/lua/luci/model/cbi/iptv_auth" \
	"$IPTV_ROOT/usr/lib/lua/luci/view/iptv_auth" \
	"$IPTV_ROOT/usr/share/iptv-auth/logos"

install -m 644 "$PACK/iptv-auth/files/etc/config/iptv-auth" "$IPTV_ROOT/etc/config/iptv-auth"
install -m 755 "$SRC/etc/init.d/iptv-auth" "$IPTV_ROOT/etc/init.d/iptv-auth"
install -m 755 "$SRC/etc/hotplug.d/iface/99-iptv-auth" "$IPTV_ROOT/etc/hotplug.d/iface/99-iptv-auth"
install -m 755 "$PACK/iptv-auth/files/etc/uci-defaults/iptv-auth-setup" "$IPTV_ROOT/etc/uci-defaults/iptv-auth-setup"
install -m 755 "$SRC/usr/bin/iptv-auth.py" "$IPTV_ROOT/usr/bin/iptv-auth.py"
install -m 755 "$SRC/usr/bin/iptv-auth-ota.sh" "$IPTV_ROOT/usr/bin/iptv-auth-ota.sh"
install -m 755 "$SRC/usr/bin/iptv-auth-ota-check.sh" "$IPTV_ROOT/usr/bin/iptv-auth-ota-check.sh"
install -m 755 "$SRC/usr/bin/rtp2httpd-ota-check.sh" "$IPTV_ROOT/usr/bin/rtp2httpd-ota-check.sh"
install -m 755 "$SRC/usr/bin/rtp2httpd-update.sh" "$IPTV_ROOT/usr/bin/rtp2httpd-update.sh"
install -m 644 "$SRC/usr/lib/lua/luci/controller/iptv_auth.lua" "$IPTV_ROOT/usr/lib/lua/luci/controller/iptv_auth.lua"
install -m 644 "$SRC/usr/lib/lua/luci/model/cbi/iptv_auth.lua" "$IPTV_ROOT/usr/lib/lua/luci/model/cbi/iptv_auth.lua"
install -m 644 "$SRC/usr/lib/lua/luci/model/cbi/iptv_auth/config.lua" "$IPTV_ROOT/usr/lib/lua/luci/model/cbi/iptv_auth/config.lua"
install -m 644 "$SRC/usr/lib/lua/luci/view/iptv_auth/"*.htm "$IPTV_ROOT/usr/lib/lua/luci/view/iptv_auth/"
cp -a "$SRC/usr/share/iptv-auth/logos/." "$IPTV_ROOT/usr/share/iptv-auth/logos/"
install -m 644 "$PUB_KEY" "$IPTV_ROOT/usr/share/iptv-auth/my-openwrt.rsa.pub"

IPTV_APK="$OUT/iptv-auth/iptv-auth-${IPTV_VER}.apk"
mkpkg \
	iptv-auth "$IPTV_VER" noarch \
	"IPTV auth + M3U/EPG generation + RTSP replay + rtp2httpd live proxy + OTA update detection" \
	iptv-auth GPL-2.0 "https://github.com/bcyyt/my-openwrt" \
	"$IPTV_ROOT" "$IPTV_APK" \
	-s "post-install:$PACK/iptv-auth/post-install.sh"

cat > "$OUT/iptv-auth/version.json" <<EOF
{
  "version": "${IPTV_VER}",
  "date": "${DATE_STR}",
	"changelog": "选上游接口后自动把鉴权/回看/rtp2httpd 出站绑到该口 DHCP 网关（专用策略表，不改主路由、不加静态路由）。",
  "url": "${OTA_URL_BASE}/iptv-auth/iptv-auth-${IPTV_VER}.apk",
  "ipk_url": ""
}
EOF

# ---------- 影视中心 ----------
MEDIA_ROOT="$(mktemp -d /tmp/pkg-media.XXXXXX)"
install -d "$MEDIA_ROOT/etc/config" "$MEDIA_ROOT/etc/init.d" "$MEDIA_ROOT/etc/uci-defaults" \
	"$MEDIA_ROOT/usr/bin" \
	"$MEDIA_ROOT/usr/lib/lua/luci/controller" \
	"$MEDIA_ROOT/usr/lib/lua/luci/view/mediahub" \
	"$MEDIA_ROOT/usr/share/luci/menu.d" \
	"$MEDIA_ROOT/usr/share/rpcd/acl.d" \
	"$MEDIA_ROOT/www/luci-static/resources/mediahub" \
	"$MEDIA_ROOT/mnt/data/ffmpeg"

install -m 644 "$PACK/luci-app-mediahub/files/etc/config/mediahub" "$MEDIA_ROOT/etc/config/mediahub"
install -m 755 "$SRC/etc/init.d/alist" "$MEDIA_ROOT/etc/init.d/alist"
install -m 755 "$SRC/etc/init.d/mediahub-cms" "$MEDIA_ROOT/etc/init.d/mediahub-cms"
install -m 755 "$PACK/luci-app-mediahub/files/etc/uci-defaults/mediahub-setup" "$MEDIA_ROOT/etc/uci-defaults/mediahub-setup"
install -m 755 "$SRC/usr/bin/alist-run" "$MEDIA_ROOT/usr/bin/alist-run"
install -m 755 "$SRC/usr/bin/mediahub-alist-setup.sh" "$MEDIA_ROOT/usr/bin/mediahub-alist-setup.sh"
install -m 755 "$SRC/usr/bin/mediahub-cms.py" "$MEDIA_ROOT/usr/bin/mediahub-cms.py"
install -m 755 "$SRC/usr/bin/mediahub-install.sh" "$MEDIA_ROOT/usr/bin/mediahub-install.sh"
install -m 644 "$SRC/usr/lib/lua/luci/controller/mediahub.lua" "$MEDIA_ROOT/usr/lib/lua/luci/controller/mediahub.lua"
install -m 644 "$SRC/usr/lib/lua/luci/view/mediahub/"*.htm "$MEDIA_ROOT/usr/lib/lua/luci/view/mediahub/"
install -m 644 "$SRC/usr/share/luci/menu.d/luci-app-mediahub.json" "$MEDIA_ROOT/usr/share/luci/menu.d/luci-app-mediahub.json"
install -m 644 "$SRC/usr/share/rpcd/acl.d/luci-app-mediahub.json" "$MEDIA_ROOT/usr/share/rpcd/acl.d/luci-app-mediahub.json"
install -m 644 "$SRC/www/luci-static/resources/mediahub/qrcode.js" "$MEDIA_ROOT/www/luci-static/resources/mediahub/qrcode.js"
install -m 755 "$SRC/mnt/data/ffmpeg/ffmpeg" "$MEDIA_ROOT/mnt/data/ffmpeg/ffmpeg"
install -m 755 "$SRC/mnt/data/ffmpeg/ffprobe" "$MEDIA_ROOT/mnt/data/ffmpeg/ffprobe"

MEDIA_APK="$OUT/luci-app-mediahub/luci-app-mediahub-${MEDIA_VER}.apk"
mkpkg \
	luci-app-mediahub "$MEDIA_VER" x86_64 \
	"MediaHub - CMS aggregation + AList cloud drive + data-dir auto-detection" \
	luci-app-mediahub MIT "https://github.com/bcyyt/my-openwrt" \
	"$MEDIA_ROOT" "$MEDIA_APK" \
	-s "post-install:$PACK/luci-app-mediahub/post-install.sh"

# ---------- 状态监控（内嵌 filemanager + 中文语言包） ----------
STATUS_ROOT="$(mktemp -d /tmp/pkg-status.XXXXXX)"
install -d "$STATUS_ROOT/etc/init.d" \
	"$STATUS_ROOT/usr/lib/lua/luci/controller" \
	"$STATUS_ROOT/usr/lib/lua/luci/view/statusmon" \
	"$STATUS_ROOT/www/cgi-bin" \
	"$STATUS_ROOT/lib/apk/packages" \
	"$STATUS_ROOT/usr/share/statusmon/vendor" \
	"$STATUS_ROOT/usr/share/luci/menu.d" \
	"$STATUS_ROOT/usr/share/rpcd/acl.d" \
	"$STATUS_ROOT/www/luci-static/resources/view/system/filemanager" \
	"$STATUS_ROOT/usr/lib/lua/luci/i18n" \
	"$STATUS_ROOT/etc/uci-defaults"

install -m 755 "$SRC/etc/init.d/statusmon-acct" "$STATUS_ROOT/etc/init.d/statusmon-acct"
install -m 644 "$SRC/usr/lib/lua/luci/controller/statusmon.lua" "$STATUS_ROOT/usr/lib/lua/luci/controller/statusmon.lua"
install -m 644 "$SRC/usr/lib/lua/luci/view/statusmon/status.htm" "$STATUS_ROOT/usr/lib/lua/luci/view/statusmon/status.htm"
install -m 755 "$SRC/www/cgi-bin/statusmon" "$STATUS_ROOT/www/cgi-bin/statusmon"
install -m 644 "$SRC/lib/apk/packages/luci-app-statusmon.list" "$STATUS_ROOT/lib/apk/packages/luci-app-statusmon.list"

# luci-app-filemanager
install -m 644 "$SRC/usr/share/luci/menu.d/luci-app-filemanager.json" "$STATUS_ROOT/usr/share/luci/menu.d/luci-app-filemanager.json"
install -m 644 "$SRC/usr/share/rpcd/acl.d/luci-app-filemanager.json" "$STATUS_ROOT/usr/share/rpcd/acl.d/luci-app-filemanager.json"
install -m 644 "$SRC/www/luci-static/resources/view/system/filemanager.js" "$STATUS_ROOT/www/luci-static/resources/view/system/filemanager.js"
install -m 644 "$SRC/www/luci-static/resources/view/system/filemanager/"*.js "$STATUS_ROOT/www/luci-static/resources/view/system/filemanager/"
install -m 644 "$SRC/lib/apk/packages/luci-app-filemanager.list" "$STATUS_ROOT/lib/apk/packages/luci-app-filemanager.list"

# luci-i18n-filemanager-zh-cn
install -m 644 "$SRC/usr/lib/lua/luci/i18n/filemanager.zh-cn.lmo" "$STATUS_ROOT/usr/lib/lua/luci/i18n/filemanager.zh-cn.lmo"
cat > "$STATUS_ROOT/etc/uci-defaults/luci-i18n-filemanager-zh-cn" <<'I18N'
#!/bin/sh
uci -q batch <<-EOF
	set luci.languages.zh_cn='中文 (Chinese)'
	commit luci
EOF
exit 0
I18N
chmod 755 "$STATUS_ROOT/etc/uci-defaults/luci-i18n-filemanager-zh-cn"
install -m 644 "$SRC/lib/apk/packages/luci-i18n-filemanager-zh-cn.list" "$STATUS_ROOT/lib/apk/packages/luci-i18n-filemanager-zh-cn.list"

# keep original vendor apks as fallback for post-install apk add
if [ -f "$SRC/tmp/apk-fetch/luci-app-filemanager-26.147.46185~177cf48.apk" ]; then
	cp -a "$SRC/tmp/apk-fetch/luci-app-filemanager-26.147.46185~177cf48.apk" \
		"$STATUS_ROOT/usr/share/statusmon/vendor/"
fi
if [ -f "$SRC/tmp/apk-fetch/luci-i18n-filemanager-zh-cn-26.232.63255~f6d8575.apk" ]; then
	cp -a "$SRC/tmp/apk-fetch/luci-i18n-filemanager-zh-cn-26.232.63255~f6d8575.apk" \
		"$STATUS_ROOT/usr/share/statusmon/vendor/"
fi

STATUS_APK="$OUT/luci-app-statusmon/luci-app-statusmon-${STATUS_VER}.apk"
mkpkg \
	luci-app-statusmon "$STATUS_VER" noarch \
	"LuCI 状态监控（statusmon）含流量分类、文件管理器与中文语言包" \
	custom/statusmon GPL-2.0 "https://github.com/bcyyt/my-openwrt" \
	"$STATUS_ROOT" "$STATUS_APK" \
	-I "depends:libc luci-base" \
	-I "provides:luci-app-statusmon-any" \
	-I "replaces:statusmon luci-app-filemanager luci-i18n-filemanager-zh-cn" \
	-I "tags:openwrt:section=luci" \
	-s "post-install:$PACK/luci-app-statusmon/post-install.sh"

# ---------- 转发优化 ----------
NETQ_ROOT="$(mktemp -d /tmp/pkg-netq.XXXXXX)"
install -d "$NETQ_ROOT/etc/config" "$NETQ_ROOT/etc/init.d" "$NETQ_ROOT/etc/uci-defaults" \
	"$NETQ_ROOT/usr/bin" \
	"$NETQ_ROOT/usr/lib/lua/luci/controller" \
	"$NETQ_ROOT/usr/lib/lua/luci/model/cbi"

install -m 644 "$PACK/luci-app-netqueue/files/etc/config/netqueue" "$NETQ_ROOT/etc/config/netqueue"
install -m 755 "$PACK/luci-app-netqueue/files/etc/uci-defaults/netqueue-setup" "$NETQ_ROOT/etc/uci-defaults/netqueue-setup"
install -m 755 "$SRC/etc/init.d/netqueue" "$NETQ_ROOT/etc/init.d/netqueue"
install -m 755 "$SRC/usr/bin/netqueue-apply.sh" "$NETQ_ROOT/usr/bin/netqueue-apply.sh"
install -m 644 "$SRC/usr/lib/lua/luci/controller/netqueue.lua" "$NETQ_ROOT/usr/lib/lua/luci/controller/netqueue.lua"
install -m 644 "$SRC/usr/lib/lua/luci/model/cbi/netqueue.lua" "$NETQ_ROOT/usr/lib/lua/luci/model/cbi/netqueue.lua"

NETQ_APK="$OUT/luci-app-netqueue/luci-app-netqueue-${NETQ_VER}.apk"
mkpkg \
	luci-app-netqueue "$NETQ_VER" noarch \
	"LuCI 转发优化：队列绑定、CPU、PPPoE 队列、UDP GRO、接收积压、软件分载" \
	luci-app-netqueue GPL-2.0 "https://github.com/bcyyt/my-openwrt" \
	"$NETQ_ROOT" "$NETQ_APK" \
	-I "depends:libc luci-base" \
	-I "tags:openwrt:section=luci" \
	-s "post-install:$PACK/luci-app-netqueue/post-install.sh"

# ---------- 保留升级 ----------
SYSKEEP_ROOT="$(mktemp -d /tmp/pkg-syskeep.XXXXXX)"
install -d "$SYSKEEP_ROOT/etc/init.d" "$SYSKEEP_ROOT/etc/uci-defaults" "$SYSKEEP_ROOT/etc/syskeep" \
	"$SYSKEEP_ROOT/usr/bin" \
	"$SYSKEEP_ROOT/lib/upgrade/keep.d" \
	"$SYSKEEP_ROOT/usr/lib/lua/luci/controller" \
	"$SYSKEEP_ROOT/usr/lib/lua/luci/view/syskeep"

install -m 755 "$PACK/luci-app-syskeep/files/etc/uci-defaults/syskeep-setup" "$SYSKEEP_ROOT/etc/uci-defaults/syskeep-setup"
install -m 755 "$SRC/etc/init.d/syskeep" "$SYSKEEP_ROOT/etc/init.d/syskeep"
install -m 755 "$SRC/etc/syskeep/restore.sh" "$SYSKEEP_ROOT/etc/syskeep/restore.sh"
install -m 644 "$SRC/etc/syskeep/datadir.sh" "$SYSKEEP_ROOT/etc/syskeep/datadir.sh"
install -m 644 "$SRC/etc/syskeep/custom-apks.txt" "$SYSKEEP_ROOT/etc/syskeep/custom-apks.txt"
install -m 755 "$SRC/usr/bin/syskeep-upgrade.sh" "$SYSKEEP_ROOT/usr/bin/syskeep-upgrade.sh"
install -m 755 "$SRC/lib/upgrade/syskeep-hook.sh" "$SYSKEEP_ROOT/lib/upgrade/syskeep-hook.sh"
install -m 644 "$SRC/lib/upgrade/keep.d/syskeep" "$SYSKEEP_ROOT/lib/upgrade/keep.d/syskeep"
install -m 644 "$SRC/usr/lib/lua/luci/controller/syskeep.lua" "$SYSKEEP_ROOT/usr/lib/lua/luci/controller/syskeep.lua"
install -m 644 "$SRC/usr/lib/lua/luci/view/syskeep/index.htm" "$SYSKEEP_ROOT/usr/lib/lua/luci/view/syskeep/index.htm"

SYSKEEP_APK="$OUT/luci-app-syskeep/luci-app-syskeep-${SYSKEEP_VER}.apk"
mkpkg \
	luci-app-syskeep "$SYSKEEP_VER" noarch \
	"LuCI 保留升级：刷机保留配置、分区和插件清单，开机重装 apk" \
	luci-app-syskeep GPL-2.0 "https://github.com/bcyyt/my-openwrt" \
	"$SYSKEEP_ROOT" "$SYSKEEP_APK" \
	-I "depends:libc luci-base" \
	-I "tags:openwrt:section=luci" \
	-s "post-install:$PACK/luci-app-syskeep/post-install.sh"

echo
echo "==== packages ===="
find "$OUT" -type f -printf '%p\t%s\n' | sort
echo DONE
