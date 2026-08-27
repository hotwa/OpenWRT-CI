# Upstream Merge Policy

本文档记录 hotwa/OpenWRT-CI 与 `davidtall/DaeWRT-CI`、`davidtall/immortalwrt` 等上游同步时的取舍规则。后续 agent 处理上游更新前必须先阅读本文，再做 diff、cherry-pick 或手工搬运。

## Default Strategy

- 不直接把 `davidtall/main` 覆盖式 merge 到 `hotwa/main`。本仓库有 CPE-5G、wrtbak、Headscale/Tailscale、京东云设备、private artifact 和 CI guard 等本地长期维护内容。
- 使用小原子吸收：每次只合入一个可以解释清楚的功能组，例如“新增可选插件源”“补充磁盘工具包”“更新 DAE pinned source”“调整某个 workflow 输入”。
- 每个原子变更必须说明：来源上游 commit/range、接受的文件或 hunk、拒绝的上游 hunk、验证命令、设备影响。
- 优先手工搬运 hunk，而不是让 merge 自动选择上游版本。遇到冲突时默认保留 hotwa 本地 guard，再决定是否补上游新增行。

## Safe Atomic Absorptions

这些更新通常可以选择性吸收，但仍要跑测试：

- `Scripts/Packages.sh` 中的新增可选插件源，例如主题、磁盘管理、网络辅助、`nginx-manager`、`netwizard`、`timecontrol`、`netspeedtest`。新增源不等于默认启用；只有确认为目标固件需要时才同步加入 `Config/GENERAL.txt`。
- `Config/GENERAL.txt` 中明确的存储/维护工具，例如 `exfat-*`、`kmod-nvme`、`libnvme`、`nvme-cli`、`smartmontools`。避免顺手启用无关网络策略包。
- `package/v2ray-geodata/v2ray-geodata-updater` 的热加载改进，但保留本仓库已有的 reload/hot_reload fallback，不退回上游无 fallback 的简单实现。
- DAE、daed、homeproxy、sing-box 相关更新只在版本组合已审查后吸收，并继续使用 pinned commit、hash 或 guard test，避免动态 `git ls-remote` 破坏可复现性。`daed` 的 wing/core/outbound/quic-go 必须作为兼容组合固定到精确提交；不得恢复移动 perf 分支 checkout，也不得在构建期执行 `go get -u` 或 `go mod tidy` 改写依赖图。
- workflow 的小修可以吸收，但必须保留本仓库的 private build、wrtbak、LAN/WAN SSH、device artifact 和 secret 传递输入。

## Do Not Merge From Upstream

以下上游变化不能直接接受：

- 不删除或禁用 `CONFIG_PACKAGE_luci-app-nikki=y`，也不删除 `Scripts/Packages.sh` 中 `nikkinikki-org/OpenWrt-nikki` 的拉取逻辑。
- 不删除 `luci-app-wrtbak`、`luci-app-tailscale-community`、`tailscale`、`luci-app-lucky`、`wg-endpoint-watchdog` 及其相关 overlay/guard，除非另有实机回滚计划。
- 不删除京东云设备：`jdcloud_re-cs-07`、`jdcloud_re-ss-01`、以及仓库长期保留的 `re-ss02` 目标。上游删除设备时保留 hotwa 版本；上游新增设备时只追加，不覆盖这些设备。
- 不接受上游把 AX6600-Athena / `jdcloud_re-cs-02` 的 LED 控制改回 `NONGFAH/luci-app-athena-led`、`haipengno1/luci-app-athena-led` 或改成全局安装。该设备固定使用 `unraveloop/JDC-AX6600-Athena-LED-Controller` `v2.4.0` / `a0eae21dc1119a56aaf8633c610af03a92f7493c` 的 `athena-led` + `luci-app-athena-led` 双包；必须保留 `Scripts/function.sh` 的设备级写入和 `Scripts/GuardAthenaLedArtifact.sh` 的最终 manifest 检查，不能只修改 `Config/TEST.txt`。
- 不删除 `.github/workflows/CPE-5G.yml`、`.github/workflows/RE-CS-07-BUILD.yml`、`Config/IPQ60XX-706-NOWIFI.txt`、`Config/IPQ60XX-RE-CS-07-NOWIFI.txt`。
- 不移除 `secrets: inherit`、`WRTBAK_DEVICE_ALIAS`、`WRTBAK_PROXY_PROFILE`、`Scripts/WrtbakR2Config.sh`、`Scripts/PrivateFirmwareGuard.sh`，也不让 secret-bearing 固件进入 GitHub Release。
- 不把 CPE-5G 固件源码从 README 记录的完整 40 字符 SHA 改成移动分支。`davidtall/immortalwrt:stable` 只能作为候选，不能作为生产基线。
- 不接受上游对 `diy.sh` 的默认源切换为 `davidtall/immortalwrt viking-main`，除非只是本地实验分支并已明确不影响 CI。
- 不删除 `Scripts/fetch_node_runtime.sh`、`Scripts/fetch_uv_runtime.sh`、`files/etc/profile.d/20-node-agent.sh`、`files/etc/profile.d/30-agent-update-check.sh` 以及 Node.js 24 LTS / Python 3.12 / OpenCode / Pi / Hermes Agent 智能体运行时注入逻辑。
- 不用上游大范围删除来清理 docs、tests、overlay、packages。若上游没有这些文件，视为 hotwa 本地长期维护内容。

## Required Checks

上游同步 PR 或分支至少跑以下检查：

```bash
bash tests/test_jdcloud_devices_and_nikki_guard.sh
bash tests/test_wrtbak_package_guard.sh
bash tests/test_upstream_plugin_alignment.sh
bash tests/test_upstream_merge_policy.sh
```

涉及 CPE-5G、Headscale/Tailscale、wrtbak 首启路径时，还要按 `AGENTS.md` 和 `docs/headscale-auto-enroll.md` 的门禁执行。涉及 kernel、NSS、qca-ssdk、Qualcommax patch、RE-SS-01 DTS/DTB、factory pipeline 或固件源码 SHA 时，必须同步更新 README 基线表，并完成实机验证后才能推广。

## Merge Note Template

每次选择性吸收上游时，在 PR/commit 说明中记录：

```text
Upstream source: davidtall/DaeWRT-CI <commit-or-range>
Accepted: <files/hunks>
Rejected: <files/hunks and reason>
Protected: Nikki, jdcloud devices, wrtbak/private build, CPE baseline
Verified: <local tests and/or Action run>
Device impact: <RE-CS-07 / RE-SS-01 / re-ss02 / ordinary QCA>
```
