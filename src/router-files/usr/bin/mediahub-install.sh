#!/bin/sh
# install.sh — mediahub 自动安装脚本
# 自动判断包管理器和安装方式：
#   1. 有 apk → 尝试 apk add（如果 /bin/sh 依赖报错则回退到 tar 解压）
#   2. 有 opkg → 尝试 opkg install
#   3. 都没有 → 直接 tar 解压
# 安装后自动执行 uci-defaults（含 pick_data_root + AList 部署 + 内核更换）
#
# 用法：
#   sh install.sh                    # 自动查找当前目录下的 .apk 或 .ipk
#   sh install.sh /path/to/pkg.apk   # 指定包路径
#   sh install.sh /path/to/pkg.ipk

set -e

PKG_FILE="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

# 如果未指定包路径，在当前目录和脚本目录查找
if [ -z "$PKG_FILE" ]; then
    for f in "$SCRIPT_DIR"/*.apk "$SCRIPT_DIR"/*.ipk "$PWD"/*.apk "$PWD"/*.ipk; do
        if [ -f "$f" ]; then
            PKG_FILE="$f"
            break
        fi
    done
fi

if [ -z "$PKG_FILE" ] || [ ! -f "$PKG_FILE" ]; then
    echo "[mediahub] ERROR: 未找到安装包"
    echo "[mediahub] 用法: sh install.sh /path/to/luci-app-mediahub-*.apk"
    exit 1
fi

echo "============================================"
echo "  MediaHub 自动安装"
echo "  包: $(basename "$PKG_FILE")"
echo "============================================"

# ===== 0. 检测包管理器 =====
PKG_MGR=""
if command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
elif command -v opkg >/dev/null 2>&1; then
    PKG_MGR="opkg"
fi
echo "[mediahub] 包管理器: ${PKG_MGR:-无（将使用 tar 解压）}"

INSTALL_OK=0

# ===== 0.5 保护用户配置（防 apk/opkg 升级直接覆盖 /etc/config/mediahub）=====
# apk add 成功路径没有 tar 回退那样的保护逻辑：若系统未走 protected-paths
# （未生成 .apk-new），/etc/config/mediahub 会被包内默认配置直接覆盖，
# Cookie/data_dir 丢失。先备份，2.6 节校验兑底恢复。
if [ -f /etc/config/mediahub ]; then
    cp /etc/config/mediahub /tmp/mediahub.conf.apk-protect 2>/dev/null || true
    echo "[mediahub] 已备份现有配置（升级保护）"
fi

# ===== 1. 尝试包管理器安装 =====
case "$PKG_MGR" in
    apk)
        echo ""
        echo "[mediahub] 尝试 apk add ..."
        # 先确保签名公钥受信任（如果包旁边有 .rsa.pub）
        PUBKEY=""
        for k in "$(dirname "$PKG_FILE")"/*.rsa.pub "$SCRIPT_DIR"/*.rsa.pub /etc/apk/keys/iptv-auth.rsa.pub; do
            if [ -f "$k" ]; then
                PUBKEY="$k"
                break
            fi
        done
        if [ -n "$PUBKEY" ]; then
            mkdir -p /etc/apk/keys
            cp "$PUBKEY" /etc/apk/keys/ 2>/dev/null || true
            echo "[mediahub] 签名公钥: $PUBKEY"
        fi

        if apk add --allow-untrusted "$PKG_FILE" 2>&1; then
            INSTALL_OK=1
            echo "[mediahub] apk add 成功"
        else
            # apk RC≠0 不一定代表本包安装失败：系统级损坏包（apk fix 可见，
            # 如 app-meta-* 从仓库不可用）会让本机所有 apk 操作返回 1。
            # 检查本包是否实际已注册安装，给出准确诊断
            if apk info -e luci-app-mediahub >/dev/null 2>&1; then
                echo "[mediahub] apk add 返回非 0，但本包已注册安装（多为系统级依赖告警，非本包问题）"
                echo "[mediahub] 继续走 tar 补装，确保文件完整 + 配置保留"
            else
                echo "[mediahub] apk add 失败（可能依赖问题），回退到 tar 解压"
            fi
        fi
        ;;
    opkg)
        echo ""
        echo "[mediahub] 尝试 opkg install ..."
        if opkg install "$PKG_FILE" 2>&1; then
            INSTALL_OK=1
            echo "[mediahub] opkg install 成功"
        else
            echo "[mediahub] opkg install 失败，回退到 tar 解压"
        fi
        ;;
esac

# ===== 2. tar 解压回退（APK/IPK 都是 gzip tar 归档） =====
if [ "$INSTALL_OK" = "0" ]; then
    echo ""
    echo "[mediahub] 使用 tar 解压安装 ..."

    # 保护用户配置文件（tar 解压会覆盖 /etc/config/mediahub）
    if [ -f /etc/config/mediahub ]; then
        cp /etc/config/mediahub /tmp/mediahub.conf.preserve
        echo "[mediahub] 已保护用户配置 /etc/config/mediahub"
    fi

    EXTRACT_DIR="/tmp/mediahub-install-$$"
    mkdir -p "$EXTRACT_DIR"

    case "$PKG_FILE" in
        *.apk)
            # APK: gzip(tar(.SIGN.* .PKGINFO etc/ usr/ ...))
            # || true：解压失败时交给下方 ROOT_DIR 检查报错，不能被 set -e 静默中断
            tar xzf "$PKG_FILE" -C "$EXTRACT_DIR" 2>/dev/null || true
            ;;
        *.ipk)
            # IPK: gzip(tar(./debian-binary ./data.tar.gz ./control.tar.gz))
            # 需要先解外层 gzip+tar，再解 data.tar.gz（|| true 同上，报错交给 ROOT_DIR 检查）
            tar xzf "$PKG_FILE" -C "$EXTRACT_DIR" 2>/dev/null || true
            if [ -f "$EXTRACT_DIR/data.tar.gz" ]; then
                tar xzf "$EXTRACT_DIR/data.tar.gz" -C "$EXTRACT_DIR" 2>/dev/null || true
                # data.tar.gz 内是 ./etc ./usr 结构，提取后直接在 EXTRACT_DIR 下
            fi
            ;;
    esac

    # 找到实际的文件树根（含 etc/ 或 usr/ 的目录）
    ROOT_DIR=""
    for d in "$EXTRACT_DIR" "$EXTRACT_DIR"/*/ "$EXTRACT_DIR"/./; do
        if [ -d "${d}etc" ] || [ -d "${d}usr" ]; then
            ROOT_DIR="${d}"
            break
        fi
    done
    # 兜底：直接在 EXTRACT_DIR 找
    if [ -z "$ROOT_DIR" ]; then
        if [ -d "$EXTRACT_DIR/etc" ] || [ -d "$EXTRACT_DIR/usr" ]; then
            ROOT_DIR="$EXTRACT_DIR/"
        fi
    fi

    if [ -z "$ROOT_DIR" ]; then
        echo "[mediahub] ERROR: 解压后未找到 etc/ 或 usr/ 目录"
        ls -la "$EXTRACT_DIR"
        rm -rf "$EXTRACT_DIR"
        exit 1
    fi

    echo "[mediahub] 解压根目录: $ROOT_DIR"

    # 复制文件到系统根目录
    for d in etc usr www; do
        if [ -d "${ROOT_DIR}${d}" ]; then
            cp -a "${ROOT_DIR}${d}"/* "/${d}/" 2>/dev/null || true
            echo "[mediahub] 已安装 /${d}/"
        fi
    done

    rm -rf "$EXTRACT_DIR"

    # 恢复用户配置（保留 data_dir/cookies 等用户设置，不覆盖为包内默认值）
    if [ -f /tmp/mediahub.conf.preserve ]; then
        cp /tmp/mediahub.conf.preserve /etc/config/mediahub
        rm -f /tmp/mediahub.conf.preserve
        echo "[mediahub] 已恢复用户配置（data_dir/Cookies 保留）"
    fi

    INSTALL_OK=1
    echo "[mediahub] tar 解压安装完成"
fi

# ===== 2.5 清理 apk/opkg 残留的 .apk-new / .opkg-new / -opkg =====
# apk add 对受保护路径（/etc）遇到已存在且内容不同的文件时不覆盖，而是写成 *.apk-new；
# opkg 升级 conffile 冲突时的后缀是 *-opkg（实测 iStoreOS 24.10 opkg），非 .opkg-new；
# 包管理器部分成功后回退 tar 安装时，这些包内默认配置的副本就成了残留。
# 用户配置以现场为准（tar 路径已单独保护并恢复 /etc/config/mediahub），残留副本无用途：
#   - 本体文件存在 → 删除残留
#   - 本体文件缺失（部分安装异常）→ 用残留副本补位，保证安装完整
NEW_FILES="
/etc/config/mediahub
/etc/uci-defaults/mediahub-setup
/etc/init.d/mediahub-cms
/etc/init.d/alist
"
NEWRES=0
for real in $NEW_FILES; do
    for suf in .apk-new .opkg-new -opkg; do
        residue="${real}${suf}"
        if [ -f "$residue" ]; then
            if [ -f "$real" ]; then
                rm -f "$residue"
            else
                mv "$residue" "$real"
            fi
            NEWRES=$((NEWRES + 1))
        fi
    done
done
if [ "$NEWRES" -gt 0 ]; then
    echo "[mediahub] 已清理 $NEWRES 个包管理器残留文件 (.apk-new/.opkg-new/-opkg)"
fi

# ===== 2.6 配置防覆盖兑底（配合 0.5 的备份）=====
# 正常升级：apk 走 protected-paths 生成 .apk-new（2.5 已清理），用户配置完好；
# 异常升级：apk 直接覆盖了配置（用户字段丢失）→ 用 0.5 的备份整体恢复
if [ -f /tmp/mediahub.conf.apk-protect ]; then
    NEED_RESTORE=0
    for opt in data_dir cookie_115 cookie_quark; do
        CUR=$(uci -q get "mediahub.main.$opt" 2>/dev/null || true)
        if [ -z "$CUR" ] && grep -q "option $opt" /tmp/mediahub.conf.apk-protect 2>/dev/null; then
            NEED_RESTORE=1
        fi
    done
    if [ "$NEED_RESTORE" = "1" ]; then
        cp /tmp/mediahub.conf.apk-protect /etc/config/mediahub
        echo "[mediahub] WARN: 包管理器覆盖了用户配置，已从备份恢复（Cookie/data_dir 保留）"
    fi
    rm -f /tmp/mediahub.conf.apk-protect
fi

# ===== 3. 设置文件权限 =====
echo ""
echo "[mediahub] 设置权限 ..."
chmod 755 /usr/bin/mediahub-cms.py 2>/dev/null || true
chmod 755 /usr/bin/mediahub-alist-setup.sh 2>/dev/null || true
chmod 755 /etc/init.d/mediahub-cms 2>/dev/null || true
chmod 755 /etc/init.d/alist 2>/dev/null || true
chmod 755 /usr/bin/alist-run 2>/dev/null || true
chmod 755 /etc/uci-defaults/mediahub-setup 2>/dev/null || true

# ===== 4. 执行 uci-defaults（核心安装逻辑） =====
# UCI_DEFAULTS_RAN=1 表示 uci-defaults 存在且执行成功（它内部会启停服务）；
# =0 表示升级安装（uci-defaults 首次安装后已被清理）或执行失败 ——
# 两种情况都不会有人重启服务，新代码不会生效，需在 4.5 节补重启
UCI_DEFAULTS_RAN=0
echo ""
echo "[mediahub] 执行安装后配置 ..."
if [ -f /etc/uci-defaults/mediahub-setup ]; then
    sh /etc/uci-defaults/mediahub-setup 2>&1
    rc=$?
    if [ "$rc" = "0" ]; then
        rm -f /etc/uci-defaults/mediahub-setup
        UCI_DEFAULTS_RAN=1
        echo "[mediahub] uci-defaults 执行成功，已清理"
    else
        echo "[mediahub] uci-defaults 返回 $rc，保留以便下次启动重试"
    fi
else
    echo "[mediahub] uci-defaults 不存在（升级安装或已执行过），跳过"
fi

# ===== 4.5 升级场景服务重载 =====
# 升级安装（apk/opkg 覆盖文件）时 uci-defaults 不存在，没人重启服务，
# 常驻进程（mediahub-cms.py Python / alist 二进制）仍运行旧代码。
if [ "$UCI_DEFAULTS_RAN" = "0" ]; then
    echo "[mediahub] 升级场景：重启服务加载新代码 ..."
    /etc/init.d/alist restart 2>/dev/null || true
    /etc/init.d/mediahub-cms restart 2>/dev/null || true
fi

# ===== 5. 清理 LuCI 缓存 =====
rm -f /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null

# ===== 5.5 等待服务启动（AList 全新安装数据库初始化需 5-15 秒） =====
echo ""
echo "[mediahub] 等待服务启动 ..."

alist_api_ready() {
    # 就绪标准：/api/fs/list 返回 JSON（任何 code 都算就绪，401 也是就绪）
    curl -s -m 3 http://127.0.0.1:5244/api/fs/list -X POST \
         -H "Content-Type: application/json" \
         -d '{"path":"/","page":1,"per_page":1}' 2>/dev/null | grep -q '"code"'
}

# 5.5a 等待两个服务进程出现（最多 15 秒）
WAIT=0
MAX_WAIT=15
while [ $WAIT -lt $MAX_WAIT ]; do
    if pidof alist >/dev/null 2>&1 && pgrep -f mediahub-cms >/dev/null 2>&1; then
        echo "[mediahub] 服务进程已启动 (${WAIT}s)"
        break
    fi
    sleep 1
    WAIT=$((WAIT + 1))
done

# 5.5b 进程未出现则重启一次
if [ $WAIT -ge $MAX_WAIT ]; then
    echo "[mediahub] 进程启动超时（${MAX_WAIT}s），尝试重启 ..."
    /etc/init.d/alist restart 2>/dev/null || true
    /etc/init.d/mediahub-cms restart 2>/dev/null || true
    sleep 3
fi

# 5.5c 等待 AList API 就绪（最多 30 秒）
# 进程在跑不等于 API 可用：全新安装时 AList 初始化数据库需 5-15 秒，
# CMS 首轮挂载同步依赖 AList API，未就绪会导致挂载列表为空
ALIST_WAIT=0
while [ $ALIST_WAIT -lt 30 ]; do
    if alist_api_ready; then
        echo "[mediahub] AList API 已就绪 (${ALIST_WAIT}s)"
        break
    fi
    sleep 1
    ALIST_WAIT=$((ALIST_WAIT + 1))
done

# 5.5d API 超时则重启 AList 再等 10 秒
if [ $ALIST_WAIT -ge 30 ]; then
    echo "[mediahub] AList API 未就绪，重启 AList 再等 10 秒 ..."
    /etc/init.d/alist restart 2>/dev/null || true
    RETRY=0
    while [ $RETRY -lt 10 ]; do
        if alist_api_ready; then
            echo "[mediahub] AList API 已就绪（重启后 ${RETRY}s）"
            break
        fi
        sleep 1
        RETRY=$((RETRY + 1))
    done
    if [ $RETRY -ge 10 ]; then
        echo "[mediahub] WARN: AList API 仍未就绪，请查看日志: logread | grep alist"
    fi
fi

# 5.5e 等待 CMS 端口 8901 就绪（最多 60 秒）
# CMS 启动需加载持久化片库（vods.json.gz 可达 50MB+，解压解析需 10-30 秒），
# 进程存在不等于端口就绪；不等端口会让最终验证误报 CMS ❌、退出码非 0
CMS_WAIT=0
while [ $CMS_WAIT -lt 60 ]; do
    if netstat -tln 2>/dev/null | grep -q ':8901'; then
        echo "[mediahub] CMS 端口 8901 已就绪 (${CMS_WAIT}s)"
        break
    fi
    sleep 1
    CMS_WAIT=$((CMS_WAIT + 1))
done
if [ $CMS_WAIT -ge 60 ]; then
    echo "[mediahub] WARN: CMS 端口 8901 未就绪（60s），请查看日志: logread | grep -i mediahub"
fi

# ===== 6. 最终验证 =====
echo ""
echo "============================================"
echo "  安装验证"
echo "============================================"

ERRS=0

# AList 进程
if pidof alist >/dev/null 2>&1; then
    echo "[✅] AList 进程运行中 (PID: $(pidof alist))"
else
    echo "[❌] AList 进程未运行"
    ERRS=$((ERRS + 1))
fi

# CMS 进程
if pgrep -f mediahub-cms >/dev/null 2>&1; then
    echo "[✅] CMS 代理运行中 (PID: $(pgrep -f mediahub-cms))"
else
    echo "[❌] CMS 代理未运行"
    if netstat -tln 2>/dev/null | grep -q ':8901'; then
        echo "    [!] 端口 8901 正被其他进程占用（可能是残留的旧 CMS），排查: netstat -tlnp | grep 8901"
    fi
    ERRS=$((ERRS + 1))
fi

# 端口
if netstat -tln 2>/dev/null | grep -q ":5244"; then
    echo "[✅] AList 端口 5244 监听中"
else
    echo "[❌] AList 端口 5244 未监听"
    ERRS=$((ERRS + 1))
fi
if netstat -tln 2>/dev/null | grep -q ":8901"; then
    echo "[✅] CMS 端口 8901 监听中"
else
    echo "[❌] CMS 端口 8901 未监听"
    ERRS=$((ERRS + 1))
fi

# 数据目录（|| true：选项未设置时 uci 返回非 0，防止 set -e 在此静默中断验证流程）
DATA_DIR=$(uci -q get mediahub.main.data_dir 2>/dev/null || true)
if [ -n "$DATA_DIR" ]; then
    FS_TYPE=$(df -T "$DATA_DIR" 2>/dev/null | tail -1 | awk '{print $2}')
    case "$FS_TYPE" in
        tmpfs|ramfs)
            echo "[⚠️] 数据目录: $DATA_DIR ($FS_TYPE — 内存盘，重启丢数据!)"
            ERRS=$((ERRS + 1))
            ;;
        "")
            echo "[❌] 数据目录: $DATA_DIR (无法检测文件系统)"
            ERRS=$((ERRS + 1))
            ;;
        *)
            echo "[✅] 数据目录: $DATA_DIR ($FS_TYPE — 真实分区)"
            ;;
    esac
else
    echo "[❌] 数据目录未设置"
    ERRS=$((ERRS + 1))
fi

# LuCI 视图
if [ -d /usr/lib/lua/luci/view/mediahub ]; then
    echo "[✅] LuCI 视图已安装 ($(ls /usr/lib/lua/luci/view/mediahub/ | wc -l) 个文件)"
else
    echo "[❌] LuCI 视图缺失"
    ERRS=$((ERRS + 1))
fi

# 关键文件
MISSING=""
for f in /usr/bin/mediahub-cms.py /usr/bin/mediahub-alist-setup.sh /usr/bin/alist-run \
         /etc/init.d/mediahub-cms /etc/init.d/alist /etc/config/mediahub; do
    [ -f "$f" ] || MISSING="$MISSING $f"
done
if [ -z "$MISSING" ]; then
    echo "[✅] 关键文件完整"
else
    echo "[❌] 缺失文件:$MISSING"
    ERRS=$((ERRS + 1))
fi

# 内核更换验证
if [ -f /usr/bin/alist ]; then
    echo "[✅] AList 二进制存在"
else
    echo "[⚠️] AList 二进制未找到（首次安装需要网络下载，请检查 mediahub-alist-setup.sh 输出）"
fi

# 旧 OpenList 检查
if [ -f /usr/bin/openlist ] && [ ! -f /usr/bin/openlist.bak-migrated ]; then
    echo "[⚠️] 旧 OpenList 二进制仍存在（未迁移）"
fi

echo ""
echo "============================================"
LAN_IP=$(uci -q get network.lan.ipaddr 2>/dev/null || echo '192.168.1.1')
if [ "$ERRS" = "0" ]; then
    echo "  ✅ 安装成功，无错误"
else
    echo "  ⚠️  $ERRS 个问题需要检查（上方标记 ❌ 的项）"
fi
echo ""
echo "  AList 网盘:  http://${LAN_IP}:5244"
echo "  LuCI 管理:   http://${LAN_IP}/cgi-bin/luci/admin/services/mediahub"
echo "  TVBox 配置:  http://${LAN_IP}:8901/tvbox.json"
echo "============================================"

exit $ERRS
