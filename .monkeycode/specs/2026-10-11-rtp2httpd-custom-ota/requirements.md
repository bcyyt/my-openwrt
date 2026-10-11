# Requirements Document

## Introduction

为 ImmortalWrt x86_64 路由器提供自编译 rtp2httpd：把官方写死的初始缓冲池加大，二进制托管在本仓库，LuCI「rtp2httpd 在线更新」从本仓库拉取。上游发新版本时，重新打补丁、编译、上传仓库后，路由器按仓库清单更新。

## Glossary

- **System**: iptv-auth 插件中的 rtp2httpd 更新脚本与 LuCI 配置页
- **Upstream**: stackia/rtp2httpd 官方源码与 GitHub Release
- **Custom Binary**: 对本仓库补丁编译出的 x86_64 静态可执行文件
- **Repo Manifest**: `packages/rtp2httpd/version.json`，含 version、date、changelog、url
- **Initial Buffer Pool**: `BUFFER_POOL_INITIAL_SIZE`，官方值为 128，每个缓冲 1536 字节
- **OTA Update**: 路由器下载 Custom Binary，原子替换 `/usr/bin/rtp2httpd` 后由 procd 拉起

## Requirements

### Requirement 1

**User Story:** AS 管理员, I want 使用加大初始缓冲池的 rtp2httpd, so that 4K 开播时缓冲池不必从 128 块往上扩

#### Acceptance Criteria

1. WHEN 管理员编译 Custom Binary, the System SHALL 把 `BUFFER_POOL_INITIAL_SIZE` 设为 512
2. WHEN 管理员编译 Custom Binary, the System SHALL 把 `BUFFER_POOL_EXPAND_SIZE` 设为 512
3. WHEN Custom Binary 启动, the System SHALL 在 `--help` 输出版本号，版本号与 Upstream 标签一致

### Requirement 2

**User Story:** AS 管理员, I want 把自编译二进制放进本仓库, so that 路由器能用 raw GitHub 地址下载

#### Acceptance Criteria

1. WHEN Custom Binary 构建完成, the System SHALL 把 x86_64 与 aarch64 两个文件写入 `packages/rtp2httpd/`
2. WHEN Custom Binary 构建完成, the System SHALL 写入 Repo Manifest，字段包含 version、date、changelog、url
3. WHEN 仓库只保留当前 Custom Binary, the System SHALL 使 `packages/rtp2httpd/` 中仅存在当前版本的 x86_64、aarch64 二进制与一份 Manifest

### Requirement 3

**User Story:** AS 管理员, I want LuCI 检查更新和立即更新走本仓库, so that 装上的是带补丁的版本

#### Acceptance Criteria

1. WHEN 管理员点击「检查更新」, the System SHALL 读取 Repo Manifest 得到 latest 版本
2. WHEN Manifest 中的 version 高于当前 `/usr/bin/rtp2httpd` 版本, the System SHALL 提示可更新
3. WHEN 管理员点击「立即更新」, the System SHALL 按 Manifest 的 url 下载 Custom Binary，校验可执行后原子替换 `/usr/bin/rtp2httpd`
4. WHEN 替换完成, the System SHALL 结束旧 rtp2httpd 进程并等待 procd 拉起新进程
5. IF 下载失败或新文件无法执行, the System SHALL 保留现有 `/usr/bin/rtp2httpd` 并在状态文件中写失败原因

### Requirement 4

**User Story:** AS 管理员, I want 上游发新版时能按同一补丁重编译并上传, so that 路由器下次 OTA 拿到新上游加补丁的二进制

#### Acceptance Criteria

1. WHEN 管理员指定 Upstream 标签, the System SHALL 拉取该标签源码、应用缓冲池补丁并编译 x86_64 与 aarch64 Custom Binary
2. WHEN 新 Custom Binary 推送到 main, the System SHALL 更新 Repo Manifest 的 version 与 url
3. WHEN 路由器再次检查更新, the System SHALL 以 Manifest 的 version 作为可安装版本
