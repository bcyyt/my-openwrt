# Requirements Document

## Introduction

新增 LuCI 独立一级菜单「安全监测」。汇总外网爆破/端口探测，并分析 PPPoE 拨号、域名解析、IPTV 代理、DHCP 租约等行为。图表展示趋势与摘要。管理员可手动拉黑外网来源。系统不自动封禁。

## Glossary

- **外网攻击**: 源地址位于 WAN 侧、针对本机管理或入站服务的未授权访问尝试
- **爆破**: 同一来源在短时间内多次认证失败（SSH 或 LuCI）
- **探测**: 针对未开放或被防火墙拒绝的端口/协议的连接尝试
- **PPPoE 行为**: 拨号成功、断开、重拨、PADO 超时、地址变化
- **DNS 行为**: 查询次数、NXDOMAIN、高频域名、来源客户端
- **IPTV 行为**: 鉴权状态、直播/回看会话、播放失败
- **DHCP 行为**: 新终端、租约发放、NAK、未知 MAC
- **摘要记录**: 按时间窗与对象聚合后的计数与最近一次时间
- **系统**: 本插件及其 LuCI 页面

## Requirements

### Requirement 1

**User Story:** AS 管理员, I want 在 LuCI 看到外网攻击总览图表, so that 一眼判断当前是否被扫或被爆破

#### Acceptance Criteria

1. WHEN 管理员打开安全监测页, THE 系统 SHALL 展示最近 24 小时的攻击次数折线图
2. WHEN 管理员打开安全监测页, THE 系统 SHALL 展示攻击类型占比图（爆破、探测）
3. WHEN 管理员打开安全监测页, THE 系统 SHALL 展示来源地址 Top 10 柱状图
4. WHEN 管理员打开安全监测页, THE 系统 SHALL 展示当日、近 24 小时、近 7 日的攻击总次数与独立来源数

### Requirement 2

**User Story:** AS 管理员, I want 监测 SSH 与 LuCI 登录爆破, so that 知道谁在撞密码

#### Acceptance Criteria

1. WHEN WAN 侧来源对 SSH 认证失败, THE 系统 SHALL 记一条爆破类原始事件（时间、来源地址、目标端口、用户名若日志中有）
2. WHEN WAN 侧来源对 LuCI 认证失败, THE 系统 SHALL 记一条爆破类原始事件（时间、来源地址、目标端口）
3. WHEN 同一来源在 10 分钟内认证失败达到 5 次, THE 系统 SHALL 将该来源在摘要中标为爆破
4. IF 来源地址属于 LAN 或本机回环, THE 系统 SHALL 把该事件排除在外网攻击统计之外

### Requirement 3

**User Story:** AS 管理员, I want 看到外网端口探测摘要, so that 了解谁在扫路由器

#### Acceptance Criteria

1. WHEN WAN 入站新连接被记录且目标端口不在本机开放端口列表中, THE 系统 SHALL 记一条探测类原始事件
2. WHEN 同一来源在 5 分钟内触及 8 个及以上不同目标端口, THE 系统 SHALL 将该来源在摘要中标为端口扫描
3. WHILE WAN 探测日志不可用, THE 系统 SHALL 在页面提示探测数据不可用，并继续展示爆破与其它行为数据

### Requirement 4

**User Story:** AS 管理员, I want 分析 PPPoE 连接行为, so that 能看出断线与频繁重拨

#### Acceptance Criteria

1. WHEN PPPoE 链路变为 up 或 down, THE 系统 SHALL 记录事件（时间、结果、IPv4/IPv6 若已分配）
2. WHEN 管理员打开安全监测页, THE 系统 SHALL 展示当前拨号状态、本次在线时长、近 24 小时重拨次数
3. WHEN 近 24 小时重拨次数达到 5 次, THE 系统 SHALL 在 PPPoE 卡片上标为频繁重拨
4. WHEN 管理员查看 PPPoE 摘要, THE 系统 SHALL 列出最近 20 条拨号/断开/PADO 超时事件

### Requirement 5

**User Story:** AS 管理员, I want 分析域名解析行为, so that 能看出解析失败和异常高频查询

