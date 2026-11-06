# RE-CS-02 的 2.4 GHz IoT 兼容预设

用户提供的 RE-CS-02 / ath11k 现场记录显示：向日葵 C1Pro（Espressif）在
HT/HE 模式下没有关联记录，删除 HT 配置后完成关联及 WPA 四次握手。
这是本设备的现场互操作结果，不代表所有 ESP8266/ESP32 都有相同缺陷。

`/etc/uci-defaults/99-iot-2g-wifi` 仅对 `jdcloud,re-cs-02` 生效，按
`band=2g` 匹配所有射频及其 AP，不依赖 radio 编号或硬件路径。
其首启预设为信道 6、CN、启用 legacy rates、关闭 11n/ax 和 country IE，
**删除 htmode 和 require_mode**；AP 使用 `DAE-WRT-IoT`、WPA2-PSK/CCMP，
关闭 PMF、U-APSD、低 ACK 踢除和 11r/k/v。不要将其改回 HT20/HE20，
也不要用空字符串或 `NONE` 代替删除选项，否则可能破坏已验证的插座兼容性。

HT/HE 属于射频级配置，因此同一 2.4 GHz 射频上的所有 AP 都受影响，
其余 STA 配置保留。两个 5 GHz 射频继续使用既有 HE80/149 和 HE80/36 预设。
兼容模式最高为 54 Mbps 的传统 b/g 速率，适合插座和传感器。
本次不新增 DHCP 绑定，保留原有地址管理。

## 私有编译

RE-Mesh 的 RE-CS-02 job 显式传入仓库 Secret `RE_CS02_IOT_WIFI_PASSWORD`。
值采用用户提供的现有密码，不写入源码、工作流输入或日志。
`Scripts/ConfigureReCs02IotWifi.sh` 只为 `IPQ60XX-RE-CS-02` 注入
`/etc/re-cs-02/iot-wifi.key`（目录 0700、文件 0600），并强制加密产物。
缺少有效密码或未启用加密时构建失败。旧三频预设也从此私有文件读取密码，
保持用户给定的既有 5 GHz 凭据；源码不再保存该预设的明文密码。
非目标机型不会应用此 IoT hook。无线配置未生成时 hook 留待下次启动重试。

## 验证范围

`bash tests/test_jdcloud_recs02_wifi_defaults.sh` 执行首启脚本，覆盖不同
radio 编号、多个 2.4 GHz 射频、重复执行、5 GHz/STA 保持、机型门禁、
无线尚未生成及密码私有分类。可设置 `RECS02_TEST_UCI=/path/to/uci` 使用
真实 UCI；普通 CI 使用命令边界 fixture。

编译后还应检查最终 rootfs 中脚本为 0755、私有密码文件为 0600、
旧首启逻辑不会重设 HT20。只下载加密产物，在私有目录解密验校。
刷机尚未授权：以上验证不能替代实际 hostapd 模式、插座关联、DHCP 和控制测试。
后续实机验收应确认 2.4 GHz 无 HT/HE、两个 5 GHz 仍 HE80，再检查插座的
associated、四次握手、地址分配与实际控制；不输出无线密码。
