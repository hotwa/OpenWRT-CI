# Nikki 启动后恢复

`nikki-boot-guard` 在正常开机流程后延迟 120 秒执行一次。仅当 Nikki 配置已
启用、WAN 默认路由已出现而 mihomo 核心仍未运行时，才在与订阅同步共用的锁下
限时重试一次 `/etc/init.d/nikki start`。它不会改变订阅、代理规则或启用状态。

每日 04:10 的订阅同步在完成后也核验已启用的核心；若核心缺失，仅重试一次并
记录失败，避免“订阅同步成功”掩盖核心未运行。排查时查看
`logread -e nikki-boot-guard`、`/var/log/nikki-subscription-sync.log` 和
`/var/log/nikki/app.log`。若 Nikki 配置允许停机清日志，应在手动重启服务前
先保存日志，否则不能从重启后的日志倒推原始停止原因。
