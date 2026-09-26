# CNB 迁移调查与阶段门禁（未切换）

调查初始基线：GitHub `hotwa/OpenWRT-CI` 的 `origin/main` = `34ba9fabb6e42268d4fbc1bd7d6015db925b29a7`（2026-09-26）；后续已更新并推送私有 CNB 仓库的独立分支，实际阶段 0 运行结果见文末。所有源码修改限于本仓库独立工作树 `.worktrees/cnb-migration`；未触碰设备。

## 现有工作保护与基线

- 原工作树 `main` = `da8b87dc00526216ae9630a4b5d803303cbeb262`；fetch 后相对 `origin/main` 领先 4、落后 33。修改：`.github/workflows/WRT-CORE.yml`、`files/etc/init.d/nikki-subscription-sync`、`files/etc/uci-defaults/99-nikki-subscription-cron`、`files/usr/sbin/nikki-subscription-sync`、`tests/test_nikki_subscription_sync.sh`、`tests/test_retired_binary_preload.sh`。未跟踪：`.pi/modes.config.json`、`.pi/settings.json`、`files/etc/uci-defaults/98-clean-legacy-startup`、`projects/openwrt-ci/env.build.yml`、`env.cd.yml`、`env.runtime-release.yml`。原工作树不纳入迁移提交，也不读取这三个用户准备的文件中的值；只检查了键名结构。
- GitHub 默认分支 `main`，公开仓库，无未合并 PR。近期成功固件运行：RE-CS-07 [36219044448](https://github.com/hotwa/OpenWRT-CI/actions/runs/36219044448)，head SHA `c5d2d829576d70fc42fc716445b7b6af26f420d2`，私有制品约 907 MB、未过期；另有近期失败运行。Agent-Runtime-Bump 按计划每小时运行；Fleet CD 最近三次失败，不能将其视为已验收的设备部署。GitHub 现有 `firmware-cd` Environment API 显示 branch-policy 保护，未显示 required-reviewer 规则；在 CNB 上更不能默认假定审批等价。
- 最新可信分支**没有** `Scripts/wrt_cache_payload_guard.sh`，也没有任何该名称调用；该名称可能只存在于另一个未合并工作树/分支。不得为迁移擅自复制、删除或放宽缓存守卫；若用户指的是其他基线，应先确认源分支和合并策略。
- 已阅读 `AGENTS.md`、`docs/upstream-merge-policy.md`、`docs/agent-runtime-version-policy.md`、`docs/headscale-auto-enroll.md`、`docs/ci-debug-gate.md`、`docs/firmware-fleet-cd.md`。保持源码及 runtime 固定 pin、uv→Node→Multica、Nikki/Headscale/wrtbak 私有门禁。当前 `docs/firmware-fleet-cd.md` 明说现有 GitHub CD **不验证** WAN/Nikki/Tailscale 服务健康；CNB CD 不得照搬这一缺口后宣称满足目标。

## CNB 平台核查及访问阻塞

访问 CNB 官方 [GitHub Actions 迁移指南](https://docs.cnb.cool/zh/build/migrate-to-cnb/migrate-from-github-actions.html)、[密钥仓库](https://docs.cnb.cool/zh/repo/secret.html)、[流水线权限](https://docs.cnb.cool/zh/build/permission.html)：CNB 使用根目录 `.cnb.yml` / `include`，Linux Docker 容器而非 GitHub VM；矩阵并非原生等价、缓存可用节点卷或 `docker:cache`，附件插件可上传产物。密钥仓库通过 `imports` 注入 YAML/JSON 文件为环境变量；`allow_slugs`、`allow_events`、`allow_branches`、`allow_images` 共同控制文件引用，但一旦声明 `allow_*`，触发者角色权限会被这些规则取代。这些规则不是任务级最小密钥范围、部署审批或可靠设备锁的证明。CNB 开发者及以上角色可触发/重跑构建；不能单靠 `main` 文本条件或脚本保护有部署钥匙的作业。

初次调查时浏览器未登录；用户登录后已在组织页面确认 `b2233/cloud-secret` 为现有**密钥仓库**，main 当前可见 `projects/openwrt-ci/{env.build.yml,env.cd.yml,env.release.yml}`。仅看了目录和文件名，**没有打开文件内容或核对值**，也没有编辑/覆盖；本地未跟踪的 `env.runtime-release.yml` 与云端 `env.release.yml` 名称不同，绝不自动同步。组织列表原无 `openwrt-ci`（6 个仓库），登录态直接访问也返回 404；按用户允许创建仓库的指示，已通过 Web UI 创建独立的**私有仓库** [`b2233/openwrt-ci`](https://cnb.cool/b2233/openwrt-ci)，页面显示“私有”。创建时为空，后续已推送 GitHub 基线 `main` 和 CNB 影子迁移分支并触发试点。初次本地 Git HTTPS 凭据访问新私库返回 Repository Not Found；现已在 CNB Web UI 创建 `openwrt-ci-win11-git-02`（90 天、仅 `b2233/openwrt-ci`、仅 `repo-code` 读写，其他授权默认），凭据通过 Windows Git Credential Manager 按仓库路径持久保存；未在聊天、命令行参数或仓库文件中存值。创建时 `git ls-remote` 成功（refs 为 0），`git push --dry-run` 到隔离迁移分支成功；实际推送及 runner 执行链接见文末。仍需核对密钥文件的 ACL/存在性（不能读取值）和受保护分支。

官方密钥仓库文档允许在受审计 Web UI 中存储实际值，但本次明确要求**不得把真实密钥写入 cloud-secret 的明文 YAML**。因此不能照抄该示例注入实际值；先由用户确认 CNB 上满足此要求的加密变量/凭据注入方式，或另选经用户批准、符合其约束的机制。任何需要秘钥的私有构建/发布/CD 在此之前停用；不要求用户在聊天中发送值。

## 迁移矩阵（状态：调查完成，均未在 CNB 验证）

| GitHub 入口 / 触发 / 输入 | 脚本、依赖与权限 | 制品/密钥 | CNB 拟议实现与差异 |
| --- | --- | --- | --- |
| `WRT-CORE.yml` reusable，32 个输入（源码 repo/branch/SHA、设备/板型、WAN、私有/测试、容器 runtime、debug、缓存等） | `Scripts/{function,Packages,Handles,Settings}.sh`、uv/Node/Multica bootstrap、Nikki/Tailnet、`PrivateFirmwareGuard.sh`、设备 artifact guards；build `contents:read`，缓存 downloads/staging/ccache | 私有或公开镜像、`metadata.json`、`SHA256SUMS`，14 天；按需传递 build secrets，debug 使用 CI key | 先把平台无关 build/manifest/精确 checksum 校验提成脚本，保留原 reusable 输入及测试；CNB runner Docker/缓存/下载与 GHA 不同，需实际运行。首次影子任务绝不注入 CD/签名密钥。 |
| `WRT-RELEASE.yml` reusable，artifact 名与 tag | 同 run 下载、精确校验 metadata/checksum，`contents:write` | GitHub 公开 release；私有与 build-only 禁止公开 | 独立受保护发布身份和仓库内制品证明；CNB 附件不自动等价 GitHub immutable run artifact。未验证前禁用。 |
| `RE-CS-07-BUILD.yml` 手动，`DEBUG_SSH/LAN_IP/WAN_PROTOCOL` | 调用 core；RE 源 SHA 精确 pin，WAN DHCP/PPPoE；`actions:read,contents:write` | 私有固件及校验和 | 首个**无部署**试点，保持相同 SHA/输入；无密钥时只可先跑非私有 smoke，不能声称与私有 GHA 固件等价。 |
| `RE-Mesh-BUILD.yml` 手动，目标/设备 LAN IP/WAN/debug | 两个有条件 core 调用 | RE-SS-01/RE-CS-02 制品、build secrets | 两个固定设备任务/显式参数，不假定原生矩阵。待试点通过。 |
| `CPE-5G.yml` 手动，`BUILD_BASELINE_A/TEST/WAN_PROTOCOL/DEBUG_SSH` | A 有条件、B 默认；完整 40 字符 source pin `0bad892975fe49fd180f99b414a7f168bb694dd7`；core | CPE A/B/私有制品 | 不改 pin/校验/默认 B；真机 RE-SS-01 验收单独做。 |
| `QCA-6.18-VIKINGYFY.yml` 手动，PACKAGE/TEST/WAN/Tailnet/debug | core 矩阵任务 | 多目标产物/build secrets | YAML anchors/独立流水线，参数矩阵静态覆盖测试；无原生矩阵等价保证。 |
| `WLG-RE-CS-07-BUILD.yml` 手动，LAN/WAN/debug | core OpenClash 配置 | 设备镜像、Nikki/其他 build secrets | 独立验证包/目标，不能共用 RE-CS-07 普通产物。 |
| `RE-CONTAINER-RUNTIME-TEST.yml` 手动，设备/runtime/版本/debug | 三个有条件 core 调用 | 测试镜像/build secrets | 保持 runtime guards 与单独测试身份，非发布。 |
| `WRT-CORE-TEST.yml` reusable | legacy 输入，read-only | 无 release | 现无 caller；保留并迁移 smoke/参数合约测试，不删除旧入口。 |
| `Agent-Runtime-Bump.yml` 每小时+手动 `dry_run/force_release` | 两架构 build/probe、签名、发布、再提交 main；`contents:write` | `AGENT_RUNTIME_USIGN_SECRET_KEY`、签名 generation | 与普通编译分离，专属身份/并发防重复/签名验证/发布回滚，未核查前不迁移自动调度。 |
| `FIRMWARE-FLEET-CD.yml` 手动 `BUILD_RUN_ID/TARGET/PREFLIGHT/DEPLOY=false` | `Scripts/FirmwareFleetDeploy.sh`、Tailnet；GitHub Environment `firmware-cd`；`actions:read,contents:read` | env 级 SSH key+known_hosts；repo CI Headscale key；目标设备 | 先只读、再手动单设备、再多设备；需平台审批、可信分支、按任务限钥、串行锁**实际验证**。目前不创建可执行 CD。 |
| `CI-DEBUG-SSH-TEST.yml` 手动 hold 1–90 分钟 | `setup_ci_tailscale.sh`，单实例锁，清理状态 | `HEADSCALE_CI_AUTHKEY/HEADSCALE_URL` | 不作为试点默认功能；CNB Docker runner 与 GHA held runner 不同，需独立隔离与审计。 |
| `Auto-Clean.yml` 每周日 20:00 UTC+手动 | `actions:write`，清理 GHA cache/失败 run | 无固件 | CNB 缓存/留存 API 不同，先研究并独立实现，绝不复用删除 GitHub 的令牌。 |

## 密钥名称与最小作用域（只核对存在性，未读取任何值）

GitHub repo secret 名称存在：`AGENT_RUNTIME_USIGN_SECRET_KEY`、`CLIPROXYAPI_API_KEY`、`CLIPROXYAPI_BASE_URL`、`COMMANDCODE_API_KEY`、`GH_PAT`、`HEADSCALE_CI_AUTHKEY`、`HEADSCALE_OPENWRT_AUTHKEY`、`HEADSCALE_URL`、`MULTICA_TOKEN`、`MULTICA_WORKSPACE_ID`、`NIKKI_SUBSCRIPTION_URL`、`OPENWRT_DROPBEAR_AUTHORIZED_KEYS`、`SAMBA_DEFAULT_PASSWORD`、`WRTBAK_HOME_PROXY_URL`、`WRTBAK_OFFICE_PROXY_URL`、`WRTBAK_R2_ACCESS_KEY_ID`、`WRTBAK_R2_BUCKET`、`WRTBAK_R2_ENDPOINT`、`WRTBAK_R2_PREFIX`、`WRTBAK_R2_REGION`、`WRTBAK_R2_SECRET_ACCESS_KEY`。GitHub `firmware-cd` environment secret 名称存在：`FIRMWARE_CD_SSH_PRIVATE_KEY`、`FIRMWARE_CD_KNOWN_HOSTS`。**GitHub 当前工作流静态引用但 repo secret 清单未见**：`OPENWRT_WAN_PPPOE_USERNAME`、`OPENWRT_WAN_PPPOE_PASSWORD`、`MULTICA_SERVER_URL`、`MULTICA_APP_URL`；需核实是否有其他 scope 或按需空值。`GH_PAT` 与旧 WRTBAK 项存在不表示仍被最新工作流使用，不自动迁入。`GITHUB_TOKEN` 为 GHA 内建，不是可复制密钥。

| 用途 | 名称（仅名称） | 原 scope → CNB 最小目标 scope / 允许任务 | 用户待办 |
| --- | --- | --- | --- |
| 私有 build overlay | `NIKKI_SUBSCRIPTION_URL`, `OPENWRT_WAN_PPPOE_USERNAME/PASSWORD`, `OPENWRT_DROPBEAR_AUTHORIZED_KEYS`, `SAMBA_DEFAULT_PASSWORD`, `MULTICA_TOKEN`, `MULTICA_SERVER_URL`, `MULTICA_APP_URL`, `MULTICA_WORKSPACE_ID`, `COMMANDCODE_API_KEY`, `CLIPROXYAPI_API_KEY`, `CLIPROXYAPI_BASE_URL` | GitHub repo → **仅可信受保护分支的私有 build task**，不得给 PR/fork/任意分支；公共 smoke 不注入 | 确认缺失的名称和任务范围，不提供值到聊天 |
| Headscale 设备注册 | `HEADSCALE_OPENWRT_AUTHKEY` | GitHub repo → 仅需生成该设备**私有**固件的 build task；与 CI key 用途不同，镜像内仍可恢复，不公开分发 | 校验 tag/有效期/可复用策略，优先短期单设备 key；不可合并 key |
| Headscale CI/debug/deploy runner | `HEADSCALE_CI_AUTHKEY`, `HEADSCALE_URL` | GitHub repo → 隔离的 debug/CD task；普通 build 不用（debug 默认关）；现有文档描述 CI key 同时携带 debug/deploy tags，是待审计风险，不改变 key/ACL | 审查隔离，不改变现有 Headscale 配置 |
| 受控 CD | `FIRMWARE_CD_SSH_PRIVATE_KEY`, `FIRMWARE_CD_KNOWN_HOSTS` | GitHub `firmware-cd` environment → 仅独立受保护手动 CD；对主机公钥严格 pin | CNB 未验证审批/任务限钥/锁前**不得配置实际 CD** |
| Runtime 签名 | `AGENT_RUNTIME_USIGN_SECRET_KEY` | GitHub repo → 仅独立受保护签名/发布，不给构建任务 | 单独评审发布身份与并发 |
| 旧 GitHub API/WRTBAK | `GH_PAT`, `GITHUB_TOKEN`, `WRTBAK_*` | 原 repo/GHA 内建 → 默认**不迁**；需独立证明使用及最小权限 | 清点后再决定，不能隐式全仓写 |

## 分阶段验收、回滚和阻塞事项

0. **访问/安全前置**：浏览器已登录且两个私库已确认，构建仓库为空。本机已按 CNB [Git 认证官方文档](https://docs.cnb.cool/zh/guide/git-access.html)完成构建私库的 HTTPS/GCM 认证（Git 用户名固定 `cnb`；CNB **不支持 SSH Git**；不在聊天、命令行参数或输出中提供令牌）；仅核查密钥 ACL/名称而不读取值。核实密钥注入机制满足“不写明文 YAML”、PR/fork 隔离、分支保护、作业限钥及审批；检查 runner 架构/镜像/系统依赖、磁盘内存、时限、持久缓存、网络、附件留存及下载、并发额度与计费。任一关键安全能力不满足，停止该特权阶段。回滚：不推送、不启用任务，GitHub 维持原样。
1. **影子构建/测试**：先保留 GitHub 所有入口。可信私库、无 CD/签名钥匙的 RE-CS-07 手动 build，保证相同 source SHA、workflow commit、target、WAN 参数与私有输入（只有安全注入经验证才跑私有对照）。保留所有 Guard、runtime pin；测缓存守卫/命中率，缓存键涵盖 source SHA、目标、工具链和配置。核验 sysupgrade/factory 所需清单，`metadata.json` 至少记录 source/workflow commit、板型、输入、名称、生成时间，不含秘密；SHA256SUMS 与顶层合法文件精确匹配。对照相同 SHA 的 GHA run 日志、身份、清单与校验和，说明 latest-at-build 和时间戳造成的不可逐字节复现。回滚：停止 CNB 手动试点，GitHub 原 build 继续。
2. **校验与发布**：CNB artifact 下载后再次精确覆盖验证、明确私有/公开分类、发布身份限权和失败回滚；私有固件绝不进入公开 release。签名 runtime 另设双架构验签/探测与提交顺序、串行/防重复门禁。回滚：撤销 CNB 发布入口，沿用 GitHub 产物；不删旧 release。
3. **只读 CD**：经保护的入口按 allowlist 从已成功构建的 run 获取可信制品，验证来源、commit、board、SHA256 和 device identity/host key/空间/WAN；只读且不传输/刷机，真实设备探测本身也须用户另行授权。回滚：停 CNB 预检，保留现有 GitHub/人工路径。
4. **单设备受控 CD**：需用户再次明确授权真实设备操作、独立审批、严格 host key pin、每设备串行锁；顺序校验目标、`sysupgrade -T`、升级后新 boot ID/commit marker/data/WAN/Tailscale/MagicDNS/Nikki，模糊升级或 post-boot 失败立即停止，不自动重刷。回滚使用经批准的物理/独立救援路径，绝不盲目刷写。
5. **夜间只构建，再多设备**：先经批准时区的只构建 schedule、连续多轮成功/产物校验；按设备依次实机验收后才讨论自动 CD（默认关闭），记录费用/超时与回退。只有用户确认全链路切换后才考虑停止对应 GitHub 工作流，绝不自动删除 workflow、secrets、分支保护或旧产物。

**阶段 0 无密钥试点（2026-09-26）**：仅在 `migration/cnb-shadow-*` 的 `push` 定义 `.cnb.yml`，运行 `Scripts/cnb_shadow_probe.sh` 盘点 runner 并执行缓存身份、RE-CS-07 工作流和 CI 权限边界三个短测。没有 `imports`、PR/schedule/release/CD、设备连接或固件编译；并在测试进程清除 CNB 内建临时 token。`tests/test_cnb_shadow_pipeline.py` 静态约束该范围。先推送可信公开 GitHub 基线到 CNB 私有仓 `main`（该基线无 CNB 配置），再推送迁移分支触发试点，记录实际 run 链接和机器资源；即使此试点成功，也不代表固件构建完成。

**阶段 0 实际验收**：已将 GitHub `origin/main` 精确 commit `db38b3129eef517890b1eabe5a0b75f0dad1c26c` 推到 CNB 私有 `main`，并将隔离分支 commit `79856f8c` 推到 `migration/cnb-shadow-20260926`（无 force/mirror）。CNB [运行 `cnb-hv4-1k3ehqost`](https://cnb.cool/b2233/openwrt-ci/-/build/logs/cnb-hv4-1k3ehqost) 状态“通过”，三个 guard 均通过，退出码 0；runner `Linux x86_64`、8 vCPU、16 GiB RAM、`/workspace` 显示 512 GiB 可用、容器 `ubuntu:24.04`。基础镜像未提供 git（脚本可选 commit 输出为空），后续 build identity 必须显式校验 CNB 注入的 commit 与源码 pin。没有构建固件或生成附件，故无 checksum/metadata 对照。该 run 验证了触发和纯 shell runner，但不能据此宣称构建迁移完成。

官方 [超时策略](https://docs.cnb.cool/zh/build/timeout.html)：流水线最多 20 小时；Job 默认最多 2 小时，显式 `timeout` 最多 12 小时；默认无输出 10 分钟超时。官方 [缓存文档](https://docs.cnb.cool/zh/build/pipeline-cache.html)：节点并非固定，默认跨约 3 个节点；本地 `docker.volumes` 不保证跨节点命中，跨节点要单独验证 `docker:cache`。固件构建须设定时限/日志心跳，不能将节点缓存等同可信产物。附件留存/下载、网络可达性、并发额度和费用仍未实测。CNB `main` 当前**没有分支保护规则**；新建规则的默认选项要求评审、状态检查，并禁止直接推送（包括负责人），组织当前仅一位成员，直接采用默认值可能锁死 GitHub 镜像和自审合并。未擅自保存该规则；需确定可信第二评审人及 main 镜像更新策略。私有密钥任务和发布/CD 在完成可信分支保护前不得配置。

**阶段 0.5 无密钥上游报告候选**：`Scripts/cnb_upstream_report.py` 只读读取现有 RE-CS-07/CPE-5G 工作流中的 40 字符 source pin，从 GitHub 公共 API 对照 VIKINGYFY `main` 的 `package/qca-nss`（内联 NSS 包）、`target/linux/qualcommax`（目标内核/补丁）及 `include/kernel-version.mk`（内核元数据）路径最近提交；另报告原始 ImmortalWrt `master` 的目标/内核路径最近提交及 `davidtall:stable` 候选 head。运行本地验证当前两款设备的 NSS 路径均有上游路径历史变化，**这不是版本兼容性、安全性或可合并性判断**；不自动更新 pin、签名、构建、发布或连接设备。公共 API 限额/网络可能失败，不可误报“无更新”。CNB [运行 `cnb-o8o-1k3ejle80`](https://cnb.cool/b2233/openwrt-ci/-/build/logs/cnb-o8o-1k3ejle80) 已在 `3b9e0eb` 上实际通过：Python `3.13-bookworm` 容器在约 8 秒内得到公共 API 报告并以 0 退出，两个生产 pin 对应 `package/qca-nss` 和 `target/linux/qualcommax` 最近提交与当前上游不同；原始 ImmortalWrt `master` 与 davidtall `stable` head 也可达。该次验证的是**报告脚本和网络**，不是完整驱动 API/ABI 对照或任何固件构建。另增加迁移分支**显式分支名**的每周日 09:00（CNB 系统时区 Asia/Shanghai）只读监测候选；官方 [定时任务文档](https://docs.cnb.cool/zh/build/crontab.html) 明确 cron 不支持 glob、任务以最后修改者身份执行，CNB_TOKEN 默认局限本仓库。该周期触发尚未到时，需运行后确认其实际行为及费用。

**当前停点**：CNB 已通过无密钥 shell 试点，尚无 CNB 固件校验结果；密钥注入方式、任务级隔离及审批/锁仍未证实。默认 RE-CS-07 含 Samba 包，`SAMBA_DEFAULT_PASSWORD` 为完整默认构建的硬依赖；其他所需名目及作用见 [`cnb-secret-entry-checklist.md`](cnb-secret-entry-checklist.md)，设备首启 `HEADSCALE_OPENWRT_AUTHKEY` 不等于 CI 的 `HEADSCALE_CI_AUTHKEY`，不能从已部署设备取旧 key 代用。下一步先选 RE-CS-07 做无设备操作的完整构建适配和私有对照，不能在未验证安全边界前导入 build/CD/签名密钥。不得用“已经写出 YAML”或“创建了空仓”充当迁移完成。
