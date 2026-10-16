# my-openwrt

ImmortalWrt / OpenWrt 插件：IPTV 代理、影视中心、状态监控、网络优化、保留升级。APK（apk）与 x86_64 IPK（opkg）均在 `packages/`。

## 软件包

| 包名 | 版本 | 架构 | 说明 |
|------|------|------|------|
| `iptv-auth` | 2.3.35-r0 | noarch | 鉴权、M3U/EPG；554 回看/时移代理由独立 C 守护进程 `iptv-replayd`（静态 musl，x86_64/aarch64）；缓冲池 24MB、UDP 接收 4MB；纯标准库 HTTP，无 pip/requests 依赖 |
| `luci-app-mediahub` | 1.5.7-r0 | x86_64 | 影视中心（CMS + AList + ffmpeg） |
| `luci-app-statusmon` | 4.40 | noarch | 状态监控；常驻采样器固定节奏采样（更准更省）；「系统性能」单面板（系统/CPU/内存 合成一张面板，含占用环 + CPU/内存曲线）与「温度」模块（CPU 封装/硬盘，3h/24h 可切换）；客户端分页；PPPoE 流量跨重拨累计；「安全」标签：登录爆破来源记录（永久保留、可清除）、攻击日志（永久保留、可清空）与手动拉黑；「日志」标签：PPPoE/DHCP/LuCI 登录/SSH 登录四类下拉查看（原安全监测已并入）；已移除 WAN 端口探测日志，不再刷屏系统日志 |
| `luci-app-netqueue` | 1.0.20-r0 | noarch | 网络优化：转发、CPU 模式/睿频、NAT、DHCP、DNS、静态 IP、过期 ARP 清理 |
| `luci-app-syskeep` | 1.0.18-r0 | noarch | 保留升级：刷机还原网络/接口/防火墙；备份优先拷贝路由器本地安装包；日志逐条写出自装插件 |

APK 在 `packages/`，用 `keys/my-openwrt.rsa` 签名。
影视中心只有 APK。其余插件另有 x86_64 IPK，供传统 opkg 使用。

## 安装

```bash
# 部署签名公钥
cp my-openwrt.rsa.pub /etc/apk/keys/
chmod 644 /etc/apk/keys/my-openwrt.rsa.pub

# IPTV 代理
apk add iptv-auth-2.3.35-r0.apk

# 影视中心
apk add luci-app-mediahub-1.5.7-r0.apk

# 状态监控
apk add luci-app-statusmon-4.40.apk

# 网络优化
apk add luci-app-netqueue-1.0.20-r0.apk

# 保留升级
apk add luci-app-syskeep-1.0.18-r0.apk
```

签名未信任时：

```bash
# 临时允许未信任签名
apk add --allow-untrusted xxx.apk
```

传统 opkg（x86_64 IPK，不含影视中心）：

```bash
# IPTV 代理
opkg install iptv-auth_2.3.35-r0_x86_64.ipk

# 状态监控
opkg install luci-app-statusmon_4.40_x86_64.ipk

# 网络优化
opkg install luci-app-netqueue_1.0.20-r0_x86_64.ipk

# 保留升级
opkg install luci-app-syskeep_1.0.18-r0_x86_64.ipk
```

## IPTV

LuCI 菜单：**服务 → IPTV 代理**。

OTA：`packages/iptv-auth/version.json`。改 `version` 后 LuCI 状态页可热更新。仓库需 Public，否则 raw.githubusercontent.com 会 404。

rtp2httpd 自编译（缓冲池 1024）在 `packages/rtp2httpd/`。上游发新版后：

```bash
# 拉取官方标签、打补丁、编 x86_64 与 aarch64 静态包
bash packaging/rtp2httpd/build.sh 3.17.2
```

回看代理 `iptv-replayd` 为独立 C 守护进程，源码在 `src/iptv-replayd/`。改动后重新交叉编译
（静态 musl，x86_64/aarch64，产物落 `packages/iptv-replayd/`），再执行 `packaging/build-apks.sh`
打进 `iptv-auth` 包：

```bash
# 交叉编译 iptv-replayd 两种架构
bash packaging/iptv-replayd/build.sh

# 打包（自动按架构把二进制装入 iptv-auth apk/ipk）
export APK=/path/to/apk
bash packaging/build-apks.sh
```

## IPTV 更新日志

从 IPv6 双栈起：

| 版本 | 日期 | 说明 |
|------|------|------|
| 2.3.35 | 2026-10-16 | 修复外网回看偶发失败：上游门户拒绝 playseek 窗口 `end` 落在未来的请求（RTSP 562），`iptv-replayd` 现将 `programend` 收敛到当前时刻前 2 秒，消除 rtp2httpd `(e)` 占位符落在“现在”边界导致的抖动；握手期间上游返回非 2xx 不再误判为握手完成而进入转发。回看转发优化：握手缓冲区在进入转发前释放、S→C 方向复用入口线程（每会话约省 656KB 内存与一个线程）。控制面优化：EPG/台标抓取并发（`fetch_workers`，默认 4，上限 16）、IPTV HTTP 长连接复用（并设 `TCP_NODELAY`，避免小请求叠加延迟 ACK 造成停顿）。rtp2httpd 参数页新增「最大客户端数」（`-m`，默认 5，可调 1~256），可自行提升同时观看并发上限 |
| 2.3.34 | 2026-10-16 | 554 回看/时移代理拆为独立 C 守护进程 `iptv-replayd`（无 Python、去 GIL，静态 musl x86_64/aarch64；init.d 按 `uname -m` 选二进制，升级走 post-upgrade）；C 端读 `/etc/TZ` 修正静态 musl 日志时区（本机 `/etc/localtime` 悬空会回退 UTC）；控制面仅落盘运行时状态（源站 IP 空值时保留上次值） |
| 2.3.33 | 2026-10-15 | HTTP(S) 改用 Python 标准库 urllib，去掉 requests/pip 依赖（依赖改 ca-bundle） |
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

转发默认开队列绑定、CPU 锁定最高、睿频、PPPoE 队列、UDP GRO、接收积压；软件分载默认关。

CPU 模式对应 Intel HWP：节能 power、均衡 balance_performance、性能 performance；锁定最高把最低频率钉满。睿频对应 `intel_pstate/no_turbo`。

NAT 模式：NAT1 完全锥形（`defaults.fullcone`）、NAT3 默认 masquerade、NAT4 `masquerade fully-random`。与转发总开关无关。

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
