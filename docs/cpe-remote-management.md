# CPE-5G 远程管理与主备网络

## 接口角色与现场证据

`wan` 是以太网 IPv4 主出口，支持 DHCP 或 PPPoE；`5G` 是同一台 UDX710 的 usb0 IPv4 备用出口；`cpe6` 是 usb0 上的原生 IPv6 控制接口。它不是第三个物理 WAN，不能作为冗余接口删除。

`cpe6` 由 netifd 管理，并负责地址、LAN RA、UDX 返回路由及 SIM IPv4/IPv6 额度门禁。删除它会停止这些状态更新，开机 reconcile 又会重建。LuCI 协议显示为 `SIM IPv6 (usb0)`，保留内部名称及 LAN `ip6class`。以太网 `wan.ipv6=0`，wan6 禁用。

此前 2026-10-04 的只读现场记录确认：WAN 为 PPPoE、默认路由 metric 10；SIM 为 usb0、metric 20；mwan3 两者 online；蜂窝 IPv6 控制器 online。Tailscale 名称为 `cpe-5g-s13.hs.jmsu.top`，身份保存在独立 eMMC `/data/tailscale/tailscaled.state`。

此前独立 Mac LAN 救援和定时回滚实验已验证 PPPoE 断开、WAN 会话仍在但公网被阻断时的新 IPv4 连接经 SIM，以及 WAN 恢复后的自动切回。本机默认路由的假死兜底也已验证。现场 DHCP offer 探测未获得租约，不能把 DHCP 实机切换写成已通过。

WAN 使用三个 ICMP 目标、至少两个成功；失败三轮下线、恢复五轮上线。实际耗时包含每个目标超时，先前故障实验约 25 秒完成 WAN offline 判定。独立本机巡检为五秒，不保证现有 TCP/UDP 会话迁移。ICMP 可达但 DNS/TLS 失败、认证门户、部分目的地故障仍须另行验证，不能承诺覆盖所有异常。

持久服务由 procd 自动启动并 respawn；本机 IPv4 巡检与 UDX 额度/工具维护分别串行运行，UDX 的 ADB 通信等待不再阻塞本机巡检。额度未知或超过现场 40 GiB 上限时，SIM 公网 IPv4/IPv6关闭；私有 UDX 管理路径保留。正常 WAN 在线时蜂窝 IPv6仍消耗 SIM，双栈客户端可能优先选择它。

## Lucky 入口部署清单

当前已部署 Tailnet 和 ESA 公网 UDX 管理入口。公网使用 `cpe.lucky.jmsu.top`，复用现有 `lucky.jmsu.top` ESA 基础版站点；此前讨论的 `cpe.jmsu.top` 没有作为本次公网入口部署。实现、恢复机制及私有编译契约以 [CPE SIM IPv6 与 Lucky 公网管理](cpe-lucky-public-origin.md) 为准。

下面是运行配置清单，不是 Lucky API 导入格式。现有 Lucky 配置通过原生 API 按固定名称和完整范围管理；保留无关规则、账号及显式禁用状态，不以整份配置覆盖实现新增入口。

| 设置 | Tailnet 后台 | ESA 公网后台 |
| --- | --- | --- |
| 用户入口 | `http://cpe-5g-s13.hs.jmsu.top:16800/` | `https://cpe.lucky.jmsu.top/` |
| 监听链路 | Lucky `100.64.0.53:16800` | HAProxy 蜂窝 IPv6 `18443` → Lucky `127.0.0.1:16801` |
| 反代目标 | `http://192.168.66.1:6677/` | `http://192.168.66.1:6677/` |
| 域名/路径 | 完整后台根路径 | 严格匹配公网 Host `cpe.lucky.jmsu.top`，SNI `cpe-origin.jmsu.top`，完整根路径 |
| 认证 | Tailnet ACL、Lucky 临时账号，加 UDX 原有登录 | 回源 mTLS 与固定密钥请求头、Lucky WebAuth/BasicAuth，加 UDX 原有登录 |
| 默认不匹配请求 | 拒绝 | 拒绝 |
| 缓存 | 禁用 | ESA 绕过缓存，现场响应为 `DYNAMIC` |

