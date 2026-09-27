# CNB 构建域密钥模板与手工填入步骤

最后整理：2026-09-27。

本文说明如何把 GitHub Actions 里使用的**构建域**密钥手工迁移到
`b2233/cloud-secret` 的 `projects/openwrt-ci/env.build.yml`。它只列**名称**与
**占位符**，任何真实值都不允许出现在本仓库、CI 日志或附件里。

## 1. 相关文件

| 文件 | 作用 |
| --- | --- |
| `.cnb/cloud-secret-env.build.template.yml` | **未填写的模板**（占位符），生成物，供手工复制 |
| `Scripts/cnb_secret_inventory.py` | 只读盘点 + 生成/校验模板（`--audit` / `--write` / `--check`） |
| `.github/workflows/CNB-Secret-Audit.yml` | **仅手动** `workflow_dispatch` 的只读审计（不编译、不改任何密钥） |
| `tests/test_cnb_secret_inventory.py` | 断言模板无真实值、名单与 profile `required_secrets` 一致 |

## 2. 运行一次只读审计（GitHub 侧，手动）

1. 打开 GitHub `hotwa/OpenWRT-CI` → Actions → 选择 **CNB secret audit (manual, read-only)** → `Run workflow`。
2. 该 job 只做三件事：打印名称清单、打印每个名称的 **`set`/`unset` 布尔**、上传**未填写模板**为 artifact（保留 14 天）。
3. 它不会读取、打印、哈希或复制任何值；日志形如：

```text
build-domain secret names (names only; no values are read or printed):
  required  HEADSCALE_OPENWRT_AUTHKEY          profiles=cpe5g-a,cpe5g-b,qca-ipq60xx-wifi-no,qca-ipq60xx-wifi-yes
  required  SAMBA_DEFAULT_PASSWORD             profiles=cpe5g-a,...,wlg-re-cs-07
  optional  CLIPROXYAPI_API_KEY                callers=...,WRT-CORE.yml
  unused    HEADSCALE_CI_AUTHKEY               (GitHub-only; not used by the CNB replay)
  forbidden FIRMWARE_CD_SSH_PRIVATE_KEY        (deployment/release boundary)
presence only (set/unset); no value is read or printed
SAMBA_DEFAULT_PASSWORD=set
HEADSCALE_OPENWRT_AUTHKEY=unset
CLIPROXYAPI_BASE_URL=unset
```

> 日志里**只会**出现 `=set` / `=unset`，不会出现任何值的片段、长度或摘要。

## 2.5 名称分组（只列名称；用户提供的完整 GitHub Secrets 清单已并入）

| 分组 | 名称 | 说明 |
| --- | --- | --- |
| **build-required** | `SAMBA_DEFAULT_PASSWORD`、`HEADSCALE_OPENWRT_AUTHKEY` | 为空/占位符即 fail closed；`HEADSCALE_OPENWRT_AUTHKEY` 仅 CPE-5G 与两条 QCA 需要 |
| **build-optional** | `NIKKI_SUBSCRIPTION_URL`、`OPENWRT_DROPBEAR_AUTHORIZED_KEYS`、`OPENWRT_WAN_PPPOE_USERNAME`、`OPENWRT_WAN_PPPOE_PASSWORD`、`MULTICA_TOKEN`、`MULTICA_SERVER_URL`、`MULTICA_APP_URL`、`MULTICA_WORKSPACE_ID`、`COMMANDCODE_API_KEY`、`CLIPROXYAPI_API_KEY`、`CLIPROXYAPI_BASE_URL` | 留空即复现 GitHub 侧的降级路径 |
| **github-only / 其他域（CNB 不使用）** | `HEADSCALE_CI_AUTHKEY`、`HEADSCALE_URL`（CI debug hold，不重放且已从构建环境剔除）、`GH_PAT`（GitHub API 自动化） | 不写入构建模板 |
| **forbidden（部署/发布/备份域）** | `FIRMWARE_CD_SSH_PRIVATE_KEY`、`FIRMWARE_CD_KNOWN_HOSTS`（`firmware-cd` 环境）、`AGENT_RUNTIME_USIGN_SECRET_KEY`、`WRTBAK_HOME_PROXY_URL`、`WRTBAK_OFFICE_PROXY_URL`、`WRTBAK_R2_ACCESS_KEY_ID`、`WRTBAK_R2_SECRET_ACCESS_KEY`、`WRTBAK_R2_BUCKET`、`WRTBAK_R2_ENDPOINT`、`WRTBAK_R2_PREFIX`、`WRTBAK_R2_REGION` | **绝不进入 build 模板**；本仓库不绑定 `firmware-cd` 环境 |
| **内建** | `GITHUB_TOKEN` | GitHub Actions 内建，不是可复制密钥 |

