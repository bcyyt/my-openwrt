# my-openwrt OTA 制品仓库

本仓库只存放路由器 OTA 升级所需的签名安装包与版本清单，源码、打包脚本和签名私钥
保存在私有仓库 `bcyyt/my-openwrt-sy`。

目录结构：

- `packages/iptv-auth/`：IPTV 代理 APK/IPK 与 `version.json`
- `packages/luci-app-mediahub/`：影视中心 APK
- `packages/luci-app-statusmon/`：状态监控 APK/IPK
- `packages/luci-app-netqueue/`：网络优化 APK/IPK
- `packages/luci-app-syskeep/`：保留升级 APK/IPK
- `packages/rtp2httpd/`：自编译 rtp2httpd 二进制与 `version.json`
  - `NOTICE.md` / `LICENSE`：GPL-2.0 著作权、修改说明、致谢与许可全文
  - `source/`：对应修改后源码（上游 tar.gz + 补丁 + 构建脚本 + 校验值）
- `packages/ffmpeg-mini/`：内置精简 ffmpeg 构建产物
- `packages/iptv-replayd/`：回看代理二进制
- `packages/keys/my-openwrt.rsa.pub`：APK 签名公钥
- `packages/logos/`：频道台标 PNG，播放列表 `tvg-logo` 指向此处

OTA 地址保持 `https://raw.githubusercontent.com/bcyyt/my-openwrt/main/packages/...`，
路由器无需改动。发布新版本时从私有仓库执行 `packaging/publish-ota.sh` 同步本目录。
