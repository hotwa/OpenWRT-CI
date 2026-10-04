# CPE-5G：蜂窝 IPv6、IPv4 备份与持久身份

此配置针对 LAN 为 `192.168.13.0/24` 的 CPE-5G B，用户选择的 Tailscale 名称是 `cpe-5g-s13`，注册并应用名称后通过 `cpe-5g-s13.hs.jmsu.top` 访问。它沿用已验证的 UDX710、RNDIS USB 硬件和 OpenWrt 源码基线；为了实现这项 IPv6 能力，不需要升级 UDX710 固件或更换硬件。

本次加入的是待实机验收的用户空间自动化。短时实验已验证本机、隔离 LAN 节点及真实 Mac 的 SLAAC/IPv6 出站，也验证了离线 RA 默认路由撤回；这些结果不代表新 netifd worker、更多 LAN 设备、流量上限门禁、换前缀或新固件已通过生产验收。

## 网络用途与流量

| 路径 | 平时用途 | 故障时行为 |
| --- | --- | --- |
| 以太网 `wan` | IPv4 DHCP；也支持工作流选择 PPPoE 或保留已配置的 PPPoE。禁用其 IPv6 客户端。 | mwan3 多目标探测连续失败后将新的 IPv4 连接切到 `5G`；恢复后回切。 |
| USB `5G` / `usb0` | UDX710 私有管理链路和 IPv4 备用出口。 | SIM 有额度且蜂窝可达时提供 IPv4；额度门禁关闭时不可作为公网备份。 |
| USB `cpe6` | 从当前蜂窝 `/64` 为 OpenWrt 和一个 LAN 提供原生 IPv6。 | 蜂窝 IPv6 不可达时撤回托管地址、前缀和路由；不会从以太网取得替代 IPv6。 |
| Tailscale | 复用本机持久身份，按 Headscale ACL 提供远程维护与站点访问。 | 底层仍需要可用的以太 IPv4 或蜂窝网络；同时失效时无法凭空提供连接。 |

WAN/member metric 为 `10`，5G 为 `20`，IPv4 使用主备策略。DHCP 租约存在或 PPPoE 会话仍连接，不代表公网可用，所以健康检查使用多个公网目标。切换只影响新连接，现有 TCP 会话不能保证无缝迁移。

**长期给 LAN 通告蜂窝 IPv6，意味着 WAN 正常时支持 IPv6 的应用也会消耗 SIM 流量。** IPv4 的备用角色不等于 SIM 平时闲置；IPv6 下载、Tailnet 直连和低频健康探测均可能计入额度。如需尽量节省 SIM，应另行选择只在故障时通告 IPv6 或限定设备的策略，不能将当前全 LAN 模式描述为零流量备用。

当前现场 UDX710 的流量上限为 **40 GiB**（42,949,672,960 字节）。服务只读取既有额度和累计 RX＋TX，不改变限额、不开启飞行模式、不强制重新拨号、不清零计数。额度周期和重置仍由 UDX710 及管理员控制；不能假定它自动按月重置。

## IPv6 路由与 CI 集成

CPE-5G B 明确传入以下非敏感构建参数；A 和普通固件不启用这组 CPE 功能：

```yaml
WRT_CPE_5G: true
WRT_CPE_IPV6: true
WRT_EMMC_DATA_PROVISIONING: true
WRT_HEADSCALE_HOSTNAME: cpe-5g-s13
```

`Scripts/ConfigureCpeIpv6.sh` 将 `Scripts/cpe5g-ipv6/` 的受限 ADB 客户端、模型、探测和 netifd worker 放入镜像，同时生成 `/etc/config/cpe5g_ipv6`。启动 reconcile 等待 wrtbak 首启门禁终态，再建立 `network.cpe6`，由 netifd 管理 worker。初始 `mode='lan'` 的目标是通过 odhcpd RA/SLAAC 给一个 LAN 通告蜂窝 `/64`；不是运营商 DHCPv6-PD，也不承诺为多个独立 VLAN 各提供一个 `/64`。

