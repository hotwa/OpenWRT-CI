# 高通 NSS 驱动上游更新调研报告

> 调研日期：2026-09-06
> 调研范围：davidtall/LiBwrt-openwrt-6.x、ImmortalWrt 上游、VIKINGYFY/immortalwrt
> 目标平台：IPQ60xx（jdcloud re-cs-07 / re-ss-01 / re-cs-02），内核 6.18

---

## 1. 调研摘要

| 项目 | 结论 |
|------|------|
| **当前使用版本** | VIKINGYFY/immortalwrt `main`（浮动，未 pin commit），NSS firmware 12.5.210，QSDK 13.1 |
| **上游最新状态** | ImmortalWrt 上游**已移除 NSS**，转向 PPE 网络栈；VIKINGYFY fork 继续维护 NSS |
| **LiBwrt 状态** | **已停止维护**（最后更新 2025-08-10），仅内核 6.12，无 k6.18 分支 |
| **是否需要更新 NSS 驱动** | **不需要** — 当前 VIKINGYFY main 已包含最新可用的 NSS 驱动（QSDK 13.1，2026-01 源码），且比 qosmio 公共 feed（QSDK 12.5）更新 |
| **主要风险** | **战略风险高**：NSS 在上游已被 PPE 取代，VIKINGYFY 是唯一活跃的 NSS 维护者；若其停止维护则无上游兜底 |
| **建议优先级** | 中 — 建议 pin WRT_COMMIT 保证构建可复现；长期需评估 PPE 迁移路径 |

---

## 2. 当前仓库 NSS 配置梳理

### 2.1 源码来源

- **仓库**：`https://github.com/VIKINGYFY/immortalwrt.git`
- **分支**：`main`
- **Commit 锁定**：**未锁定**（`QCA-6.18-VIKINGYFY.yml` 未传 `WRT_COMMIT`，每次构建拉取最新 main）
- **内核版本**：6.18（`target/linux/qualcommax/Makefile` → `KERNEL_PATCHVER:=6.18`）

### 2.2 NSS 固件版本

在 `Scripts/Settings.sh` 中配置：

```bash
# IPQ60xx / IPQ807x 使用 12.5
echo "CONFIG_NSS_FIRMWARE_VERSION_12_5=y"
# IPQ50xx 使用 12.2
echo "CONFIG_NSS_FIRMWARE_VERSION_12_2=y"
```

实际 NSS firmware 二进制版本：**12.5.210**（`NSS_MAJOR=12, NSS_MINOR=5, NSS_REL=210`），来自 `QCA_Networking_2024.SPF_12.5/ED1`。

### 2.3 NSS 包集成方式

VIKINGYFY 将 NSS 驱动**内联**到 `package/qca-nss/` 目录，不依赖外部 feed：

```
package/qca-nss/
├── nss-eip-firmware/      # EIP 加密固件 2.5.7
├── nss-firmware/          # NSS 固件 2025.05.01 (12.5.210)
├── qca-mcs/               # 多链路聚合
├── qca-nss-clients/       # NSS 用户态客户端 QSDK 12.5.5
├── qca-nss-crypto/        # NSS 加密加速 QSDK 13.1
├── qca-nss-dp/            # NSS 数据平面 (2026-01-19)
├── qca-nss-drv/           # NSS 核心驱动 QSDK 13.1 (2026-01-12)
├── qca-nss-ecm/           # ECM 快捷转发 QSDK 13.1
├── qca-nss-phy/           # NSS PHY (2026-01-11)
└── qca-ssdk/              # SSDK 交换芯片驱动 (2025-11-14)
```

因此 `CONFIG_FEED_nss_packages=n` 和 `CONFIG_FEED_sqm_scripts_nss=n` 被显式关闭（feed 不存在，关闭避免警告）。

### 2.4 启用的 NSS 功能模块（`Scripts/function.sh` → `set_nss_driver()`）

