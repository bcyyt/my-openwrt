# rtp2httpd 3.17.2 (3.17.2-r1) 对应源码

本目录是 my-openwrt 分发的 rtp2httpd 3.17.2-r1 二进制的完整对应源码材料。

## 上游源码

- 地址：<https://github.com/stackia/rtp2httpd/archive/refs/tags/v3.17.2.tar.gz>
- 本地归档：`upstream-rtp2httpd-3.17.2.tar.gz`
- sha256：`ce866091321a0d69dff7e8f7dda5d68be94e901659ed7d2ff4896029c8200ee6`

## 修改补丁（按顺序应用）

1. `buffer-pool-1024.patch`：缓冲区池初始/扩展大小 128 → 1024
2. `catchup-keep-seek-mode.patch`：导出 playlist.m3u 保留 `r2h-seek-mode` / `r2h-seek-offset` / `r2h-ifname`
3. `client-hup-and-timeout.patch`：仅在 HUP 时断开客户端；`TCP_USER_TIMEOUT` 10s → 600s

## 构建

需要 `cmake`、`make`、`curl` 或 `wget`；工具链由上游 `scripts/build-static.sh`
自动下载（musl-cross release 20260823，x86_64/aarch64 两套）。

```bash
mkdir -p /tmp/r2h && cd /tmp/r2h
tar -xzf /path/to/upstream-rtp2httpd-3.17.2.tar.gz
cd rtp2httpd-3.17.2
for p in buffer-pool-1024 catchup-keep-seek-mode client-hup-and-timeout; do
    patch -p1 < /path/to/$p.patch
done
RELEASE_VERSION=3.17.2-r1 TOOLCHAIN_PREFIX=x86_64-unknown-linux-musl bash scripts/build-static.sh
RELEASE_VERSION=3.17.2-r1 TOOLCHAIN_PREFIX=aarch64-unknown-linux-musl bash scripts/build-static.sh
```

产物位于 `build-<prefix>-static/dist/usr/bin/rtp2httpd`。

## 产物校验

| 文件 | md5 | sha256 |
|------|-----|--------|
| rtp2httpd-3.17.2-r1-x86_64 | `cf571ceee5e88ef5f41c594a038becd7` | `43e9257b61bf05ceec11ec3ec63efe45ef706f9e6a072ecb7ceefae6ddc2766b` |
| rtp2httpd-3.17.2-r1-aarch64 | `33cc351aaee4f6f601f6d9331b8f4bdf` | `1c8c5dc00ca494ac6701693111d5c72194c792d4603f98e525f8037bf1501c77` |

用上述源码与补丁从零重建 x86_64 产物，与上表 md5 逐字节一致。

`build.sh` 是同一构建流程的封装（自动下载上游归档、应用补丁、输出到 `packages/rtp2httpd/`）。

## 许可

GPL-2.0，全文见上级目录 `LICENSE`；著作权与致谢见上级目录 `NOTICE.md`。
