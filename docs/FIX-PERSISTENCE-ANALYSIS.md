# 修复持久性与长期稳定性分析

## 概述

本文档分析本仓库中所有运行时修复（uci-defaults、init.d 服务、配置覆盖层）在设备刷机、sysupgrade、固件升级后的持久性，以及长期稳定运行的风险点。

## 修复持久性机制

### OpenWrt uci-defaults 执行模型

- **执行时机**：`/etc/uci-defaults/` 下的脚本在首次开机（刷机/sysupgrade 后）由 `/etc/init.d/boot` 执行一次，执行后被系统删除
- **配置持久化**：脚本中通过 `uci set` + `uci commit` 写入的配置保存在 `/etc/config/` 下，属于 overlay 文件系统，**跨重启持久保留**
- **sysupgrade 行为**：`/etc/config/` 默认被备份并恢复；新固件中的 uci-defaults 脚本在 sysupgrade 后首次开机重新执行
- **幂等性要求**：所有 uci-defaults 脚本应设计为幂等（先检查再设置），避免重复执行时覆盖 operator 手动修改

### init.d 服务执行模型

- `/etc/init.d/` 下的服务在每次开机时按 START 优先级执行
- 通过 `/etc/init.d/<name> enable` 创建的 symlink 在 `/etc/rc.d/` 下，跨重启保留
- init.d 服务是**每次开机都执行**的，适合需要持续生效的逻辑

## 各修复项持久性分析

### 1. odhcpd LAN IPv6 配置（95-odhcpd-lan-config）

| 维度 | 分析 |
|------|------|
| **执行方式** | uci-defaults，首次开机执行一次 |
| **配置位置** | `/etc/config/dhcp` 的 `dhcp.lan` section |
| **跨重启** | ✅ 配置保存在 overlay，每次开机 odhcpd 读取该配置 |
| **sysupgrade 后** | ✅ `/etc/config/dhcp` 被备份恢复；新固件 uci-defaults 重新执行确保配置一致 |
| **operator 修改保护** | ⚠️ uci-defaults 每次 sysupgrade 后会重新执行，覆盖 operator 对 ra/dhcpv6/ra_slaac 的手动修改。这是预期行为——这些是固件级默认配置 |
| **未来 IPv6 启用** | ✅ hybrid 模式设计为：无前缀时静默 relay，有前缀时自动 server。无需修改配置即可支持未来 IPv6 |
| **固件升级风险** | 低。odhcpd 配置接口（ra/dhcpv6/ra_slaac）在 OpenWrt 中长期稳定 |

### 2. nikki 管理端口绑定 LAN（96-nikki-bind-lan）

| 维度 | 分析 |
|------|------|
| **执行方式** | uci-defaults，首次开机执行一次 |
| **配置位置** | `/etc/config/nikki` 的 `nikki.mixin.api_listen` |
| **跨重启** | ✅ 配置保存在 overlay |
| **sysupgrade 后** | ✅ 重新执行 |
| **operator 修改保护** | ⚠️ sysupgrade 后会覆盖 operator 对 api_listen 的修改 |
| **LAN IP 变化** | ⚠️ **已知限制**：uci-defaults 只在首次开机执行一次。如果 operator 后续修改了 LAN IP，nikki 的 api_listen 不会自动更新，可能导致管理页面无法访问。operator 需手动执行 `uci set nikki.mixin.api_listen='<新IP>:9090' && uci commit nikki` |
| **改进建议** | 长期可考虑改为 init.d 服务每次开机执行，但当前行为可接受（LAN IP 通常不变） |
| **固件升级风险** | 低。nikki 配置路径 `nikki.mixin.api_listen` 相对稳定 |

### 3. /data 自动挂载与 pi-subagents 配置（99-auto-mount-data）

| 维度 | 分析 |
|------|------|
| **执行方式** | 双重机制：(1) uci-defaults 首次开机执行；(2) 同时安装为 `/usr/sbin/auto-mount-data`，由 `emmc-data-provision` init.d 服务（START=19）**每次开机调用** |
| **配置位置** | `/etc/config/fstab`（挂载配置）、`/data/pi/agent/extensions/subagent/config.json`（pi-subagents） |
| **跨重启** | ✅ fstab 配置在 overlay；/data 分区由 fstab 服务每次开机挂载；init.d 服务每次开机验证挂载状态 |
| **sysupgrade 后** | ✅ fstab 配置备份恢复；/data 分区不受 sysupgrade 影响（独立分区）；uci-defaults 重新执行 |
| **operator 修改保护** | ✅ pi-subagents config.json 使用 `if [ ! -e ... ]` 守卫，**不会覆盖** operator 已有的配置 |
| **storeRoot 绝对路径** | ✅ 写入 `{"scheduledRuns":{"storeRoot":"/data/pi/subagents/schedules"}}`，绝对路径避免 pi-subagents 的 trust check 失败 |
| **固件升级风险** | 中。pi-subagents 配置格式如果上游变更可能导致不兼容，但 storeRoot 字段是标准配置 |

