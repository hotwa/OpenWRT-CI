# API 发布：实现与部署边界


2026-10-06 更新：已保留配置安装 Wi-Fi B Action `37400726446`，ROM `50e37ae`；USB 热插拔修复及上述 agent-runtime/Python/uhttpd/Nikki 修复已包含在 ROM。升级启动后同一 API 容器自动恢复，原 Tailnet/Multica Agent 身份、PPPoE、SIM IPv6、IoT AP 和公网认证检查通过。Lucky 原生 DDNS 仍为 SYNC_FAILURE，公网可达不能替代任务验收，实际原因需继续核对。此版本未追加两次软重启、断电冷启动或物理 USB 插拔；旧版本记录不得移作新版验收。provider 登录与推理/SSE 仍待验收。

## 固定 CPE B 模型入口

仓库已实现 CPE B 独立、无浏览器的 CLIProxyAPI 容器。2026-10-05 已安装 Action `37282283649`（ROM `7754eb8`），保留配置与真实 eMMC `/data`；同一容器在两次软重启及断电冷启动后自动恢复，配置哈希与身份保持一致，资源限额和 loopback 绑定正常。公网 UDX 无认证 401、有效认证 200；API 有效 Bearer 200 空列表、无认证 401。无 OAuth/provider，不能据此宣称推理可用。历史间歇 ESA 522 仍需长期观察，真实 JSON/SSE 推理、取消和无缓存待验收；冷启动换前缀后公网恢复，DDNS 查询权限报错仍待修复。现场补丁解决 agent-runtime 目录符号链接更新、Python profile export、旧 uhttpd 探针与 Nikki 缺失 IPv6 Fake-IP 池；旧 ROM 不包含这些补丁。执行前阅读 firmware 仓库的 `docs/cpe-api-container.md`、`docs/container-runtime-test.md`、`docs/cpe-service-publishing.md` 与 `Scripts/cpe5g-api/model.mjs`、`Scripts/cpe5g-ipv6/api-service-registry.mjs`。

固定实现使用 nerdctl **2.4.1** 与官方 CLIProxyAPI **v8.0.13** Linux ARM64 manifest：

`docker.io/eceasy/cli-proxy-api@sha256:913f5db831ef5919ff63edb5f818df7dd8c821a18d36a92145449a8d8a1b787d`

CPE B opt-in，A 与普通工作流不启用。应用使用 host network，但必须只监听 `127.0.0.1:8317`；192 MiB、0.5 CPU、128 PID。固定 ROM OCI archive 可离线导入，启动不拉取网络镜像，也不启动第二个 containerd。nerdctl 2.4.1 的 image inspect 无法解析此长 digest 引用；实现以固定本地 `docker.io/eceasy/cli-proxy-api:v8.0.13` alias 检查 `RepoDigests` 中的精确 ARM64 manifest，并由 ctr 验证本地 alias 实际 TARGET digest，不能只信任 tag。`/data` 必须为真实 ext4/f2fs 块设备挂载；配置、凭据及 OAuth 状态持久化在 `/data/compose/cpe-api/` 的 `config.yaml`、`credentials.json`、`auth/`。已存在数据、管理员关闭状态和不同镜像 pin 均保留，变更需明确迁移。

批准链路为 `ai.lucky.jmsu.top` → ESA → `cpe-origin.jmsu.top:18443`（SIM 动态 IPv6、HTTPS、专用 mTLS、`X-CPE-Origin`）→ HAProxy 精确 Host/method/path → Lucky `127.0.0.1:16802` → CPA `127.0.0.1:8317`。只有以下三组请求可公开：

- `GET /v1/models`
- `POST /v1/chat/completions`
- `POST /v1/responses`

保留应用 Bearer，不套 UDX Basic/WebAuth；管理 API、面板、OAuth 回调、metrics、插件和未批准路径不公开。未知 Host、额外路径/方法及含查询串的非精确 URL 不应获得额外权限。UDX 仍使用 `cpe.lucky.jmsu.top`、Lucky `16801` 和独立 Tailnet `16800`；API 故障应只撤下 API 路由，不能破坏 UDX。

固定受管 registry 为 `/etc/cpe5g-lucky/api-service.json`，运行时字段/格式由 `api-service-registry.mjs` 严格校验，默认关闭。独立 API Lucky rule/keys、私有注入、missing-only 恢复、HAProxy allowlist 与 `/var/run/cpe5g-lucky/api-ready.json` 已实现。API readiness 检查原生 Lucky 受管规则与无/错误 Bearer 的 401；独立结果仍标识 `shared_gate: udx`，UDX 公共源站 gate 故障会阻断整个入口。`ready=true` 不证明 ESA 实际调用、OAuth 已登录或模型可用。

