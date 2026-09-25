# RE-CS-07 启动自愈与 CI/CD 验收

本文件把 2026-09-25 针对 `jdcloud,re-cs-07` 现场巡检报告中的 FW-1…FW-7
映射到固件仓库。固件构建/本地 mock 通过不等于设备已验收；只有匹配板型的产物
完成受保护的部署并通过下方真机检查，才能标记 RE-CS-07 CI/CD 可用。

## 修复映射与行为

| Issue | 仓库修复 | 设备侧副作用/边界 |
| --- | --- | --- |
| FW-1 CommandCode 自更新污染 `/opt` | `20-node-agent.sh`、SSH 版本提示及 runtime 探测统一设置 `COMMANDCODE_SKIP_UPDATES=1`；`agent-runtime-baseline-readonly` 将 `/opt/node`、`/opt/uv`、`/opt/agent-runtime` 做只读 bind mount。启动后及每天 02:53 运行 `agent-runtime-health-check`：只有明确 `health_failed` 才用 manager 回滚；无 `/data`、busy、签名/下载临时错误只标记 deferred。签名更新仍在每天 03:07 走原有完整 generation 流程。 | CLI 自更新与针对 `/opt` 的手工写入会失败，这是预期保护。检查与回滚不下载、不安装应用。若回滚也失败，会留下 `rollback_failed` 并写系统日志，不静默宣称恢复。 |
| FW-2 维护锁饥饿/残留 | auto-upgrade、runtime guard、日志整理、runtime health 使用独立 `flock` 防重入；只在运行时切换/Multica 重启/文件整理时抢公共 `/var/lock/multica-maintenance.lock`。auto-upgrade 对公共锁最多等待 60 秒后明确 defer。 | `flock` 在进程退出时由内核释放，不再依赖目录锁清理；定时任务之间可能 defer 一次，但不会因旧目录永久阻塞。 |
| FW-3 Quad100 旧失败状态 | 真正循环的 procd monitor 每 60 秒探测；状态为 `unknown/ok/failed`，并保存 epoch、FQDN、地址和结果原因；DNS 需同时匹配查询名与有效 IPv4。 | 未就绪状态不会被误报成新失败；超过 5 分钟的结果不算健康。 |
| FW-4 Wi-Fi | 暂不变更。现场资料显示该镜像没有无线驱动栈，但是否为产品预期仍需型号/硬件确认。 | 没有新增 Wi-Fi/NSS/防火墙包或改变无线配置；在产品决策前按有线设备验收。 |
| FW-5 原子发布残留 | 新文件使用同目录 `mktemp` 并在复制/发布失败时清理；runtime/profile 只清除严格匹配、PID 已退出且属于受管路径的旧临时项。 | 不扫描或删除任意 `/data` 文件；设备重启后可安全清理精确的旧临时软链。 |
| FW-6 `/data/node -> /opt/node` | 保持 `/data/node` 为活动 runtime 的兼容链接；若没有签名 generation，它可指向只读固件 baseline。全局 npm prefix 指向 `/opt/node` 不代表可写：只读保护使其写入明确失败。 | 不把 `/data/node` 改成第二套可写全局包树，避免绕过签名 generation 和组件 manifest。 |
| FW-7 可观测性 | `openwrt-ci-health --json` 报告 `/`、`/data` 可用空间、root 密码状态（只报 empty/locked/set，不输出 shadow hash）、Quad100 新鲜度及证据、runtime 即时 verify 与上次启动/每日自检状态。 | 输出不包含口令、哈希、订阅 URL、auth key 或 token。 |

## 本机只读验收

以下命令用于升级后 SSH 检查；它们不会写 UCI、改 runtime 或触发升级：

```sh
openwrt-ci-health --json
openwrt-ci-health --require data,wan,tailscale,magicdns,nikki,runtime
agent-runtime verify --json
cat /var/run/agent-runtime-health.status
cat /var/run/quad100-health.ok
awk '$2 ~ /^\/opt\/(node|uv|agent-runtime)$/ { print $2, $4 }' /proc/mounts
```

期望：health gate 返回 0；runtime 的 `verify` 为 `ok`、`self_check` 为 `verified`
（若启动时安全回滚过则为 `rolled_back`）；`/proc/mounts` 中三个 baseline
mount 都带 `ro`。Quad100 状态需 `state=ok`、时间戳不超过 300 秒，FQDN 和
IPv4 与当前 Tailnet 节点相符。运行 `cmdc --version` 后再次执行
`agent-runtime verify --json` 必须仍返回 `ok`，且 `/` 可用空间不会因 CLI
升级膨胀。

升级后的首次冷启动、软重启和设备实际 CI/CD 投送仍须逐台验收。部署必须使用对应
`jdcloud_re-cs-07` 产物、验证 artifact SHA256/板型、保留主机指纹校验，并要求
`sysupgrade -T` 通过。任何 host-key、板型、/data、空间或启动验收不符都应停止，
不能跳过门禁或盲目再次刷写。

## 回滚

- runtime 自检认定健康失败时，自动先尝试 `agent-runtime rollback --json`；检查结果在
  `/var/run/agent-runtime-health.status`，日志使用 `agent-runtime-health-check` tag。
- 若只读 baseline mount 无法启用，应检查 `logread -e agent-runtime`。在确认处于
  LAN/串口恢复路径后，可停用 `/etc/init.d/agent-runtime-baseline-readonly` 并重启，
 但这会移除防止 manifest 被包管理器覆盖的保护，不应用作日常回滚方案。
- 固件脚本/默认策略的完整回滚应由已验收的前一固件构建提交并走正常 sysupgrade
  门禁；不要手工 `npm install`、改 `/opt` manifest、删除 `/data` 或清空 overlay。

此文档不表示已经触碰或刷写 RE-CS-07。自动化变更需先构建目标 artifact、检查
metadata/校验和，再经设备侧 preflight 和 post-boot health 验收。
