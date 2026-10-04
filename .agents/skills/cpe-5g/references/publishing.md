# API 发布：现有边界与实施路径

当前部署：`cpe.lucky.jmsu.top` → 已有 ESA 站点 `lucky.jmsu.top` → DNS 源站 `cpe-origin.jmsu.top:18443`（SIM 的动态 IPv6，HTTPS + 专用 mTLS + `X-CPE-Origin`）→ HAProxy 精确 UDX Host → Lucky `127.0.0.1:16801` → UDX `192.168.66.1:6677`。UDX 在 Tailnet 的独立入口为 `:16800`。现有源站和 UDX 认证可用不代表服务发布能力已经存在。

建议模型入口：明确批准的新域名 → 同站点 ESA → 复用源站 DNS/SNI/cert → HAProxy 精确 Host → 独立 Lucky loopback backend → 内网 LiteLLM → 私有 vLLM。实际端口由注册表分配并检查占用；`16802` 只是第一个候选。先保留一层网关对虚拟 key 的预算、并发和模型权限控制，别把 vLLM 的所有接口直接暴露。

## 规格与授权

把用户指定的地址、端口、协议、精确公网域名、允许的方法与路径配对、应用 key 引用与流式超时写为 service JSON，再 `validate`/`plan`。`public.routes` 逐项声明 `{method,path}`，例如只允许 `GET /v1/models` 和 `POST /v1/chat/completions`，不可把全局 method 列表与 path 列表相乘扩大权限。样例关闭，规划格式不会被当前固件执行。用户给出明确发布任务和端点就是该范围的授权，无需再问一次常规可逆配置；其他公网服务、付费站点或破坏性操作不因本 skill 而自动获授权。

脚本仅接受显式 RFC1918/ULA IP，不解析主机名、不扫描 LAN、不读取 key 引用；若实际用户需要不同上游拓扑，应按其请求调整校验并记录真实路由边界，而非偷偷改成另一台示例主机。

鉴权使用应用 `Authorization: Bearer <virtual-key>`。UDX 的浏览器 Basic/WebAuth 会与标准 API Bearer 同占 `Authorization`，不能套给模型客户端。认证是否有效必须用无/错误 key 与有效 key 分别验收。公开的 API allowlist 不包含管理页面、密钥管理、内部健康/metrics；未知 Host 与未批准路径保持拒绝。

若用户希望浏览器登录后免手动 Bearer 调用，应另建受认证的 UI/BFF，由服务器保管限权 key；不能把 UDX Basic 叠在标准 API 上，也不能把 master key 送给浏览器。目前本 skill 的 API 规划仅支持上游 Bearer，不会自行部署 BFF。

## 首次发布必须实现的固件扩展

在持久 firmware 仓库阅读 `docs/cpe-service-publishing.md` 与以下模块，先确认是否已有后续实现，避免重复造一套受管配置。当前可识别的是 UDX 专用 v1：

- `Scripts/cpe5g-ipv6/lucky-origin.mjs`：`haproxyConfig` 固定单 Host 和 `16801`。需要独立可选 service registry、精确 Host→loopback backend ACL 和逐项 method/path 匹配，保留 SNI、mTLS、源站 header 和未知 Host 拒绝。UDX cookie/header 修改只作用于 UDX backend。不能用 wildcard Host 或 method/path 笛卡尔积代替注册。
- `reconcile-lucky-managed.mjs`：UDX 规则只允许一个固定子规则。给 API 独立名称、ID、key registry 和恢复逻辑，不能塞进 UDX `ProxyList`。未受管手工 Lucky 规则可能保留，但不会自动重建，也不能突破 HAProxy Host 限制。
- `lucky-origin.mjs` 的 `probeOrigin` 与 `public-access.mjs`：现有 readiness/nft 放行依赖 UDX。设计 API 独立健康结果，避免一个 API 失败停掉 UDX；也要明确 UDX 故障时 API 是否被共同 gate 阻断。不能只增加一条路由而忽略共享就绪条件。
- `Scripts/ConfigureCpeLuckyRemote.sh`、`restore-lucky-private.mjs`：现有私有文件白名单和生产 validator 不接受任意新文件。新增可选 JSON 的窄白名单、校验、独立 restore journal，保留现有 UDX v1 manifest。保留配置升级采用 missing-only 恢复，旧 JSON 不会被 ROM 自动覆盖；新功能要做显式兼容迁移。
- `Scripts/ConfigureCpeIpv6.sh`：模块安装名单、keep.d 与启动恢复入口一起检查。可选 API 错误需局部禁用，不应破坏已存在的 UDX 服务或 WAN/SIM 自动恢复。

