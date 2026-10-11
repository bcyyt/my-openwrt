# my-openwrt

ImmortalWrt / OpenWrt APK 插件仓库：IPTV 代理、影视中心、状态监控、网络优化、保留升级。

## 软件包

| 包名 | 版本 | 架构 | 说明 |
|------|------|------|------|
| `iptv-auth` | 2.3.12-r0 | noarch | IPTV 鉴权、M3U/EPG、RTSP 回看、rtp2httpd 直播代理；4K 无节目单时回填同名高清 EPG |
| `luci-app-mediahub` | 1.5.7-r0 | x86_64 | 影视中心（CMS + AList + 静态 ffmpeg） |
| `luci-app-statusmon` | 4.26 | noarch | 状态监控；客户端按活跃/空闲/离线分页；PPPoE 流量跨重拨累计 |
| `luci-app-netqueue` | 1.0.16-r0 | noarch | 网络优化：转发、DHCP、DNS、静态 IP、过期 ARP 自动清理；界面与 IPTV 风格统一 |
| `luci-app-syskeep` | 1.0.6-r0 | noarch | 保留升级：刷机保留配置与数据盘；界面与 IPTV 风格统一 |

APK 位于 `packages/`，均用 `keys/my-openwrt.rsa` 签名。

## 安装

把公钥放到路由器：

```bash
# 部署签名公钥
cp my-openwrt.rsa.pub /etc/apk/keys/
chmod 644 /etc/apk/keys/my-openwrt.rsa.pub
```

安装包：

```bash
# IPTV 代理
apk add iptv-auth-2.3.12-r0.apk

# 影视中心
apk add luci-app-mediahub-1.5.7-r0.apk

# 状态监控（含文件管理器与中文语言包）
apk add luci-app-statusmon-4.26.apk

# 网络优化（转发 / DHCP / DNS / 静态 IP）
apk add luci-app-netqueue-1.0.16-r0.apk

# 保留升级
apk add luci-app-syskeep-1.0.6-r0.apk
```

若提示 UNTRUSTED signature，确认公钥已放入 `/etc/apk/keys/`，或临时使用：

```bash
# 临时允许未信任签名（公钥未部署时）
apk add --allow-untrusted xxx.apk
```

## IPTV OTA

默认 OTA 地址：

https://raw.githubusercontent.com/bcyyt/my-openwrt/main/packages/iptv-auth/version.json

`version.json` 中的 `url` 指向同目录 APK。LuCI「运行状态与日志」页可检测并热更新。

仓库当前为 private 时，raw.githubusercontent.com 会返回 404。需要在 GitHub 仓库 Settings 把仓库设为 Public，路由器才能拉取 OTA。

重新打包后修改 `packages/iptv-auth/version.json` 的 `version` 字段即可触发 OTA。

2.3.12：4K 频道运营商未返回节目单时，按同名高清台回填 EPG。

## 网络优化

LuCI 菜单：**网络 → 网络优化**。

转发、DHCP、邻居、DNS 在同一页，各自「保存并应用」。绑定静态 IP 马上生效。不断开 PPPoE，也不改 wan2 / IPTV 路由。

当前包：`packages/luci-app-netqueue/luci-app-netqueue-1.0.16-r0.apk`。

### 转发

- **启用转发优化**：总开关。关掉后下面几项都恢复系统默认。
- **网卡队列绑定**：IRQ / XPS 按队列绑核。PPPoE 物理口 RPS 打到全部 CPU，LAN / IPTV 口关 RPS，走网卡 RSS。
- **CPU 性能模式**：全部 CPU 使用 `performance`。
- **软件流量分载**：减轻 conntrack 转发开销。家用建议关掉；打开后状态监控会少计客户端流量。
- **PPPoE 发送队列**：`pppoe-wan` 的 `txqueuelen` 从 3 提到 1000。
- **UDP GRO 转发**：打开 `rx-udp-gro-forwarding`。
- **加大接收积压**：`netdev_max_backlog` 从 1000 提到 4096。

默认：总开关、队列、CPU、PPPoE 队列、GRO、积压开启；软件分载关闭。

### DHCP

- **启用 DHCP**：给 LAN 发地址。关掉后终端要自己设 IP。
- **按顺序分配**：对应 dnsmasq `sequential_ip`。打开后从地址池最小 IP 依次发放；关掉则按 MAC 哈希。
- **起始地址**：网段偏移。例如 `192.168.10.0/24` 填 `100` 表示从 `192.168.10.100` 开始。
- **地址数量** / **租期**：LAN 地址池大小和租约时间。
- **终端 DNS**：默认「本机」。选「自定义」后写入 DHCP option 6。

空着起始地址、数量、租期再保存时，不会删掉路由器上已有的值。
转发、DHCP、邻居、DNS 各自「保存并应用」。

### 邻居与静态 IP

- 页面列出当前租约、静态绑定和 `br-lan` ARP。过期动态租约会从列表拿掉。
- 邻居列表每页 10 台。
- **邻居清理（秒）**：ARP `gc_stale_time`，STALE 邻居按这个时间回收。
- **自动清理过期邻居**：按秒数定时执行。只删 FAILED 和已不在租约/静态绑定里的残留 ARP；REACHABLE 和当前仍在用的地址保留。
- **绑定静态 IP**：写 `dhcp.host`，删掉该 MAC 的旧租约，重载 dnsmasq，清掉旧/新 IP 的邻居条目。点绑定立刻生效。

### DNS

