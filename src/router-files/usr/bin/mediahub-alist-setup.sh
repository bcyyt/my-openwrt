#!/bin/sh
# mediahub-alist-setup.sh — AList 自动下载部署脚本
# 在 apk/ipk post-install 阶段调用，自动下载并部署 AList 网盘程序
# 支持多镜像站故障转移 + 数据目录自适应（避免 tmpfs 塞爆）
# 注意：不使用 set -e —— admin set 在新数据目录上可能失败（数据库未初始化），
#       这不应该是致命错误；服务启动后 AList 会自动初始化数据库

ALIST_VER="v3.64.0"
ALIST_BIN="/usr/bin/alist"
ALIST_RUN="/usr/bin/alist-run"
ALIST_INIT="/etc/init.d/alist"
ARCH=$(uname -m)

# ===== 数据目录自适应（核心逻辑） =====
# 目标：找到一块"真实分区"（非 tmpfs/ramfs）作为 AList 数据盘。
# 原因：部分路由器（如 OpenWRT 24.10）的 /mnt/data 是 4MB tmpfs（内存盘），
#       AList 的 SQLite 数据库会塞爆 tmpfs，且重启后全部丢失。
pick_data_root() {
    # 0. UCI 已有配置则直接使用（用户手动指定优先）
    local existing=$(uci -q get mediahub.main.data_dir 2>/dev/null)
    if [ -n "$existing" ] && [ -d "$existing" ]; then
        echo "$existing"
        return 0
    fi

    # 1. 遍历 /proc/mounts，找 /mnt/ 下真实分区（排除 tmpfs/ramfs/overlay）
    # /proc/mounts 格式：设备 挂载点 文件系统类型 挂载选项 dump pass
    local best_size=0
    local best_dir=""
    local mnt_dev mnt_point mnt_fstype mnt_opts mnt_dump mnt_pass

    while read -r mnt_dev mnt_point mnt_fstype mnt_opts mnt_dump mnt_pass; do
        # 排除内存文件系统
        case "$mnt_fstype" in
            tmpfs|ramfs|overlay|proc|sysfs|devtmpfs|squashfs|ubifs|cgroup*|debugfs|tracefs|mqueue|securityfs|configfs|fusectl|pstore|bpf|autofs|devpts|hugetlbfs)
                continue
                ;;
        esac
        # 只看 /mnt/ 下的挂载点
        case "$mnt_point" in
            /mnt/*)
                # 排除 overlay 的 lowerdir（iStoreOS 的 overlayfs 挂载）
                echo "$mnt_opts" | grep -q "lowerdir" && continue
                # 计算分区总空间（KB）
                local mnt_size=$(df -k "$mnt_point" 2>/dev/null | tail -1 | awk '{print $2}')
                if [ -n "$mnt_size" ] && [ "$mnt_size" -gt "$best_size" ] 2>/dev/null; then
                    best_size="$mnt_size"
                    best_dir="$mnt_point"
                fi
                ;;
        esac
    done < /proc/mounts

    # 1b. 如果 /proc/mounts 不可读或没找到，用 df 后备扫描 /mnt/*
    if [ -z "$best_dir" ]; then
        for d in /mnt/*; do
            [ -d "$d" ] || continue
            local fs_type=$(df -T "$d" 2>/dev/null | tail -1 | awk '{print $2}')
            case "$fs_type" in
                tmpfs|ramfs|overlay|squashfs|ubifs|"")
                    continue
                    ;;
            esac
            local sz=$(df -k "$d" 2>/dev/null | tail -1 | awk '{print $2}')
            if [ -n "$sz" ] && [ "$sz" -gt "$best_size" ] 2>/dev/null; then
                best_size="$sz"
                best_dir="$d"
            fi
        done
    fi

    # 2. 找到真实分区 → 使用 <分区>/alist
    if [ -n "$best_dir" ] && [ "$best_size" -gt 10240 ]; then
        # 至少 10MB 才算可用
        echo "[mediahub] Data root: $best_dir (${best_size}KB) [real partition]" >&2
        echo "$best_dir/alist"
        return 0
    fi

    # 3. 没找到真实分区 → /mnt/data/alist（兼容旧布局，但如果是 tmpfs 会发出警告）
    if [ -d "/mnt/data" ]; then
        local data_fs=$(df -T /mnt/data 2>/dev/null | tail -1 | awk '{print $2}')
        if [ "$data_fs" = "tmpfs" ] || [ "$data_fs" = "ramfs" ]; then
            echo "[mediahub] WARNING: /mnt/data is tmpfs (${data_fs})! AList data will be LOST on reboot!" >&2
            echo "[mediahub] Consider mounting a real partition at /mnt/data or setting mediahub.main.data_dir" >&2
        fi
        echo "/mnt/data/alist"
        return 0
    fi

    # 4. 兜底：/var/alist（至少不在 /tmp，避免被定期清理）
    echo "/var/alist"
}

# 执行自适应
ALIST_DATA=$(pick_data_root)
echo "[mediahub] AList data directory: $ALIST_DATA"

# 把数据目录写入 UCI（alist-run 和 mediahub-cms.py 都从这里读取）
uci set mediahub.main.data_dir="$ALIST_DATA"
uci commit mediahub 2>/dev/null || true

# 根据架构选择包名（OpenWrt 使用 musl libc，必须下载 musl 版本）
case "$ARCH" in
    x86_64)  PKG_NAME="alist-linux-musl-amd64.tar.gz" ;;
    aarch64) PKG_NAME="alist-linux-musl-arm64.tar.gz" ;;
    armv7l)  PKG_NAME="alist-linux-musl-arm.tar.gz" ;;
    i686)    PKG_NAME="alist-linux-musl-386.tar.gz" ;;
    *)       echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

# GitHub 原始下载地址
GH_BASE="https://github.com/AlistGo/alist/releases/download/${ALIST_VER}"

# 镜像站列表（按优先级排列）
# 使用时将 GitHub URL 前缀替换为镜像站前缀
MIRRORS="
https://mirror.ghproxy.com/
https://ghfast.top/
https://gh-proxy.com/
https://ghproxy.net/
https://cf.ghproxy.cc/
https://hub.gitmirror.com/
"

# AList 二进制已存在则只跳过下载，其余部署步骤（config/密码同步/服务）继续执行
if [ -x "$ALIST_BIN" ]; then
    echo "[mediahub] AList binary already exists, skipping download."
    SKIP_DOWNLOAD=1
else
    SKIP_DOWNLOAD=0
    echo "[mediahub] Downloading AList ${ALIST_VER} for ${ARCH}..."
fi

# 创建数据目录
mkdir -p "$ALIST_DATA/data"
mkdir -p "$ALIST_DATA/data/log"
mkdir -p "$ALIST_DATA/data/temp"

# 生成默认配置（如果不存在）
if [ ! -f "$ALIST_DATA/data/config.json" ]; then
    # 生成随机 JWT_SECRET（OpenWrt busybox 无 od，依次回退 openssl / hexdump / uuid）
    if command -v openssl >/dev/null 2>&1; then
        JWT_SECRET=$(openssl rand -hex 16 2>/dev/null)
    elif command -v hexdump >/dev/null 2>&1; then
        JWT_SECRET=$(head -c 16 /dev/urandom | hexdump -e '16/1 "%02x"')
    else
        JWT_SECRET=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-')
    fi
    [ -z "$JWT_SECRET" ] && JWT_SECRET="mediahub$(date +%s)"
    cat > "$ALIST_DATA/data/config.json" << CFGEOF
{
  "force": false,
  "site_url": "",
  "cdn": "",
  "jwt_secret": "${JWT_SECRET}",
  "token_expires_in": 48,
  "database": {
    "type": "sqlite3",
    "host": "",
    "port": 0,
    "user": "",
    "password": "",
    "name": "",
    "db_file": "data/data.db",
    "table_prefix": "x_",
    "ssl_mode": "",
    "dsn": ""
  },
  "scheme": {
    "address": "0.0.0.0",
    "http_port": 5244,
    "https_port": -1,
    "force_https": false,
    "cert_file": "",
    "key_file": "",
    "unix_file": "",
    "unix_file_perm": "",
    "enable_h2c": false,
    "enable_h3": false
  },
  "temp_dir": "data/temp",
  "bleve_dir": "data/bleve",
  "dist_dir": "",
  "log": {
    "enable": true,
    "name": "data/log/log.log",
    "max_size": 50,
    "max_backups": 30,
    "max_age": 28,
    "compress": false,
    "filter": { "enable": false, "filters": [] }
  },
  "delayed_start": 0,
  "auto_memory_limit": 4,
  "min_free_memory": 0,
  "max_block_limit": 0,
  "max_connections": 0,
  "max_concurrency": 64,
  "tls_insecure_skip_verify": false,
  "tasks": {
    "download": { "workers": 5, "max_retry": 1, "task_persistant": false },
    "transfer": { "workers": 5, "max_retry": 2, "task_persistant": false },
    "upload": { "workers": 5, "max_retry": 0, "task_persistant": false },
    "copy": { "workers": 5, "max_retry": 2, "task_persistant": false },
    "move": { "workers": 5, "max_retry": 2, "task_persistant": false },
    "decompress": { "workers": 5, "max_retry": 2, "task_persistant": false },
    "decompress_upload": { "workers": 5, "max_retry": 2, "task_persistant": false },
    "allow_retry_canceled": false
  },
  "cors": {
    "allow_origins": ["*"],
    "allow_methods": ["*"],
    "allow_headers": ["*"]
  },
  "s3": { "enable": false, "port": 5246, "ssl": false },
  "ftp": { "enable": false, "listen": ":5221", "find_pasv_port_attempts": 50, "active_transfer_port_non_20": false, "idle_timeout": 900, "connection_timeout": 30, "disable_active_mode": false, "default_transfer_binary": false, "enable_active_conn_ip_check": true, "enable_pasv_conn_ip_check": true },
  "sftp": { "enable": false, "listen": ":5222" },
  "mcp": { "enable": false },
  "last_launched_version": "${ALIST_VER}",
  "proxy_address": ""
}
CFGEOF
fi

# 下载函数：测速选最快镜像站，按测速排序依次下载（减少部署时间）
download_alist() {
    local pkg_url="$GH_BASE/$PKG_NAME"
    local tmp_file="/tmp/${PKG_NAME}"
    local speed_file="/tmp/mediahub_speed.txt"
    local url_file="/tmp/mediahub_urls.txt"

    # ---- 1. 测速：对每个下载源发 range 请求下载前 64KB（8 秒超时） ----
    echo "[mediahub] Speed-testing download sources (64KB probe, 8s timeout each)..."
    > "$speed_file"

    # GitHub 直连
    local r t_code t_time
    r=$(curl -s -m 8 -r 0-65535 -o /dev/null -w '%{http_code}|%{time_total}' "$pkg_url" 2>/dev/null || echo "0|999")
    t_code="${r%%|*}"; t_time="${r##*|}"
    if [ "$t_code" = "200" ] || [ "$t_code" = "206" ]; then
        echo "[mediahub]   GitHub direct : ${t_time}s"
        echo "$t_time $pkg_url" >> "$speed_file"
    else
        echo "[mediahub]   GitHub direct : unavailable"
    fi

    # 各镜像站
    for mirror in $MIRRORS; do
        [ -z "$mirror" ] && continue
        r=$(curl -s -m 8 -r 0-65535 -o /dev/null -w '%{http_code}|%{time_total}' "${mirror}${pkg_url}" 2>/dev/null || echo "0|999")
        t_code="${r%%|*}"; t_time="${r##*|}"
        if [ "$t_code" = "200" ] || [ "$t_code" = "206" ]; then
            echo "[mediahub]   $mirror : ${t_time}s"
            echo "$t_time ${mirror}${pkg_url}" >> "$speed_file"
        else
            echo "[mediahub]   $mirror : unavailable"
        fi
    done

    # ---- 2. 按耗时排序生成下载顺序（快在前） ----
    > "$url_file"
    if [ -s "$speed_file" ]; then
        sort -n "$speed_file" | awk '{ $1=""; sub(/^ /,""); print }' > "$url_file"
        echo "[mediahub] Download order (fastest first):"
        head -3 "$url_file" | sed 's|^|  |'
    else
        # 测速全部失败：回退到固定顺序（直连 + 镜像列表）
        echo "[mediahub] Speed test unavailable for all sources, using default order"
        echo "$pkg_url" >> "$url_file"
        for mirror in $MIRRORS; do
            [ -z "$mirror" ] && continue
            echo "${mirror}${pkg_url}" >> "$url_file"
        done
    fi
    rm -f "$speed_file"

    # ---- 3. 按顺序下载完整文件 ----
    local success=0
    while read -r dl_url; do
        [ -z "$dl_url" ] && continue
        echo "[mediahub] Downloading from: $dl_url"
        rm -f "$tmp_file"
        curl -sL -m 300 -o "$tmp_file" "$dl_url" 2>/dev/null || true
        if [ -s "$tmp_file" ] && [ "$(wc -c < "$tmp_file")" -gt 10000000 ]; then
            echo "[mediahub] Download OK ($(wc -c < "$tmp_file") bytes)"
            success=1
            break
        else
            echo "[mediahub] Download incomplete, trying next source..."
        fi
    done < "$url_file"
    rm -f "$url_file"

    if [ $success -eq 0 ]; then
        echo "[mediahub] ERROR: All download attempts failed!"
        echo "[mediahub] You can manually download AList from:"
        echo "[mediahub]   $pkg_url"
        echo "[mediahub] Extract the 'alist' binary and place it at $ALIST_BIN"
        return 1
    fi

    # 解压并安装
    echo "[mediahub] Extracting..."
    cd /tmp
    tar xzf "$tmp_file" 2>/dev/null || tar xzf "$tmp_file" --strip-components=0 2>/dev/null

    # 查找解压出的 alist 二进制
    local ol_bin=""
    for f in /tmp/alist /tmp/alist-linux-*/alist /tmp/alist-linux*/alist; do
        if [ -f "$f" ] && [ -s "$f" ]; then
            ol_bin="$f"
            break
        fi
    done

    if [ -z "$ol_bin" ]; then
        echo "[mediahub] ERROR: alist binary not found in archive"
        return 1
    fi

    cp "$ol_bin" "$ALIST_BIN"
    chmod 755 "$ALIST_BIN"
    rm -f "$tmp_file"
    rm -rf /tmp/alist* 2>/dev/null

    echo "[mediahub] AList binary installed to $ALIST_BIN"
    return 0
}

