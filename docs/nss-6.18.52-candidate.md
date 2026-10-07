# Linux 6.18.52 / NSS 候选接入

## 范围与状态

候选分支：`codex/nss-6.18.52-candidate`。
固定完整源码 `VIKINGYFY/immortalwrt@0fb9b10cb9df51fb076470e1dd93d1c30dd89d83`。
只更新 CPE-5G、RE-Mesh（RE-CS-02 / RE-SS-01）、RE-CS-07 的源码 pin。
这是完整源码候选升级，包含内核及通用补丁依赖，不声称只 cherry-pick NSS 补丁；不合并上游 CI 仓库。
本分支保留机型配置、网络/代理策略、运行时 pin 和 private Secret 映射；用户在 CS02 冷启动 USB 通过后明确授权合入 main，其余物理门禁暂缓，见下文限制。

## 当前实机状态与 CS02 修复

`567c319` 三个 Action 已成功，四台已保留配置刷入。CS07、SS01、CPE 两次软重启通过。CS02 原先 9 条监管 Call trace / CN 更新 `-22` 问题已在 `863a288` 修复；实际 global/phy0/phy1/phy2 均 CN，Call trace 0，两次软重启通过。用户确认断电上电后，新通用 USB 补挂脚本自动挂载到设备配置的 `/mnt/kioxia`，读写通过；只读离线 exFAT 检查为 clean，核心网络、NSS、eMMC、Gecoos、原验收容器与原 agent/runtime ID 恢复。

用户明确暂缓 CS07、SS01、CPE 的剩余物理验收，并要求 CPE 保留 UDX710 不做拔插测试；这些项目未实测，不标为通过。依据用户在 CS02 新脚本冷启动成功后的明确指令合入 main。CS02 新建应用 `garage-cs02` 仍依赖未配置的 `/mnt/garage-data`；它不是原固件验收容器，未宣称恢复成功、未改其数据路径。

USB 通用恢复已独立通过 PR #32 合 main（`f44557031fe9761646ab12349fcf766978b1b36e`），不固定 UUID，不创建免密码 SMB。按 sysfs USB 祖先仅重放未挂载存储的原生 fstools add 事件，开机窗口有界；共享与稳定挂载点保留为设备配置。现场冷启动的通用脚本与 PR #32 代码一致。

原源码 `a4638cd` 中的 `990-ath11k-clamp-reg-rule-bandwidth.patch` 在新源码中被删除。候选分支为 CS02 恢复这一完整、已审阅的补丁，SHA256 为 `dd4ad38515ad746630d28dae3669cfef7be3ddb6dc1fd552586a0cf137d1c38a`。补丁将监管规则带宽限制在已有频率范围内，不改国家码、功率或频率端点，不取消 cfg80211 验证。安装器限于 CS02 + 完整源码 `0fb9b10` + backports 7.2 精确版本和包 hash；遇到未知版本或冲突补丁立即失败。源码包上零 fuzz 应用检查、编译后的 C 规则测试及安装器作用域/漂移/幂等测试通过。只重编 CS02；Action `37523641754` 成功，实机告警已消除。

CS02 本次升级还发生备份流程事故：完整数据库目录没有被 sysupgrade 清单覆盖，覆盖断言失败后命令串仍继续刷机。已恢复上一版完整 Gecoos 数据库快照并保留残留目录；近期数据库修改未证明保留。修订升级 skill：暂停数据库后独立枚举、核验归档内容及 CURRENT/MANIFEST 依赖，刷机要求成功覆盖记录和精确归档摘要，任何前置失败都必须停止。

| 构建 | 原源码 pin | 候选 |
| --- | --- | --- |
| CPE-5G Wi-Fi B / 可选 NOWIFI A | `0bad892975fe49fd180f99b414a7f168bb694dd7` | `0fb9b10cb9df51fb076470e1dd93d1c30dd89d83` |
| RE-Mesh：RE-CS-02 / RE-SS-01 | `a4638cd4389183f1a1fcad0441f491ca11c97757` | 同上 |
| RE-CS-07 NOWIFI | `a4638cd4389183f1a1fcad0441f491ca11c97757` | 同上 |