### 4. headscale 自动注册（94-headscale-auto-enroll）

| 维度 | 分析 |
|------|------|
| **执行方式** | uci-defaults 首次开机 + init.d 服务（`/etc/init.d/headscale-auto-enroll`）+ hotplug 钩子 |
| **配置位置** | `/etc/config/headscale_auto_enroll` |
| **跨重启** | ✅ init.d 服务每次开机运行 |
| **operator 修改保护** | ✅ uci-defaults 只设置默认值，已存在的配置不覆盖 |
| **固件升级风险** | 低 |

### 5. tailscale 相关修复（96-tailscale-uci-fallback, 97-tailscale-nikki-guard, 98-tailscale-magicdns-forward, 99-tailscale-route-reconcile 等）

| 维度 | 分析 |
|------|------|
| **执行方式** | uci-defaults 首次开机 + init.d 服务（route-reconcile、quad100-health、nikki-boot-guard） |
| **跨重启** | ✅ init.d 服务每次开机运行 |
| **sysupgrade 后** | ✅ 重新执行 |
| **固件升级风险** | 中。tailscale 版本升级可能改变行为，但 guard 脚本设计为容错（`uci -q` 静默失败） |

## sysupgrade 后修复是否重新生效

**结论：全部重新生效。**

| 修复类型 | sysupgrade 后行为 |
|----------|-------------------|
| uci-defaults 配置覆盖 | 新固件中的脚本在首次开机执行，写入 `/etc/config/` |
| init.d 服务 | 服务文件在固件中，`enable` 状态通过 `/etc/rc.d/` symlink 保留（如果在备份列表中）或由 uci-defaults 重新 enable |
| /data 分区 | 独立分区，不受 sysupgrade 影响 |
| 配置文件 | `/etc/config/` 默认备份恢复 |

## 长期稳定性风险评估

### 风险 1：ImmortalWrt 上游配置接口变更

- **概率**：低。odhcpd、nikki、tailscale 的 UCI 配置接口在 OpenWrt 生态中长期稳定
- **影响**：如果上游变更配置路径，uci-defaults 中的 `uci set` 会静默失败（`uci -q`），导致修复不生效
- **缓解**：(1) 使用 `uci -q` 避免脚本中断；(2) pin `WRT_COMMIT` 控制上游版本；(3) 测试套件验证配置路径存在

### 风险 2：NSS 驱动维护停止

- **概率**：中。ImmortalWrt 上游已移除 NSS 转向 PPE，VIKINGYFY 是目前唯一在 kernel 6.18 上活跃维护 NSS 的公开仓库
- **影响**：如果 VIKINGYFY 停止维护，未来内核升级可能无法继续使用 NSS 加速
- **缓解**：(1) 当前 pin WRT_COMMIT 保证可复现构建；(2) 长期评估 PPE 迁移路径；(3) 详见 NSS-DRIVER-RESEARCH.md

### 风险 3：pi-subagents / agent-runtime 版本升级

- **概率**：中。这些是快速迭代的项目
- **影响**：配置格式变更可能导致不兼容
- **缓解**：(1) config.json 使用 `if [ ! -e ]` 守卫，不覆盖 operator 配置；(2) Agent-Runtime-Bump workflow 有版本验证和测试

### 风险 4：测试套件与 workflow 不同步

- **概率**：已解决。之前硬编码 workflow 列表导致 QCA-6.12 删除后 8 个测试失败
- **缓解**：本次重构引入 `tests/lib/workflow-discovery.sh` 动态发现所有调用 WRT-CORE 的 workflow，未来增删 workflow 自动适配

## 结论

1. **所有修复都是持久性的**，不是临时补丁。它们通过 UCI 配置覆盖层和 init.d 服务在每次开机和 sysupgrade 后持续生效
2. **operator 手动修改在大多数情况下被保护**（pi-subagents config.json、headscale 配置等使用 `if [ ! -e ]` 守卫）
3. **已知限制**：nikki api_listen 绑定在 LAN IP 变化后不会自动更新（可接受，LAN IP 通常不变）
4. **主要长期风险**是 NSS 驱动维护停止和上游配置接口变更，已通过 pin commit 和动态测试发现缓解
5. **刷机后所有修复会重新生效**：uci-defaults 在首次开机执行，init.d 服务每次开机运行，/data 分区独立保留
