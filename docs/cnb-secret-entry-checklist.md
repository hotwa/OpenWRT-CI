# CNB secret 待填清单（只有名称；**此文件不得填写值**）

当前已在登录的 CNB Web UI **仅检查** `b2233/cloud-secret/projects/openwrt-ci/env.build.yml` 的键名及 ACL，未查看/输出值或改写现有文件；授权规则与分支保护阻塞项见 [`cnb-secret-import-plan.md`](cnb-secret-import-plan.md)。CNB 的 `imports` 把密钥仓库 YAML/JSON 注入环境变量；文件内容可能对获授权的仓库角色可见。用户本次批准规划引用现有密钥仓库，但**尚未授权放宽 ACL、开放不受保护的分支或在本仓库复制值**。不要通过聊天发送值或在构建仓库提交值。

## 第一阶段：默认 RE-CS-07（DHCP、`WRT_BUILD_ONLY=true`、无 debug）

| 名称 | 必填？ | 作用及界限 |
| --- | --- | --- |
| `SAMBA_DEFAULT_PASSWORD` | **默认目标必填** | `Config/GENERAL.txt` 打开 `luci-app-samba4`，`Scripts/generate_samba_credentials.sh` 无此变量即失败。会生成私有固件中的 Samba 凭据；构建须私有、不可公开 release。不得使用测试/通用弱口令冒充对照。 |
| `HEADSCALE_OPENWRT_AUTHKEY` | 可选：仅需固件首启自动注册 Headscale 时 | 启用设备自动注册，构建时写入私有固件 `/etc/tailscale/headscale.authkey`，首启后按脚本处理。须专门签发合适 tag/期限的**设备** preauth key；已部署设备上的旧 key 可能过期/不可重用，也不能代替 CI key。 |
| `OPENWRT_DROPBEAR_AUTHORIZED_KEYS` | 可选 | 固件 SSH 公钥配置；不是 SSH 私钥。 |
| `NIKKI_SUBSCRIPTION_URL` | 可选 | 固件首启/运行期 Nikki 订阅；含 token 时须私有构建。 |
| `MULTICA_TOKEN`, `MULTICA_SERVER_URL`, `MULTICA_APP_URL`, `MULTICA_WORKSPACE_ID` | 可选：仅启用 Multica 自动注册时 | agent 中控接入；相关值进入私有 overlay，须一起核对服务端与 workspace。 |
| `COMMANDCODE_API_KEY`, `CLIPROXYAPI_API_KEY`, `CLIPROXYAPI_BASE_URL` | 可选：仅需对应 provider 预置时 | CLI provider 认证和端点，绝不可公开分发固件。 |
| `OPENWRT_WAN_PPPOE_USERNAME`, `OPENWRT_WAN_PPPOE_PASSWORD` | **仅 WAN_PROTOCOL=pppoe 时成对必填** | PPPoE 拨号账号；默认 DHCP 不需要。GitHub repo secret 名单未发现这两项，不能假设已经配置。 |

*默认固件即使只满足 Samba 一项也是**私有**，不能拿它冒充无密钥的公开产物。先完成受保护分支、可信镜像、任务限钥、密钥注入及私有附件下载/校验验收，再启用有密钥构建。*

## 后续独立高权限任务（第一阶段**不填、不导入**）

| 任务 | 待填名称 | 作用及条件 |
| --- | --- | --- |
| Tailscale runner debug / 只读 CD | `HEADSCALE_CI_AUTHKEY`, `HEADSCALE_URL` | CI runner 入 Headscale，**不是设备首启 key**；与 build 阶段隔离，审计 tag。 |
| CD 真机预检/升级 | `FIRMWARE_CD_SSH_PRIVATE_KEY`, `FIRMWARE_CD_KNOWN_HOSTS` | 仅设备 CD 的私钥与严格主机公钥 pin；独立审批、每设备串行锁、明确设备授权后再配置。 |
| Agent runtime 签名发布 | `AGENT_RUNTIME_USIGN_SECRET_KEY` | 仅签名发布任务，和普通 firmware build 隔离。 |
| 上游监测（以后若 API 限额） | 可选**只读、最小权限** GitHub API token，名字待定 | 当前监测直接访问公开 GitHub API，不需 token；限额不足才讨论独立只读身份。`GH_PAT` 不自动迁入。 |

`GH_PAT`、`GITHUB_TOKEN` 和 `WRTBAK_*` 不属于第一阶段默认必填；不要照搬整个 GitHub secret 集合。用户可在经批准的密钥管理 UI **自行填写值**，只需在聊天中确认“名称是否配置完成”，不要发送值、截图或文件内容。
