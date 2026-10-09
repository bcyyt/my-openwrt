# Requirements Document

# Introduction

为当前 ImmortalWrt SNAPSHOT x86_64 路由器提供固件升级入口：刷入新固件后，保留原有 UCI/系统配置、已安装插件，以及数据分区 `/mnt/data`。

# Glossary

- **System**: luci-app-syskeep 及其命令行 `syskeep-upgrade.sh`
- **Firmware Image**: ImmortalWrt x86_64 squashfs combined-efi 固件文件（本地上传或 URL）
- **Keep Config**: sysupgrade 保留 `/etc` 中已修改文件（含 UCI）
- **Package World**: `/etc/apk/world` 中记录的已安装软件包列表
- **Custom APK**: 本仓库插件（iptv-auth、luci-app-mediahub、luci-app-statusmon、luci-app-netqueue）
- **Data Partition**: `nvme0n1p3` 挂载点 `/mnt/data`（影视、Docker 等数据）
- **Restore Job**: 新固件首次启动后按清单重装插件的后台任务

# Requirements

## Requirement 1

**User Story:** AS 管理员, I want 在刷机前自动备份配置和插件清单, so that 新固件启动后能恢复原环境

#### Acceptance Criteria

1. WHEN 管理员启动升级, the System SHALL 把 Package World 与 Custom APK 清单写入 `/mnt/data/syskeep/`
2. WHEN 管理员启动升级, the System SHALL 生成一份 `/etc` 配置 tar.gz 备份到 `/mnt/data/syskeep/`
3. WHEN 备份完成, the System SHALL 把 Restore Job 脚本放到 `/etc` 下会随 Keep Config 保留的路径

## Requirement 2

**User Story:** AS 管理员, I want 刷机只更新系统分区, so that 数据盘和现有配置还在

#### Acceptance Criteria

1. WHEN 管理员确认刷入 Firmware Image, the System SHALL 调用 sysupgrade 并保留 `/etc` 已修改文件
2. WHEN 管理员确认刷入 Firmware Image, the System SHALL 让 sysupgrade 附带已安装软件包清单
3. WHEN 管理员确认刷入 Firmware Image, the System SHALL 保持现有磁盘分区表，使 Data Partition 继续存在
4. IF Firmware Image 校验失败, the System SHALL 中止刷写并在日志中写明原因

## Requirement 3

**User Story:** AS 管理员, I want 新固件启动后自动重装原来的插件, so that 不用手工一个个装回去

#### Acceptance Criteria

1. WHEN 新固件首次完成启动且 `/mnt/data/syskeep/` 存在未完成 Restore Job, the System SHALL 按清单重装软件包
2. WHEN 重装官方源软件包, the System SHALL 使用新固件自带的 ImmortalWrt apk 软件源
3. WHEN 重装 Custom APK, the System SHALL 从本仓库已发布的 APK 地址安装对应包
4. IF 单个软件包安装失败, the System SHALL 记录失败项并继续安装剩余软件包
5. WHEN Restore Job 结束, the System SHALL 写成功/失败清单到 `/mnt/data/syskeep/restore-status.json`

## Requirement 4

**User Story:** AS 管理员, I want 在 LuCI 里执行升级并看到进度, so that 不用只靠 SSH

#### Acceptance Criteria

1. WHEN 管理员打开「系统 → 保留升级」, the System SHALL 显示当前版本、已装插件数量、数据盘状态
2. WHEN 管理员提供 Firmware Image（上传或 URL）并确认, the System SHALL 开始备份并刷写
3. WHILE Restore Job 正在运行, the System SHALL 在该页面显示当前步骤与失败项

## Requirement 5

**User Story:** AS 管理员, I want 先演练再真正刷机, so that 误操作不会立刻毁掉系统

#### Acceptance Criteria

1. WHEN 管理员选择「仅校验」, the System SHALL 检查固件、备份路径和分区信息，并且跳过实际刷写
2. IF `/mnt/data` 未挂载, the System SHALL 拒绝开始刷写
