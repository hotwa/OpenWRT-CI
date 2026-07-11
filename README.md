# OpenWRT-CI
云编译OpenWRT固件，开启内核eBPF，支持DAED 内核级透明代理

官方版：
https://github.com/immortalwrt/immortalwrt.git

高通版：
https://github.com/VIKINGYFY/immortalwrt.git

## 上游关系与 RE-SS-01 已验证基线

- CI 工作流上游：`davidtall/DaeWRT-CI`。
- 固件源码候选上游：`davidtall/immortalwrt:stable`。该移动分支只用于跟踪候选更新，不是自动生产基线。
- CPE-5G 当前优先已验证基线：2026-07-06 / `0bad892975fe49fd180f99b414a7f168bb694dd7` / Linux `6.18.37`，对应 DaeWRT-CI 的 IPQ60XX-NOWIFI Release，并已在 `jdcloud,re-ss-01` 成功启动。
- 历史已知可启动回退点：2026-06-25 / `42a1f64b5dbd2a99d05daca94ae5a87eebff59b4` / Linux `6.18.35`。

| 组件 | 当前已验证版本 | 来源提交 |
| --- | --- | --- |
| 固件源码 commit | `VIKINGYFY/immortalwrt@0bad892975fe49fd180f99b414a7f168bb694dd7` | 7.06 产物 `/etc/openwrt_release` 的 `r0-0bad892` 解析结果；构建必须精确 detached checkout |
| Linux kernel | `6.18.37` | `target/linux/generic/kernel-6.18` blob `efbfe514334d0ec7ea223dfd217ee03a9842c8e3`；tarball SHA256 `a83cd200e6646db52866b8309e9137b9e9048b613cbda10ced2b811aae125255` |
| qca-nss 补丁树 | `package/qca-nss` | tree `16f46086b41275bcc004e534f966f9cd509cd146` |
| qca-nss-dp | `d8f802f0`，APK `6.18.37.2026.01.19~d8f802f0-r1` | tree `1d9f3483fbaecd08630d4982d6194c4bb8b30659` |
| qca-nss-drv | `6aa14c7`，APK `6.18.37.13.1.2026.01.12~6aa14c7-r18` | tree `ea51b83dab5384601fe66a1614d0cf0adbb99de4` |
| qca-nss-ecm | `8c7355b`，APK `6.18.37.13.1.2026.04.03~8c7355b-r8` | tree `052044910e24884c1060e87fd003c0cac716cb28` |
| qca-ssdk | `d9a19649`，APK `6.18.37.2025.11.14~d9a19649-r1` | tree `0ce02e13bdce01e62c1caf5e15d0e1f2ded0d1c1` |
| Qualcommax 6.18 内核补丁 | `target/linux/qualcommax/patches-6.18` | tree `d211c3263007c73642721596c4004424b32016a8` |
| RE-SS-01 DTS/DTB | `target/linux/qualcommax/dts/ipq6000-re-ss-01.dts`；FIT 描述 `OpenWrt jdcloud_re-ss-01` | DTS blob `a278a87acb783e546cc473878cb8fe5ca3d50a92` |
| RE-SS-01 factory pipeline | `append-kernel | pad-to 6144k | append-rootfs | append-metadata` | `ipq60xx.mk` blob `44a7716b4009d8be76c4c54fa399cf89bec4a838` |

Release 的 Source code tar.gz 只代表 `davidtall/DaeWRT-CI` 的 CI 脚本、配置和补丁层，不是 ImmortalWrt 内核源码。上表的内核、NSS、DTS 与 factory provenance 来自实际 sysupgrade 元数据以及完整 ImmortalWrt SHA。复现固件必须使用完整源码 SHA，不能拼接单项对象。普通 QCA 构建不受这个 CPE 专属固定影响。

`CPE-5G` 一次建立两个 NOWIFI 受控构建：A 固定同一 SHA、使用从 7.06 CI tag 派生且仅缩减设备选择到 RE-SS-01 的 `IPQ60XX-706-NOWIFI` 配置、关闭 CPE/Lucky/Tailscale/Headscale/wrtbak feature overlay并使用 `192.168.10.1`；B 使用同一 SHA 和同一配置，只增加 `usb0`/`192.168.66.0/24`、`192.168.13.1` LAN 及上述 feature overlay。只有 A、B 均通过实机启动门禁后，才另行测试 `IPQ60XX-WIFI-YES`。

更新上游后必须先作为候选构建，并在 RE-SS-01 上验证刷写、LAN/WAN、NSS、两次软重启、一次断电冷启动及 CPE 管理链路。出现无法启动、网口或 NSS 回归时，退回本表记录的上一个实机已验证完整 SHA，不回滚 hotwa 的功能提交。

LiBWrt：
https://github.com/davidtall/LiBwrt-openwrt-6.x

# U-BOOT

高通版：
https://github.com/chenxin527/uboot-ipq60xx-emmc-build
https://github.com/chenxin527/uboot-ipq60xx-nand-build
https://github.com/chenxin527/uboot-ipq60xx-nor-build

联发科版：
https://drive.wrt.moe/uboot/mediatek

京东云亚瑟 AX1800 Pro DAED 需要更换分区表和uboot,具体使用方法详见恩山帖子:
https://www.right.com.cn/forum/thread-8402269-1-1.html

# 固件简要说明：

固件每天早上4点自动编译。

固件信息里的时间为编译开始的时间，方便核对上游源码提交时间。

MEDIATEK系列、QUALCOMMAX系列、ROCKCHIP系列、X86系列。

# 目录简要说明：

workflows——自定义CI配置

Scripts——自定义脚本

Config——自定义配置

# hotwa 保留设备说明

hotwa 仓库需要长期保留京东云 `re-cs-07`、`re-ss-01`、`re-ss02` 三个型号。后续从上游合并时，如果上游删除这些型号，不要接受删除；如果上游新增其他设备，可以在保留这三个型号的基础上继续合并新增设备。
