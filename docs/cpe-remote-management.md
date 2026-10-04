# CPE-5G 远程管理与主备网络

## 接口角色与现场证据

`wan` 是以太网 IPv4 主出口，支持 DHCP 或 PPPoE；`5G` 是同一台 UDX710 的 usb0 IPv4 备用出口；`cpe6` 是 usb0 上的原生 IPv6 控制接口。它不是第三个物理 WAN，不能作为冗余接口删除。

`cpe6` 由 netifd 管理，并负责地址、LAN RA、UDX 返回路由及 SIM IPv4/IPv6 额度门禁。删除它会停止这些状态更新，开机 reconcile 又会重建。LuCI 协议显示为 `SIM IPv6 (usb0)`，保留内部名称及 LAN `ip6class`。以太网 `wan.ipv6=0`，wan6 禁用。

2026-10-04 的只读检查确认：WAN 为 PPPoE、默认路由 metric 10；SIM 为 usb0、metric 20；mwan3 两者 online；蜂窝 IPv6 控制器 online。Tailscale 名称为 `cpe-5g-s13.hs.jmsu.top`，身份保存在独立 eMMC `/data/tailscale/tailscaled.state`。

此前独立 Mac LAN 救援和定时回滚实验已验证 PPPoE 断开、WAN 会话仍在但公网被阻断时的新 IPv4 连接经 SIM，以及 WAN 恢复后的自动切回。本机默认路由的假死兜底也已验证。现场 DHCP offer 探测未获得租约，不能把 DHCP 实机切换写成已通过。

WAN 使用三个 ICMP 目标、至少两个成功；失败三轮下线、恢复五轮上线。实际耗时包含每个目标超时，先前故障实验约 25 秒完成 WAN offline 判定。独立本机巡检为五秒，不保证现有 TCP/UDP 会话迁移。ICMP 可达但 DNS/TLS 失败、认证门户、部分目的地故障仍须另行验证，不能承诺覆盖所有异常。

持久服务由 procd 自动启动并 respawn；本机 IPv4 巡检与 UDX 额度/工具维护分别串行运行，UDX 的 ADB 通信等待不再阻塞本机巡检。额度未知或超过现场 40 GiB 上限时，SIM 公网 IPv4/IPv6关闭；私有 UDX 管理路径保留。正常 WAN 在线时蜂窝 IPv6仍消耗 SIM，双栈客户端可能优先选择它。

## Lucky 入口部署清单

下面列出已部署的 Tailnet 入口和待部署的 ESA 入口，不是 Lucky API 导入格式。现有 Lucky 加密配置必须通过有效的管理会话或完整私有导出修改，不能重置账号或覆盖整份配置来添加规则。

| 设置 | Tailnet 后台 | ESA 公网后台 |
| --- | --- | --- |
| 用户入口 | `http://cpe-5g-s13.hs.jmsu.top:16800/` | `https://cpe.jmsu.top/` |
| Lucky 新监听 | Tailnet IPv4 / 16800，或由防火墙限定 tailscale0 | IPv6 HTTPS / 18443，仅批准回源来源 |
| 反代目标 | `http://192.168.66.1:6677/` | `http://192.168.66.1:6677/` |
| 域名/路径 | 完整后台根路径 | 严格匹配 `cpe.jmsu.top`，完整根路径 |
| 认证 | Tailnet ACL、Lucky 临时账号，加 UDX 原有登录 | 先用 Lucky 自带账号认证；后续 OIDC/2FA，加 UDX 原有登录 |
| 默认不匹配请求 | 拒绝 | 拒绝 |
| 缓存 | 禁用 | ESA 绕过缓存，包括 HTML、API、登录及认证回调 |