RE-Mesh / RE-CS-07 已含 7 月 22–23 日的 NSS 初始化保护、EDMA NAPI/GRO、IRQ/DMA 清理和调频持久化；不能把这些描述成它们这次新增的功能。它们此次新增主要包括后续内核/通用 USB/WCSS 适配、SSDK 更新和 ECM RAWIP 编译条件修复。

## NSS 吸收与收益边界

- [0be028e](https://github.com/VIKINGYFY/immortalwrt/commit/0be028e15911193ead2f9d7b599f3f77ea32c3a2)：NSS netlink 写操作权限、mirred/qdisc 清理、skb 内存计量、空缓冲区分配、桥接 VLAN 加速。
- [9cf9dbf](https://github.com/VIKINGYFY/immortalwrt/commit/9cf9dbf14f01e8d5768075946cc37c276b556cea)：初始化前调频保护与 EDMA 警告限速。
- [20f4214](https://github.com/VIKINGYFY/immortalwrt/commit/20f42148a480dc4355746a1fd38f345e6d571cca) + [a4638cd](https://github.com/VIKINGYFY/immortalwrt/commit/a4638cd4389183f1a1fcad0441f491ca11c97757)：NAPI/GRO、IRQ/DMA 失败清理、调频读数和持久化；后一提交修正前一补丁。
- [17ab5ae](https://github.com/VIKINGYFY/immortalwrt/commit/17ab5ae4d8765601c2bd8634010dcf6d613a9ba5)：RAWIP 只在 qmi_wwan_q 和 NSS RMNET 均满足时编译，避免引用不存在的符号。UDX usb0 是以太网式接入，不能因此声称 SIM 提速。
- NSS 固件二进制包 nss-firmware tree `078039db273f13e5806b3b3713c900ec9b0c7848`、nss-eip-firmware tree `9ce7afe81ce36fb47a9d3eac643392073cef678c` 不变。drv/dp 源码 pin 不变但补丁树变化，ECM release 8→9，SSDK release 1→2。
- 保留 CPE Wi-Fi NSS 禁用策略。其他设备吞吐/CPU收益需对照测试；不能用其他机型的内存测量代替本机结果。

## 设备树：板级文件与最终 DTB 的区别

三个板级 DTS 文件完全相同（也与 `a4638cd` 相同）：

| 设备 | 文件 | blob |
| --- | --- | --- |
| RE-SS-01 | `target/linux/qualcommax/dts/ipq6000-re-ss-01.dts` | `a278a87acb783e546cc473878cb8fe5ca3d50a92` |
| RE-CS-02 | `target/linux/qualcommax/dts/ipq6010-re-cs-02.dts` | `bef591b4ef6c421f28a0f0d3aa67817ac7a14799` |
| RE-CS-07 | `target/linux/qualcommax/dts/ipq6010-re-cs-07.dts` | `6d35c84638d9573966b5441267f6569225e310ff` |

但它们包含 IPQ6018 通用 DTSI，最终 DTB 会受通用补丁影响：

1. **USB 扁平化**：`0144-arm64-dts-qcom-ipq6018-Flatten-usb-controller-nodes.patch` 将旧的 qcom 包装节点与 dwc3 子节点合为单节点，使用 `qcom,snps-dwc3`，更新寄存器范围，合并控制器/电源/PHY 中断及 PHY 属性。这是驱动绑定变化，不是新增 USB 口或提高标称速度。
2. **USB host 模式位置**：`0143-*move-DR-mode-to-board-DTS.patch` 从 SoC DTSI 移除统一 host 默认；`ipq6018-common.dtsi` 在 `&usb3` 显式加 `dr_mode = "host"`。三个设备都继承该 common 文件，因此源码层面已保留 host 模式，仍需实测 UDX 枚举和 U 盘热插拔。
3. **Wi-Fi WCSS 固件启动**：`0905-arm64-dts-qcom-ipq6018-use-secure-WCSS-remoteproc.patch` 使用 secure PIL compatible，显式指定 `IPQ6018/q6_fw.mdt` / `m3_fw.mdt`，增加 QDSS 时钟；`0812-remoteproc-qcom-wcss-sec-add-ipq6018-support.patch` 配套使用 `wcnss` 子系统名称。Wi-Fi 构建必须检查固件加载、两个软重启和冷启动；RE-CS-07 NOWIFI 不以此声称无线能力。
4. **通用时钟/PWM 和内核补丁刷新**：有新增、重排、删除和上下文刷新，文件变动不能一概算成功能增强。

`ipq6010-re-cs.dtsi` 不变：blob `47b87bc05bcbc9e718d99b734b2241473745db90`。
`ipq6018-common.dtsi`：`9df78f12d94ab0ba76d403f3e958b704aca3a16c` → `18084f755f9dfac79743861936f0d8a1f6a2e57d`，实际文本变化为上述 host 属性。
`ipq60xx.mk` 整文件变化，但三个 JDCloud Device 定义没有 diff；变化涉及其他厂商设备和镜像工具，不能将其当作 JDCloud factory pipeline 升级。candidate blob `66922e63a655436c37553c1fe3d9c278eb878b0c`。

## 上游合并记录

Upstream source: VIKINGYFY/immortalwrt `0fb9b10cb9df51fb076470e1dd93d1c30dd89d83`
Accepted: 完整源码候选 pin（含 Linux 6.18.52 / NSS / SSDK / USB / WCSS 依赖），范围限三条机型构建入口。
Rejected: 不导入 DaeWRT-CI 的设备删除、代理替换或运行时/私有配置覆盖；davidtall/immortalwrt stable 42180ada 是 CPE 基线祖先，不作升级。
Protected: AI agent runtime、Tailscale/Headscale、Nikki、JDCloud 设备、Wrtbak disabled guard、CPE Wi-Fi B / A isolation、SIM native ledger、Lucky eMMC 与加密产物。
Verified: GitHub tree/blob/contents 比较；本地护栏结果记录于 PR。四台编译/刷写及两次软重启通过；CS02 冷启动/USB 通过，其他物理项目按用户指令暂缓。
Device impact: CPE-5G、RE-SS-01、RE-CS-02、RE-CS-07；普通 QCA/WLG 构建入口不修改。

## 验收与回退

先从候选分支显式 dispatch 对应入口，DEBUG_SSH 保持默认关闭，CPE 默认只 B。核对完整 workflow SHA / 源码 SHA / artifact SHA256 后，按设备依次验收 LAN/WAN、NSS 统计与 CPU/吞吐、无线（适用时）、eMMC、Tailscale/Nikki、2 次软重启、1 次冷启动。
CPE 另验 UDX usb0、SIM IPv6、公网回源、mwan3 标记和配额账本；真实故障测试必须有独立救援和限时恢复。
USB 实际拔插不能用 mock 测试代替。编译成功不等于硬件启动通过。
回退只恢复对应 workflow 源码 pin：CPE 回到 `0bad892975fe49fd180f99b414a7f168bb694dd7`，其他三个设备回到 `a4638cd4389183f1a1fcad0441f491ca11c97757`，保留无关 hotwa 功能提交和 `/data`。

## 已刷入产物

所有产物完整文件校验和与完整源码 SHA 均已核验。设备保持各自精确 workflow 提交，后续文档合并提交不冒充已刷固件。

| 设备 | workflow 提交 | Action | sysupgrade SHA256 |
| --- | --- | --- | --- |
| RE-CS-02 | `863a28839356ab967cc38f1369652d5fec5e08da` | `37523641754` | `dcf1d2a7962e27a0670262403bf89779f59a520088810b28266c739c3b3a5591` |
| RE-SS-01 | `567c31956729e3552ded5d166f4c32f425e63d01` | `37482768819` | `8e754575e049c88d0260fd941a2fb055cfc63cc4128151de4fda385cd569f8be` |
| RE-CS-07 | `567c31956729e3552ded5d166f4c32f425e63d01` | `37482778679` | `1c7edcf3d43591421e53b41b274c0bd281e6472a5d22619c95042cf114c7bb85` |
| CPE Wi-Fi B | `567c31956729e3552ded5d166f4c32f425e63d01` | `37482786828` | `a2fb43748ad217e26f63b40b48db61bd7b897daa0b4265019f41f4f58a489679` |

修复版 CS02 ZIP SHA256：`5a2094642f4b25b2d2c2662958b6782728ca0b872dc15a18cdf9f4458c28f63f`。其他私有 ZIP 摘要、备份 coverage receipt 和逐次启动证据保留在本机私有 ledger，不公开配置或凭据。