| 模块 | 配置 | 说明 |
|------|------|------|
| 数据平面 | `kmod-qca-nss-dp` | NSS-DP 网卡驱动 |
| 核心驱动 | `kmod-qca-nss-drv` | NSS 核心 |
| 桥接管理 | `kmod-qca-nss-drv-bridge-mgr` | 硬件桥接 |
| VLAN | `kmod-qca-nss-drv-vlan` | VLAN 加速 |
| IGMP 侦听 | `kmod-qca-nss-drv-igs` | IGMP Snooping |
| PPPoE | `kmod-qca-nss-drv-pppoe` | PPPoE 加速 |
| PPTP | `kmod-qca-nss-drv-pptp` | PPTP 加速 |
| Qdisc | `kmod-qca-nss-drv-qdisc` | 流量整形 |
| ECM | `kmod-qca-nss-ecm` | 快捷转发（核心加速） |
| MACsec | `kmod-qca-nss-macsec` | MACsec 加密 |
| L2TPv2 | `kmod-qca-nss-drv-l2tpv2` | L2TP 加速 |
| LAG | `kmod-qca-nss-drv-lag-mgr` | 链路聚合 |
| 加密 | `kmod-qca-nss-crypto` | 硬件加密加速 |
| SQM | `sqm-scripts-nss` | NSS 感知的 SQM |

**禁用**：`CONFIG_ATH11K_NSS_SUPPORT=n`、`CONFIG_NSS_DRV_WIFI_EXT_VDEV_ENABLE=n`（NOWIFI 构建）。

### 2.5 本地 NSS 相关补丁

- `patches/libiwrt/999-fix-k612-net-device-cacheline-assert.patch` — **仅适用于 LiBwrt k6.12-nss**，由 `Scripts/patch_libiwrt_k612_cacheline_assert.sh` 条件注入（仅当 source=davidtall/LiBwrt-openwrt-6.x 且 branch=k6.12-nss 时生效）。当前 VIKINGYFY 构建**不使用**此补丁。

---

## 3. 各仓库 NSS 驱动版本对比

### 3.1 版本对比总表

| 组件 | VIKINGYFY/immortalwrt (当前) | qosmio/nss-packages (LiBwrt 用) | ImmortalWrt 上游 |
|------|------------------------------|--------------------------------|-----------------|
| **内核** | 6.18 | 6.12 | 6.18 |
| **NSS firmware** | 12.5.210 (2025.05.01) | 12.5.210 / 12.2 / 12.1 / 11.4 可选 | **无（PPE 替代）** |
| **nss-drv** | QSDK **13.1**, 2026-01-12, `6aa14c7`, r18 | QSDK **12.5**, 2024-11-13, `d5ee67b`, r17 | 已移除 |
| **nss-ecm** | QSDK **13.1**, `8c7355b`, r8 | QSDK **12.5**, 2024-11-06, `30fbfa4`, r7 | 已移除 |
| **nss-crypto** | QSDK **13.1**, `60e27b9`, r1 | 有（版本未单列） | 已移除 |
| **nss-dp** | 2026-01-19, `d8f802f` | 有（外部 feed） | **已移除**（2026-05） |
| **nss-clients** | QSDK 12.5.5, 2024-09-12, `51be82d`, r13 | QSDK 12.5 | 已移除 |
| **nss-phy** | 2026-01-11, `85cb19f` | — | 已移除 |
| **qca-ssdk** | 2025-11-14, `d9a1964` | 有 | **已移除**（2026-05） |
| **nss-eip-firmware** | 2.5.7 | 有 | 已移除 |
| **最后更新** | 2026-09-04（活跃） | 2026-01-02（低频） | N/A（转向 PPE） |

### 3.2 关键差异分析

1. **QSDK 版本代差**：VIKINGYFY 使用 QSDK **13.1**，qosmio 公共 feed 仍停留在 QSDK **12.5**。VIKINGYFY 的 NSS 驱动源码比公共 feed 新约 14 个月。
2. **固件版本一致**：两者使用相同的 firmware tarball（`qca-sdk-nss-fw 2025.05.01`），NSS 固件二进制均为 12.5.210。
3. **集成方式不同**：VIKINGYFY 内联到 `package/qca-nss/`，LiBwrt 通过外部 feed `qosmio/nss-packages` 引入。
4. **上游方向相反**：ImmortalWrt 上游正在**删除** NSS，VIKINGYFY 正在**维护和更新** NSS。

---

## 4. 各仓库详细状态

### 4.1 davidtall/LiBwrt-openwrt-6.x

| 项目 | 状态 |
|------|------|
| 最后推送 | 2025-08-10（已停滞约 13 个月） |
| 默认分支 | `kernel-6.12` |
| 可用分支 | `ap8220`, `k6.12-nss`, `kernel-6.12`, `main`, `test` |
| k6.18 分支 | **不存在** |
| k6.12-nss 最后提交 | 2025-08-09 `f38a5476`（rpcd 更新，非 NSS 相关） |
| NSS 来源 | 外部 feed `qosmio/nss-packages`（QSDK 12.5） |
| 内核 | 6.12 |