## 私有管理、全新 OAuth 与明确上游配置

此 CPA 实例独立于用户 Windows/WSL 的 CPA。未来用户要求登录时，在已部署且核实 pin 的 `cpe-api` 容器中先运行固定二进制的 `-help`，确认 v8.0.13 实际支持的 provider login、no-browser、callback 端口与流程，再执行用户指定 provider 的**全新 OAuth**。不复制其他 CPA 的 auth、provider key 或凭据。认证数据应由流程直接写到容器挂载的 `/root/.cli-proxy-api`（设备 `/data/compose/cpe-api/auth/`），不提交 Git/固件或回显给聊天。

管理服务保持 `management.allow-remote=false`，管理 key 与 client key 分开，内置面板与自动面板下载关闭。使用已验证 SSH profile 建立本机 loopback forward，例如在复用 profile 的 identity、known_hosts、jump 参数的 SSH 命令中加入 `-N -L 127.0.0.1:18317:127.0.0.1:8317 -o ExitOnForwardFailure=yes`；仍需管理鉴权。不要开启公网管理或更改 CPA wildcard bind。OAuth 的 callback 端口先从实际 help/登录提示确认，仅为该次登录建立必要的本机 loopback forward；完成后关闭隧道。浏览器登录依照 `kimi-webbridge` 路由，工具缺失时按仓库规定询问替代方式。

用户明确指定 upstream provider/base URL、模型映射和凭据引用后，才按固定 v8.0.13 schema 配置该 provider。读取仓库使用的固定版本示例，给受限私有配置制作备份，保留 listener、auth-dir、管理限制、日志限制、插件关闭与镜像 pin，使用本机安全文件/引用传递秘密，不把值放到命令行或聊天。生产 validator 支持普通 block provider lists，拒绝 aliases/tags、多文档、复杂 flow maps/block scalars；新增确需的 YAML 格式应先修改 validator 并做 fixture 验证，不能绕过校验启动。现有配置不会被模板覆盖；按批准的维护窗口重载并验证既有 OAuth 保存情况。配置上游不会自动启用公网 registry、Lucky 或 ESA，也不授权发现/发布其他 LAN 服务。

首次部署严格遵守 `docs/cpe-api-container.md` 的固定镜像、真实数据挂载、容器和 firmware device gates；本技能帮助脚本没有部署命令。没有 provider 时，鉴权的 `/v1/models` 返回 200 空列表只证明 listener/client auth，不能宣布可推理。

## 其他明确指定的 API

`validate`/`plan` 仍支持用户指定的 RFC1918/ULA 内网 API **离线规划**。`references/service.example.json` 的 `{version,name,public,upstream,...}` 与固定 CPA registry 格式不同，不能安装为 `/etc/cpe5g-lucky/api-service.json`，也不能借样例地址扩展发布授权。单独添加 Lucky 规则不能绕过 HAProxy 精确 Host。其他端点须按批准范围修改受管 registry、路由、私有注入/恢复与验证；不扫描 LAN、不通配 Host、不以两个全局列表相乘扩大 method/path 权限。

## ESA 与实际验收

保持专用 mTLS、源站 SNI/header 和每个精确 Host 的云规则；不要假设 UDX Host 的 ESA 客户端证书或规则自动覆盖 AI Host。DNS 子账号继续只管理现有 `cpe-origin.jmsu.top`，不因 AI 域名扩大权限。API Host 禁用普通/POST 缓存，检查 SSE 缓冲、内容优化、压缩与 `no-transform`；机器接口不能返回 JS challenge/HTML 验证页。源站 timeout 按该 Host 配置并实测，CPA 固定 15 秒 streaming keepalive 不保证超过云超时的长流一定成功。

授权部署后做少量真实调用，分别记录无/错误 key 401、有效 Bearer models、实际指定模型 JSON/SSE、延迟首 token、心跳长流、取消停止上游、无缓存及 Host/path 隔离；不做压力测试。还需记录实机 loopback/WAN 暴露、cgroup 限制、缺镜像/挂载安全失败、现有 OAuth 保留及停止/重启恢复。真实重启、冷启动与 WAN-loss 测试遵循独立救援、维护与限时回滚要求。SIM 公网 IPv6 源站流量计入配额，mwan3 不迁移既有 TCP/SSE 会话。

完成报告区分：仓库实现、fixture 验证、实机部署、云端规则、OAuth/provider 配置及公网调用。没有证据的阶段明确标记待验证。