**对账（名称不一致处）**：
- 在 GitHub 清单里但没有任何 workflow 引用：`GH_PAT` 与全部 `WRTBAK_*`（9 个）；
- 被 workflow 引用但用户提供的 repo secret 清单未见：`MULTICA_SERVER_URL`、`MULTICA_APP_URL`、`OPENWRT_WAN_PPPOE_USERNAME`、`OPENWRT_WAN_PPPOE_PASSWORD` —— 需要核实是否有其他 scope（或按需留空，缺省即降级）。
- **非 secret 变量（`vars.*`）**：用户未提供，本模板与审计脚本都不包含任何 `vars` 条目；如需迁移请另行提供名单，再单独评审。

## 3. 手工填入 cloud-secret

1. 在 CNB 打开 `b2233/cloud-secret` → `projects/openwrt-ci/env.build.yml`。
2. 按 `.cnb/cloud-secret-env.build.template.yml` 的骨架核对四件事：
   - `allow_slugs: [b2233/openwrt-ci]`
   - `allow_events: [web_trigger_re_private_build, vscode]`
   - `allow_branches: [main, migration/cnb-shadow-20260926]`
   - 变量名逐字一致（大小写、下划线）。
3. **必填**（为空或占位符会让 CNB 构建 fail closed，而不是产出"不会自动入网"的固件）：
   - `SAMBA_DEFAULT_PASSWORD`
   - `HEADSCALE_OPENWRT_AUTHKEY` —— **必须先在 Headscale 轮换/吊销旧的泄露 key 再填新值**。
4. **可选**（留空即复现 GitHub 侧的降级路径）：`NIKKI_SUBSCRIPTION_URL`、
   `OPENWRT_DROPBEAR_AUTHORIZED_KEYS`、`OPENWRT_WAN_PPPOE_USERNAME/PASSWORD`（仅 pppoe）、
   `MULTICA_TOKEN/SERVER_URL/APP_URL/WORKSPACE_ID`、`COMMANDCODE_API_KEY`、
   `CLIPROXYAPI_API_KEY/BASE_URL`。
5. **不要填入**：`FIRMWARE_CD_SSH_PRIVATE_KEY`、`FIRMWARE_CD_KNOWN_HOSTS`、
   `AGENT_RUNTIME_USIGN_SECRET_KEY`（部署/发布域，构建域永不接收）；
   `HEADSCALE_CI_AUTHKEY`、`HEADSCALE_URL` 在 CNB 侧不使用（CI debug hold 不重放，且已被
   replay 从构建环境剔除）。
6. 保存到 `main` 后立即对下一次手动构建生效（ACL 与变量都在运行时读取）。

## 4. 占位符语义

- 模板里的 `<FILL:required>` / `<FILL:optional>` 只是占位符；CNB replay 的
  `clean_optional()` 会把 `<...>` 视为**未设置**，所以占位符不可能被当成凭据使用。
- 手工填写后请**不要**把填好的副本提交到任何仓库。

## 5. 本地自检

```bash
python3 Scripts/cnb_secret_inventory.py --audit
python3 Scripts/cnb_secret_inventory.py --check .cnb/cloud-secret-env.build.template.yml
python3 -m unittest tests/test_cnb_secret_inventory.py
```

`--check` 会在以下情况失败：缺少必填名称、出现部署域名称、出现非占位符的值、
`allow_*` 与评审值不一致，或模板列出一个 GitHub workflow 从未引用的名称。
