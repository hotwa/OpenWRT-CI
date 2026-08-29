# Agent Runtime 版本策略

本文档定义 `OpenWRT-CI` 里边缘智能体运行时（OpenCode / Pi / Hermes / Multica 及其依赖）的版本取舍：**哪些允许自动跟随上游最新版，哪些必须硬 pin 只能人工改**，以及保证这两层不互相打断的联动闸门。

后续 agent 或维护者修改 `Scripts/node-agent-runtime/`、`Scripts/fetch_node_runtime.sh`、`Scripts/fetch_uv_runtime.sh`、`Scripts/fetch_multica_runtime.sh` 或 `.github/workflows/Agent-Runtime-Bump.yml` 前，先读本文。

## 核心原则：应用层浮动，底座硬 pin

| | 应用层（float） | 运行时底座（pin） |
| :--- | :--- | :--- |
| 内容 | agent CLI、CLI 插件、包管理器、Multica | Node.js、uv、离线 CPython、OpenWrt 源码、内核 |
| 版本策略 | 自动跟随上游 latest | 精确版本 + 校验和，只有人改 |
| 改动方式 | `Agent-Runtime-Bump.yml` 每日自动提交到 main | 人工 commit，需说明体积/开机影响 |
| 出错代价 | 单个 agent 命令不可用，重刷即恢复 | 整条 rootfs 的 ELF 布局、musl 目标、编译工具链，甚至能否开机 |

应用层之所以敢浮动：它是纯 JS + 平台分包，升级失败会被下面两道门槛在**提交前**挡掉。底座之所以必须浮动禁止：`fetch_uv_runtime.sh` 的每一个镜像条目都是不可压缩的 `install_only` tar.gz，直接计入固件体积；而 OpenWrt 源码 commit / 内核一变，就要走 `README.md` 基线表和 RE-SS-01 实机验证流程（见 `docs/upstream-merge-policy.md`、CPE-5G 基线条目）。

## 层 1：自动跟随最新（`Agent-Runtime-Bump.yml` 负责）

| 组件 | pin 位置 |
| :--- | :--- |
| `opencode-ai`、`@earendil-works/pi-coding-agent`、`hermes-agent`、`pnpm` 及全部 opencode/pi 插件（共 12 个依赖） | `Scripts/node-agent-runtime/package.json` + `package-lock.json` |
| Multica CLI/daemon | `Scripts/fetch_multica_runtime.sh` 的 `MULTICA_VERSION` 默认值 |

`Scripts/bump_agent_runtime.sh` 是唯一的升级入口：`plan` 只报告，`apply` 重写上述文件并跑完全部门槛。它不碰底座任何一行。

## 层 2：硬 pin（只允许人工修改）

| 组件 | pin 位置 | 当前值 |
| :--- | :--- | :--- |
| Node.js LTS | `Scripts/fetch_node_runtime.sh` `NODE_DEFAULT_VERSION` / `NODE_FALLBACK_VERSION` | 24.20.0 / 22.23.2 |
| uv 二进制 + 双架构校验和 | `Scripts/fetch_uv_runtime.sh` `UV_VERSION` / `UV_*_SHA256` | 0.12.7 |
| 离线 CPython 发布集 | `Scripts/fetch_uv_runtime.sh` `PYTHON_RELEASE_TAG` | 20260825 |
| 离线 CPython 系列 | `Scripts/fetch_uv_runtime.sh` `PYTHON_SERIES` | 3.11 3.12 3.13 |
| OpenWrt 源码 commit | 各设备工作流 `WRT_COMMIT`（`RE-*` / `CPE-5G.yml`） | RE: `a4638cd4…`，CPE: `0bad8929…` |
| 内核 | 随 OpenWrt 源码 commit，不单独 pin | — |

`PYTHON_SERIES` 不是"随便挑的三个版本"，每一档都有明确消费者：3.11 是 `hermes-agent` npm postinstall 显式 `--python 3.11` 请求的受管解释器，3.12 是 multica/agent 运行时文档版本，3.13 是 uv 的默认解析目标。删掉任何一档都必须先确认对应消费者已经消失。

