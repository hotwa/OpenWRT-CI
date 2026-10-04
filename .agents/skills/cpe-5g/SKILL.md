---
name: cpe-5g
description: 检查 RE-SS-01 CPE-5G 的 SSH、WAN/SIM 备份、IPv6、Lucky 入口与独立 CLIProxyAPI 容器，并为明确指定的 API 配置与 Lucky＋ESA 发布提供实施指导。
---

# CPE-5G

用户的 CPE 为 OpenWrt RE-SS-01，LAN `192.168.13.1`，UDX710 管理地址 `192.168.66.1:6677`，usb0 `192.168.66.2`。以太网 WAN 的 DHCP/PPPoE IPv4 优先，SIM IPv4 备用；IPv6 只来自 SIM。Tailnet 名称 `cpe-5g-s13.hs.jmsu.top`。这些是当前实例的发现线索，以实机与用户提供的 profile 为准。

## 检查与连接

先读 [references/connection.md](references/connection.md)。使用现有维护密钥和已验证的主机指纹，经 Mac 跳板或 Tailnet 连接；把连接参数与凭据**路径**存于仓库外的本机私有 profile。帮助脚本不读取云凭据或 API 密钥，不向远端复制维护私钥。

```bash
python3 scripts/cpe5g.py status --profile /root/.config/cpe-5g/profile.json
python3 scripts/cpe5g.py api-status --profile /root/.config/cpe-5g/profile.json
```

脚本仅收集白名单状态，不写设备、不测速、不扫描内网。解释 WAN 协议、mwan3 在线状态、SIM 配额、IPv6 控制器与 UDX 公网源站就绪；`udx_origin.ready` 只证明现有 UDX 入口，不能据此断言未来 API 已发布。SIM 优化检查可读 APN、双栈、频段、信号与小量现有日志；先区分真实掉线与探针/路由问题，不能从合同速率字段推断实测速度。远程断 WAN、重启或刷机必须遵循仓库的独立救援与限时回滚要求。

需要浏览器操作时先加载并遵循当前环境的 `kimi-webbridge` skill，使用同一任务标签组。若 skill 或所需工具缺失，说明缺项并询问替代方式；SSH 只读工作可以继续。优先读取控制器 status 和已登录 UDX HTTP；多个 agent 直接 ADB 会与永久 worker 竞争，配额读取失败可能短时禁用 SIM。确需 ADB 时复用固件有锁 transport 与批准命令，不直开 `5555`。不要输出 SIM 标识、登录 cookie、Lucky token、云密钥或完整配置。

## CPE API 与明确端点发布

先读 [references/publishing.md](references/publishing.md)。用户提出具体发布任务时，沿用其已有授权；缺少内网地址/端口、精确公网域名或应用鉴权引用时，只补齐这些必要信息，继续做不依赖它们的工作。以用户明确给出的端点为对象，不发现并发布其他 LAN 服务。

仓库已实现 CPE B 独立 headless CLIProxyAPI v8.0.13 ARM64 容器（nerdctl 2.4.1、`127.0.0.1:8317`）及 `ai.lucky.jmsu.top` 的三个精确 API 路由，经 Lucky `16802`、HAProxy `18443` 与 ESA mTLS。2026-10-04 实机 CPA 容器已启动，鉴权 `/v1/models` 返回 200 空列表；尚未 OAuth/provider 登录，公网 AI 链路及冷启动仍待验收。代码与 fixture 成功不代表这些后续 gate 通过。`api-status` 仅检查固定运行时/容器资源与独立 `api-ready.json`，不读取 config、keys 或 auth，不证明公网推理。私有管理 SSH forward、全新 OAuth 与明确 upstream 配置读发布参考。脚本无 `publish` 命令，离线规格也不是固定 CPA 的运行注册格式。

```bash
python3 scripts/cpe5g.py validate --service /path/to/service.json
python3 scripts/cpe5g.py plan --profile /root/.config/cpe-5g/profile.json --service /path/to/service.json
```

[references/service.example.json](references/service.example.json) 是关闭状态的规划样例，示例 IP 与域名不构成发布授权。规划 JSON 不能安装为固定 CPA 的 `api-service.json`。接口保持应用的 `Authorization: Bearer`，不要套 UDX 浏览器 Basic/WebAuth；管理 API、OAuth 回调、密钥管理保持私有，凭据持久化在 `/data/compose/cpe-api/`，不复制现有 Windows/WSL CPA 登录状态。

`public.routes` 逐项绑定请求方法与路径；保留用户批准的精确配对，不能用两个全局列表组合出额外权限。

查找 profile 中的 firmware 仓库，先读该仓库 `AGENTS.md`、`docs/cpe-service-publishing.md` 与相关现有代码。修改只针对 CPE B 的受管服务注册、精确 Host 路由、独立 Lucky 规则、私有 CI 注入/恢复及相关测试。保留 UDX 入口、WAN/SIM 策略和精确源码/kernel/NSS pin。秘密不进入公共仓库/固件；私有固件注入使用现有加密流程与 CI Secret，应用 provider/OAuth 留在受限持久数据目录；保留配置的 sysupgrade 不会自动用新 ROM 覆盖旧 JSON，必须设计兼容恢复和迁移。

完成时分别报告：检查到的现状、实际改动、已通过的验证、仍待部署的部分。发布验收包括无密钥拒绝、Bearer 请求、JSON 与 SSE、取消上游请求、无缓存、不同 Host 隔离以及公网实际调用；不能只看到 HTTPS `200` 就宣布成功。
