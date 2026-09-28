# Pi 设备 DNS：DHCP 租约上报

`OpenWRT-CI` 镜像携带 `/usr/sbin/pi-dhcp-sync`、DHCP hotplug 脚本和 procd
服务。它每 5 秒将本机 LAN 的有效 IPv4 租约提交到
`https://adg.jmsu.top/pi-dhcp/v1/snapshot`，新增、更新和移除租约时立即补报。
ECS 接收器按站点 token 与网段校验快照，再以 AdGuard Home 的 **Client MAC +
精确 DNS Rewrite** 为白名单更新 `*.pi.jmsu.top`。设备名和 MAC 只登记在
AdGuard Home，不写入公开固件；DHCP hostname 变化不会改变已登记的域名。

## 三站试点

| 站点 | 测试名 | 当前地址 |
| --- | --- | --- |
| s10 | `n100fnos.pi.jmsu.top` | `192.168.10.223` |
| s11 | `mac5.pi.jmsu.top` | `192.168.11.184` |
| s12 | `desktop-cjgncd6.pi.jmsu.top` | `192.168.12.197` |

这些地址只是 2026-09-28 的实测结果，不是固件中的固定记录。ECS 的
站点配置与 token 以及三站的当前私有配置由服务器管理仓库维护。
`/etc/pi-dhcp-sync/site` 和 `/etc/pi-dhcp-sync/curl.conf` 通过 OpenWrt 的
sysupgrade keep 列表保留。普通保留配置升级后，服务开机直接继续上报。
全新刷机必须先从私有备份恢复或下发这两个文件；公开镜像没有 token，服务
虽已启用但保持空闲。下发后执行 `/etc/init.d/pi-dhcp-sync start` 即可。

Nikki 的 `+.pi.jmsu.top` 固定通过 `tailscale0` 查询 Tailnet AdGuard DNS
`100.64.0.6:53`，并排除 fake IP。固件对 Nikki 的 DNS mixin 做按 matcher
合并，保留订阅原有策略；fake-IP 排除表取并集。首次启动清除旧的 dnsmasq
全局 3600 秒最短/陈旧缓存设置。**5 秒是上报周期，不是 DNS TTL**；AGH、
Nikki 和客户端仍可能缓存约 10–30 秒或更久。

## 验收

在每站 OpenWrt 上执行：

```sh
/etc/init.d/pi-dhcp-sync status
cat /tmp/pi-dhcp-sync.last-success
nslookup n100fnos.pi.jmsu.top 127.0.0.1
nslookup mac5.pi.jmsu.top 127.0.0.1
nslookup desktop-cjgncd6.pi.jmsu.top 127.0.0.1
nslookup unknown.pi.jmsu.top 127.0.0.1
```

最后一个查询应为 NXDOMAIN。迁移到另一站时，先确认新站点获租约并上报，
再检查 DNS 更新和 Tailnet 路由。采集器目前只选 `network.lan.ipaddr` 所在
`/24` 的 IPv4 租约；多 VLAN、IPv6 或其他网段需要扩展后再启用。若网卡
变化，应在 AdGuard Home Client 中增加新 Ethernet MAC。

ECS 接收器源码、AdGuard Home 登记步骤及回滚方法见服务器管理仓库的
`ops/ecs/pi-dhcp-sync/README.md`。不要把 `curl.conf`、token、设备 MAC 或
AdGuard Home API 凭据加入 Git 或 GitHub Actions 日志。
