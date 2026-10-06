# Linux 6.18.52 / NSS 候选接入

## 范围与状态

候选分支：`codex/nss-6.18.52-candidate`。
固定完整源码 `VIKINGYFY/immortalwrt@0fb9b10cb9df51fb076470e1dd93d1c30dd89d83`。
只更新 CPE-5G、RE-Mesh（RE-CS-02 / RE-SS-01）、RE-CS-07 的源码 pin。
这是完整源码候选升级，包含内核及通用补丁依赖，不声称只 cherry-pick NSS 补丁；不合并上游 CI 仓库。
本分支没有修改机型配置、网络/代理策略、运行时 pin 或 private Secret 映射；未提升生产基线、未刷机。

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
Verified: GitHub tree/blob/contents 比较；本地护栏结果记录于 PR。编译/实机门禁待执行。
Device impact: CPE-5G、RE-SS-01、RE-CS-02、RE-CS-07；普通 QCA/WLG 构建入口不修改。

## 验收与回退

先从候选分支显式 dispatch 对应入口，DEBUG_SSH 保持默认关闭，CPE 默认只 B。核对完整 workflow SHA / 源码 SHA / artifact SHA256 后，按设备依次验收 LAN/WAN、NSS 统计与 CPU/吞吐、无线（适用时）、eMMC、Tailscale/Nikki、2 次软重启、1 次冷启动。
CPE 另验 UDX usb0、SIM IPv6、公网回源、mwan3 标记和配额账本；真实故障测试必须有独立救援和限时恢复。
USB 实际拔插不能用 mock 测试代替。编译成功不等于硬件启动通过。
回退只恢复对应 workflow 源码 pin：CPE 回到 `0bad892975fe49fd180f99b414a7f168bb694dd7`，其他三个设备回到 `a4638cd4389183f1a1fcad0441f491ca11c97757`，保留无关 hotwa 功能提交和 `/data`。
