# Tailscale 动态路由自愈

固件中的 `/etc/init.d/tailscale-route-reconcile` 是一个只读观测、分级修复的
常驻守护进程，用来处理“`tailscaled` 控制面显示在线，但内核接口或策略路由
没有恢复”的启动竞态。它由公共 `WRT-CORE` overlay 注入，因此所有启用
`WRT_TAILSCALE_ROUTE_RECONCILE` 的固件（默认开启）都包含同一版本；不依赖
RE-CS-02、RE-CS-07 或某个固定 LAN 网段。只有明确构建无 Tailscale 的基线镜像
才应把该开关设为 `false`。

## 健康判据

每轮默认每 300 秒执行一次。所有期望路由均从 `tailscale debug netmap` 动态读取，
不使用 `status --json` 的 `Online` 字段，也不写死 `192.168.x.x`：

1. `BackendState=Running`；
2. `tailscale0` 存在并持有本机 Tailscale IPv4；
3. netmap 每个 peer 的 IPv4 `/32` 存在于实际策略路由表；
4. 每个 peer 的 IPv4 `PrimaryRoutes` 存在于该表；
5. `100.100.100.100/32`（MagicDNS）存在；
6. `ping -c 1 -W 2 100.100.100.100` 成功，验证实际数据面。

路由表号不固定：脚本先扫描 `ip -4 route show table all`，选择包含最多
`dev tailscale0` 路由的表；表为空时再从 `ip -4 rule` 的 `from all lookup N`
推断；最后才以 52 作为带 WARN 的兼容回退。新批准的 Headscale 子网会在下一轮
自动进入期望集合。

## 修复阶梯与启动竞态

- 本机 IPv4 缺失：连续两轮确认后直接 `/etc/init.d/tailscale restart`；不浪费
  `force-netmap-update`，因为它无法修复已丢失的内核地址。
- 路由或 ping 失败：连续两轮后执行一次
  `tailscale debug force-netmap-update`；该命令对 netmap 内容不变的内核漂移
  可能是 no-op，第三轮仍失败才重启 Tailscale。
- 两次重启至少间隔 1800 秒；冷却期间只记录 WARN，不反复抖动网络。
- 修复后等待 `netmap_wait` 秒并立即执行完整复检，记录
  `post-repair verification PASSED/FAILED`。
- `BackendState` 非 Running、status/netmap 读取失败、没有 self IPv4，或
  `headscale-auto-enroll` 的活动锁存在时，本轮只记录并跳过修复。

启动顺序由 init 脚本保持为：`tailscale` → `headscale-auto-enroll` (98) →
`tailscale-route-reconcile` (99)。`headscale-auto-enroll` 已禁用旧的
`tailscale-settings` reconciler，避免其 `--cleanup` 与运行中的 daemon 竞争。
脚本只执行 netmap 刷新和 Tailscale 重启，不修改 UCI、Headscale 审批或主机电源。

## 构建注入

公共工作流 `.github/workflows/WRT-CORE.yml` 提供：

```yaml
WRT_TAILSCALE_ROUTE_RECONCILE: true
```

开启时无论 `WRT_FEATURE_OVERLAY` 是否开启，都会复制 helper、init、UCI fallback
和默认配置，并在 `defconfig` 后确认 `CONFIG_PACKAGE_tailscale=y`。当前
RE-SS-01、RE-CS-02、RE-CS-07、CPE overlay 及 QCA 构建均显式开启。CPE 的
`BUILD_BASELINE_A` 是唯一有意关闭 Tailscale 的对照构建，并显式将开关设为
`false`。

## 运维命令

```sh
/etc/init.d/tailscale-route-reconcile status
/usr/sbin/tailscale-route-reconcile --status
/usr/sbin/tailscale-route-reconcile --once
logread -e tailscale-route-reconcile
cat /var/run/tailscale-route-reconcile.state
```

UCI 配置段位于 `/etc/config/tailscale`：

| 选项 | 默认值 | 作用 |
| --- | ---: | --- |
| `enabled` | `1` | 是否运行守护进程 |
| `check_interval` | `300` | 检查间隔（秒） |
| `failure_threshold` | `2` | 连续确认次数 |
| `restart_cooldown` | `1800` | 重启最小间隔（秒） |
| `netmap_wait` | `8` | 修复动作后等待（秒） |

临时停用或恢复：

```sh
uci set tailscale.route_reconcile.enabled='0'  # 恢复用 '1'
uci commit tailscale
/etc/init.d/tailscale-route-reconcile restart
```

## 离线验收

`tests/test_tailscale_route_reconcile.sh` 覆盖动态表号、无 `Online` 过滤、健康
基线、路由漂移三阶段、地址丢失、冷却和 auto-enroll 锁；
`tests/test_tailscale_package_guards.sh` 验证公共 overlay 和所有 Tailscale 关键
文件仍被 CI 注入。测试不连接真实设备。
