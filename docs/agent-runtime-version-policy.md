# Agent Runtime 版本策略

本文档定义 `OpenWRT-CI` 的边缘智能体运行时（OpenCode / Pi / Hermes /
Multica）版本边界：哪些输入可由自动化跟随上游，哪些底座必须人工精确
pin，以及设备如何只接受完整、已签名的运行时 generation。

修改 `Scripts/node-agent-runtime/`、`Scripts/fetch_node_runtime.sh`、
`Scripts/fetch_uv_runtime.sh`、`Scripts/build_hermes_core.sh` 或
`.github/workflows/Agent-Runtime-Bump.yml` 前，先读本文和
`docs/agent-runtime-release.md`。

## 核心原则：应用层浮动，底座硬 pin

| | 应用层（float） | 运行时底座（pin） |
| :--- | :--- | :--- |
| 内容 | agent CLI、CLI 插件、包管理器、Multica | Node.js、uv、离线 CPython、OpenWrt 源码、内核 |
| 版本策略 | 自动化解析 latest，但写入精确 lock/pin | 精确版本 + 校验和，只有人工改 |
| 交付方式 | 每小时 UTC 第 0 分钟构建、探测并发布一对已签名的不可变 generation | 随固件人工提交；改动须说明体积与启动影响 |
| 设备行为 | 仅经 `agent-runtime` 下载、验签、健康检查并原子切换完整 generation | `/opt` 中的固件基线是只读回退源 |

应用层自动化并不让设备解析 `@latest`。`Agent-Runtime-Bump.yml` 只在
arm64 与 x64 musl 的完整 generation 都已构建和探测后，才签名 index 与
manifest、发布 release；成功发布后才把验证过的应用层 pin 提交到 `main`。
任何失败均不发布、不提交。底座不能浮动：Node、uv、CPython 镜像、源码
commit 或内核变化会改变 ELF、musl 或固件体积契约。

## 层 1：自动跟随最新（`Agent-Runtime-Bump.yml`）

| 组件 | pin 位置 |
| :--- | :--- |
| `opencode-ai`、`@earendil-works/pi-coding-agent`、`hermes-agent`、`pnpm` 及 OpenCode/Pi 扩展 | `Scripts/node-agent-runtime/package.json` + `package-lock.json` |
| Multica CLI/daemon | `Scripts/fetch_multica_runtime.sh` 的 `MULTICA_VERSION` |
| 受审查的 `pi-plan-mode` | `Scripts/node-agent-runtime/vendor/pi-plan-mode/` |

`Scripts/bump_agent_runtime.sh` 是浮动层的唯一升级入口：`plan` 只报告，
`apply` 才重写 lock/pin，并交叉安装 arm64/x64 musl，再运行仓库守卫。
它绝不写入底座 pin。设备上的 Runtime Manager 不运行 `npm install`、
`pnpm update` 或 `hermes update`。

## 层 2：硬 pin（只允许人工修改）

| 组件 | pin 位置 | 当前值 |
| :--- | :--- | :--- |
| Node.js LTS | `Scripts/fetch_node_runtime.sh` 的 `NODE_DEFAULT_VERSION` / `NODE_FALLBACK_VERSION` | 24.20.0 / 22.23.2 |
| uv 二进制 + 双架构校验和 | `Scripts/fetch_uv_runtime.sh` 的 `UV_VERSION` / `UV_*_SHA256` | 0.12.7 |
| 离线 CPython 发布集 | `Scripts/fetch_uv_runtime.sh` 的 `PYTHON_RELEASE_TAG` | 20260825 |
| 离线 CPython 系列输入 | `Scripts/fetch_uv_runtime.sh` 的 `PYTHON_SERIES` | 3.11 3.12 3.13 |
| OpenWrt 源码 commit | 各设备工作流的 `WRT_COMMIT` | RE: `a4638cd4…`，CPE: `0bad8929…` |
| 内核 | 随 OpenWrt 源码 commit，不单独 pin | — |

### CPython 3.11 去重契约