#### Acceptance Criteria

1. WHEN dnsmasq 查询日志可用, THE 系统 SHALL 统计近 24 小时查询次数、NXDOMAIN 次数、独立客户端数
2. WHEN 管理员打开安全监测页, THE 系统 SHALL 展示查询量最高的 10 个域名与 NXDOMAIN 最多的 10 个域名
3. WHILE dnsmasq 查询日志未开启, THE 系统 SHALL 提示 DNS 明细不可用，并展示转发/本地应答计数（若 syslog 中有）
4. WHEN 单客户端 1 分钟查询次数达到 200, THE 系统 SHALL 在 DNS 摘要中标为高频查询

### Requirement 6

**User Story:** AS 管理员, I want 分析 IPTV 代理行为, so that 能看到谁在看直播或回看以及鉴权是否正常

#### Acceptance Criteria

1. WHEN 管理员打开安全监测页, THE 系统 SHALL 展示 IPTV 鉴权状态、当前直播会话数、回看会话数
2. WHEN rtp2httpd 或 iptv-auth 产生播放/鉴权日志, THE 系统 SHALL 计入 IPTV 行为事件（频道名若可解析）
3. IF 鉴权失败, THE 系统 SHALL 在 IPTV 卡片标为鉴权异常
4. WHEN 管理员查看 IPTV 摘要, THE 系统 SHALL 列出最近播放来源、频道、直播或回看

### Requirement 7

**User Story:** AS 管理员, I want 分析 DHCP 行为, so that 能发现新终端和异常租约

#### Acceptance Criteria

1. WHEN dnsmasq 发出 DHCPACK, THE 系统 SHALL 记录租约事件（MAC、IPv4、主机名）
2. WHEN 出现从未见过的 MAC, THE 系统 SHALL 在 DHCP 摘要中标为新终端
3. WHEN 出现 DHCPNAK, THE 系统 SHALL 记一条异常租约事件
4. WHEN 管理员打开安全监测页, THE 系统 SHALL 展示当前租约数、近 24 小时新终端数、最近 20 条 DHCP 事件

### Requirement 8

**User Story:** AS 管理员, I want 查看可筛选的攻击摘要与明细, so that 能核对具体来源和时间

#### Acceptance Criteria

1. WHEN 管理员打开攻击摘要表, THE 系统 SHALL 按来源地址列出类型、次数、首次时间、最近时间、涉及端口
2. WHEN 管理员按类型或来源地址筛选, THE 系统 SHALL 只显示匹配的摘要行
3. WHEN 管理员点开一条摘要, THE 系统 SHALL 列出该来源最近 50 条原始事件
4. WHEN 管理员切换 24 小时 / 7 日范围, THE 系统 SHALL 同步更新图表与各行为摘要

### Requirement 9

**User Story:** AS 管理员, I want 记录保留可控且不影响路由转发, so that 监测可长期开着

#### Acceptance Criteria

1. WHILE 插件已启用, THE 系统 SHALL 保留最近 7 日小时摘要与最近 24 小时原始事件
2. WHEN 原始事件超过 24 小时或条数超过 20000, THE 系统 SHALL 删除最旧记录并保留小时计数
3. IF 日志解析失败, THE 系统 SHALL 跳过该行并继续处理后续日志
4. THE 系统 SHALL 以 APK 与 x86_64 IPK 形式发布，安装后出现 LuCI 一级菜单「安全监测」

### Requirement 10

**User Story:** AS 管理员, I want 在摘要页手动拉黑外网来源, so that 确认后的扫描或爆破地址立刻进不来

#### Acceptance Criteria

1. WHEN 管理员对一条外网来源执行拉黑, THE 系统 SHALL 拒绝该地址从 WAN 访问本机，并在摘要中标为已拉黑
2. WHEN 管理员解除拉黑, THE 系统 SHALL 从拒绝列表去掉该地址
3. IF 来源地址属于 LAN 或本机, THE 系统 SHALL 拒绝拉黑并返回错误
4. WHEN 路由器重启, THE 系统 SHALL 恢复已保存的拉黑地址
