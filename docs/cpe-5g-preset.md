# CPE-5G 固件预设

`CPE-5G` 是为连接 UDX710 CPE 的 `jdcloud,re-ss-01` 路由器准备的手动构建预设。

## 网络规划

| 网络 | 用途 |
| --- | --- |
| `192.168.66.0/24` | CPE 与 OpenWrt 的 USB/5G 管理链路；CPE 为 `192.168.66.1`，OpenWrt 的 5G 接口通常为 `192.168.66.2`。 |
| `192.168.13.0/24` | CPE-5G OpenWrt LAN；默认路由器地址为 `192.168.13.1`。 |

`192.168.13.0/24` 避免与既有的 `192.168.10.0/24`、`192.168.11.0/24`、`192.168.12.0/24` 网段重叠，适合后续作为 Headscale 子网路由的唯一 LAN 前缀。

## 内置服务

- `luci-app-lucky` 由共享 `GENERAL` 配置全局启用。
- `tailscale` 与 `luci-app-tailscale-community` 已内置。私有构建中只有在注入 `HEADSCALE_OPENWRT_AUTHKEY` Secret 时才会首启自动加入 Headscale；该密钥不写入仓库。
- CPE-5G 预设默认不启用 LAN 到 Tailnet 的转发。路由器本身可经 Tailnet 管理；如需让 LAN 客户端访问 Tailnet，必须在触发构建前单独评估并启用对应策略。

## 触发构建

GitHub Actions 选择 **CPE-5G**，正常构建时保留 `LAN_IP=192.168.13.1`。如只校验最终配置，将 `TEST` 设为 `true`。

固件刷入后，先确认 `usb0`/5G 接口获得 `192.168.66.2`，再确认 LAN 为 `192.168.13.1`、Lucky 页面可访问、以及 `tailscale status` 已加入 Headscale。