## 联动闸门

浮动层一旦升到"需要新的解释器系列"，就会撞上固定层。三道闸把这种耦合变成显式失败：

1. **升级期**（`bump_agent_runtime.sh apply`）：对 `arm64` 与 `x64` 各做一次真实交叉 `npm ci --os=linux --cpu=<cpu> --libc=musl`，断言对应的 `opencode-linux-<cpu>-musl` 平台包已解析出来，并读出 hermes 的 `pythonVersion` 与 `PYTHON_SERIES` 比对；随后跑完整仓库守卫套件。任一门槛失败 → 非零退出 → 工作流不提交。
2. **构建期**（`fetch_node_runtime.sh` `write_agent_runtime_policy()`）：读 `node_modules/hermes-agent/package.json` 的 `pythonVersion`，在 `wrt/files/opt/uv/python-mirror/manifest.txt` 里查该系列，缺失即 `ERROR` 终止编译。这要求 `WRT-CORE.yml` 保持 uv → node → multica 的调用顺序（当前在 466-468 行）。
3. **守卫测试**：`tests/test_uv_runtime_preload.sh` 要求 3.11/3.12/3.13 在列、禁止 3.10；`tests/test_agent_runtime_policy.sh` 把本文档、升级脚本、工作流和构建期互锁绑在一起断言。

## "每次编译都是最新版吗？"

不是，也不应该是。编译从不访问 registry 取 `@latest`：`fetch_node_runtime.sh` 用 `npm ci` 按 `package-lock.json` 安装，Node/uv/CPython/Multica 用脚本里的 pin。所以**固件新鲜度 = 最近一次 bump 提交的时间**，自动任务每日 UTC 19:00（北京时间 03:00）跑一次，最大滞后 24 小时。想立刻跟进：手动 dispatch `Agent-Runtime-Bump`（勾 `dry_run` 可只看报告不提交）。

本仓库所有工作流都没有 `push` 触发器，bump 提交不会自动引起编译，只会作用于下一次派发的构建。

## 刷机即用与设备端升级

`/opt` 是只读 squashfs，设备上的全局安装必须落到 `/data`：

- `/etc/init.d/uv-storage` 建出 `/data/node` 并在 `/tmp/uv-env.sh` 里导出 `NPM_CONFIG_PREFIX`/`npm_config_prefix=/data/node`、`PNPM_HOME=/data/node/bin`；
- `/etc/profile.d/20-node-agent.sh` 把 `/data/node/bin` 排在 `/opt/node/bin` 之前，`NODE_PATH` 同序，所以交互式 shell 里的 `opencode`/`pi`/`hermes` 优先命中 `/data` 的新版本；
- procd 不加载 `profile.d`，因此 `/etc/init.d/multica` 与 `/etc/init.d/hermes-runtime` 各自显式设置 `PATH`；
- CI 会裁剪 `hermes-agent` 里烤进 runner 环境的 `runtime/python` 与 `venv`（x86_64/glibc，在 aarch64/musl 上根本无法执行），首启由 `/etc/init.d/hermes-runtime`（START=96，晚于 uv-storage 的 90 与 multica 的 95）调用 `/usr/sbin/hermes-runtime-provision`，按 `/etc/agent-runtime/agent-update.env` 记录的 `HERMES_NPM_VERSION` 在 `/data` 重装。

因此设备侧 `npm i -g <pkg>@latest` / `hermes update` 只会前进，重刷固件即回到该固件的基线版本；`/etc/profile.d/30-agent-update-check.sh` 只做 24h 登录提示，不改版本。`agent-update.env` 里的 `HERMES_PYTHON_SERIES` 是给上面第 2 道闸和离线镜像用的契约记录，provisioner 本身不消费它——它只保证请求的解释器系列能在 `/opt/uv/python-mirror` 里命中。
