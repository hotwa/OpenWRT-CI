# PPPoE `wan6` 日志策略

RE-SS-01 当前 PPPoE 线路没有 IPv6 上游，因此 `netifd` 可能周期性记录
`wan6: error connecting LLA socket`。这不影响 IPv4、Tailscale、Nikki、DNS 或
Agent Runtime；它表示 DHCPv6/链路本地探测没有得到上游响应，而不是 WAN4 故障。

仓库不在所有机型的固件里强制关闭 `network.wan6`：CPE 和其他部署可能需要
IPv6，且固件 overlay 没有可靠的统一 `network` 配置所有者。需要明确关闭 IPv6
的单台设备可在本机执行并持久化：

```sh
uci set network.wan6.proto='none'
uci set network.wan6.auto='0'
uci commit network
/etc/init.d/network reload
```

执行前应确认该设备不依赖 IPv6 上游、IPv6 Tailnet 或 IPv6 服务发布。默认构建
保留 `wan6`，避免把一台线路的观测误用于整个固件仓库。