**结论**：LiBwrt 已实质停止维护，且无内核 6.18 的 NSS 分支。当前仓库中保留的 LiBwrt cacheline 补丁和 `patch_libiwrt_k612_cacheline_assert.sh` 属于历史遗留，对 VIKINGYFY 构建无影响。**不建议回退或迁移到 LiBwrt。**

### 4.2 ImmortalWrt 上游（immortalwrt/immortalwrt）

| 项目 | 状态 |
|------|------|
| NSS 支持 | **已移除** |
| 替代方案 | PPE（Packet Processing Engine）+ EDMA |
| 内核 | 6.18 |

**关键迁移时间线**：

| 日期 | Commit | 事件 |
|------|--------|------|
| 2026-02-18 | `16d110a` | `qualcommax: replace NSS-DP DTSI with PPE DTSI` — 为 IPQ5018/IPQ6018/IPQ8074 添加 PPE 驱动绑定 |
| 2026-02-20 | `f504356` | `qualcommax: ipq60xx/ipq807x: convert to PPE networking stack` — IPQ60xx/IPQ807x 从 NSS 数据平面迁移到 PPE 栈（IPQ50xx 暂不支持） |
| 2026-05-17 | `d0d71dc` | `kernel: drop qca-nss-dp and qca-ssdk` — 所有目标已迁移完毕，正式删除 NSS-DP 和 SSDK |

以上变更源自 **OpenWrt PR #22381**，由 Robert Marko（robimarko）和 John Crispin 等上游开发者推动。

**PPE vs NSS 区别**：
- PPE 是高通新一代数据包处理引擎，驱动已**上游化**到 Linux 内核主线
- NSS 依赖高通闭源固件 + 大量 out-of-tree 内核补丁，维护成本高
- PPE 目前不支持 IPQ50xx，且功能集（如 ECM 快捷转发、VPN 加速）可能不如 NSS 成熟

**结论**：ImmortalWrt 上游不再提供 NSS 驱动。继续使用 NSS 意味着必须依赖 VIKINGYFY fork 的持续维护。

### 4.3 VIKINGYFY/immortalwrt（当前使用）

| 项目 | 状态 |
|------|------|
| 最后提交 | 2026-09-04 `fcbac91`（活跃维护中） |
| 分支 | `main` |
| 内核 | 6.18 |
| NSS 集成 | `package/qca-nss/` 内联，QSDK 13.1 |
| NSS 维护 | **活跃**，持续更新和修复 |

**近期 NSS 相关提交**：

| 日期 | Commit | 说明 |
|------|--------|------|
| 2026-08-09 | `dc68d53` | refresh patches（刷新 NSS 补丁以适配最新内核） |
| 2026-08-05 | `a01450f` | update qualcommax（新增 TP-Link TL-ER2260T 支持） |
| 2026-07-23 | `a4638cd` | **qualcommax: persist NSS frequency and fix NAPI setup** — 持久化 NSS 频率设置，修复 NAPI 配置；新增 `nss_freq` init 脚本和配置 |
| 2026-07-23 | `20f4214` | qualcommax: improve NSS and EDMA handling — 改进 NSS 和 EDMA 处理 |
| 2026-07-22 | `9cf9dbf` | qualcommax: harden NSS and EDMA startup — 加固 NSS 和 EDMA 启动流程 |
| 2026-07-09 | `0be028e` | update qca-nss |
| 2026-07-01 | `bcc5613` | update qca-nss |
| 2026-06-29 | `2e49692` | update qca-nss wifi-no |

**结论**：VIKINGYFY 是目前唯一在 kernel 6.18 上活跃维护 NSS 的公开仓库，且驱动版本（QSDK 13.1）比公共 feed 新。2026 年 7 月集中修复了 NSS 频率持久化、NAPI、EDMA 启动等稳定性问题。

---

## 5. 重要更新与安全修复

### 5.1 qosmio/nss-packages（公共 feed）近期修复