用户暂不接 OIDC，采用独立 Lucky 临时账号，认证覆盖根页面、API 和静态资源。子规则启用 `EnableBasicAuth` 和 `OtherParams.WebAuth`，`BasicAuthRegConf` 留空，禁用自动开防火墙和缓存。浏览器使用 Lucky 登录 Cookie，机器客户端可用 BasicAuth；临时账号独立于 Lucky 管理员与 Wi-Fi 密码。后续接入 OIDC/2FA 仍须配置身份提供方、客户端及回调。Lucky 管理员登录不自动保护 UDX 反代规则。[Web 服务](https://lucky666.cn/docs/modules/web/)、[功能版本](https://lucky666.cn/docs/updatelogs/v2.X/)

当前外部机器客户端验收：未认证请求返回 401，有效 BasicAuth 返回 UDX 页面 200，UDX 未登录 API 返回 401。公网 HTTPS 链路仅为 `LuckyWebAuthorization_` 登录 Cookie 补齐缺失的 `Secure` 和 `SameSite=Lax`；保留 `HttpOnly`、已有属性、UDX Cookie 和 Bearer 认证头。此前 Tailnet 经 Mac 隧道及直接 MagicDNS 的浏览器登录已通过；本轮本机 DNS 与 TLS 临时错误自行消失后，真实 Edge 浏览器也通过公网 Lucky 登录，UDX `/api/auth/status` 返回 200、`logged_in:false`、`auth_required:true`，受保护 `/api/netif/list` 仍返回 401。未输入 UDX 密码或更改 UDX 设置。

UDX 前端使用相对 `/api/...` 路径，适合独立域名根路径反代，但页面写操作仍未验收。已读取的前端把终端地址拼为 `http://当前域名:7681`，当前入口没有代理该端口，不能宣称网页终端已可公网使用。

Lucky 配置目录 `localips` 非空会替换其默认内网名单。若通过 Tailscale 管理被判定为外网，应保留默认 RFC1918/链路本地范围后补入批准的 Tailnet IPv4/IPv6 网段，避免直接打开全公网管理。[安装与内网名单](https://lucky666.cn/docs/install/)

临时账号、快照及备份只保存在设备和本机私有文件中。私有 CI 种子现已通过六个可选 `CPE_LUCKY_REMOTE_BUNDLE_1..6` Secret 槽位注入，每片不超过 35,000 个 ASCII 字符，目前五片已填写。只有启用 CPE B、原生 IPv6、RE-SS-01 目标及产物加密时才允许注入；种子包含原生 Lucky 管理条目、认证、专用 DNS 凭据与必要 TLS 材料，不包含 CA 私钥或 ESA 客户端私钥。公开仓库、日志及明文产物不保存这些私有值。

sysupgrade 保留清单和私有 ROM 恢复流程已纳入实现：保留已有续期证书、显式禁用状态及无关配置，缺失材料经恢复门禁补齐，事务未完成时公网入口关闭。新固件的编译结果须以对应 Action 为准，刷写和新代码的冷启动验收仍须另行完成；当前在线部署结果不代表这些固件验收已经通过。Tailscale 身份继续保存在独立 eMMC `/data/tailscale/tailscaled.state`。

## ESA 回源与 IPv6 门禁

当前上线链路：

```text
浏览器 HTTPS cpe.lucky.jmsu.top:443 → ESA（强制 HTTPS、绕过缓存）
  → cpe-origin.jmsu.top 的 OpenWrt 蜂窝 IPv6 HTTPS :18443
  → HAProxy（专用客户端证书、精确 Host/SNI、固定回源密钥）
  → Lucky 127.0.0.1:16801（WebAuth/BasicAuth）
  → UDX710 私有 USB HTTP 192.168.66.1:6677
```

原生 IPv6 回源和公网 HTTPS 当前均已连通。ESA 校验源站证书，并提供专用客户端证书给 HAProxy；浏览器自身不必具备 IPv6。公网 Host 与证书 SNI 分别使用上面的固定值，不允许任意 Host 或端口回源。旧 Lucky `:::8443` 公网监听已关闭。[DNS 记录](https://help.aliyun.com/zh/edge-security-acceleration/esa/user-guide/introduction-of-dns-related-parameters)、[回源端口](https://help.aliyun.com/zh/edge-security-acceleration/esa/user-guide/back-to-source-protocols-and-ports-1)、[源站证书](https://help.aliyun.com/zh/edge-security-acceleration/esa/user-guide/back-to-source-protocols-and-ports)

Lucky 原生 DDNS `managed-cpe5g-origin-ipv6` 每 120 秒运行一次，使用受管取址脚本，只发布本机 usb0 已安装、状态可信且额度允许的 IPv6。专用 AliDNS 账号仅修改 `cpe-origin.jmsu.top` 子域，AAAA TTL 为 600 秒；前缀变化后外部缓存仍可能延迟收敛，旧前缀不能作为当前回源证据。此前指向 UDX usb0 的旧记录不属于此原生 OpenWrt 入口。

Lucky 原生 ACME `cpe5g-origin` 使用 AliDNS DNS-01，当前服务器证书有效至 2027-01-02。映射后由固定钩子验证域名、信任链、私钥与有效期，再以同一事务发布服务器证书、私钥和独立指纹文件。授权策略不由续期钩子改写。旧 `cpe5g-openwrt` 外部同步目录及 2026-10-10 到期证书仅是历史配置，不承担新入口续期；不能再依赖其缺失的适配器。

ESA 与本机健康检查的 mTLS 客户端证书有效期为五年，需要到期前人工轮换。服务器 ACME 自动续期不包含这组客户端凭据的轮换，CA 私钥及 ESA 客户端私钥不进入 CPE 固件。

`cpe6_guard` 与 fw4 为 TCP 18443 执行双重门禁，仅允许 IPv6 控制器授予的短期授权。额度未知、超限、地址状态不可信、监听认证自检失败或证书/恢复事务未完成时均关闭入口，包括已有连接；只加 fw4 allow 无法绕过这一门禁。不开放其他 WAN IPv6 或整个 LAN。回源 mTLS 和固定密钥进一步限定被授权的 ESA 链路。

若运营商以后阻断原生入站，可另验证 UDX IPv6 relay 转发至 `192.168.66.2:18443`。该备选路径当前未作为上线方案使用，必须单独验证真实公网入站、回包和前缀更新，不能从出站成功推断。

Lucky 原生管理 API 的正确请求头是 `openToken`，不是管理员会话的 `Lucky-Admin-Token`。实际 token 仅保存在私有配置中，不因添加公网入口开放管理 API。批准的浏览器 SSH 目标、统一身份提供方和 2FA 仍属于后续独立配置。

## SSH 管理

常规远程 SSH 优先走 Tailscale ACL 与现有 Dropbear；不通过 ESA 普通 HTTPS 代理传原始 TCP 22。浏览器 SSH 可以使用 Lucky 现有 Web 终端，本地 Shell 与批准的 LAN SSH 目标分别配置；保留独立 2FA，不让用户输入任意内网目标。现场 UDX 没有发现 SSH 22 监听；ADB 5555 与 UDX 的 7681 网页终端不等于 SSH，不能直接当作 SSH 服务器配置。[Lucky Web 终端](https://www.lucky666.cn/docs/modules/webterminal/)

若后续单独批准浏览器终端公网入口，应配置独立域名、统一认证及批准连接列表，核对现有 ESA 套餐的 WebSocket 能力并验证长连接心跳。当前 UDX 入口没有开放浏览器 SSH；普通七层 HTTPS 代理不承载 raw SSH，四层代理为另一个功能及套餐条件。[网络优化](https://help.aliyun.com/zh/edge-security-acceleration/esa/user-guide/network-optimization)、[四层代理](https://help.aliyun.com/zh/edge-security-acceleration/esa/user-guide/configuration)

Lucky 管理面板、Nikki 9090、UDX ADB 和 LuCI 不能作为通用公网后台开放。额度耗尽会关闭蜂窝公网入口；要在这种情况下继续使用公网域名，应另设计 ESA -> 已有 ECS -> Tailnet -> CPE 的回源路径。Tailscale 本身可继续走正常 Ethernet IPv4。

## Nikki 与两出口

现场 Nikki 已运行 `rule` 模式，outbound_interface 未设置，生成配置没有固定 interface-name。一个订阅可用于 WAN/SIM。Nikki 决定 DIRECT/代理，系统路由和 mwan3 决定可用物理出口；不要为切换把出站接口固定到 wan。须检查个别代理节点是否自带 interface-name。[固定 Nikki mixin](https://github.com/nikkinikki-org/OpenWrt-nikki/blob/7b203f6c4c5e94c6c0026acb301090aa1d310e7f/nikki/files/ucode/mixin.uc)

本仓库 Nikki 自行管理 nft/策略路由，生成的 tun.auto-route、auto-redirect、auto-detect-interface 为 false；不应照搬通用 TUN 自动探测设置。已有 LAN/UDX/Tailnet/MagicDNS DIRECT 和 mwan3 bypass 必须保留。[固定 Nikki 启动路径](https://github.com/nikkinikki-org/OpenWrt-nikki/blob/7b203f6c4c5e94c6c0026acb301090aa1d310e7f/nikki/files/nikki.init)

救急时建议复用已有订阅和规则，只代理确实需要的流量。当前启动/每日订阅刷新及每周规则数据更新没有 WAN 健康门禁，仍可能走 SIM；本轮尚未改变这个行为。可追加 CPE 专用“WAN online 才自动下载更新”门禁，首次无本地配置时保持直连或批准一次初始化；不要在每次切换时重启 Nikki。仅手动关闭 Nikki 也可能被下次成功订阅同步重新启用。
