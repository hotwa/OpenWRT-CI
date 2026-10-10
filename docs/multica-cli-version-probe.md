# Multica 版本探测在 OpenWrt 上的快速路径

Multica 0.6.1 对每个 CLI 的 `--version` 调用有 10 秒上限。CS02 的 Pi
和 OpenCode 在高负载下偶发超过该上限，导致本轮 provider 缺席。两者近乎
同时被 SIGKILL 与并发启动、各自触发相同上限一致，不能单凭时间差认定
共用一个超时 context。

固件的 Multica procd 实例只给版本探测与任务启动提供两个透明 wrapper：
`MULTICA_PI_PATH=/usr/sbin/multica-pi-cli` 从活动签名 generation 的
manifest 读取 Pi 版本，`MULTICA_OPENCODE_PATH=/usr/sbin/multica-opencode-cli`
从 OpenCode 管理器的活动版本目录读取版本。只有文件和版本格式均有效时才走
快速路径；否则调用真实 CLI。除单独的 `--version` 外，全部参数原样交给原
CLI，不改变任务运行方式、Agent ID 或 runtime ID。

验收时需在设备上对照 wrapper 与真实 CLI 的版本输出，并在正常及高负载
注册周期中核验 `daemon.log` 的 `agent version detected` 和
`registered runtime`。固件打包测试只证明静态配置与 wrapper 行为，不能
替代高负载实机验收。