| 日期 | Commit | 说明 |
|------|--------|------|
| 2026-01-02 | `0d970db` | nss-firmware: 使用预打包 tarball 避免哈希波动（构建稳定性） |
| 2025-12-23 | `e16ba70` | **Fix PPP deadlock by using lockless functions** — 修复 PPP 死锁（#71），重构 PPP 通道处理使用无锁函数 |
| 2025-11-21 | `ea44533` | treewide: Fix deprecated AUTORELEASE（构建警告修复） |
| 2025-07-14 | 多个 | nss-eip 固件更新、nss-clients ovpn init 修复、nss-macsec 内核 6.12 构建修复 |

**注意**：这些修复在 qosmio feed 中，但 VIKINGYFY 使用的是自己内联的 QSDK 13.1 代码，可能已包含或独立修复了这些问题。PPP 死锁修复需要确认 VIKINGYFY 是否包含。

### 5.2 VIKINGYFY 近期 NSS 修复（已包含在当前 main）

- **NSS 频率持久化**（`a4638cd`，2026-07-23）：新增 `/etc/config/nss_freq` 和 `/etc/init.d/nss_freq`，确保 NSS 核心频率在重启后保持
- **NAPI 修复**（`a4638cd`）：修复 EDMA v1 的 NAPI GRO 分离补丁
- **EDMA 处理改进**（`20f4214`，2026-07-23）
- **NSS/EDMA 启动加固**（`9cf9dbf`，2026-07-22）

### 5.3 已知安全问题

本次调研未发现针对 NSS 驱动的已公开 CVE 安全公告。NSS 驱动主要风险在于：
- 闭源固件无法独立审计
- out-of-tree 内核补丁与主线内核的兼容性
- 上游已放弃维护，安全修复依赖 fork 维护者

---

## 6. 风险评估

### 6.1 风险矩阵

| 风险项 | 等级 | 说明 |
|--------|------|------|
| **战略风险：上游放弃 NSS** | **高** | ImmortalWrt 上游已转向 PPE，VIKINGYFY 是唯一活跃维护者。若 VIKINGYFY 停止维护或无法跟上内核更新，NSS 将无上游兜底 |
| **构建可复现性** | **中** | 未 pin `WRT_COMMIT`，每次构建拉取最新 main，可能引入未经验证的变更 |
| **NSS 驱动版本过时** | **低** | 当前 QSDK 13.1 已是公开可用最新版本，比 qosmio feed（QSDK 12.5）更新 |
| **NSS 固件版本过时** | **低** | firmware 12.5.210 与 qosmio feed 一致，来自同一 tarball |
| **PPP 死锁修复缺失** | **低-中** | qosmio 在 2025-12 修复了 PPP 死锁，需确认 VIKINGYFY QSDK 13.1 是否已包含等效修复 |
| **LiBwrt 回退风险** | **高（若回退）** | LiBwrt 已停滞 13 个月，内核 6.12，无安全更新 |
| **PPE 功能差距** | **中（长期）** | 若未来被迫迁移 PPE，ECM 快捷转发、VPN 加速等功能可能需要重新验证 |

### 6.2 更新 NSS 驱动的风险

NSS 是高通底层网络加速子系统，更新涉及：
- **内核兼容性**：NSS 驱动包含大量 out-of-tree 补丁，更新可能与当前内核 6.18 产生冲突
- **网络稳定性**：NSS 负责数据平面转发，驱动变更可能导致丢包、断流或性能回退
- **功能回归**：ECM、VPN 加速、SQM 等功能可能受影响
- **固件匹配**：NSS 驱动版本需与 firmware 版本匹配，不同步可能导致加载失败

**当前无需主动更新 NSS 驱动**，因为 VIKINGYFY main 已经是最新。

---

## 7. 建议与优先级

### 7.1 立即行动（低优先级）

1. **无需更新 NSS 驱动版本** — 当前 VIKINGYFY main 已包含 QSDK 13.1（最新公开版本）和近期稳定性修复。

### 7.2 短期建议（中优先级）

2. **考虑 pin `WRT_COMMIT`** — 当前 `QCA-6.18-VIKINGYFY.yml` 使用浮动 main，建议在验证稳定后 pin 到具体 commit（如 `a4638cd` 或更新的稳定点），避免 VIKINGYFY 上游引入回归。可通过 workflow 的 `WRT_COMMIT` 参数实现。

