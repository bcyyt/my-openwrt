# my-openwrt OTA 制品仓库

本仓库只存放路由器 OTA 升级所需的签名安装包与版本清单，源码、打包脚本和签名私钥
保存在私有仓库 `bcyyt/my-openwrt-sy`。

目录结构：

- `packages/iptv-auth/`：IPTV 代理 APK/IPK 与 `version.json`
- `packages/luci-app-mediahub/`：影视中心 APK
- `packages/luci-app-statusfw/`：状态与防火墙 APK/IPK（性能监控 + 防火墙/安全采集器）
- `packages/luci-app-netqueue/`：网络优化 APK/IPK
- `packages/luci-app-syskeep/`：保留升级 APK/IPK
- `packages/rtp2httpd/`：自编译 rtp2httpd 二进制与 `version.json`
  - `NOTICE.md` / `LICENSE`：GPL-2.0 著作权、修改说明、致谢与许可全文
  - `source/`：对应修改后源码（上游 tar.gz + 补丁 + 构建脚本 + 校验值）
- `packages/ffmpeg-mini/`：内置精简 ffmpeg 构建产物
- `packages/iptv-replayd/`：回看代理二进制
- `packages/keys/my-openwrt.rsa.pub`：当前 APK 签名公钥
- `packages/keys/my-openwrt-legacy.rsa.pub`：轮换前公钥（校验旧制品）
- `packages/logos/`：频道台标 PNG，播放列表 `tvg-logo` 指向此处

## 第三方组件与许可：rtp2httpd（修改版，GPL-2.0）

`packages/rtp2httpd/` 分发的 `rtp2httpd-3.17.2-r1-x86_64`、`rtp2httpd-3.17.2-r1-aarch64`
`packages/rtp2httpd/` 分发的 `rtp2httpd-3.17.2-r2-x86_64`、`rtp2httpd-3.17.2-r2-aarch64`
是 rtp2httpd 3.17.2 的修改版，由 bcyyt 为 my-openwrt 构建并分发。

- 上游项目：<https://github.com/stackia/rtp2httpd>，版本 v3.17.2
- 最初作者：Ondrej Caletka、Richard Golier
- 现代化重构与维护：Stackie Jia <jsq2627@gmail.com>
- 本修改版修改部分著作权：Copyright (C) 2026 bcyyt
- 许可：GNU General Public License v2.0，全文见 `packages/rtp2httpd/LICENSE`

修改内容：`buffer_pool.h` 缓冲区池初始/扩展大小 128 → 1024；`m3u.c` 导出
`playlist.m3u` 时保留 `r2h-seek-mode` / `r2h-seek-offset` / `r2h-ifname`；
`connection.c` 的 `TCP_USER_TIMEOUT` 10s → 600s 并在 `worker.c` 中仅在 HUP 时断开客户端
（忽略客户端 GET 后的写半关闭），连接错误日志由 DEBUG 调整为 INFO。
生成 `playlist.m3u` 时可按 `--rewrite-logo-host` 把 `tvg-logo` 主机名改成请求 Host，端口保持不变。

按 GPL-2.0 要求，修改后的完整源码随二进制在同一目录提供：`packages/rtp2httpd/source/`
包含上游源码归档、四个补丁、构建脚本 `build.sh` 与 `SOURCE.md`（上游归档 sha256、
补丁顺序、构建命令、产物 md5/sha256）。用该材料从零重建的 x86_64 产物与分发二进制
md5 在构建后写入 `source/SOURCE.md`。同样的声明随包提供于
`packages/rtp2httpd/NOTICE.md`。

致谢：rtp2httpd 的作者与维护者 Ondrej Caletka、Richard Golier、Stackie Jia 及上游贡献者；
musl libc（MIT，<https://musl.libc.org/>）提供静态运行库；cross-tools/musl-cross
（<https://github.com/cross-tools/musl-cross>）提供交叉工具链；OpenWrt、ImmortalWrt
社区提供运行环境与文档；LuCI 项目（Apache-2.0）提供 Web 框架。

OTA 地址为 `https://gitee.com/bcyyt/my-openwrt/raw/main/packages/...`。
发布新版本时从私有仓库执行 `packaging/publish-ota.sh` 同步 GitHub 公开仓，并同步同一目录到 Gitee 公开仓 `bcyyt/my-openwrt`。

## iptv-auth 近期版本

| 版本 | 日期 | 说明 |
|------|------|------|
| 2.3.66-r4 | 2026-10-29 | 当前包。上游 IPTV 口关闭 peerdns，DHCP DNS 只给本程序解析 EDS/EPG。EDS 走 /EDS/authurl 并跟随同机跳转，发现成功即写入 UCI，配置页显示 EPG 入口。含 r3：EDS 默认域名 esidt.scrmt.org.cn:8001，上游 DNS 解析后发现 EPG 入口和门户。StbIP 随上游接口 IPv4 自动更新。鉴权前向 EPG 入口 getencrypttoken.jsp 自动发现门户；失败沿用现 iptv_server。配置页新增 EDS / EPG 入口。含 2.3.65-r10 加固：LuCI/OTA 调用链（POSIX 单引号、http/https、M3U 属性转义、curl -f、mktemp）；apk 升级钩子也会检查并替换较新的 rtp2httpd 再重启。LuCI 更新 iptv-auth 时若 rtp2httpd 有新版本则一并替换并重启全部进程；仓库 rtp2httpd 3.17.2-r3；M3U 台标走本机 /logo/，rtp2httpd 可按请求 Host 改写台标主机；删除 logo_url_mode；OTA/台标/rtp2httpd 走 Gitee 网页 raw；curl 跟随 302；升级写回 ota_url 并清掉镜像残留；版本比较纳入 -rN |
