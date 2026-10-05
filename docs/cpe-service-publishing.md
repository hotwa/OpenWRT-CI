# CPE-5G 内网 API 的 HTTPS 发布

## 当前状态与入口边界

2026-10-04 的 `cpe.lucky.jmsu.top` 已可通过 Lucky 临时认证和 UDX 自身登录访问。
现有生产 UDX 入口保持不变。新增实现只允许独立的 `ai.lucky.jmsu.top`，
转发到 CPE 上的 CLIProxyAPI `127.0.0.1:8317`；没有授权其他 LAN 服务。
实现和离线 HAProxy/SSE 验证已经完成，实际 Lucky/ESA 端到端验收须单独记录。
容器、固定 ARM64 镜像及 `/data` 持久化见 [部署合同](cpe-api-container.md)。

本地 [`cpe-5g` skill](../.agents/skills/cpe-5g/SKILL.md) 提供只读设备检查、服务请求
校验和部署规划。受管首次 API 路由能力已实现；上线仍需完成端到端验收；
不能把离线 plan 输出当作服务已发布。实际 LAN 地址、端口、公开域名、公开模型及密钥
文件引用由部署请求提供。示例地址不代表允许连接或发布。

推荐链路：

```text
OpenAI-compatible client: Authorization: Bearer <limited virtual key>
  → https://<approved-service>.lucky.jmsu.top/v1
  → existing lucky.jmsu.top ESA
  → cpe-origin.jmsu.top:18443 over SIM IPv6, HTTPS + mTLS + origin header
  → HAProxy exact Host and path/method route
  → an independent Lucky loopback listener
  → CPE CLIProxyAPI container (or explicitly approved LAN gateway)
  → private vLLM model services
```

当前首次部署使用 `ai.lucky.jmsu.top`；新增前核对现有 DNS 与规则无重名。
每项服务使用明确 Host、LAN 上游和允许的 API 路径，不提供整个 LAN 的通用公网代理。
UDX 的网页认证和 API 的 Bearer 认证分别配置；SSH 仍使用 LAN 或 Tailscale。
模型推理运行在 LAN 服务器，OpenWrt 承担路由和代理。

## 认证与流式请求