服务从 UDX710 的当前 `sipa_eth0` 读取有效 `/64`，不取 USB 上残留的第一个公网地址。它为本机配置独立地址，并维护 UDX710 表 `181`、`200` 经 OpenWrt USB 链路本地地址的回程路由。托管路由使用独立 metric，避免覆盖厂商原有路由；在前缀变化或停止时只清理自己的项。

固定版本的 [netifd 停止流程](https://github.com/openwrt/netifd/blob/d155e4cefbd964b7c022618c1d74b549de25e8a8/proto-ext.c#L762-L781) 只给协议进程 5 秒清理。worker 收到停止信号后取消正在等待的 ADB 请求，先关闭本机 IPv6 门禁、撤回 RA 并清理托管策略，再在 3.5 秒总预算内尝试远端清理；停止中的异步结果不能继续发布地址或开放门禁。若 UDX710 不可达，远端自有路由可能留待下一次启动按所有权标记回收。五种实际 SIGTERM 子进程测试已覆盖探测、健康检查、路由添加、空闲等待和卡住的远端清理；这不代替实机停止验收。

OpenWrt 使用独立策略表，并将 LAN、ULA、链路本地及 Tailnet 的相应流量留给正确路由；mwan3 的 IPv4 主备策略不应接管 IPv6，Nikki 已标记流量也不应被蜂窝规则抢走。这里采用路由延伸，当前实现不要求在 LAN/USB 之间启用 NDP relay。相关原理见 [RFC 7278](https://datatracker.ietf.org/doc/html/rfc7278)。

`5G` 与 `cpe6` 共用 `usb0`。固定 [netifd 的设备设置](https://github.com/openwrt/netifd/blob/d155e4cefbd964b7c022618c1d74b549de25e8a8/system-linux.c#L2720-L2721) 会把接口上的 `ipv6=0` 应用为内核 `disable_ipv6=1`，并非只关闭 DHCPv6。新配置在蜂窝 IPv6 功能启用时保留 `network.5G.ipv6=1`，使链路本地地址可供 worker 使用；初始配置和恢复后校准均处理这一点，启用已有的停用配置也会触发网络重载。`5G` 仍使用 IPv4 `proto=dhcp`，固定版本的 [DHCP 协议脚本](https://github.com/VIKINGYFY/immortalwrt/blob/0bad892975fe49fd180f99b414a7f168bb694dd7/package/network/config/netifd/files/lib/netifd/proto/dhcp.sh#L11) 不会因此生成 DHCPv6 子接口。以太网 `wan` 保持 `ipv6=0`，`wan6` 保持停用。

### RA 离线门禁与 DNS

基线 [odhcpd 包定义](https://github.com/VIKINGYFY/immortalwrt/blob/0bad892975fe49fd180f99b414a7f168bb694dd7/package/network/services/odhcpd/Makefile#L17) 固定到 `odhcpd@68f382690bfaec56d5b1f31c3c31c48bcb642e3a`。这一版本不能用 UCI `ra_lifetime='0'` 强制关闭默认路由通告：零值会进入寿命默认计算。worker 保持 `ra_default='0'`，离线将 `prefix_filter` 置为 `fc00::/7`，在线才开放为 `::/0`。按代码逻辑推导，过滤掉公网 PIO 后没有可用的公网前缀，便进入 Router Lifetime 为零的分支；来源分别支持 [寿命默认计算](https://github.com/openwrt/odhcpd/blob/68f382690bfaec56d5b1f31c3c31c48bcb642e3a/src/router.c#L377)、[PIO 过滤](https://github.com/openwrt/odhcpd/blob/68f382690bfaec56d5b1f31c3c31c48bcb642e3a/src/router.c#L763)、[非 ULA 前缀判定](https://github.com/openwrt/odhcpd/blob/68f382690bfaec56d5b1f31c3c31c48bcb642e3a/src/router.c#L807) 和 [零寿命分支](https://github.com/openwrt/odhcpd/blob/68f382690bfaec56d5b1f31c3c31c48bcb642e3a/src/router.c#L878)。这些链接只支持 RA 过滤机制，不作为下文实机测试的证据。

门禁切换使用 RAM 中的 UCI delta，只在在线/离线状态变化且配置变化时 reload odhcpd，不在每个轮询周期 commit 闪存。离线 RA 的默认路由寿命为零，不等于立即从客户端删除旧地址；已获取的 GUA 仍可能缓存约 180 秒。路由撤回与源前缀过滤共同限制旧地址继续走公网。`fc00::/7` 允许 ULA 的行为来自代码设计，本轮现场没有 ULA，所以不声称已实测 ULA 保留。

B 默认设置 `ra_dns='0'`，避免把短寿命蜂窝 GUA 当作 RDNSS 地址下发，随后换前缀留下不可达的 DNS。已有 `192.168.13.x` 双栈客户端继续使用 IPv4 DHCP 提供的 dnsmasq/mosdns/Nikki DNS 管线，IPv4 DNS 同样可以解析 AAAA；这不限制 IPv6 数据连接。仅有 IPv6 的客户端需另行提供稳定 DNS 配置。新的 DNS 默认设置尚未随候选固件完成实机验收。

CPE B 仅在 `network.5G.dns` 为空时补入 `223.5.5.5`、`119.29.29.29`，保持 `peerdns=0`；用户已有 DNS 值和 Nikki/mosdns 策略保留。固定 [netifd 配置读取逻辑](https://github.com/openwrt/netifd/blob/d155e4cefbd964b7c022618c1d74b549de25e8a8/interface.c#L929) 分别处理运营商 DNS 与静态 DNS，[resolv 生成逻辑](https://github.com/openwrt/netifd/blob/d155e4cefbd964b7c022618c1d74b549de25e8a8/interface-ip.c#L1559) 仅将 UP 接口的 DNS 写入自动生成文件；普通 IPv4 DNS 包沿用现有主备出口策略。现场跳板的普通 DNS 探测返回 `No route to host`，尚未证明此备用 DNS 路径可用；先前 `--resolve` 实验固定了目标地址，也不能证明普通 DNS 解析成功，仍待新镜像验收。

当额度读取未知或超限时，OpenWrt 在自身防火墙阻断 USB 公网 IPv4/IPv6 出站及转发，并撤回可用的 IPv6 通告；私有 `192.168.66.0/24` 管理、DHCP 和必要 NDP 保留。额度状态不能从“USB 仍在线”推断，IPv4/IPv6 健康状态也分别判断。若已到达硬上限，WAN 再故障时就没有可用蜂窝公网备份。

现场只读检查显示 `flow_offloading=1`。新 CPE reconcile 将 fw4 的 `flow_offloading` 和 `flow_offloading_hw` 设为 `0`，通过成功的 firewall reload 删除旧 flowtable，避免已加速连接绕过 forward 额度规则。固定版本的 [fw4 ruleset 模板](https://github.com/openwrt/firewall4/blob/b6e5157527d361f99ad52eaa6da273cb0f2dfd59/root/usr/share/firewall4/templates/ruleset.uc#L8-L31) 支持删除旧 flowtable，[设备选择逻辑](https://github.com/openwrt/firewall4/blob/b6e5157527d361f99ad52eaa6da273cb0f2dfd59/root/usr/share/ucode/fw4.uc#L540-L555) 在关闭 flow offloading 后返回空列表；[Linux flowtable 文档](https://docs.kernel.org/networking/nf_flowtable.html) 说明命中 flowtable 的包会绕过常规转发钩子。这项修改不改变 NSS 内核、源码 pin 或以太网配置。普通 RNDIS `usb0` 预期不注册 NSS，但本轮没有实机证明；连续 USB 流在额度未知/超限时能否及时被门禁阻断，仍需新固件实机验收。

公网原生地址不等于允许公网登录。默认入站保护先于地址发布，保留必要 ICMPv6、已建立连接和受控的 Tailnet 连通性；SSH、代理和其它业务仍需逐项审核目标、端口、来源及认证。ADB `5555`、CPE 管理 `6677`、LuCI 和 Dropbear 不应因新增地址而自动公开。优先通过 Tailscale SSH/ACL 维护；公网业务 DDNS 应另行配置，MagicDNS 名称与动态蜂窝公网前缀是两种地址体系。

## 实测证据与未验证范围

2026-10-03 的实验使用现有 UDX710 固件，完成了以下验证：

| 实测项目 | 结果与范围 |
| --- | --- |
| OpenWrt 独立 `/128` | 公网 ping 和 HTTPS 出站成功；地址在 `usb0` 上时可使用 UDX710 原有 USB `/64` 回程路由。 |
| 隔离 LAN 节点独立 `/128` | veth 接入 `br-lan`，IPv6 出站成功；三个香港公网探测点主动连接临时 HTTP 端口，均收到 HTTP 200。 |
| 真实 Mac `en8` 自动 SLAAC | 未手配客户端地址或路由，自动取得蜂窝 GUA 的 stable 和 temporary 地址。 |
| 真实 Mac `en8` HTTPS | `curl --interface en8 --resolve 'dns.alidns.com:443:[2400:3200::1]'` 的 HTTPS DNS 查询成功，JSON `Status=0`；该项验证 IPv6 数据路径，固定解析地址不代表新的客户端 DNS 默认已验收。 |
| 在线 RA | 抓包看到蜂窝 `/64` PIO，标志为 onlink、auto，Router Lifetime 为 120 秒。 |
| 离线 RA | 保持路由器内核 GUA/默认路由时，将 `prefix_filter` 设为 `fc00::/7`，抓包确认 Router Lifetime 为 0 秒。 |

真实 Mac 实验在 OpenWrt 和 UDX710 两端均设置 600 秒自动回滚，结束后清理自身添加的路由、地址、pref/table `612` 和 nft 规则；原有 USB IPv4 默认路由保持不变，没有断 WAN 或写入闪存。动态公网地址和抓包/探测原始结果保留为本地运行记录，不写入固件或 Git。

这些结果证明当前路径能承载原生 IPv6、公网 TCP 回程、单台真实客户端 SLAAC，以及固定版本的 RA 离线门禁。没有完成公网 SSH 认证测试，也没有证明运营商提供 DHCPv6-PD；现场没有 ULA，本轮不宣称 ULA 相关路径已实测。新 netifd 自动化、更多 LAN 设备、换前缀收敛、重启/冷启动、流量门禁、Nikki/mwan3/Tailscale 联动及性能仍须分别实机验收。

## eMMC 与 Tailscale 身份

名称配置不依赖 AuthKey 是否存在：无 key 的构建也保存 `hostname_mode='explicit'` 和 `hostname_override='cpe-5g-s13'`，镜像默认 `headscale_auto_enroll.main.enabled='0'`，不会擅自注册新节点。此时已有 `/data` state 可由 tailscaled 重新连接原节点，控制端名称不会仅因写入 UCI 就自动改变；首次注册或应用新名称仍需一次已授权的注册/偏好应用。

显式名称构建还生成一次性的 `/etc/uci-defaults/93-headscale-explicit-hostname`，在 `94-headscale-auto-enroll` 启动服务前将保留配置中的名称改为 `cpe-5g-s13`。它只写四个 hostname 字段，使用本次构建规范化后的名称和可选 prefix；CPE 的空 prefix 会清理旧值。它保留原来的 enabled 值，不读取或修改 key/state；因此当前设备保留的 `openwrt-cpe-5g-13` 名称不会遮住用户选择。UCI 写入或提交失败会留待重试，成功后脚本按 OpenWrt 首启规则删除。之后在 UCI hostname 设置中主动更名不会被该迁移每次轮询覆盖；再次安装显式名称固件时会应用那次构建的名称。空 hostname 构建不生成此迁移，沿用原来的 LAN 派生命名。

`/data/tailscale/tailscaled.state` 是本机生成的密码学身份，绝不从其它机器复制到镜像、写入 Git 或注入 CI。`tailscale-state-persist` 只接受独立的真实块设备 `/data` 挂载。已有 `/data` state 为权威，不被旧 `/etc` state覆盖；迁移改变 `state_file` 时真正 stop/start tailscaled，启动成功后才发布 ready。空的已有 state、迁移冲突或启动失败都会保持注册门禁关闭。

CPE B 开启的是受保护的 RE eMMC provisioner。它不是任意 GPT 修复或格式化授权：已有文件系统必须保留，未知/不满足审查条件的布局必须停止并诊断。当前现场观测为 **Tailscale `NeedsLogin`、没有独立 `/data` 挂载、GPT 存在异常**；因此这台设备尚不具备“刷入即可远程访问”的身份和存储前提。首次部署需先收集只读存储证据、核对精确分区和备份，再建立可用 `/data` 并完成一次注册。

同一状态跨升级保留依赖具体刷写方式确实保留独立 `/data`。支持的 retained-config sysupgrade 和已审查 Factory 路径不能推广到厂刷、整盘重分区或任意 Factory 工具。用户选择的 explicit 名称也不自动成为 fleet CD 合格目标，不能复用现有 `ss01-12` 的部署记录。详见 [Headscale 自动注册](headscale-auto-enroll.md)、[eMMC 制备](emmc-data-provisioning.md) 和 [/data 运行时](data-runtime.md)。

## 加密交付与本机解密

GitHub 的 [artifact 下载权限说明](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts) 允许已登录且拥有仓库读取权限的用户下载产物；公开仓库的 artifact 名称带 `private` 后缀不会建立维护者专属权限。CPE A、B 都明确传入 `WRT_ENCRYPT_ARTIFACT=true`，包括 `TEST=true` 配置验证构建；A 的隔离固件功能不因此改变。普通 QCA 和 fleet 调用保持默认 `false`，沿用原交付格式。

CORE 在打包后使用固定的 [age v1.3.2](https://github.com/FiloSottile/age/releases/tag/v1.3.2) 和 `Config/cpe5g-artifact-recipient.pub` 中的维护公钥，将完整 payload 封装后加密。CI 不接收解密所需的 SSH 维护私钥。共享秘密检测仍保留 `WRT_PRIVATE_BUILD` 原义；加密路径由独立输入决定，关闭明文上传、按设备拆分和公共 Release。唯一上传目录为 `wrt/encrypted-upload/`，名称以 `private-encrypted` 结尾，外层只含 `firmware.tar.age`、`SHA256SUMS` 和 `ENCRYPTION.json`。

下载到持有对应私钥的本机后，使用 [age 的 SSH Ed25519 支持](https://github.com/FiloSottile/age/blob/v1.3.2/README.md#ssh-keys) 解密；该路径需要私钥文件，不能仅依赖 ssh-agent。以下命令在仓库根目录执行，目录应按本次候选新建：

```sh
bash Scripts/FetchAge.sh /tmp/cpe-age
bash Scripts/DecryptFirmwareArtifact.sh \
  /tmp/cpe-age/age \
  /path/to/cpe-private-encrypted \
  /root/project/OpenWrt-Config-Backup/ops/ssh/openwrt_config_backup_maintainer_ed25519 \
  /path/to/cpe-decrypted
(cd /path/to/cpe-decrypted && sha256sum -c SHA256SUMS)
```

`DecryptFirmwareArtifact.sh` 的参数顺序为 `AGE_BIN ENVELOPE_DIR IDENTITY_FILE OUTPUT_DIR`。这些 helper 在 Linux/WSL 中非交互运行，使用无需口令的 SSH 私钥；当前维护密钥已通过真实往返验证。解密后保留原固件文件、manifest、metadata 与原 `SHA256SUMS`；仍须核对 Action 对应的 workflow SHA、精确源码 pin、RE-SS-01 型号及 factory/sysupgrade checksum，然后进行 rootfs 静态模块检查。外层 checksum 只验证下载密文，不能代替这些候选验证。`TEST=true` 配置包缺少原 checksum 时，仅允许 helper 在私有 staging 补生成，不修改原 `wrt/upload`；正式构建缺少 checksum 必须失败。解密后的配置包仍不是可刷固件。

加密保护的是 artifact 交付，不会隐藏 Actions 日志、撤回旧产物或替代设备验收。新固件刷写、首次建立有效 `/data`、注册并确认 `cpe-5g-s13.hs.jmsu.top` 连通，仍待现场完成。

## 部署与验收

先通过 CPE-5G 的 `TEST=true` 检查配置，再构建 `TEST=false` 候选产物。配置包不是可刷写固件；记录 Action run、源码 SHA 和 artifact SHA256，再按 [CPE 基线](cpe-5g-preset.md) 保留已知可启动回退固件。本次不更改内核、NSS、设备树、源码 pin 或 Agent 运行时版本。

非破坏性观察命令不读取身份文件内容：

```sh
openwrt-data-storage-diagnose --status
uci -q get tailscale.settings.state_file
ls -ld /data/tailscale
ls -l /data/tailscale/tailscaled.state
ubus call network.interface.cpe6 status
cat /var/run/cpe5g-ipv6/status.json
mwan3 status
tailscale status
```

刷写与真实断 WAN测试必须有独立现场 LAN/串口/U-Boot 救援和定时回滚。正式验收需在新自动化下重复本机及真实 LAN 客户端 IPv6，并覆盖更多客户端、额度未知/超限但管理链仍可达、WAN 恢复回切、允许与拒绝的公网服务、同一 Headscale 节点身份以及两次软重启和一次冷启动。在这些检查完成前，不宣称新自动化已在实机长期可用。


## UDX710 BusyBox 路由归属兼容

UDX710 的 BusyBox `ip` 在 IPv6 路由输出中省略 `rt_proto`，且其
`show table all proto 196` 不能可靠过滤协议。不得把 `metric 665`
单独当作本控制器路由的归属证据，否则可能误删厂商或其他服务的路由。
CPE B 的 CI 单独编译静态 `cpe6-route-audit`：它通过只读 rtnetlink
转储，只输出协议 196、table 181/200、metric 665、usb0 和 link-local
下一跳的 /64 路由。ADB 兼容层将这份内核证据补入快照和删除后的验证，
保留所有非本控制器路由。审计程序缺失时拒绝回程路由增删；已确认额度
有效的 SIM IPv4 不因这种 IPv6 失败而被阻断。

`cpe6-route-audit-bootstrap` 从固件 `/usr/libexec/cpe5g-ipv6/route-audit`
每 30 秒校验 UDX710 `/tmp/cpe6-maint/route-audit`。缺失或版本不符时，
仅在 USB 地址 192.168.66.2 临时监听，防火墙仅允许 UDX710
192.168.66.1 访问，校验 SHA256 后才原子发布工具，随后关闭监听和规则。
服务终止时也清理资源。工具在 UDX710 RAM 中，无需修改其固件或分区；
OpenWrt 和模块重启后均可从烘焙的副本恢复，不依赖手工放置的 eMMC 文件。

现场补丁已验证本机 IPv6 ping/HTTPS、LAN Mac SLAAC/ping/指定 CPE 网卡
的 HTTPS，以及删除临时审计工具后的自动补发。CI 新镜像仍需单独验证
冷启动和实际 WAN 恢复；WAN 恢复的 IPv4 策略适用于新连接，已有 SIM
连接不保证自动迁移。WAN IPv6 保持禁用，蜂窝 IPv6 可持续服务 LAN。
