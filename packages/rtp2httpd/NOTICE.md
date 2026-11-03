# rtp2httpd 修改版：著作权、许可证与致谢

本目录分发的 `rtp2httpd-3.17.2-r4-x86_64`、`rtp2httpd-3.17.2-r4-aarch64` 是
rtp2httpd 3.17.2 的修改版，由 bcyyt 为 my-openwrt 项目构建并分发。
rtp2httpd 以 GNU General Public License v2.0 发布，许可全文见同目录 `LICENSE`。

## 著作权

- 上游项目：rtp2httpd，<https://github.com/stackia/rtp2httpd>
- 上游版本：v3.17.2
- 最初作者：Ondrej Caletka、Richard Golier
- 现代化重构与维护：Stackie Jia <jsq2627@gmail.com>
- 本修改版修改部分的著作权：Copyright (C) 2026 bcyyt <bcyyt@users.noreply.github.com>

## 修改内容（3.17.2-r4）

1. `src/buffer_pool.h`：`BUFFER_POOL_INITIAL_SIZE`、`BUFFER_POOL_EXPAND_SIZE` 由 128 调整为 1024。
2. `src/m3u.c`：新增 `append_catchup_control_params()`，导出 `playlist.m3u` 时保留
   `r2h-seek-mode`、`r2h-seek-offset`、`r2h-ifname` 三个控制参数。
3. `src/worker.c`：仅在 `POLLER_HUP` 时断开客户端，忽略 `POLLER_RDHUP`
   （客户端发送 GET 后关闭写半边属正常行为）；连接错误日志由 DEBUG 调整为 INFO。
   `TCP_USER_TIMEOUT` 保持上游 10s。
4. `src/configuration.c` / `src/m3u.c`：新增 `--rewrite-logo-host`。生成 `playlist.m3u`
   时把 `tvg-logo="http(s)://.../logo/..."` 的主机名改成请求 Host（去掉端口），
   台标端口与 `/logo/` 路径保持不变。

以上改动对应 `source/` 下 4 个补丁文件：`buffer-pool-1024.patch`、
`catchup-keep-seek-mode.patch`、`client-hup-and-timeout.patch`、
`logo-rewrite-host.patch`；未修改的文件与上游 v3.17.2 一致。

## 对应源码（GPL-2.0 第 3 条要求）

修改后的完整源码与二进制同目录提供，位于 `source/`：

| 文件 | 说明 |
|------|------|
| `upstream-rtp2httpd-3.17.2.tar.gz` | 上游 v3.17.2 源码归档（GitHub tag tarball） |
| `buffer-pool-1024.patch` 等 4 个补丁 | r4（当前发布）的全部改动，`patch -p1` 依次应用 |
| `UPGRADE.md` | 补丁清单与上游升级 SOP（含逐项修复语义核对表） |
| `build.sh` | 构建脚本（下载、打补丁、双架构静态编译） |
| `SOURCE.md` | 源码归档 sha256、补丁应用方法、构建命令与产物校验值 |

重新构建 r4：

```bash
mkdir -p /tmp/r2h && cd /tmp/r2h
tar -xzf source/upstream-rtp2httpd-3.17.2.tar.gz
cd rtp2httpd-3.17.2
for p in buffer-pool-1024 catchup-keep-seek-mode client-hup-and-timeout logo-rewrite-host; do
  patch -p1 < ../source/$p.patch
done
RELEASE_VERSION=3.17.2-r4 TOOLCHAIN_PREFIX=x86_64-unknown-linux-musl bash scripts/build-static.sh
```

（aarch64 同理换用 aarch64 工具链；与分发二进制逐字节一致的直接编译命令见 `source/SOURCE.md`。）

## 致谢

- 感谢 rtp2httpd 的作者与维护者 Ondrej Caletka、Richard Golier、Stackie Jia，
  以及上游贡献者提供的 IGMP / FCC / RTSP 代理实现。
- 感谢 musl libc（MIT，<https://musl.libc.org/>）：本二进制为静态链接 musl。
- 感谢 cross-tools/musl-cross（<https://github.com/cross-tools/musl-cross>）
  提供的预编译 musl 交叉工具链。
- 感谢 OpenWrt、ImmortalWrt 社区提供的运行环境与文档。
- 感谢 LuCI 项目（Apache-2.0）：配置页基于其 Web 框架运行。
