# my-openwrt

ImmortalWrt / OpenWrt APK 插件仓库：IPTV 代理、影视中心、状态监控、转发优化、保留升级。

## 软件包

| 包名 | 版本 | 架构 | 说明 |
|------|------|------|------|
| `iptv-auth` | 2.3.11-r0 | noarch | IPTV 鉴权、M3U/EPG、RTSP 回看、rtp2httpd 直播代理；选上游接口后自动走专线策略表（不改主路由） |
| `luci-app-mediahub` | 1.5.4-r0 | x86_64 | 影视中心（CMS + AList + 静态 ffmpeg） |
| `luci-app-statusmon` | 4.20 | noarch | 状态监控；内置 luci-app-filemanager 与中文语言包 |
| `luci-app-netqueue` | 1.0.1-r0 | noarch | 转发优化：队列绑定、CPU、PPPoE 队列、UDP GRO、接收积压、软件分载 |
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

# 转发优化
apk add luci-app-netqueue-1.0.1-r0.apk

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
