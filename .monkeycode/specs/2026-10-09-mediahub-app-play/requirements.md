# Requirements Document

## Introduction

重构影视中心面向 TVBox 类 APP 的三块体验：订阅、列表、搜索、海报都要加快；全部网盘走同一套 8901 反代播放；批量刮削后仍无封面的网盘影片用截帧补上。系统仍走现有 `8901` CMS + AList，不改 wan2 / IPTV，不改保留升级。

## Glossary

- **System**: `luci-app-mediahub` 与 `mediahub-cms.py`（监听 8901）
- **APP**: 使用 `tvbox.json` / 小雅 PG 订阅的播放器（TVBox、影视仓等）
- **CMS Source**: `/cms.php/provide/vod` 聚合采集站
- **Cloud Source**: `/cloudcms.php/provide/vod` 网盘片源
- **Play Proxy**: APP 播放请求经 8901 反代到 AList `/p/`（web_proxy + Range）
- **Frame Poster**: 从网盘视频抽出的一帧 JPEG，经 `/thumb/` 提供给 APP
- **Warm Cache**: 网盘文件列表、签名、搜索结果已在内存或磁盘缓存中

## Requirements

### Requirement 1

**User Story:** AS APP 用户, I want 打开订阅和首页列表更快返回, so that 进分类不用空等

#### Acceptance Criteria

1. WHEN APP 请求 `/tvbox.json` 或等价订阅入口, the System SHALL 在 500 毫秒内返回完整 JSON（本机回环测量，不含 APP 解析）
2. WHEN APP 请求 Cloud Source 首页第一页且 Warm Cache 命中, the System SHALL 在 800 毫秒内返回含 `class` 与 `list` 的 CMS JSON
3. WHEN APP 请求 CMS Source 首页第一页且全量库已加载, the System SHALL 在 800 毫秒内返回一页 20 条
4. WHILE APP 连续翻页, the System SHALL 保持每页 20 条且 `page` 从 1 起算，空页返回空 `list` 并保留 `class`

### Requirement 2

**User Story:** AS APP 用户, I want 搜索和海报加载少等待, so that 刷列表时封面能跟上

#### Acceptance Criteria

1. WHEN APP 对 Cloud Source 发起关键词搜索且 Warm Cache 命中, the System SHALL 在 500 毫秒内返回最多 20 条
2. WHEN APP 请求已刮削或已截帧的海报 URL, the System SHALL 返回 JPEG 并带不少于 86400 秒的缓存头
3. IF 远端海报源超时超过 3 秒, the System SHALL 返回已缓存海报或空 `vod_pic`，列表接口继续在 800 毫秒内结束

### Requirement 3

**User Story:** AS APP 用户, I want 点网盘影片尽快出画面且拖动不掉线, so that 115/夸克能当本地片看

#### Acceptance Criteria

1. WHEN APP 打开任意网盘挂载下的 Cloud Source 播放地址, the System SHALL 把播放 URL 指到与订阅相同的主机和 8901 端口上的 `/play` 反代
2. WHEN APP 对 Play Proxy 发出带 `Range` 的 GET, the System SHALL 把 Range 原样转给 AList 并回传 `206` 或完整 `200` 与 `Accept-Ranges`
3. WHEN APP 首次请求某网盘文件, the System SHALL 在 3 秒内开始向 APP 写出首个数据块（路由器到 APP 的局域网，且该网盘上游可达）
4. WHILE 同一文件连续播放, the System SHALL 把 Range 请求转到 AList `/p/` 或 `raw_url`，避免 APP 直连 5244 或 302 CDN

### Requirement 4

**User Story:** AS 管理员, I want 网盘影片尽量都有正片截帧封面, so that 没刮削到的片子也能在 APP 里认出来

#### Acceptance Criteria

1. WHEN 批量刮削结束, the System SHALL 对仍无海报且路径指向视频文件的 Cloud Source 条目各发起一次 Frame Poster 任务
2. WHEN Frame Poster 任务成功, the System SHALL 把该条目的 `vod_pic` 指向 `/thumb/<hash>.jpg`
3. WHEN 视频时长可解析, the System SHALL 在正片时间点截取一帧（短片取中点，长片避开片头区间）
4. IF 正片时间点截取失败, the System SHALL 回退到文件前 3 秒再截一帧
5. IF 一次截取失败, the System SHALL 在日志中记录路径与原因，并在下次批量刮削时对该路径重试

### Requirement 5

**User Story:** AS 管理员, I want 这次改动可安装可回退, so that 家用路由升级后还能用旧包

#### Acceptance Criteria

1. WHEN 打包完成, the System SHALL 产出新版本 `luci-app-mediahub` APK 并用现有 RSA 签名
2. WHEN 管理员安装新 APK, the System SHALL 保留已有 UCI、AList 挂载和 `poster_extra` / thumbs 缓存