# 执行下载（二进制已存在时跳过）
if [ $SKIP_DOWNLOAD -eq 0 ]; then
    download_alist || exit 1
fi

# 启动包装脚本：不覆盖已安装的 alist-run（包内版本已支持从 UCI 读取 data_dir 自适应）
# 如果 alist-run 不存在（非包安装场景），才生成基础版本
if [ ! -f "$ALIST_RUN" ]; then
    cat > "$ALIST_RUN" << 'RUNEOF'
#!/bin/sh
# alist-run — AList 启动包装：数据目录从 UCI mediahub.main.data_dir 读取
DATA_DIR=$(uci -q get mediahub.main.data_dir 2>/dev/null)
if [ -z "$DATA_DIR" ]; then DATA_DIR="/mnt/data/alist"; fi
mkdir -p "$DATA_DIR" 2>/dev/null
cd "$DATA_DIR" 2>/dev/null || cd /tmp
exec /usr/bin/alist "$@"
RUNEOF
    chmod 755 "$ALIST_RUN"
    echo "[mediahub] Created alist-run wrapper"
else
    chmod 755 "$ALIST_RUN"
    echo "[mediahub] alist-run already exists (UCI-adaptive version from package)"
fi

# 创建 init 脚本
cat > "$ALIST_INIT" << 'INITEOF'
#!/bin/sh /etc/rc.common

