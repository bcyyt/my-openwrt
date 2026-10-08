#!/bin/sh
# iptv-auth-ota.sh — iptv-auth 在线热更新（由 LuCI 配置页调用）
# 用法: iptv-auth-ota.sh <APK_URL> <IPK_URL> <VERSION>
# APK_URL: noarch APK 下载地址（apk 系统用）
# IPK_URL: 含 {arch} 占位符的 IPK 下载地址（opkg 系统用，{arch} 替换为实际架构）
# 流程: 检测包管理器 → 下载对应包 → 安装（签名验证/校验）→ 服务重启
# 状态写入 /tmp/iptv-auth-ota.json 供 LuCI 轮询
STATUS=/tmp/iptv-auth-ota.json

set_status() {
    printf '{"state":"%s","message":"%s","version":"%s"}\n' "$1" "$2" "$3" > "$STATUS"
}

APK_URL="$1"
IPK_URL="$2"
VER="$3"

# 检测包管理器：apk 优先（iStoreOS/OpenWrt 25.12+），其次 opkg（传统 OpenWrt）
if command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    DL_URL="$APK_URL"
elif command -v opkg >/dev/null 2>&1; then
    PKG_MGR="opkg"
    # 检测架构
    ARCH=$(grep DISTRIB_ARCH /etc/openwrt_release 2>/dev/null | cut -d"'" -f2)
    [ -n "$ARCH" ] || ARCH="x86_64"
    # 替换 {arch} 占位符
    DL_URL=$(echo "$IPK_URL" | sed "s/{arch}/$ARCH/g")
else
    set_status "failed" "未找到 apk 或 opkg 包管理器" ""
    exit 1
fi

[ -z "$DL_URL" ] && { set_status "failed" "缺少下载地址（$PKG_MGR 模式）" "$VER"; exit 1; }

# 并发保护
if [ -f "$STATUS" ] && grep -q '"state":"running"' "$STATUS" 2>/dev/null; then
    echo "concurrent update detected, exiting" >&2
    exit 1
fi

set_status "running" "正在下载 $VER（$PKG_MGR 模式）" "$VER"

# 临时包路径：opkg 要求 .ipk 后缀才识别为本地包文件（.pkg 会报 Unknown package）
if [ "$PKG_MGR" = "apk" ]; then
    TMP_PKG="/tmp/iptv-auth-ota.apk"
else
    TMP_PKG="/tmp/iptv-auth-ota.ipk"
fi
rm -f "$TMP_PKG"
if ! curl -sL -m 120 -o "$TMP_PKG" "$DL_URL" 2>/dev/null; then
    set_status "failed" "下载失败: $DL_URL" "$VER"
    rm -f "$TMP_PKG"
    exit 1
fi

if [ ! -s "$TMP_PKG" ]; then
    set_status "failed" "下载失败（文件为空）: $DL_URL" "$VER"
    rm -f "$TMP_PKG"
    exit 1
fi

set_status "running" "正在安装 $VER（$PKG_MGR 验证 + 覆盖升级）" "$VER"

if [ "$PKG_MGR" = "apk" ]; then
    # apk add 自动验证签名（公钥已部署在 /etc/apk/keys/）
    INSTALL_OUT=$(apk add "$TMP_PKG" 2>&1)
    INSTALL_RC=$?
else
    # opkg install（IPK 无签名验证，靠文件完整性）
    INSTALL_OUT=$(opkg install "$TMP_PKG" 2>&1)
    INSTALL_RC=$?
fi
rm -f "$TMP_PKG"

if [ $INSTALL_RC -ne 0 ]; then
    # apk add 可能因非致命告警返回非零（conffile 冲突、旧包孤儿文件等），
    # 但包实际已安装成功。验证实际版本是否达标再判定成败。
    ACTUAL_VER=""
    if [ "$PKG_MGR" = "apk" ]; then
        ACTUAL_VER=$(apk list --installed 2>/dev/null | grep '^iptv-auth-' | head -1 | awk '{print $1}' | sed 's/iptv-auth-//')
    else
        ACTUAL_VER=$(opkg list-installed 2>/dev/null | grep '^iptv-auth ' | head -1 | awk '{print $3}')
    fi
    if [ "$ACTUAL_VER" != "$VER" ]; then
        set_status "failed" "安装失败: $INSTALL_OUT" "$VER"
        exit 1
    fi
    # 版本匹配，非致命告警忽略
fi

# 清理 apk conffile 冲突产生的 .apk-new 残留
rm -f /etc/config/iptv-auth.apk-new 2>/dev/null

# 显式重启服务（postinst 在 APK 格式下不执行，必须在此主动重启加载新代码）
set_status "running" "正在重启服务加载新版本..." "$VER"
/etc/init.d/iptv-auth restart >/dev/null 2>&1

# 带重试的进程存活检测（最长等待 30 秒，每 3 秒检查一次）
_wait_procs() {
    _n=0
    while [ $_n -lt 10 ]; do
        if pidof rtp2httpd >/dev/null 2>&1 && pgrep -f iptv-auth.py >/dev/null 2>&1; then
            return 0
        fi
        sleep 3
        _n=$((_n+1))
    done
    return 1
}
if _wait_procs; then
    if [ "$PKG_MGR" = "apk" ]; then
        NEW_VER=$(apk list --installed 2>/dev/null | grep '^iptv-auth-' | head -1 | awk '{print $1}' | sed 's/iptv-auth-//')
    else
        NEW_VER=$(opkg list-installed 2>/dev/null | grep '^iptv-auth ' | head -1 | awk '{print $3}')
    fi
    set_status "done" "更新完成（$PKG_MGR），已升级到 $NEW_VER" "$NEW_VER"
    exit 0
else
    set_status "failed" "安装成功但服务未启动，请手动执行 /etc/init.d/iptv-auth restart" "$VER"
    exit 1
fi
