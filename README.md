# OpenWRT-CI
云编译OpenWRT固件，开启内核eBPF，支持DAED 内核级透明代理

官方版：
https://github.com/immortalwrt/immortalwrt.git

高通版：
https://github.com/VIKINGYFY/immortalwrt.git

## 上游关系与 RE-SS-01 已验证基线

- CI 工作流上游：`davidtall/DaeWRT-CI`。
- 固件源码候选上游：`davidtall/immortalwrt:stable`。该移动分支只用于跟踪候选更新，不是自动生产基线。
- 上游合并策略见 `docs/upstream-merge-policy.md`。默认只做小原子吸收，不能用上游覆盖删除 hotwa 的京东云设备、Nikki、wrtbak/private build、CPE-5G 或 Headscale/Tailscale guard。
- CPE-5G 当前生产基线：B 功能对照，2026-07-06 / `0bad892975fe49fd180f99b414a7f168bb694dd7` / Linux `6.18.37` / `IPQ60XX-706-NOWIFI`。2026-07-12 已在 `jdcloud,re-ss-01` 完成刷写并进入系统，`usb0=192.168.66.2/24`，OpenWrt 本机访问 CPE `192.168.66.1:6677` 返回 HTTP 200。
- A 纯底层对照使用同一 SHA/NOWIFI 配置、关闭 feature overlay，也已完成刷写并正常进入系统；保留为后续启动问题隔离基线。
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

日常触发 `CPE-5G` 时默认 `BUILD_BASELINE_A=false`，因此只构建已验证的 B 生产固件。只有遇到无法启动、NSS/网口异常或需要区分“底层源码问题”和“hotwa feature overlay 问题”时，才显式设置 `BUILD_BASELINE_A=true` 额外构建 A；A 不是日常升级固件，也不替代 B。

CPE-5G B 与普通 feature-overlay 构建共享 wrtbak/Headscale 首启门禁。factory 启动时先等待 wrtbak 判断是否恢复已有 `tailscaled.state`；仅在恢复终态确认没有可复用身份时才执行 Headscale 新注册，避免刷机产生临时残留节点。

CPE-5G B 还单独内置 mwan3：以太 WAN 是主线路（network/member metric `10`），UDX710 `usb0` 的 `5G` 是备用线路（metric `20`）。多目标健康检查识别“接口仍在线但互联网已断”，连续失败/恢复阈值抑制抖动；`192.168.66.0/24` CPE 管理链路和 `192.168.13.0/24` LAN 明确旁路默认策略，保持 Lucky 入站响应经 usb0 对称返回。该配置不进入 A 或普通 QCA 固件，详细参数与实机回滚门禁见 `docs/cpe-5g-preset.md`。

### CPE IPv6 入站与 Lucky

当前推荐公网服务链路为：`CPE 公网动态 IPv6:外部端口 -> CPE IPv6-to-IPv4 relay -> OpenWrt usb0 192.168.66.2:Lucky入口端口 -> Lucky反向代理 -> 192.168.13.x:服务端口`。Lucky 应监听 `192.168.66.2` 或 `0.0.0.0` 的指定入口端口；LAN 服务本身无需“转发到 192.168.66.2”。只开放明确需要的端口和 Host 规则，避免把整个 `192.168.13.0/24` 暴露给公网。

蜂窝网络当前只观察到 CPE 自身获得运营商 `/64` 地址，尚未证明运营商提供 DHCPv6-PD。仅发送 RA 不能把同一个 `/64` 正常路由给 OpenWrt LAN；若无可委派前缀，需要 RA relay/NDP proxy、邻居缓存维护、回程路由和 IPv6 防火墙协同，重启换前缀时还要重新收敛，属于中高难度且运营商相关的实验功能。生产环境继续采用 CPE IPv6 端口转发；PD/RA/NDP 只在独立实验分支和可回滚设备上开发。