Tailnet 的 16800 监听已按下节部署；公网 18443 监听尚未创建。Lucky 2.27.2 已有 IPv6 Web 反代、网页认证、通用 OIDC 和 Web 终端；后续接入 OIDC 时仍需配置身份提供方、客户端及回调。Lucky 的管理员登录不自动保护另一条 UDX 反代规则，须在该 Web 子规则配置认证。[Web 服务](https://lucky666.cn/docs/modules/web/)、[功能版本](https://lucky666.cn/docs/updatelogs/v2.X/)

UDX 管理主页返回 HTTP 200，未登录 API 返回 auth_required。使用相对 `/api/...` 路径，适合独立域名根路径反代；需实际验证 Host、Location、cookie、认证头、Origin 和页面写操作。不能为适配代理删除 UDX 的登录。已读取的 UDX 前端把终端地址拼为 `http://当前域名:7681`，直接反代不会自动修好这个终端链接。

Lucky 配置目录 `localips` 非空会替换其默认内网名单。若通过 Tailscale 管理被判定为外网，应保留默认 RFC1918/链路本地范围后补入批准的 Tailnet IPv4/IPv6网段，避免直接打开全公网管理。[安装与内网名单](https://lucky666.cn/docs/install/)

2026-10-04 用户选择暂不接 OIDC，先启用 Lucky 自带认证。已部署独立父规则 `managed-cpe-udx-tailnet`，仅监听 `100.64.0.53:16800`，反代固定 UDX 后端，默认未匹配 Host 关闭；旧 8443 规则保留。新子规则启用 `EnableBasicAuth` 和 `OtherParams.WebAuth`，`BasicAuthRegConf` 留空以保护所有路径，禁用自动开防火墙和缓存。临时账号独立于管理员与 Wi-Fi 密码，浏览器使用 Lucky 登录 Cookie，机器客户端回退 BasicAuth；不覆盖 UDX Bearer 认证。

真实浏览器经 Mac 跳板临时隧道及直接 MagicDNS 两条路径均通过 Lucky 登录并到达 UDX 登录页；Cookie 请求能读取 UDX 的未登录状态，错误 Bearer 得到 UDX 未授权响应。无认证/错误 BasicAuth 的根页面、API、静态资源返回 401；有效账号加错误 Host 被关闭。没有输入 UDX 密码或更改其登录。

临时账号、规则快照和变更前备份存于 CPE `/data/cpe5g-lucky`，访问凭据另存本机 Downloads 的私有文件，均不入 Git。`/etc/lucky/` 和相应 eMMC 凭据/规则文件已加入现场 sysupgrade 保留清单。该认证为设备配置，不含于正在构建镜像；保留配置升级会继承，清空配置刷机不应宣称自动恢复。Lucky 服务重启后监听及规则已恢复，有效账号返回 UDX 页面和登录状态，错误密码与未认证 API 仍返回 401；整机冷启动验收仍待完成。

## ESA 回源与 IPv6 门禁

优先链路：

```text
浏览器 HTTPS :443 -> ESA（代理与绕过缓存）
  -> OpenWrt 蜂窝 IPv6 HTTPS :18443（校验证书、限定来源）
  -> Lucky（临时账号认证；后续接入统一认证 + 2FA）
  -> UDX710 私有 USB HTTP 192.168.66.1:6677
```

如果运营商只允许 UDX 自身的入口，再使用已批准的 UDX IPv6 relay 转发到 `192.168.66.2:18443`。这是备选路径，必须验证真实公网入站、回包及前缀更新，不能由 IPv6 出站成功推断。

ESA A/AAAA 代理记录可以使用 IPv6 源站；浏览器不必有 IPv6。用户访问 443，回源可以另设 HTTPS 18443；设置回源 Host/SNI 与 Lucky 证书一致，并启用源站证书校验。ESA 边缘 HTTPS 不会自动保证回源证书校验。[DNS 记录](https://help.aliyun.com/zh/edge-security-acceleration/esa/user-guide/introduction-of-dns-related-parameters)、[回源端口](https://help.aliyun.com/zh/edge-security-acceleration/esa/user-guide/back-to-source-protocols-and-ports-1)、[源站证书](https://help.aliyun.com/zh/edge-security-acceleration/esa/user-guide/back-to-source-protocols-and-ports)

Lucky 可更新 ESA DDNS，发布当前受控入口的 IPv6，而不是任取 UDX 上遗留地址。现场 DNS 的 `cpe.jmsu.top` 指向 UDX usb0 地址；它不是 OpenWrt 当前原生 IPv6 地址。前缀重拨后必须更新；旧前缀不能作为源站验收证据。

当前 `cpe6_guard` input priority -15 拒绝新的 usb0 公网 IPv6 TCP 入站。直接回源方案需在该托管门禁中添加精确的端口/来源例外，再配套 fw4；仅增加 fw4 allow 不够。例外应保留额度门禁，缺失/未知额度时不接受新入口，不能开放整个端口范围。可用 ESA 回源节点集合时限定来源并维护更新。[源站防护](https://help.aliyun.com/zh/edge-security-acceleration/esa/user-guide/origin-protection)

现场已有 Lucky `:::8443` 监听。首次使用未匹配规则的 SNI 导致握手被拒绝；改用真实 `cpe-admin.cpe5g-openwrt.origin.jmsu.top` 后，系统 CA 校验成功并返回认证 401，证明这个原有入口的 TLS 正常。现有源站证书于 2026-10-10 到期，公网上线前应完成续期链路验证。`/etc/lucky/cert-sync` 引用的适配器不在设备中，不能由现有证书有效推断自动续期正常。

已有 token 的正确 API 请求头是 `openToken`，不是管理员登录会话的 `Lucky-Admin-Token`；改正后 `/api/info` 与规则读写均成功。旧的错误请求头测试不能作为密钥失效证据。

公网写入前缺少的部署信息：ESA 站点及套餐、可维护配置位置；批准的浏览器 SSH 目标。统一身份提供方可后续接入，临时 Lucky 认证已可用。真实值仅放私有配置/CI Secret 与加密固件，公开仓库不保存客户端密钥、登录凭据或 SSH 私钥。

## SSH 管理

常规远程 SSH 优先走 Tailscale ACL 与现有 Dropbear；不通过 ESA 普通 HTTPS 代理传原始 TCP 22。浏览器 SSH 可以使用 Lucky 现有 Web 终端，本地 Shell 与批准的 LAN SSH 目标分别配置；保留独立 2FA，不让用户输入任意内网目标。现场 UDX 没有发现 SSH 22 监听；ADB 5555 与 UDX 的 7681 网页终端不等于 SSH，不能直接当作 SSH 服务器配置。[Lucky Web 终端](https://www.lucky666.cn/docs/modules/webterminal/)

若把浏览器终端放到公网，建议独立 `ssh.cpe.jmsu.top`，统一认证及批准连接列表，在 ESA 启用 WebSocket 并验证长连接心跳。ESA 免费套餐不支持 WebSocket；普通七层 HTTPS 代理不承载 raw SSH，四层代理为另一个功能及套餐条件。[网络优化](https://help.aliyun.com/zh/edge-security-acceleration/esa/user-guide/network-optimization)、[四层代理](https://help.aliyun.com/zh/edge-security-acceleration/esa/user-guide/configuration)

Lucky 管理面板、Nikki 9090、UDX ADB 和 LuCI 不能作为通用公网后台开放。额度耗尽会关闭蜂窝公网入口；要在这种情况下继续使用公网域名，应另设计 ESA -> 已有 ECS -> Tailnet -> CPE 的回源路径。Tailscale 本身可继续走正常 Ethernet IPv4。

## Nikki 与两出口

现场 Nikki 已运行 `rule` 模式，outbound_interface 未设置，生成配置没有固定 interface-name。一个订阅可用于 WAN/SIM。Nikki 决定 DIRECT/代理，系统路由和 mwan3 决定可用物理出口；不要为切换把出站接口固定到 wan。须检查个别代理节点是否自带 interface-name。[固定 Nikki mixin](https://github.com/nikkinikki-org/OpenWrt-nikki/blob/7b203f6c4c5e94c6c0026acb301090aa1d310e7f/nikki/files/ucode/mixin.uc)

本仓库 Nikki 自行管理 nft/策略路由，生成的 tun.auto-route、auto-redirect、auto-detect-interface 为 false；不应照搬通用 TUN 自动探测设置。已有 LAN/UDX/Tailnet/MagicDNS DIRECT 和 mwan3 bypass 必须保留。[固定 Nikki 启动路径](https://github.com/nikkinikki-org/OpenWrt-nikki/blob/7b203f6c4c5e94c6c0026acb301090aa1d310e7f/nikki/files/nikki.init)

救急时建议复用已有订阅和规则，只代理确实需要的流量。当前启动/每日订阅刷新及每周规则数据更新没有 WAN 健康门禁，仍可能走 SIM；本轮尚未改变这个行为。可追加 CPE 专用“WAN online 才自动下载更新”门禁，首次无本地配置时保持直连或批准一次初始化；不要在每次切换时重启 Nikki。仅手动关闭 Nikki 也可能被下次成功订阅同步重新启用。
