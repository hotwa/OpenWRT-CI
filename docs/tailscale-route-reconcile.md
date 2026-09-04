# Tailscale 动态路由自愈

固件包含 `/etc/init.d/tailscale-route-reconcile`，用于处理
“Tailscale 控制面在线，但 OpenWrt 的 policy-routing table 52 没有安装远端
子网路由”的时序故障。

## 设计原则

- 不维护 192.168.x.x 的静态清单，也不执行 `ip route add`。期望路由来自
  `tailscale debug netmap` 中在线 Peer 的 `PrimaryRoutes`，因此 Headscale
  后续批准的新网段会自动纳入检查。
- 检查很轻量，默认每 300 秒执行一次；检查本身不会重启 Tailscale。
- 必须连续两次确认缺失（默认约 10 分钟）才进入修复流程。
- 先调用 `tailscale debug force-netmap-update` 做无损 netmap 刷新，等待 8 秒
  后再次核对；刷新已经恢复时不会重启服务。
- 只有刷新仍失败才执行 `/etc/init.d/tailscale restart`，并在两次修复尝试之间
  默认保留 30 分钟冷却时间。每次重启后由下一轮检查验证结果。
- 控制面未进入 `BackendState=Running`、netmap 不可读或没有在线子网路由时，
  只跳过本轮，不把不确定状态误判成故障。

现有 `95-tailscale-settings-disable` 继续保留。该 LuCI reconciler 在部分版本
会对仍运行中的 `tailscaled` 执行 `--cleanup`，可能清掉 tailscale0 和 table 52；
路由自愈服务不能替代这个启动顺序护栏。

## 运维命令

```sh
/etc/init.d/tailscale-route-reconcile status
/usr/sbin/tailscale-route-reconcile --status
/usr/sbin/tailscale-route-reconcile --check
logread -e tailscale-route-reconcile
ip route show table 52
```

需要临时停用时，修改 UCI 后重载服务即可；不会删除已有路由：

```sh
uci set tailscale.route_reconcile.enabled='0'
uci commit tailscale
/etc/init.d/tailscale-route-reconcile restart
```

恢复默认：

```sh
uci set tailscale.route_reconcile.enabled='1'
uci commit tailscale
/etc/init.d/tailscale-route-reconcile restart
```

可调参数位于 `/etc/config/tailscale` 的
`config route_reconcile 'route_reconcile'`：

| 选项 | 默认值 | 作用 |
| --- | ---: | --- |
| `check_interval` | `300` | 两次检查的秒数；只影响观察频率 |
| `failure_threshold` | `2` | 连续缺失多少次后进入修复流程 |
| `restart_cooldown` | `1800` | 两次重启尝试的最小间隔（秒） |
| `netmap_wait` | `8` | 无损 netmap 刷新后的等待秒数 |

这些参数只影响自愈守护进程，不改变 `accept_routes=1`、Headscale ACL 或
Tailscale 的动态路由接收策略。
