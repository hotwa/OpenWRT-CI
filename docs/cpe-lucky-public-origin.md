# CPE SIM IPv6 与 Lucky 公网管理

此配置仅用于 CPE-5G B 的私有加密固件，底层源码仍固定为
`VIKINGYFY/immortalwrt@0bad892975fe49fd180f99b414a7f168bb694dd7`。
普通固件的 `/etc/cpe5g/public-origin.json` 默认关闭。

## 入口与线路

```text
https://cpe.lucky.jmsu.top
  → 现有 lucky.jmsu.top ESA，HTTPS、禁用缓存、强制 HTTPS
  → cpe-origin.jmsu.top 的 SIM 原生 IPv6，TCP 18443
  → OpenWrt HAProxy：专用客户端证书 + 固定 Host/SNI + 回源密钥
  → Lucky 127.0.0.1:16801：临时账号认证
  → UDX710 http://192.168.66.1:6677：保留 UDX 自身登录
```

公网入口仅代理 UDX 管理网页。Tailscale 内保留
`http://cpe-5g-s13.hs.jmsu.top:16800/`；OpenWrt SSH 继续使用
Tailscale 或 LAN 密钥登录。此方案不开放 LAN 整网、SSH 或 ADB 到公网。

以太网 WAN 只使用 IPv4，DHCP/PPPoE 的账号及协议由用户配置。
mwan3 的 WAN 优先、usb0 备用策略不因公网入口改变。SIM IPv6 持续用于此入口，
Lucky 与 HAProxy 的 Nikki 服务 cgroup 旁路保证控制流量按实际路由发送。
已有 TCP 会话不会跨故障切换迁移，验收切换应检查新连接。

