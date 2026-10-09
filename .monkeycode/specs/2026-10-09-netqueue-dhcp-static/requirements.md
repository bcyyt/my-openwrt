# Requirements Document

## Introduction

系统优化页增加 DHCP 邻居列表、租约/邻居清理时间，以及按 MAC 绑定静态 IP。静态绑定保存后立即写入 dnsmasq 并清掉旧租约与 ARP，使下一次 DHCP 使用新地址。

## Glossary

- **DHCP 邻居列表**: 当前租约、静态绑定与 br-lan ARP 邻居按 MAC 合并后的终端表
- **清理时间**: DHCP 租期（leasetime）与 ARP `gc_stale_time`
- **静态 IP**: UCI `dhcp.host` 中 MAC 到 IPv4 的绑定

## Requirements

### Requirement 1

**User Story:** AS 管理员, I want 在系统优化页看到 DHCP 邻居并设置清理时间, so that 过期终端及时从列表和邻居表消失

#### Acceptance Criteria

1. WHEN 打开系统优化页, THE 系统 SHALL 列出未过期租约、静态绑定与 br-lan 邻居（MAC、主机名、当前 IP、剩余租期、邻居状态）
2. WHEN 管理员保存租期, THE 系统 SHALL 写入 `dhcp.lan.leasetime` 并重载 dnsmasq
3. WHEN 管理员保存邻居清理秒数, THE 系统 SHALL 把 `gc_stale_time` 应用到 default 与 br-lan
4. IF 租约到期时间早于当前时间, THE 系统 SHALL 从邻居列表中去掉该动态租约

### Requirement 2

**User Story:** AS 管理员, I want 给终端绑定静态 IP, so that 地址固定且马上按新地址重新分配

#### Acceptance Criteria

1. WHEN 管理员提交合法 MAC 与 LAN 子网内 IPv4, THE 系统 SHALL 写入或更新 `dhcp.host`
2. WHEN 静态绑定保存成功, THE 系统 SHALL 删除该 MAC 的动态租约、重载 dnsmasq，并删除旧/新 IP 的 br-lan 邻居条目
3. IF 目标 IP 是网关地址或已被其他 MAC 静态占用, THE 系统 SHALL 拒绝绑定并返回错误
4. WHEN 管理员取消静态绑定, THE 系统 SHALL 删除对应 `dhcp.host`、清租约并重载 dnsmasq