3. **验证 PPP 死锁修复** — 确认 VIKINGYFY 的 QSDK 13.1 `qca-nss-drv` 是否已包含 qosmio `e16ba70` 的 PPP 无锁修复。如果设备使用 PPPoE 拨号，这是稳定性相关修复。检查方式：在 VIKINGYFY 源码中搜索 `nss_pppoe` 相关代码是否使用 `nss_pppoe_session_lockless` 或类似函数。

4. **清理 LiBwrt 遗留代码** — `patches/libiwrt/` 和 `Scripts/patch_libiwrt_k612_cacheline_assert.sh` 仅对已停止维护的 LiBwrt 生效，当前构建不使用。可评估是否保留（作为备选）或归档。

### 7.3 长期规划（高优先级，持续关注）

5. **监控 VIKINGYFY NSS 维护活跃度** — VIKINGYFY 是 NSS on kernel 6.18 的唯一活跃维护者。定期检查其 `package/qca-nss/` 提交频率，若出现长期停滞需提前规划。

6. **评估 PPE 迁移可行性** — 长期来看，PPE 是上游方向。建议：
   - 跟踪 OpenWrt PPE 驱动对 IPQ60xx 的功能完善程度
   - 评估 PPE 是否满足当前需求（NAT 加速、SQM、VPN 等）
   - 在测试环境中尝试 ImmortalWrt 上游 PPE 构建，对比性能和功能
   - **注意**：PPE 目前不支持 IPQ50xx，但当前目标平台是 IPQ60xx，不受影响

7. **关注 qosmio/nss-packages 更新** — 虽然当前使用 VIKINGYFY 内联版本，但 qosmio feed 是 NSS 包的公共协作点，重要修复（如 PPP 死锁）可能先出现在这里。

---

## 8. 参考链接

### 仓库
- VIKINGYFY/immortalwrt: https://github.com/VIKINGYFY/immortalwrt
- davidtall/LiBwrt-openwrt-6.x: https://github.com/davidtall/LiBwrt-openwrt-6.x
- immortalwrt/immortalwrt: https://github.com/immortalwrt/immortalwrt
- qosmio/nss-packages: https://github.com/qosmio/nss-packages
- qosmio/qca-sdk-nss-fw: https://github.com/qosmio/qca-sdk-nss-fw

### 关键 Commit / PR
- OpenWrt PR #22381 (PPE 迁移): https://github.com/openwrt/openwrt/pull/22381
- ImmortalWrt PPE 转换: https://github.com/immortalwrt/immortalwrt/commit/f50435627d37
- ImmortalWrt 删除 NSS-DP/SSDK: https://github.com/immortalwrt/immortalwrt/commit/d0d71dcc097f
- VIKINGYFY NSS 频率持久化: https://github.com/VIKINGYFY/immortalwrt/commit/a4638cd43891
- qosmio PPP 死锁修复: https://github.com/qosmio/nss-packages/commit/e16ba7016336

### 本地文件
- `Scripts/Settings.sh` — NSS firmware 版本配置
- `Scripts/function.sh` — `set_nss_driver()` NSS 模块启用
- `Config/IPQ60XX-WIFI-NO.txt` — IPQ60xx NSS 配置
- `.github/workflows/QCA-6.18-VIKINGYFY.yml` — 构建源码来源
- `.github/workflows/WRT-CORE.yml` — 核心构建流程（支持 `WRT_COMMIT` pin）
- `patches/libiwrt/999-fix-k612-net-device-cacheline-assert.patch` — LiBwrt 遗留补丁

---

## 附录：NSS 组件版本速查（VIKINGYFY main，2026-09-06）

| 包 | PKG_VERSION / 来源 | PKG_RELEASE | 源码日期 |
|----|-------------------|-------------|----------|
| nss-firmware | 2025.05.01 (fw 12.5.210) | 1 | — |
| nss-eip-firmware | 2.5.7 | 1 | — |
| qca-nss-drv | 13.1.2026.01.12~6aa14c7 | 18 | 2026-01-12 |
| qca-nss-ecm | 13.1.~8c7355b | 8 | — |
| qca-nss-crypto | 13.1.~60e27b9 | 1 | — |
| qca-nss-dp | ~d8f802f | 1 | 2026-01-19 |
| qca-nss-clients | 12.5.5.2024.09.12~51be82d | 13 | 2024-09-12 |
| qca-nss-phy | ~85cb19f | 1 | 2026-01-11 |
| qca-ssdk | ~d9a1964 | 1 | 2025-11-14 |
| qca-mcs | — | — | — |