相应测试应覆盖默认没有 registry 时原行为不变、未知 Host/路径拒绝、Bearer 保留、UDX header 隔离、端口/ID 冲突、可选 registry 坏配置、恢复/迁移以及独立 readiness。运行直接相关测试；随后按仓库 workflow guard 完成私有 CI 与加密产物校验。未经实机验收的新固件不能称为已部署。

## ESA 与应用设置

已有 `lucky.jmsu.top` Basic 站点支持 IPv6、HTTPS、自定义源站端口和 mTLS；同站点新域名通常复用源站 AAAA/DDNS。当前 CPE DNS 子账号只管理 `cpe-origin.jmsu.top`，不要为 AI 域名扩大其 DNS 权限。新增 ESA 精确 public Host 的源站规则、已有 origin SNI、该 Host 授权的专用 mTLS 客户端和源站 header；当前 UDX 客户端证书仅分配给 UDX Host，不能假设新 Host 自动继承。

API 域名必须绕过缓存，同时排除 POST cache（其规则优先级可覆盖普通绕过）。SSE 检查缓冲、内容优化、压缩及 `Cache-Control: no-transform`；机器接口避免返回 JavaScript challenge/HTML 验证页，使用最窄的 API 规则并保留鉴权和限速。不要为适配 API 全站关闭其他业务的保护。

ESA 默认源站请求超时 30 秒，可设到 300 秒。官方文档不足以证明超过 300 秒的 SSE 一定断开或一定持续，应在真实链路测试首 token 延迟、持续心跳与长流。LiteLLM 的 keepalive 要按实际安装版本核对；支持时在网关启用约 15 秒心跳，包括等待首 token 的阶段。先发送心跳可能提前提交 HTTP 200，后续错误通过 SSE frame 返回，因此测试同时检查错误与结束标记。

参考官方资料：

- [ESA 套餐功能](https://help.aliyun.com/zh/edge-security-acceleration/esa/product-overview/package-function-comparison)
- [源站请求超时](https://help.aliyun.com/zh/edge-security-acceleration/esa/user-guide/configuring-the-back-to-origin-request-timeout-period)
- [POST cache](https://help.aliyun.com/zh/edge-security-acceleration/esa/user-guide/configure-post-cache)
- [内容压缩](https://help.aliyun.com/zh/edge-security-acceleration/esa/user-guide/file-compression)
- [LiteLLM keepalive](https://docs.litellm.ai/docs/proxy/timeout#keepalive-pings-for-idle-streaming-connections)

## 实际调用验收

在用户批准的端点上做少量推理请求：无 key/错误 key 拒绝为预期 JSON 状态；有效 Bearer 返回指定模型；普通响应与 SSE 正常；延迟首 token、心跳空闲和超过 300 秒的长流符合预期；大于 8 KiB 的实际业务请求不过度受 WAF 检查范围影响；不同身份不复用缓存；客户端取消能停止上游生成；并发/预算限制生效。使用固定少量测试 token，不进行吞吐压力测试。

实机网络验收分别记录 WAN 正常、SIM 后备、IPv6 前缀变化和配额受限的行为。公网 IPv6 源站在 WAN 正常时仍使用 SIM，计入 40 GiB 限额。mwan3 切换不迁移已有 TCP/SSE 连接；客户端要重试新连接，不能要求跨出口保留原流。真实断 WAN 测试需要独立救援和限时恢复，不能仅凭 SSH 会话仍在线就执行。