Lucky 官方说明 BasicAuth 与应用认证使用同一个请求头而冲突。因此 API 的独立
Lucky 规则应关闭 BasicAuth，并实测原样保留 `Authorization`；UDX 规则保持现有认证。
不能把网页 Cookie 登录当作标准 OpenAI 客户端的认证方案，也不能把 Nginx 的
`proxy_buffering`、`proxy_read_timeout` 当作 Lucky 支持的配置。
来源：[Lucky Web](https://www.lucky666.cn/docs/modules/web/)。

建议 LiteLLM 接收低权限 virtual key，限制模型、路由、预算及并发/速率。
其 virtual key 方案需要 PostgreSQL；master key 和具有 `proxy_admin` 权限的 key
仅用于管理。LiteLLM 访问 vLLM 时使用独立后端 key，从环境或秘密文件读取。
对外只开放请求批准的路径，例如 GET `/v1/models` 和 POST `/v1/chat/completions`；
管理 UI、`/key/*`、模型控制、指标接口保持私网。vLLM 官方提醒其 API key 并不保护
所有端点，不应依赖单一 `--api-key` 发布整个 vLLM 网站。
来源：[LiteLLM virtual keys](https://docs.litellm.ai/docs/proxy/virtual_keys)、
[vLLM security](https://docs.vllm.ai/en/latest/usage/security/)。

LiteLLM 支持以 `hosted_vllm/<model>`、私网 `api_base` 和环境变量后端密钥配置
`model_list`，给客户端提供稳定的模型别名。
来源：[LiteLLM vLLM provider](https://docs.litellm.ai/docs/providers/vllm)。

ESA 当前官方文档给出回源超时默认 30 秒、最多 300 秒；客户端 TCP 空闲超时
默认 30 秒。文档未说明 SSE chunk 是否重置回源超时，因此必须实测首 token 延迟、
流中静默及持续超过 300 秒的响应，不能声称心跳必然消除所有时长限制。
来源：[ESA 回源超时](https://help.aliyun.com/zh/edge-security-acceleration/esa/user-guide/configuring-the-back-to-origin-request-timeout-period)、
[ESA 使用限制](https://help.aliyun.com/zh/edge-security-acceleration/esa/product-overview/limits-on-using-esa)。

LiteLLM 现行文档提供部署级 `litellm_params.keepalive_seconds` 和全局
`litellm_settings.sse_keepalive_ping_interval_seconds`，可从 15 秒起验收。
全局心跳可覆盖等待上游响应头/首 token 的窗口，默认关闭。部署时固定并核对实际
版本，不能假定旧镜像已包含近期修复。提前发心跳已提交 HTTP 200；之后的上游错误
可能成为 SSE error frame，客户端必须检查完整流和结束事件。
来源：[LiteLLM timeouts](https://docs.litellm.ai/docs/proxy/timeout)、
[首 token 前心跳修复](https://github.com/BerriAI/litellm/pull/37322)。

## ESA 与现有源站的复用

现有 `lucky.jmsu.top` Basic 套餐支持 IPv6、自定义 HTTPS 回源端口、源站验证和
mTLS。普通 HTTPS API 不因这些功能需要新增付费站点，但上线时须重新核对剩余规则
配额。复用 `cpe-origin.jmsu.top` 的 AAAA、ACME 与 18443 监听；共享源站 SNI 不要求
源站证书包含新的公共 API Host。ESA 边缘证书必须覆盖实际公共 Host。
来源：[ESA 套餐功能](https://help.aliyun.com/zh/edge-security-acceleration/esa/product-overview/package-function-comparison)。

新增 API Host 的 ESA 配置应独立保存：精确域名匹配、HTTPS 回源端口 18443、
Host 为 API 公共域名、SNI 为现有源站域名、源站证书验证开启、该 Host 专用 mTLS
客户端证书、覆写该路由的回源密钥、强制 HTTPS。当前 UDX 专用客户端证书只绑定 UDX
Host，不能假定新增域名已自动获得它。

API Host 禁用缓存，并核对不存在更高优先级的 POST 缓存命中。官方明确 POST 缓存
优先于绕过缓存。对流响应禁用压缩并设置 `Cache-Control: no-store, no-transform`；
标准 API 客户端遇到网页挑战时，应精确调整相关规则，保留 API key 与速率控制。
来源：[ESA POST 缓存](https://help.aliyun.com/zh/edge-security-acceleration/esa/user-guide/configure-post-cache)、
[ESA 压缩](https://help.aliyun.com/zh/edge-security-acceleration/esa/user-guide/file-compression)、
[ESA 安全设置](https://help.aliyun.com/zh/edge-security-acceleration/esa/user-guide/setup)。

Lucky 当前部署二进制的 Bearer 透传与 SSE flush 尚未验收；应使用实际版本逐跳验证。
参考文档不能替代真实代理链路测试。

## 固件扩展与升级保留

独立、可选且默认关闭的服务 registry 已实现，放在
`/etc/cpe5g-lucky/`，仅接受已批准 Host、私网上游、允许路径/方法、认证方式和
loopback 监听。不要修改现有 UDX v1 manifest 的身份或把 API 子规则塞进 UDX 的
ProxyList。CLI 的 plan JSON 是用户请求描述，不是当前固件接受的 registry。

实施位置：

1. `Scripts/cpe5g-ipv6/lucky-origin.mjs`：增加精确 Host 分流和独立后端；保持 mTLS、
   SNI、单一 Host/header 检查及未知 Host 拒绝。UDX Cookie 处理只作用于 UDX 后端。
   API 自检失败应仅关闭 API 路由，避免让正常 UDX 入口随之停止。
2. `reconcile-lucky-managed.mjs`：服务使用独立名称、key/registry 和完整范围验证；
   管理员禁用及无关规则继续保留。现有协调器会保留无关 Lucky 规则，但不会恢复它们。
3. `ConfigureCpeLuckyRemote.sh`、`restore-lucky-private.mjs`：新文件逐项加入窄白名单、
   生产 schema 校验、恢复事务与回滚。现有恢复仅补缺失文件；更换 ROM 种子不会把
   保留的旧 JSON 自动迁移为新路由。可选 API 错误不应阻断 UDX 私有材料恢复。
4. `ConfigureCpeIpv6.sh`：安装新增模块。现有 keep.d 已保留
   `/etc/cpe5g-lucky/` 和 `/etc/lucky/`；另用 wrtbak 时核对其独立备份范围。
5. 针对配置验证、Host/path/method 拒绝、Bearer 透传、独立故障、恢复/管理员禁用、
   私有包范围和 SSE 增加直接相关测试，再运行新 CI 和实机启动验收。

共享防火墙的当前开放门禁由 UDX ready 决定，UDX 自检失败会关闭共享入口。
如果要求 API 在 UDX 后台故障时继续提供服务，需明确改为各服务独立 readiness，
再由传输层汇总可信状态；不能绕过已有配额、证书或控制器门禁。

公共仓库/skill 不保存注册密钥、API key、Lucky token、DNS key、客户端私钥或
Tailscale state。私有 seed 沿用 CPE B 六槽 Secret 和加密产物门禁，保留现有
内核、NSS 与源码 SHA。服务参数通过明确版本的文件持久化，而非只手工点击一次 UI。

## 验收与回滚

先验证批准的 LAN 上游，再分别检查 Lucky、源站和 ESA。使用低权限测试 key，
秘密通过受限文件读取，不出现在命令参数、日志或报告中。

- 无 key/错误 key/越权模型拒绝；管理路径、错误 Host、错误方法拒绝。
- 普通响应和 `curl -N` 流式响应可用；首 token 等待/流中静默超过 30 秒仍有心跳；
  长流超过 300 秒记录真实行为。200 后的 SSE 错误、客户端取消和额度限制正确。
- 没有 API 缓存命中、压缩、登录/挑战 HTML；超过 8 KiB 的正常请求体也单独测试。
- 原有 UDX 认证、WAN IPv4 主用、SIM 备用、WAN IPv6 禁用和配额门禁保持正常。
- SIM 重连/前缀变化后 DDNS 收敛，新的连接恢复；不要承诺既有 TCP/SSE 会话迁移。

变更前保存本服务相关 cloud/Lucky/registry 配置及校验值，回滚只撤本次精确 Host
和自有条目。远程断 WAN 测试仍需独立救援路径和定时回滚；大量测速、模型下载、
刷机和重启不属于普通发布验收的隐含动作。

公网 IPv6 回源经过 SIM，API 请求和响应都会计入 SIM 流量，即使 IPv4 WAN 正常。
当前 40 GiB 额度保护也适用于新服务。家庭固定宽带 IPv4 并不能自动承担这个 IPv6
源站的上行；高并发或大流量发布需另行评估稳定出口。

## 2026-10-04 SIM 只读观察

电信 `ctnet` 双栈、开机激活、NR 5G/LTE 自动模式、RNDIS 永久模式正常；WAN PPPoE
主用，SIM 备用，WAN IPv6 关闭。约 364 MiB/40 GiB 已用，配额未阻断。RSRP 约
−86～−88 dBm，SINR 3.75～7.61 dB，温度 41.18°C。RSRQ 接口之间值不一致，
不能据此锁频/锁小区。没有执行测速、强制切换或模块固件升级。

18:40:46 至 18:41:23 出现约 37 秒 SIM IPv4 探针离线。日志中还观察到 IPv6 撤址和
ADB timeout；两个后台服务共享一次只接受一个主机连接的 UDX ADB 端口，争用是需要
修复的因素，尚不能据此认定运营商或射频断线。修复应串行化完整 ADB 连接周期并
保留无法获取可信配额时的阻断语义，再作稳定性观察。

本次源码修复在两个服务共用的 `adb.mjs` 中使用现有 util-linux `flock`，
父进程持有 FD 到 TCP 完全关闭，进程死亡由内核释放锁。等待可取消且有期限，
命令使用绝对超时；配额不可用时的保护保持不变。原协议、新增 10 项真实 socket/
跨进程测试、26 项控制器测试和 9 项 bootstrap 测试通过。现场模块具有所需 flock
功能，但本次未替换现场服务；还需要新固件部署及稳定性验收。

另有旧保留 `uhttpd.cpe5g_health` 实例指向缺失的 `/www/cpe5g-health`，反复退出。
当前源码没有该实例的生成逻辑，当前 WAN/SIM 使用 ICMP 探针，公网使用独立源站
自检。2026-10-05 保留配置升级后确认该实例仍在重试；CPE managed reconcile
现仅在实例的 home 恰为此路径且目录不存在时删除它。管理员改为其它路径或
确有目录的实例保留，不创建空页面代替探针。

2026-10-05 已解密并安装 Action `37282283649` 的 Wi-Fi B 镜像，ROM 提交
`7754eb8e3c216b3dbe1b9add6efb95c47ece109c`，sysupgrade SHA-256 为
`bc51ca657dd6f60ed6717ec8ea742d1c19e1339e763fa3c7e3abc0bb5a6814d7`。
通过设备 image test，保留配置和独立 `/data`，ROM 的 ADB/API 文件哈希与
产物一致。启动时 PPPoE 尚未完成，SIM 负责默认 IPv4；PPPoE 后续恢复后
mwan3 自动回到 WAN。WAN IPv6 为 0，SIM IPv6 地址和源站 mTLS/header
readiness 恢复。公网 API 无认证 401、有效认证 200 空列表；尚无 provider
登录，不代表推理或长流验收通过。

该轮发现 agent-runtime 用 `mv -f` 更新已有目录符号链接，会沿目标写入
只读 `/opt` 并使 reconcile 失败。已改为设备 GNU/BusyBox 均支持的 `mv -fT`，
现场 reconcile 返回 ok。另修复 profile 21 在 uv 查询前未 export 安装目录、
普通 SSH 登录缺少 Python PATH 的顺序问题；现场 Python 3.13.15 已可用。
两项都有先复现再通过的隔离回归。此镜像本身不含上述现场修复；后续镜像与
修复后已完成两次整机软重启，容器自动恢复、原有 Multica/Pi 身份、Python PATH、
源站认证和无 fatal/OOM/存储错误均通过；随后实际断电冷启动中同一容器、
身份、Python PATH、AP 与 PPPoE 主出口恢复。

UDX 的旧 IPv6 relay 仍启用了 `16677 → 6677` 和 `8443 → 18443`。一次外部无认证
16677 请求超时，尚未证实它从公网可达，也不能把单次超时视为关闭证明。清理前需
确认模块内部 NAT 和当前入口依赖。本次不据此修改模块转发。

2026-10-05 还发现 Nikki/Mihomo 的 Fake-IP 模式缺少 IPv6 地址池时，即使
`ipv6` 与 `dns.ipv6` 为 true，AAAA 仍返回空列表。CPE B reconcile 仅在
已有 Nikki mixin 且 IPv6 池缺失时补 `fake_ip6_range=fc00::/18`，保留管理员
已有池，复用 Nikki 原生路由/拦截；关闭 CPE 时不修改 Nikki。缺失、保留、
恢复后修复及幂等测试通过。现场 CPE 与 Mac LAN 客户端按域名 IPv6 HTTPS
成功，但此项可能走代理，不能单独证明原生 SIM 出口。

另以临时 procd cgroup 绕过 Nikki，并在 reload 后确认实际 nft bypass 规则，
经 usb0 固定解析 `dns.alidns.com` 到 `2400:3200::1`，TLS 校验通过、HTTP 404
（根路径无资源），抓包确认受管 OpenWrt IPv6 地址与该服务器双向通信。
同方法的 Cloudflare `2606:4700:4700::1111` 请求超时，仅观察到出站 SYN；
不能宣称所有目的地址可直连。临时服务、ACL 已清理。公网 UDX 无认证 401、
有效认证 200，API 无认证 401、有效 Bearer 200 空列表；provider、推理/SSE、
有独立现场救援的真实 WAN-loss 测试仍待验收。


断电冷启动使 SIM 前缀改变，受管 IPv6 地址、回源路由及源站 readiness
随后恢复，公网从短暂 522 恢复到 UDX/API 无认证 401、有效认证 200。
启动早期有 7 次 return-route 错误，均发生于 UDX 路由审计伴随程序就绪前；
伴随程序就绪后错误计数不再增加，受管路由与当前 USB link-local 地址一致。
这不证明任意前缀切换立即生效：DDNS 间隔 120 秒，记录 TTL 600 秒。

Lucky 原生 DDNS 仍报告 SYNC_FAILURE。使用同一专用账号直接验证：
DescribeDomainRecords 可读取正确的新 AAAA，但 DescribeSubDomainRecords 被
RAM 拒绝。拟仅在现有 cpe-origin.jmsu.top 域名资源内增加该查询权限，
须核对并修改实际云策略后再验证任务；不能因公网暂时恢复宣称 DDNS 已修复。
清除 DNS 备注的假设未能解决错误，原备注已恢复，未固化该猜测。
现场补丁不等于新版 ROM：修复构建 Action 37311261178 使用 c3865fd，
默认关闭 debug gate；产物与再次刷写结果需单独记录。