- **跟随运营商**（默认）：dnsmasq 使用 WAN 拨号拿到的 DNS，写入 `resolvfile`，不写 223 / 114。
- **自定义**：按行填写上游，并打开 `noresolv`。
- **缓存条数**：对应 dnsmasq `cachesize`。

### 命令行

```bash
# 查看当前转发 / DHCP / DNS 生效情况
/usr/bin/netqueue-apply.sh status

# 按 UCI 重新套用转发参数
/etc/init.d/netqueue reload
```

UCI 在 `netqueue.main`。DHCP / DNS 仍写在 `dhcp` 配置里。

### 1.0.5

- 菜单从「转发优化」改为「系统优化」，并加上 DHCP / DNS。
- LuCI 改为自定义页和按钮开关，不再用 CBI 表单。
- 读写走同一入口的 `?act=info` / `?act=save`，避免子路由未注册导致页面拿到 HTML。
- 修复 `sys_exec()` 把 `gsub` 计数值传给 `tonumber`、页面「读取失败」、开关全关的问题。
- 保存时空字段不再删除 DHCP 地址池。

### 1.0.6

- DHCP 邻居表：租约、静态绑定、`br-lan` ARP。
- 邻居清理秒数：ARP `gc_stale_time`。
- 静态 IP 绑定走独立 `?act=static|dynamic`，保存后 `dhcp-kick` 删租约、重载 dnsmasq、清 ARP。

### 1.0.7

- 自动清理过期邻居：cron 按「邻居清理（秒）」执行，只删残留 ARP，保留在用租约/静态 IP 和 REACHABLE。

### 1.0.8

- LuCI 页手机自适应：邻居改卡片、开关与输入框不再撑出屏幕。

### 1.0.9

- 菜单与页面标题从「系统优化」改为「网络优化」。
- DHCP 邻居每页 10 台，底部分页。

### 1.0.10

- DHCP 配置有单独的「保存并应用」，只写 DHCP / 邻居清理，不改转发和 DNS。

### 1.0.11

- 转发、DHCP、DNS 各自「保存并应用」，去掉页面底部总保存。

### 1.0.12

- DHCP 邻居独立成块：清理秒数和自动清理单独保存；绑定/取消/添加静态立刻生效。

### 1.0.13

- LuCI 页对齐 IPTV / 影视中心：蓝主色、页头版本徽章、状态格、分区标题。

### 1.0.14

- 在线设备：IP 输入、绑定、取消同一排。

### 1.0.15

- 在线设备改成单行：名称、MAC、当前 IP、绑定 IP、绑定/取消。

### 1.0.16

- 在线设备单行改成整行网格对齐，名称占剩余宽度，MAC / IP / 按钮各列对齐。

## 影视中心

当前包：`packages/luci-app-mediahub/luci-app-mediahub-1.5.7-r0.apk`。

网盘播放走 `8901 /play` 反代（Range 先 AList `/p/`，失败再 `raw_url`），APP 与订阅同一端口。已有截帧会登记进海报库；刮削失败再补截帧。
升级时若本机已有 AList，只同步管理员密码（`--sync-pw`），不重下二进制、不覆盖 init。

### 1.5.7

- `/sub/pg` 对齐小雅：本机无 PG 包时拉取在线 `jsm.json`（74 站 + `pg.jar`），token 仍走本机 `/pg/tokenm.json`。
- 自有 CMS / 网盘源排在订阅最前；丢掉依赖 127.0.0.1 本地代理的 PG 直播源。

## 状态监控

当前包：`packages/luci-app-statusmon/luci-app-statusmon-4.26.apk`。

同一 MAC 多 IPv4 时优先 `REACHABLE/DELAY/PROBE` 邻居，其次 DHCP 租约，避免 STALE 旧地址盖住当前 IP。

### 4.25

- 已连接客户端增加全部 / 活跃 / 空闲 / 离线筛选，标签显示数量。
- 每页 10 台，底部分页；刷新数据时停在当前页，筛选会记住。

### 4.26

- 网络接口里 PPPoE 收发字节跨重拨累计，逻辑口重建后总量不清零。

## 保留升级

LuCI 菜单：**系统 → 保留升级**。

当前包：`packages/luci-app-syskeep/luci-app-syskeep-1.0.6-r0.apk`。

只写镜像分区 1/2（boot + rootfs），GPT 和数据盘不动。备份时对比 `/rom` 的 world，自装插件能 fetch 就拉 APK，源里没有的打文件包。数据盘按 fstab / 挂载自动识别，写入 `/etc/syskeep/datadir`。

自定义插件清单：`src/router-files/etc/syskeep/custom-apks.txt`。

```bash
# 查看数据盘、插件备份和固件准备情况
/usr/bin/syskeep-upgrade.sh status
```

### 1.0.5

- LuCI 页手机自适应：下载地址、文件选择、按钮在窄屏全宽单列。

### 1.0.6

- LuCI 页对齐 IPTV / 影视中心：蓝主色、页头版本徽章、状态格、分区标题。

## 签名密钥

- 公钥：`keys/my-openwrt.rsa.pub`（安装到 `/etc/apk/keys/`）
- 私钥：`keys/my-openwrt.rsa`（仅用于 `apk mkpkg --sign-key`）

请妥善保管私钥。

## 重新打包

依赖本机 apk-tools 3.0.5（`apk mkpkg`）：

```bash
# 设置 apk 路径后执行打包
export APK=/path/to/apk
bash packaging/build-apks.sh
```
