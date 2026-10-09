# my-openwrt

ImmortalWrt / OpenWrt APK 插件仓库：IPTV 代理、影视中心、状态监控、系统优化、保留升级。

## 软件包

| 包名 | 版本 | 架构 | 说明 |
|------|------|------|------|
| `iptv-auth` | 2.3.11-r0 | noarch | IPTV 鉴权、M3U/EPG、RTSP 回看、rtp2httpd 直播代理；选上游接口后自动走专线策略表（不改主路由） |
| `luci-app-mediahub` | 1.5.4-r0 | x86_64 | 影视中心（CMS + AList + 静态 ffmpeg） |
| `luci-app-statusmon` | 4.20 | noarch | 状态监控；内置 luci-app-filemanager 与中文语言包 |
| `luci-app-netqueue` | 1.0.5-r0 | noarch | 系统优化：转发、DHCP、DNS |
| `luci-app-syskeep` | 1.0.2-r0 | noarch | 保留升级：刷机保留配置与数据盘，自动识别数据盘并备份自装插件 |

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
apk add iptv-auth-2.3.11-r0.apk

# 影视中心
apk add luci-app-mediahub-1.5.4-r0.apk

# 状态监控（含文件管理器与中文语言包）
apk add luci-app-statusmon-4.20.apk

# 系统优化（转发 / DHCP / DNS）
apk add luci-app-netqueue-1.0.5-r0.apk

# 保留升级
apk add luci-app-syskeep-1.0.2-r0.apk
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

## 系统优化

LuCI 菜单：**网络 → 系统优化**。

转发、DHCP、DNS 在同一页。点「保存并应用」后立即生效，不断开 PPPoE，也不改 wan2 / IPTV 路由。

当前包：`packages/luci-app-netqueue/luci-app-netqueue-1.0.5-r0.apk`。

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