2026-07-12 实机门禁记录：GitHub Actions run [`29160402065`](https://github.com/hotwa/OpenWRT-CI/actions/runs/29160402065) 成功；B artifact digest 为 `sha256:bad3ff165840c982ed2ae337532ca456eb940560ae71665196cfa4245ce7631d`，B sysupgrade SHA256 为 `bb69688f6a4385e897d1cf6f9c355d22d279d94e9b9e3e87d9a15c434682485b`；A artifact digest 为 `sha256:e43afee3cb0a277e463ecb85f3ca991ea804d7dda6f56c434e30452c32dc67e7`。A、B 均已确认可启动，因此 B 现作为 CPE 功能生产基线；WiFi-YES 仍需单独测试，不能由本次 NOWIFI 结果推断。

双网卡 Windows 客户端若保留 `192.168.66.0/24 via 192.168.11.247` 的旧永久路由，会从 OpenWrt WAN 进入并被正常防火墙策略拒绝；这不代表 CPE overlay 失败。应让该网段经 LAN 网关 `192.168.13.1` 进入，使用已有 `lan -> wan/5G` forwarding。

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

# AX6600-Athena LED 插件固定策略

`re-ss02` / `jdcloud_re-cs-02` / JDC AX6600-Athena 固件固定使用 `unraveloop/JDC-AX6600-Athena-LED-Controller` 的 `v2.4.0` 双包实现：`athena-led` 核心包 + `luci-app-athena-led` LuCI 界面包。`Scripts/Packages.sh` 以 tag `v2.4.0` 和提交 `a0eae21dc1119a56aaf8633c610af03a92f7493c` 固定该来源，避免后续上游同步或 unraveloop `main` 变化悄悄改变 LED 控制行为。

该插件由 `Scripts/function.sh` 在生成正式配置时只写入 `jdcloud_re-cs-02` 的 `DEVICE_PACKAGES`；`Config/TEST.txt` 的 per-device 配置用于快速配置验证。WIFI-YES 和 WIFI-NO 正式构建都会在编译后检查 `jdcloud_re-cs-02` manifest，缺少 `athena-led` 核心或 `luci-app-athena-led` 界面时 CI 直接失败。普通 QCA、`jdcloud_re-ss-01`、CPE-5G、RE-CS-07 等固件不要全局启用这两个包。

`NONGFAH/luci-app-athena-led` 是旧单包实现，包名同样叫 `luci-app-athena-led`，会与 unraveloop 的 LuCI 包冲突。保留它只能作为历史说明或手工回退参考，不要在 AX6600-Athena 固件里默认拉取或启用。后续从上游合并 Athena LED 相关改动时，必须保留本仓库的 unraveloop 固定来源和设备级限定，不能接受上游把 LED 包源改回 NONGFAH/haipengno1 或改成全局安装。

# Cloudflare IP 测速插件

所有固件镜像固定包含 `cfst`、`cf-ip-speed-client` 与 `luci-app-cf-ip-speed-client`。`cfst` 使用 `XIU2/CloudflareSpeedTest` `v2.3.5` 按目标 CPU 架构选择的官方发布包，并在 `package/cfst/Makefile` 固定 SHA256；LuCI 客户端使用 `10000ge10000/cf-ip-speed-panel@09a8020fd7e6603522b47a4af04a0a2e39f2662e`。首次刷机后客户端已启用，但处于手动测速和不上传模式：填写昵称、确认公开众测并设置计划后才会发起周期测速。

上游客户端为了使测速与众测上传使用真实 WAN 出口，会在测速期间临时停止 Nikki、DAE、HomeProxy 等透明代理服务并在结束后恢复。该项目只发布类似 `省份.运营商.6610000.xyz` 的优选 DNS 记录，不会自动将所有 Cloudflare 托管域名改写为直连 IP。不要仅通过 Nikki fake-IP bypass 或将所有 Cloudflare CIDR 设为全局直连来规避这一行为；前者不能保证直连，后者会影响大量正常网站。若要将结果用于访问加速，必须为用户明确指定的域名单独实现 DNS 覆写和 Nikki `DIRECT` 规则；若需要测速期间代理不中断，则必须另行实现仅针对测速进程的策略路由或网络命名空间。