CPE B 同时带有 mwan3 混合规则表兼容补丁。Tailscale 1.102.3 在共享 mangle
基础链中写入原生 nft connmark 规则，见其固定版本
[实现](https://github.com/tailscale/tailscale/blob/v1.102.3/util/linuxfw/nftables_runner.go)。
这会使现场 iptables 1.8.10 的整表读取失败。兼容层仅读取 mwan3 自有链，
通过 nft 元数据确认基础链的精确跳转；卸载只移除这些跳转与自有链，
保留 Tailscale 和其他服务规则。恢复协调不再通过删除共享 mangle 表修复故障。
实现仅依赖固件根文件系统的 shell、jq 和 nft，不依赖早期开机尚未就绪的 eMMC Node。

## 原生 DDNS 与证书

Lucky 的 `managed-cpe5g-origin-ipv6` 原生 DDNS 使用
`/usr/libexec/cpe5g-ipv6/select-origin-ipv6`。脚本仅输出本机 usb0 已安装、
状态新鲜且配额允许的受管 IPv6 地址；SIM 断开、流量超限或状态不可信时无输出。
运营商前缀变化时重新取址，不把当前前缀写死进固件。
轮询 120 秒，AliDNS 免费子域 TTL 为 600 秒，外部 DNS 缓存仍可能延迟收敛。

专用 RAM 用户只能修改 `cpe-origin.jmsu.top` 子域的记录，
另有只读域名列表权限。Lucky 自定义后缀追加 `jmsu.top`，避免将该子域误认为
根域 `jmsu.top`。此账号不获得整个主域的写权限。
子域 CAA 为 `0 issue "letsencrypt.org"`，仅允许 Let's Encrypt 签发；
CAA 查询取最近的非空记录，规则见 [RFC 8659](https://www.rfc-editor.org/rfc/rfc8659.html)。

Lucky 原生 ACME 任务 `cpe5g-origin` 使用 DNS-01，日常检查时间为 03:15，
证书剩余 30 天时续期。映射目录为 `/etc/lucky/cert-sync/cpe5g-acme`；
映射完成执行固定证书部署钩子。钩子验证系统信任链、域名、私钥匹配及有效期，
把证书、私钥与 DER 指纹作为同一事务更新到
`/etc/lucky/cert-sync/cpe5g-origin/current`。
授权策略独立保存，续期不改写管理员的关闭操作。

ESA 的专用客户端证书和本机健康检查证书有效期为五年，客户端 CA 为十年；
这组 mTLS 凭据需要到期前人工轮换，不能将原生 ACME 续期等同于客户端证书续期。
CA 私钥与 ESA 客户端私钥不进入 CPE 固件。

## 启动、升级和恢复

`cpe5g-lucky-origin` 的 procd 启动任务先等待 `/data` 的 ext4 挂载，以及实际存在的
wrtbak 首启恢复终态。只有旧 UCI 配置、没有 wrtbak 程序的设备不会无限等待。
随后恢复缺失的私有材料，按固定名称和完整范围补齐三个原生 Lucky 管理条目，
刷新 Nikki 的服务旁路，最后启动回源监听。

Lucky 新建条目会自动分配 ID。实际 ID 写入独立的
`/etc/cpe5g-lucky/managed-native-keys.json`，不改写凭据 manifest。
已有条目的禁用状态、认证信息以及无关配置均保留。
发现同名歧义、监听冲突或身份不一致时，公网启动保持关闭。
域名后缀使用原生全局配置 API 追加；该 API 不支持 CAS，应避免同时编辑全局配置。

`keep.d/cpe5g-lucky` 将 Lucky、授权策略和私有材料加入 sysupgrade 保留范围。
私有 ROM 种子可恢复缺失材料，保留已续期的有效证书。
证书部署和私有恢复各有持久化事务日志；日志未完成时，监听与防火墙授权都关闭。
断电恢复仅处理本任务自己写入的文件，不覆盖管理员策略。
旧配置显式 `enabled:false`（包括历史通用默认值）继续保持关闭。

Tailscale 状态仍保存在 `/data/tailscale/tailscaled.state`，不作为编译密钥提交或打包。
若另行使用 wrtbak，须明确把 Lucky/CPE 文件加入其备份范围；wrtbak 的默认范围
不等同于 sysupgrade 的 keep.d。

## 编译与验收

私有包通过六个可选 GitHub Secrets `CPE_LUCKY_REMOTE_BUNDLE_1..6` 注入。
每片最多 35,000 个 ASCII 字符，从第 1 片连续填写，未使用的末尾 Secret 应清空或删除。
GitHub [Secrets 限制](https://docs.github.com/en/actions/reference/security/secrets)为 48 KB；
35,000 字符为 CLI 本地加密和 base64 传输留出余量；本次 48,000 明文字符上传已返回
HTTP 422 `Value is too large`，因此改用这个保守分片上限。
本次 165,172 字符的包需要五片；实际 `gh secret set` 五片全部成功才算完成上传验收。
只允许固定的 15 个文件（其中 14 个必需）、连续分片、严格 gzip/base64/tar、
256 KiB 压缩与展开上限、单文件 64 KiB 上限及语义检查，分片增加不扩大文件或权限范围。
必须同时启用 CPE B、原生 IPv6、RE-SS-01 目标和产物加密。
认证密码、DNS 密钥和私有材料不得进入公开仓库、日志或明文 artifact。

回源 TCP 18443 的 fw4 双重过滤只接受受管 IPv6 控制器授予的短期授权。
控制器缺失、旧版本、流量超限、监听未通过认证自检、证书事务未完成时均拒绝，
包括已建立的连接。开放其他 WAN IPv6 或放行整个 LAN 均不能替代这一门禁。

验收须分别记录：原生 DDNS、自动证书映射、回源 mTLS/密钥拒绝、Lucky 临时认证、
UDX 自身登录、ESA HTTPS/禁缓存、WAN 主路由和配额状态。
一次在线补丁验收不等于新固件已刷入或完成冷启动门禁。
远程断 WAN 测试仍须独立救援路径与定时回滚。

2026-10-04 在线验收已确认原生 DDNS 和 ACME 签发、证书部署、控制器门禁与 ESA 回源。
外部 HTTPS 的无认证/错误认证为 401、正确临时认证为 200，重复未认证请求仍为 401；
响应缓存状态为 `DYNAMIC`，HTTP 跳转 HTTPS。真实 Edge 浏览器也通过 Lucky 登录，
UDX 的未登录状态为 `auth_required:true`，受保护 API 保持 401；未输入 UDX 密码或执行后台写操作。
WAN PPPoE 主路由、SIM 备用路由、40 GiB 额度与 eMMC Tailscale 状态均在只读核对中正常。
