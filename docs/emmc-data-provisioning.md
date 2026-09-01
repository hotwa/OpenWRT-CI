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

## 已存在历史数据分区与升级保留

已刷入早期固件的三种 JDCloud 设备可能已经有 GPT 名称为 `data`、文件系统却
没有 `openwrt-data` 标签的尾部分区；其分区号并不作为兼容契约。这是已知兼容
布局，不代表损坏：

- 只有当 `data` 分区是 GPT 中唯一同名项、位于磁盘末尾、紧邻前一个分区、GPT
  类型为 Linux filesystem，并且板型在白名单时，固件才读取它。其真实分区号会
  写入一次性批准记录；`99-auto-mount-data` 只会卸载该设备对应的已知匿名挂载，
  再以文件系统 UUID 挂到 `/data` 并写入 fstab。后续 `sysupgrade` 直接恢复 UUID
  挂载，不依赖 `/dev/mmcblk0p*` 名称。
- 只有同一精确尾部 `data` 分区未挂载且 `blkid` 完全识别不到文件系统时，才会初始化为
  ext4/`openwrt-data`。这不是对“分区异常”的泛化修复：未知文件系统、非末尾几何、
  已被管理员挂到其他目录的分区，以及无法读取的 GPT，全部保持不动并等待人工处理。
- 格式化步骤有 900 秒（15 分钟）硬上限。超过上限会终止该次 mkfs，并在
  `/overlay/.emmc-data-provision.failed` 记录失败；首启脚本不会在每次重启或
  `sysupgrade` 后重复格式化。人工确认后才可清除该标记并重新执行受控恢复。

因此，健康的 `/data` 在升级模式刷写后保留；Python、Pi、CommandCode 与 Multica
的可写状态也会随该 UUID 挂载恢复。若 `/data` 没有成为真实挂载点，uv 会安全地
显示未就绪并拒绝把 CPython 写入根文件系统，而不是伪装成可用。

## 启用策略

公共/通用 WRT-CORE 默认关闭此功能。私有 RE Mesh（RE-SS-01、RE-CS-02）和
RE-CS-07 工作流明确启用它；其它机型仍必须先完成分区表、刷写和冷启动验证。
已经存在 `LABEL=openwrt-data` 的设备不会被重新格式化。
