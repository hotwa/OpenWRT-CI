# Upstream Merge Policy

本文档记录 hotwa/OpenWRT-CI 与 `davidtall/DaeWRT-CI`、`davidtall/immortalwrt`、`VIKINGYFY/immortalwrt` 等上游同步时的取舍规则与差异性准则。后续 agent 或维护者处理上游更新前必须先阅读本文，再做 diff、cherry-pick 或手工搬运。

## Core Principle (核心定位与哲学)

hotwa/OpenWRT-CI 不仅是一个 OpenWrt CI 构建脚本库，更是一个定位于 **「边缘 AI 智能体（Multica / Pi / CommandCode）+ 私有 Mesh 网格（Tailscale/Headscale）+ 高可用主路由」** 的专用固件平台。

- **主要工作流**：优先采用 **Multica 调度中心 + Pi / CommandCode CLI 智能体** 组合在 OpenWrt 边缘端执行自主网络巡检、防火墙规则自愈与故障诊断；
- **上游吸收原则**：小原子吸收，拒绝全量覆盖；优先手工搬运补丁 hunk，保留本地长期维护的核心差异化特性。

---

## Do Not Merge From Upstream

以下来自上游的修改**绝对禁止接受**，遇到冲突必须拒绝上游并保留 hotwa 本地版本：

| 类别 | 明确拒绝的上游变更行为 | 拒绝原因与影响 |
| :--- | :--- | :--- |
| **AI 智能体运行时** | ❌ 删除或改写 `Scripts/fetch_node_runtime.sh` 或 `/etc/profile.d/` 环境变量脚本。 | 会破坏 Node.js 24 LTS、Pi、CommandCode 与 Multica 的预装与直通环境。 |
| **Tailscale 网关** | ❌ 将 `files/etc/config/tailscale` 的 `lan_to_tailnet.enabled` 重置为 `0` 或将 `accept_routes` 重置为 `0`。 | 会导致 LAN 客户端无法开箱直连远端 Tailnet 节点与 MagicDNS，引发断网。 |
| **科学代理策略** | ❌ 删除或禁用 `CONFIG_PACKAGE_luci-app-nikki=y`，或强行恢复编译重叠臃肿的 `homeproxy`/`daed`/`dae`。 | 本仓库聚焦于 Nikki 与 Tailscale/MagicDNS 规则闭环，拒绝多代理引擎混杂导致的内核与依赖冲突。 |
| **京东云设备矩阵** | ❌ 覆盖或删除京东云目标：`jdcloud_re-cs-02` (雅典娜), `jdcloud_re-cs-01` (亚瑟), `jdcloud_re-ss-01` (哪吒), `jdcloud_re-cs-07` (太乙), `re-ss02`。 | 必须长期保留这些关键硬件的编译配置与 DTS 适配。 |
| **Athena LED 策略** | ❌ 把 AX6600-Athena (`re-cs-02`) 的 LED 控制改回 `NONGFAH` 旧包或改为全局安装。 | 该设备固定使用 `unraveloop/JDC-AX6600-Athena-LED-Controller` `v2.4.0` 双包，且仅在 `re-cs-02` 独立下发，通过 manifest 校验护栏。 |
| **CPE-5G 生产基线** | ❌ 删除 `.github/workflows/CPE-5G.yml`、将源码从完整 40 字符 SHA 改为移动分支，或破坏 `mwan3` 双网策略。 | 移动分支无法保证生产稳定性，回退源码时不得撤销无关 hotwa 功能。 |
| **灾备与安全凭据** | ❌ 删除 `Scripts/WrtbakR2Config.sh`、`PrivateFirmwareGuard.sh` 或泄露构建 Secret。 | 防止私有认证凭据泄漏到公开发布固件中。 |

---

## 🛡️ Explicit "Must Preserve" List (明确必须保留的 hotwa 差异性)

在每次同步合并后，必须确保以下 hotwa 独有特性完整存在：

1. **AI CLI Agent 矩阵**：
   - Node.js 24 LTS (musl static) 构建期秒级预装；
   - `@earendil-works/pi-coding-agent` CLI + `@aaronkyriesenbach/pi-package-manager` + `btw-pi` + `pi-plan-mode` + `pi-web-search` + `pi-wechat-assistant`；
   - `command-code` CLI（`cmdc`）；
   - `/etc/profile.d/30-agent-update-check.sh`（SSH 登录 24h 缓存状态看板）。
2. **Tailscale / Headscale 网关默认就绪**：
   - `tailscale.lan_to_tailnet.enabled='1'` + `tailscale.settings.accept_routes='1'`；
   - Headscale Auto-Enroll 首启认证与密钥自毁机制；
   - Dropbear over Tailscale 远程救机通道。
3. **已验证设备专属构建流**：
   - `.github/workflows/RE-CS-07-BUILD.yml`（太乙灾备固件）；
   - `.github/workflows/CPE-5G.yml`（NOWIFI A/B 对照与 mwan3 双网接入）。

---

## 🟢 Safe Atomic Absorptions (允许安全吸收的上游变更)

这些更新通常可以选择性吸收，但合并后仍需执行完整护栏测试：

- `Scripts/Packages.sh` 中的新增可选第三方主题或实用维护插件源（如 `diskmanager`, `netwizard`, `netspeedtest`, `nginx-manager`）；
- `Config/GENERAL.txt` 中明确需要的存储/文件系统工具（如 `exfat-*`, `kmod-nvme`, `smartmontools`）；
- `package/v2ray-geodata` 的更新与热重载逻辑（保留 hotwa 的 reload fallback）；
- GitHub Actions 运行环境依赖升级（如 Go 1.26+、Node 构建环境修复）。

---

## Required Checks (合并后必跑测试)

每次从上游吸收改动后，必须运行以下护栏测试：

```bash
bash tests/test_fetch_node_runtime.sh
bash tests/test_tailscale_lan_tailnet_gateway.sh
bash tests/test_jdcloud_devices_and_nikki_guard.sh
bash tests/test_wrtbak_package_guard.sh
bash tests/test_upstream_plugin_alignment.sh
bash tests/test_upstream_merge_policy.sh
```

## Merge Note Template

每次选择性吸收上游时，在 commit 说明中记录：

```text
Upstream source: davidtall/DaeWRT-CI <commit-or-range>
Accepted: <files/hunks>
Rejected: <files/hunks and reason>
Protected: AI Agent runtime, Tailscale gateway defaults, Nikki, jdcloud devices, wrtbak, CPE baseline
Verified: <local tests and/or Action run>
Device impact: <RE-CS-02 / RE-CS-01 / RE-SS-01 / RE-CS-07 / ordinary QCA>
```
