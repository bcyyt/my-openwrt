# my-openwrt

ImmortalWrt / OpenWrt 插件：IPTV 代理、影视中心、状态监控、网络优化、保留升级、安全监测。APK（apk）与 x86_64 IPK（opkg）均在 `packages/`。

## 软件包

| 包名 | 版本 | 架构 | 说明 |
|------|------|------|------|
| `iptv-auth` | 2.3.32-r0 | noarch | 鉴权、M3U/EPG、RTSP 回看；缓冲池 24MB、UDP 接收 4MB |
| `luci-app-mediahub` | 1.5.7-r0 | x86_64 | 影视中心（CMS + AList + ffmpeg） |
| `luci-app-statusmon` | 4.29 | noarch | 状态监控；客户端分页；PPPoE 流量跨重拨累计；rtp2httpd 快捷入口新开页；显示固件与内核 |
| `luci-app-netqueue` | 1.0.16-r0 | noarch | 网络优化：转发、DHCP、DNS、静态 IP、过期 ARP 清理 |
| `luci-app-syskeep` | 1.0.18-r0 | noarch | 保留升级：刷机还原网络/接口/防火墙；备份优先拷贝路由器本地安装包；日志逐条写出自装插件 |
| `luci-app-atkmon` | 1.0.4-r0 | noarch | 安全监测：爆破目标/来源端口、手机卡片；PPPoE、DNS、IPTV、DHCP；手动拉黑 |

APK 在 `packages/`，用 `keys/my-openwrt.rsa` 签名。
影视中心只有 APK。其余插件另有 x86_64 IPK，供传统 opkg 使用。

## 安装

```bash
# 部署签名公钥
cp my-openwrt.rsa.pub /etc/apk/keys/
chmod 644 /etc/apk/keys/my-openwrt.rsa.pub

# IPTV 代理
apk add iptv-auth-2.3.32-r0.apk

# 影视中心
apk add luci-app-mediahub-1.5.7-r0.apk

# 状态监控
apk add luci-app-statusmon-4.29.apk

# 网络优化
apk add luci-app-netqueue-1.0.16-r0.apk

# 保留升级
apk add luci-app-syskeep-1.0.18-r0.apk

# 安全监测
apk add luci-app-atkmon-1.0.4-r0.apk
```

签名未信任时：

```bash
# 临时允许未信任签名
apk add --allow-untrusted xxx.apk
```

传统 opkg（x86_64 IPK，不含影视中心）：

```bash
# IPTV 代理
opkg install iptv-auth_2.3.32-r0_x86_64.ipk

# 状态监控
opkg install luci-app-statusmon_4.29_x86_64.ipk

# 网络优化
opkg install luci-app-netqueue_1.0.16-r0_x86_64.ipk

# 保留升级
opkg install luci-app-syskeep_1.0.18-r0_x86_64.ipk

# 安全监测
opkg install luci-app-atkmon_1.0.4-r0_x86_64.ipk
```

## IPTV

LuCI 菜单：**服务 → IPTV 代理**。

OTA：`packages/iptv-auth/version.json`。改 `version` 后 LuCI 状态页可热更新。仓库需 Public，否则 raw.githubusercontent.com 会 404。

rtp2httpd 自编译（缓冲池 1024）在 `packages/rtp2httpd/`。上游发新版后：

```bash
# 拉取官方标签、打补丁、编 x86_64 与 aarch64 静态包
bash packaging/rtp2httpd/build.sh 3.17.2
```

## IPTV 更新日志

从 IPv6 双栈起：

| 版本 | 日期 | 说明 |
|------|------|------|
| 2.3.32 | 2026-10-13 | 缓冲池改为 16384 块（约 24MB），UDP 接收缓冲改为 4MB |
| 2.3.31 | 2026-10-13 | 回看代理改为双线程阻塞直通转发（S→C / C→S） |
| 2.3.30 | 2026-10-12 | 回看上游 S→C 静默 10s 发 OPTIONS keepalive，无效则重建会话 |
| 2.3.29 | 2026-10-12 | 不再请求 `/status/sse`；从 rtp2httpd 日志识别直播/回看频道 |
| 2.3.28 | 2026-10-12 | 监控页占用 23234 时也不再轮询 `/status/sse` |
| 2.3.27 | 2026-10-12 | 无外部直播连接时不轮询 `/status/sse` |
| 2.3.26 | 2026-10-12 | 状态页客户端对照 Lan.m3u 显示频道，排除监控页 |
| 2.3.25 | 2026-10-12 | 状态页可选择 OTA 镜像前缀 |
| 2.3.24 | 2026-10-12 | 状态页显示 IPv6 客户端；OTA 支持镜像 |
| 2.3.23 | 2026-10-12 | 开启 IPv6 双栈代理（rtp2httpd `:::23234`，防火墙放行 23234/2000/554） |

## 网络优化

LuCI 菜单：**网络 → 网络优化**。转发、DHCP、邻居、DNS 分区保存。绑定静态 IP 立刻生效。

转发默认开队列绑定、CPU performance、PPPoE 队列、UDP GRO、接收积压；软件分载默认关。

DHCP 空着起始地址/数量/租期再保存，会保留路由器上已有值。邻居清理只删 FAILED 和已不在租约/静态绑定里的 ARP。

DNS 默认跟随运营商拨号结果。

```bash
# 查看转发 / DHCP / DNS
/usr/bin/netqueue-apply.sh status

# 按 UCI 重载转发
/etc/init.d/netqueue reload
```

## 影视中心

网盘播放走 `8901 /play`。升级时若已有 AList，只同步管理员密码，不重装二进制。

## 状态监控

同一 MAC 多 IPv4 时优先 REACHABLE 邻居，其次 DHCP 租约。客户端按活跃/空闲/离线筛选，每页 10 台。

## 保留升级

LuCI 菜单：**系统 → 保留升级**。只写 boot/rootfs，GPT 和数据盘不动。刷机后还原网络、接口、防火墙，并按刷机前已装清单恢复插件。

```bash
# 查看数据盘、插件备份和固件准备情况
/usr/bin/syskeep-upgrade.sh status
```

## 签名与打包

公钥 `keys/my-openwrt.rsa.pub` 放到 `/etc/apk/keys/`。私钥仅用于 `apk mkpkg --sign-key`。

```bash
# 设置 apk 路径后打包
export APK=/path/to/apk
bash packaging/build-apks.sh
```
| `iptv-auth` | 2.3.31-r0 | noarch | 鉴权、M3U/EPG、RTSP 回看；握手后双线程直通转发 |
apk add iptv-auth-2.3.31-r0.apk
| `iptv-auth` | 2.3.31-r0 | noarch | 鉴权、M3U/EPG、RTSP 回看；握手后双线程直通转发 |
ImmortalWrt / OpenWrt 插件：IPTV 代理、影视中心、状态监控、网络优化、保留升级、安全监测。APK（apk）与 x86_64 IPK（opkg）均在 `packages/`。
