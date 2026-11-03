# rtp2httpd 自编译补丁清单与上游升级 SOP

> 目的：上游（github.com/stackia/rtp2httpd）发新版本后，按本文件把全部自编译补丁重新套上并发布，
> 不需要重新排查任何历史问题。当前基线：**v3.17.2 → 3.17.2-r4**（2026-11-01）。

## 一、补丁清单（4 个独立补丁，按序 `patch -p1` 应用）

| # | 补丁文件 | 改动目的 | 主要涉及文件 | 升级冲突风险 |
|---|---|---|---|---|
| 1 | buffer-pool-1024.patch | 缓冲池初始/扩展块数 128 → 1024，抗播放器停顿背压 | buffer_pool.h 的 BUFFER_POOL_INITIAL_SIZE、EXPAND_SIZE | 低（常量定义） |
| 2 | catchup-keep-seek-mode | 导出 playlist.m3u 时保留 `r2h-seek-mode` / `r2h-seek-offset` / `r2h-ifname` 参数（浏览器直接拖动回看用） | m3u.c 导出路径 | 低 |
| 3 | client-hup-and-timeout | 客户端半关闭（FIN）不主动断流，仅 HUP 断开；`TCP_USER_TIMEOUT` 保持上游 10s | worker.c 的 HUP 处理 | 中（若上游重构连接生命周期） |
| 4 | logo-rewrite-host | 新增 `--rewrite-logo-host`：按请求 Host 改写 `tvg-logo` 主机名并保留端口与 `/logo/` 路径（多网卡/域名访问 EPG 图标） | configuration.c/.h、m3u.c（新参数 + 导出改写） | 低-中（新命令行参数） |

## 二、升级流程（上游发新版时）

1. 改 `UPGRADE.md` 顶部基线与 `SOURCE.md` 上游地址（记新 tag）。
2. `bash packages/rtp2httpd/source/build.sh <新上游版本> <新发布号>` —— 自动下载
   上游归档、套 4 补丁、双架构静态编译（musl-cross 20260823 工具链自动下载）。
3. 若补丁冲突：对照上表逐个人工解决，并做语义核对（不是文本对齐，是行为核对）：
   - 1：池常量确实生效（strace 大停顿下无池耗尽路径）
   - 2：导出 m3u 带 r2h-seek-* 且浏览器可拖动
    - 3：GET 后 FIN 的播放器不断流
   - 4：非本机 Host 请求 m3u 时 logo 指向请求 Host
4. 更新 `SOURCE.md` 产物 md5/sha256、`NOTICE.md` 修改内容、`version.json`（url 指向
   新二进制 + changelog）。
5. 验证：路由器 OTA 安装后 `rtp2httpd --help` 版本正确、`/usr/bin/rtp2httpd` md5
   与 SOURCE.md 一致、直播/回看各拉 30s 无异常。
6. my-openwrt 与 my-openwrt-sy 两仓同版本提交推送（OTA 指向 my-openwrt）。
7. 收尾：`curl -X PUT 'http://127.0.0.1:23234/status/api/log-level?r2h-token=<token>' -d 'level=3'`。

## 四、历史版本链（rN ↔ 内容）

- r2/r3：缓冲池 1024、导出 seek 参数、仅 HUP 断开、TCP_USER_TIMEOUT 600s、rewrite-logo-host
- r4：TCP_USER_TIMEOUT 改回上游 10s，其余同 r3
