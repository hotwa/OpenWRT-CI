# JDCloud eMMC 数据盘首次启动初始化

智能体的可变状态始终使用真实挂载点 `/data`；不要把数据分区挂到 `/opt`。
`/opt/node` 与 `/opt/agent-runtime` 是固件内不可变运行时基线，挂载覆盖
`/opt` 会阻断 Node、Pi、CommandCode 与 Multica 的回退路径。

## 布局

首次启动准备成功后，目录职责如下：

- `/data/multica/workspaces`：Multica 工作区；
- `/data/multica`、`/data/agent-runtime`、`/data/pi`、`/data/commandcode`：运行时和
  智能体状态；
- `/data/smb`：Samba 文件目录，与智能体状态隔离；
- `/opt/data -> /data`、`/opt/smb -> /data/smb`：仅为人工管理提供的兼容链接。

Samba 共享本身仍需要在 LuCI 中配置用户和权限；固件不会创建匿名可写共享。

## 自动分区门槛

`98-provision-emmc-data` 只在 `agent-storage.main.enabled=1` 时运行，并且只
接受 `jdcloud,re-ss-01`、`jdcloud,re-cs-02`、`jdcloud,re-cs-07`。它不会选取
“最大的分区”或通用的 `userdata` 分区。

它要求精确的 GPT 拓扑中同时存在 `rootfs` 和 `rootfs_data`，仅使用最后一个
现有分区之后、GPT 尾部之前的连续空间；实际大小由设备扇区数自动计算，最小
容量为 1024 MiB。创建前会把 GPT 备份至：

`/overlay/emmc-data-provision-<board>-<timestamp>.gpt`

若 GPT 的备用表过期，脚本在备份后用 `sgdisk -e` 修复，再验证可用扇区范围。
任何白名单、拓扑、容量、分区号、设备节点或文件系统验证失败都会拒绝格式化。
新分区固定为 ext4，标签 `openwrt-data`，随后由
`99-auto-mount-data` 写入 UUID fstab、挂载 `/data` 并迁移状态。

部分内核需要重启一次才会暴露新分区节点。脚本仅为它刚创建且仍无文件系统的
分区留下私有 pending 标记；下一次启动只会完成该精确分区，绝不重新选择磁盘。

## 启用策略

公共/通用 WRT-CORE 默认关闭此功能。当前只在 `RE-SS-01 Build Only` 中启用，
作为实机门槛；RE-CS-02 和 RE-CS-07 代码受支持但必须各自完成分区表、刷写和
冷启动验证后，才可在相应工作流中打开。已经存在 `LABEL=openwrt-data` 的设备
不会被重新格式化。