START=95
STOP=15
USE_PROCD=1

PROG=/usr/bin/alist-run

start_service() {
    [ -x "$PROG" ] || return 0
    procd_open_instance
    procd_set_param command "$PROG" server
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
INITEOF
chmod 755 "$ALIST_INIT"

# 同步 AList admin 密码与 UCI 配置（扫码登录后的挂载同步依赖此密码登录 AList API）
OLPW=$(uci -q get mediahub.main.alist_pw 2>/dev/null)
if [ -z "$OLPW" ] || [ "$OLPW" = "" ]; then
    # UCI 中没有密码则先生成
    if command -v openssl >/dev/null 2>&1; then
        OLPW=$(openssl rand -hex 6 2>/dev/null)
    else
        OLPW=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | cut -c1-12)
    fi
    uci set mediahub.main.alist_pw="$OLPW"
    uci commit mediahub
    echo "[mediahub] Generated AList password"
fi
# 设置 AList admin 密码与 UCI 一致（非致命：新数据目录下数据库可能未初始化，服务启动后会自动建）
cd "$ALIST_DATA" && "$ALIST_BIN" admin set "$OLPW" >/dev/null 2>&1 || echo "[mediahub] WARN: admin set failed (will be set on first service start)"
echo "[mediahub] AList admin password synced with UCI"

echo "[mediahub] AList ${ALIST_VER} deployed successfully."