`PYTHON_SERIES` 是**构建输入**，不是最终镜像中每个 archive 都必须保留的
清单。Hermes bridge 元数据的 `pythonVersion` 决定 Core 所需的系列；目前为
3.11。`build_hermes_core.sh` 必须先从受校验的本地 `file://` mirror 创建
Core 的受管 Python 3.11 venv，并验证 Core metadata 与 bridge 的系列一致。
完成后，它只删除该 manifest-verified 3.11 `install_only` archive 和对应
manifest 行：解释器已经随 Hermes Core venv 留在 `/opt`，所以不能再把同一
CPython 打包两次。3.12/3.13 仍为其他消费者保留。

因此不得删除 `PYTHON_SERIES` 的 3.11，也不得取消 metadata/镜像匹配门；
同样不得删除 Hermes Core 构建后的精确去重步骤。将来 Hermes 改用其他系列
时，必须先同步 bridge metadata、Core、mirror、去重逻辑及其测试。

## 联动闸门

1. **升级与发布期**：`bump_agent_runtime.sh apply` 对 arm64 与 x64 做真实
   `npm ci --os=linux --cpu=<cpu> --libc=musl`，并确认 Hermes 声明的
   `pythonVersion` 属于 `PYTHON_SERIES`。CI 构建完整 Core generation，探测
   OpenCode/DCP、Pi、Hermes 与 Multica；随后运行守卫、签名并发布。
2. **固件构建期**：`fetch_node_runtime.sh` 使用 `npm ci --ignore-scripts`，
   由 `build_hermes_core.sh` 以 pinned uv 和本地 CPython mirror 构建
   Core-only Hermes。`write_agent_runtime_policy()` 检查 bridge 和 Core 的
   Python 系列相同。`WRT-CORE.yml` 必须保持 uv → node → multica 顺序。
3. **设备升级期**：`agent-runtime` 仅从固定 release URL 取得签名 index、
   manifest 与 bundle；验证签名、架构/musl/Node ABI、哈希、空间和健康后，
   才原子切换 `current`。失败 generation 不会成为活动版本。

这些是 CI/构建/设备软件门槛，不等于已完成某型号的真机验收。把某个 runtime
generation 推广到固件或生产设备前，仍需按目标设备的独立刷写、启动、网络和
回退门禁执行；不得把 QEMU 或 CI probe 表述为实机验证。

## 固件基线、generation 与设备端路径

每个固件先在只读 `/opt` 提供一个 immutable baseline；它是 `agent-runtime`
在 `/data` 不可用、下载失败或 generation 不兼容时的回退源。升级后的完整
generation 放在 `/data/agent-runtime/generations/`，由 `current`/`previous`
链接原子选择。`/data/node` 只是 Runtime Manager 发布的**兼容链接**，指向
活动 generation 的 Node 前缀；它不是可写的 npm/pnpm 全局安装位置，也不能
被手工替换为目录。

`/etc/profile.d/20-node-agent.sh` 让交互 shell 优先解析活动 generation；
procd 不加载 `profile.d`，所以 `multica` 和 `hermes-runtime` 必须显式设置
自己的 `PATH`。`/etc/profile.d/30-agent-update-check.sh` 仅在 SSH 登录时
显示状态和 `agent-runtime upgrade`/verify/rollback 指引，不修改版本。

Hermes 始终是离线 Core：构建时用锁定源码和本地 CPython mirror 生成
Core-only venv；首启 `hermes-runtime-provision` 只做本地健康检查，绝不调用
npm、pnpm、uv、git、curl 或 wget 进行联网 provision。设备处于无 WAN 或空
`/data` 时，仍应能使用健康的 `/opt` 基线。

## “每次编译都是最新版吗？”

不是。固件构建按已提交 `package-lock.json` 和底座 pin 复现；它不会从 registry
取得 `@latest`。自动任务每小时检查一次上游，但只有完整双架构 generation
已验证、签名和发布后，新的应用层 pin 才会进入 `main`。手动 dispatch 可用
`dry_run` 仅查看报告，或用 `force_release` 重建当前已验证输入的签名通道。
