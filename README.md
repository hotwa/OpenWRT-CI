# OpenWRT-CI
云编译OpenWRT固件，开启内核eBPF，支持DAED 内核级透明代理

官方版：
https://github.com/immortalwrt/immortalwrt.git

高通版：
https://github.com/VIKINGYFY/immortalwrt.git

## 上游关系与 RE-SS-01 已验证基线

- CI 工作流上游：`davidtall/DaeWRT-CI`。
- 固件源码候选上游：`davidtall/immortalwrt:stable`。该分支用于跟踪候选更新，不会自动替换生产已验证版本。
- CPE-5G 当前生产基线：2026-06-25 Release 已在 `jdcloud,re-ss-01` 实机验证的 A 基线。

| 组件 | 当前已验证版本 | 来源提交 |
| --- | --- | --- |
| 固件源码 commit | `VIKINGYFY/immortalwrt@42a1f64b5dbd2a99d05daca94ae5a87eebff59b4` | 完整 A 基线；构建必须精确 checkout 此 SHA |
| Linux kernel | `6.18.35` | `a1a3659c2918f20a45b82875fdf5f7bbf431e34a` |
| qca-nss 补丁树 | A 基线 `package/qca-nss` | `ad0b63563ff89ac01b09c6977d226d4587de2938` |
| qca-nss-dp | `d8f802f08fd8ff31057ba58edb20bbe448e7b505` | 包装/补丁 `ad0b63563ff89ac01b09c6977d226d4587de2938` |
| qca-nss-drv | `6aa14c7`，`PKG_RELEASE=18` | 包装/补丁 `5f520e5c2bc7ee41b0a3e25c0686be22d59af34f` |
| qca-nss-ecm | `8c7355b`，`PKG_RELEASE=7` | 包装/补丁 `38e28da69292dda73196b31e243985f742a30bdc` |
| qca-ssdk | `d9a196497ecee2530722d906e0efe1b7408b6ef6` | 包装/补丁 `38e28da69292dda73196b31e243985f742a30bdc` |
| Qualcommax 6.18 内核补丁 | A 基线 `target/linux/qualcommax/patches-6.18` | `38e28da69292dda73196b31e243985f742a30bdc` |
| RE-SS-01 DTB | `target/linux/qualcommax/dts/ipq6000-re-ss-01.dts` | `0c453396bfed1b3c18a77bd0fd58396da223e514` |
| RE-SS-01 factory pipeline | `target/linux/qualcommax/image/ipq60xx.mk` | `ac6d2f17ddcc6ae33c12e246f848ca0d06b5cd84` |

表中单项提交用于追踪来源；复现固件必须使用完整源码 SHA，不能拼接单项提交。CPE-5G 在该底层基线上继续叠加本仓库当前的 `192.168.13.1`、USB/5G、Lucky、Tailscale/Headscale 和 wrtbak 配置。普通 QCA 构建不受这个 CPE 专属固定影响。

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
