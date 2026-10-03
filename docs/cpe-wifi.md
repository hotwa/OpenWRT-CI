# CPE-5G RE-SS-01 无线候选

Action [37118482938](https://github.com/hotwa/OpenWRT-CI/actions/runs/37118482938) 使用 `IPQ60XX-706-NOWIFI`。该配置实际移除了无线驱动、固件、hostapd 和 Wi-Fi 脚本，不能广播热点。RE-SS-01 的无线硬件不因此消失，但需要重新构建无线镜像，不能仅改 artifact 名称。

## 构建与兼容性

当前 B 候选采用 `IPQ60XX-706-WIFI`，只构建 `jdcloud_re-ss-01`，继续固定 `VIKINGYFY/immortalwrt@0bad892975fe49fd180f99b414a7f168bb694dd7` / Linux `6.18.37`。保留原 7.06 受控配置的内核和 NSS 选项，补齐 ath11k AHB、IPQ6018 固件、RE-SS-01 校准文件、mac80211、wpad/OpenSSL 和无线管理工具。保留无线芯片的驱动能力；IoT AP 使用 HT20，不能为了关闭 AP 的 Wi-Fi 6 模式而移除 ath11k 驱动。

| 项目 | CPE 默认值 |
| --- | --- |
| SSID | `CPE-s13-IoT` |
| 无线频段 | 2.4 GHz，802.11b/g/n 兼容模式 |
| 信道与带宽 | 1（2412 MHz），HT20（20 MHz） |
| 国家代码 | CN |
| 加密 | WPA2 Personal，CCMP/AES |
| PMF / WPS /隐藏 SSID | 关闭 / 关闭 / 关闭 |
| LAN | `lan`，沿用 `192.168.13.0/24` |
| 客户端隔离 | 关闭，家庭设备可与 LAN 控制设备通信 |
| WMM / legacy rates | 开启 / 开启，允许较旧客户端 |

Wi-Fi 5 是 802.11ac，通常运行在 5 GHz；本需求的兼容设置是 2.4 GHz b/g/n 的 HT20，而非 HE20/HE40。硬件能力见 [RE-SS-01 硬件表](https://openwrt.org/toh/hwdata/jdcloud/jdcloud_re-ss-01)，选项语义见 [OpenWrt 无线配置](https://openwrt.org/docs/guide-user/network/wifi/basic)。2026-10-03 经可信 `192.168.11.1` 跳板和 Headscale SSH 读取 `ss01-12.hs.jmsu.top`：机型为 RE-SS-01，2.4 GHz 实际是 radio1、信道 1、CN、`HE20`、WPA2/CCMP、LAN；运行态也广播 `RE-SS-01`，当前保存与运行配置均没有 `wrt-lot`。因此采用其信道 1、地区和加密，但把 HE20 改为 HT20，以满足用户要求的旧 IoT 兼容模式。未读取参考设备密码。信道 1 是初始预设，现场如有干扰可以在 LuCI 改为 6 或 11。

无线客户端桥接到同一个 LAN，因此沿用 Ethernet IPv4 主用、SIM IPv4 兜底及蜂窝 IPv6 策略。无需为 IoT 增加独立的 mwan3 出口。WAN IPv6 仍关闭；SIM 限额门禁、Tailscale/eMMC 身份持久化、Lucky 和 Nikki 配置保留。

## 私有密码与首启

密码只存储于仓库 Secret `CPE_WIFI_PASSWORD`，仅 CPE B 显式传递；源码、文档和测试均不含实际密码。`WRT_CPE_WIFI` 默认关闭。启用时必须同时启用 CPE overlay 和 artifact 加密，缺少有效密码时构建失败。

CI 将密码写入 root-only 的 `/etc/cpe5g/wifi.key`。固件仍可从该文件恢复密码，所以私有固件检测将其分类为 `cpe-wifi-credential`，只允许维护公钥加密 artifact。密码不进入 cache identity、上传日志或明文配置测试包。

首启 worker 等待 wrtbak 恢复终态、识别实际 2.4 GHz radio 后，创建独立的 `wireless.cpe5g_iot` AP 并应用上述兼容参数。不会假设 radio0/radio1 顺序。新镜像的 mac80211 配置生成模板默认关闭所有原厂 AP，避免网络服务先广播上游默认密码；只有私有 worker 成功应用密码后才开启 IoT AP。由上游生成的 `default_radioN`、`CPE-5G` 原厂 AP 会关闭，包括默认 5 GHz AP，防止广播使用上游默认密码的额外热点；已有自定义 SSID 和其他频段配置保留。保留配置升级时先等待恢复再管理 CPE 专属 AP；此 AP 的 SSID、密码和兼容参数属于 CPE 预设，额外自建 AP 仍由用户管理。

A 保持 NOWIFI 隔离配置，不注入 Wi-Fi 密码；普通 QCA 或其他设备也不会启用此预设。

## 验证与上线门禁

2026-10-03 已用固件固定的真实 UCI `66127cd76c5d0bd46d5a90302cc6110f53a4e2f8` 在独立临时目录验证配置提交与特殊字符密码往返、无线配置 `0600`、radio 顺序变化、保留用户 AP、幂等、提交失败清理、重载重试和恢复门禁。暂存使用 `uci -t`，并逐项读回校验；测试没有访问现场配置或实际密码。

本轮还验证生成配置、密码保护、radio 顺序变化、幂等收敛和保留用户 AP；CI 校验完整无线 package selection 和加密产物。全固件构建成功只证明构建与产物完整，不证明无线可用。

实机须确认 RE-SS-01 2.4 GHz radio 正常、HT20/信道1/WPA2 生效，实际 IoT 设备完成关联、DHCP、DNS、LAN 控制和互联网访问。再验收 Ethernet/SIM 新连接切换、原生 IPv6、已有 SIM 额度门禁、Tailscale 身份持久化、两次软重启、一次冷启动及 CPE 管理地址。WAN 故障实验仍要求独立救援路径与定时回滚。未满足设备门禁前，已验证 NOWIFI B 保留为回退基线。
