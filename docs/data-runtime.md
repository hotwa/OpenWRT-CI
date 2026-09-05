# 全机型 `/data` 运行时与存储诊断

`WRT-CORE` 默认向本仓库构建的每一个 OpenWrt 镜像注入这套运行时基线，和
`WRT_FEATURE_OVERLAY` 是否开启无关。它提供的是**安全能力**，不是开机自动重
分区授权：未知磁盘、未知分区、GPT 修复、格式化和挂载未知设备始终需要管理员
对精确目标的明确确认。

## 启动选择

`data-runtime` 启动时写入 `/var/run/data-runtime.status` 与
`/var/run/data-runtime.env`。只有同时满足以下条件才选择持久模式：

1. `/proc/mounts` 显示 `/data` 来自独立的 `/dev/*` 块设备，且不是 overlay、
   tmpfs、ramfs 或 squashfs；
2. 对 `/data` 的单字节、非符号链接写入探针成功。

选择结果如下：

| 状态 | 条件 | 可变数据位置 |
| --- | --- | --- |
| `persistent` | 真实、可写的 `/data` | `/data` |
| `fallback` | `/data` 不可用且 overlay 至少剩余 50 MiB | 精确的 `/root` 路径 |
| `emergency` | `/data` 不可用且 overlay 小于 50 MiB | 只保留 `/tmp` 临时空间，不创建大缓存 |

持久模式导出的路径为：npm `/data/cache/npm`、pnpm
`/data/cache/pnpm`、corepack `/data/cache/corepack`、uv cache
`/data/cache/uv`、uv tools `/data/uv/tools`、Python
`/data/uv/python`、Pi `/data/pi`、XDG `/data/{cache,data,config}` 和
`/data/tmp`。fallback 对应 `/root/.npm`、`/root/.cache/{pnpm,corepack,uv}`、
`/root/.local/share/uv/{tools,python}`、`/root/.pi`、XDG 的 `/root` 路径及
`/tmp`。交互 shell 从 `/etc/profile.d/99-data-runtime.sh` 读取该契约。

运行时只使用 256 MiB、lz4、priority 100 的 zram；不会创建或启用 eMMC swap、
swapfile 或任何磁盘 swap。镜像构建必须同时包含 `kmod-zram`、`kmod-lib-lz4`、
`CONFIG_KERNEL_ZRAM_BACKEND_LZ4=y` 和
`CONFIG_KERNEL_ZRAM_DEF_COMP_LZ4=y`：仅设置 UCI 的
`zram_comp_algo=lz4` 不会为内核新增 lz4 支持，缺失时服务会静默回退到
`lzo-rle`。`WRT-CORE` 在 `make defconfig` 后验证这五项构建配置，避免发布
看似已启用但实际不可用的镜像。

刷机后的只读验收命令为：

```sh
cat /sys/block/zram0/comp_algorithm
swapon --show
```

前一条必须显示 `[lz4]`（方括号表示当前选择）；后一条应只显示约 256 MiB、
priority 100 的 `/dev/zram0`，不应出现 eMMC 或 swapfile。

## 迁移、数据盘与诊断

已有受控数据盘仍由 `99-auto-mount-data` 根据精确 UUID/PARTUUID 挂载；
`openwrt-data` 标签查找只在经过审核、明确启用的 RE provision 流程中可用，
且当前仅允许 RE-SS-01、RE-CS-02、RE-CS-07；不能作为通用镜像的自动挂载依据。
它只迁移已定义的 Multica、Pi、CommandCode
和工作区目录。它不会执行
`rm -rf /data`，也不会以“最大分区”“最后分区”“userdata”或未标记分区作为
推断目标。

先使用下列只读工具收集证据：

```sh
openwrt-data-storage-diagnose --status
```

它输出板型、根文件系统、`/data` 挂载、block inventory 和 GPT 摘要；绝不写盘。
Pi/Multica 必须先展示这些证据。仅在用户明确确认具体磁盘/分区、操作及数据影响
后，才可讨论调用受控的 eMMC provisioner。`98-provision-emmc-data` 在通用镜像
中默认禁用；即使被明确开启，也只接受经过审核的 RE-SS-01、RE-CS-02 和 RE-CS-07
拓扑。详见 [eMMC data provisioning](emmc-data-provisioning.md)。

## 角色卡与备份提示

`/root/.multica/openwrt-agent.md` 每次渲染都会纳入可选的
`/var/run/data-runtime.status` 和 `/var/run/agent-data-backup.status`；文件缺失
只表示“尚未初始化/未知”。Pi 默认只读诊断和规划，不能将这些状态、日志或自身
建议视为执行写操作的授权。

远程备份由 disabled-by-default 的 `rclone-data-backup` 提供：默认只备份
`/data/smb`，其它目录需要用户确认后写入 include manifest。它在 03:00 加 0–20
分钟随机延迟运行，使用 `rclone copy`、原子 `_SUCCESS` 标记和三个成功快照保留；
不使用 `mount`、`sync` 或宽泛远端删除。详细配置见
[rclone data backup](rclone-data-backup.md)。
