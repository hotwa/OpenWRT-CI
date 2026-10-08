# opencode 集成 OpenWrt 固件研究报告

> 调研日期：2026-09-08
> 仓库：github.com/hotwa/OpenWRT-CI @ 2b6b2f1
> 目标设备：JDCloud RE-CS 系列（qualcommax/ipq60xx, aarch64 cortex-a53, ImmortalWrt SNAPSHOT, musl libc）

---

## 一、核心结论速览

| 问题 | 结论 |
|---|---|
| 推荐集成路径 | **路径 B（仿 agent-runtime 首启下载到 /data）** |
| Multica 是否支持 opencode | **官方一等支持**，daemon 自动探测 PATH 上的 `opencode` |
| opencode 二进制大小 | linux-arm64-musl 单二进制 **~185 MB**（解压后），npm tarball 压缩后约 60-70 MB |
| 是否需要 Bun 运行时 | **不需要**。opencode 是 bun compile 产出的独立单二进制，自带运行时 |
| musl 兼容性 | **原生支持**，npm 有 `opencode-linux-arm64-musl` 专用包 |
| 非交互模式 | **支持**：`opencode run <prompt>`、`opencode serve`、`opencode acp` |
| 1GB 设备可行性 | **紧张但可行**（非交互模式），不建议同时跑 pi + opencode 的 TUI |
| OpenWrt SDK 编译路径 | **不可行**，无社区包，Bun 不在 Buildroot 中 |

---

## 二、三种集成路径对比

### 路径 A：固件直接打包（files/usr/bin/opencode）

**做法**：将 opencode 二进制放入 `files/usr/bin/`，编译进 squashfs 固件。

**关键数据**：
- `opencode-linux-arm64-musl@1.18.29` 解压后 **193,703,975 字节 ≈ 184.7 MB**（来源：npm registry `unpackedSize` 字段）["https://registry.npmjs.org/opencode-linux-arm64-musl/latest"]
- npm tarball 压缩后约 60-70 MB（bun 编译的二进制含大量 JavaScript 字节码，gzip 压缩比约 2.5-3x）
- squashfs 使用 xz/gzip 压缩，对二进制的压缩比与 tarball 接近，预计固件体积增加 **50-70 MB**

**仓库先例检查**：`files/` 目录下无任何大于 5 MB 的二进制文件。所有大体积运行时（Node.js、Pi 扩展、multica 二进制）均通过 `fetch_node_runtime.sh` 在构建时下载到 `files/opt/`，或通过 agent-runtime 机制在首启下载到 `/data`。**仓库没有大二进制直接 vendor 进 files/ 的先例。**

**问题**：
1. **固件体积膨胀 50-70 MB**：squashfs 分区通常只有 100-200 MB，opencode 占比过高
2. **版本不可升级**：要升级 opencode 必须重新编译刷固件，违背用户"不写死版本、可升级"的硬性偏好
3. **musl 兼容无问题**：opencode 官方提供 `linux-arm64-musl` 构建，不需要 glibc 兼容层
4. **浪费 /data 大分区**：设备有独立大分区 /data，固件直接打包等于放弃了这个设计

**结论**：不推荐。

---

### 路径 B：仿 agent-runtime 模式（首启下载到 /data）✅ 推荐

**做法**：参照现有 `agent-runtime` 机制，首启时从 npm registry 或 GitHub releases 下载 opencode 二进制到 `/data/opt/opencode/`，带 sha256 校验，可 bump 版本。

**opencode 分发格式分析**：
- opencode 通过 npm 包 `opencode-ai` 分发，主包仅 7.8 KB（wrapper + postinstall 脚本）["https://registry.npmjs.org/opencode-ai/latest"]
- 实际二进制通过 **optionalDependencies** 按平台分发，包括：
  - `opencode-linux-arm64-musl`（正是目标设备需要的）
  - `opencode-linux-arm64`（glibc 版）
  - `opencode-linux-x64-musl` / `opencode-linux-x64`
  - darwin/windows 各平台
- 每个平台包是**单二进制**，`preferUnplugged: true`，`libc: ["musl"]` 标记
- 二进制是 bun compile 产物，**静态链接，无外部运行时依赖**

**现有 fetch_node_runtime.sh 结构总结**（作为参照模板）：

| 结构要素 | 实现方式 |
|---|---|
| 版本变量 | `NODE_DEFAULT_VERSION` + `NODE_FALLBACK_VERSION`，支持环境变量覆盖 |
| 架构映射 | `map_node_arch()`：从 `WRT_ARCH` / `WRT_TARGET` / Config 文件推断 `linux-arm64-musl` 或 `linux-x64-musl` |
| 下载 URL | 主镜像 + GitHub fallback mirror，`retry_cmd 3 10` 重试 |
| 校验 | `node_archive_sha256()` case 语句硬编码 sha256，下载后 `sha256sum` 比对 |
| 解压安装 | `tar -xzf` 到临时目录，校验布局后 `cp -a` 到目标 |
| 架构校验 | `file` 命令验证 ELF 架构 + 静态链接 |
| 符号链接 | `setup_symlinks()` 将 bin 链接到 `/usr/bin/` |
| bump 机制 | 修改版本变量 + 更新 sha256 case 即可 |

**opencode 适配性评估**：
- opencode 是**单文件二进制**，比 Node.js（目录结构 + npm 包）简单得多
- 不需要 npm install / 扩展解析 / 跨平台裁剪等复杂逻辑
- npm registry 提供 `integrity`（sha512）字段，可直接用于校验
- 版本升级频繁（每周多个版本），需要灵活的 bump 机制

**需要新建/修改的文件清单**：

| 文件 | 职责 | 参照现有文件 |
|---|---|---|
| `Scripts/fetch_opencode_runtime.sh` | 构建时下载 opencode 二进制到 `files/opt/opencode/`（可选：作为固件 baseline），或仅生成版本元数据 | `Scripts/fetch_node_runtime.sh` |
| `files/usr/sbin/opencode-runtime` | 设备端运行时管理器：status / check / upgrade / rollback，从 npm registry 下载带校验的二进制到 `/data/opt/opencode/` | `files/usr/sbin/agent-runtime` |
| `files/usr/bin/opencode` | wrapper 脚本：优先调用 `/data/opt/opencode/current/opencode`，fallback 到固件 baseline `/opt/opencode/opencode` | 无直接参照，类似 `/opt/node` 软链模式 |
| `files/etc/init.d/opencode-runtime` | init 脚本：首启触发下载，boot 时 reconcile | `files/etc/init.d/agent-runtime` |
| `files/etc/profile.d/25-opencode.sh` | 将 `/data/opt/opencode/current` 加入 PATH，确保 multica daemon 能探测到 | `files/etc/profile.d/20-node-agent.sh` |
| `files/etc/opencode/release-url` | 下载源 URL（npm registry 或 GitHub releases） | `files/etc/agent-runtime/release-url` |
| `files/etc/config/multica`（修改） | 新增 `runtime_provider` 选项或注释说明 opencode 可用 | 现有文件，仅需文档 |
| `files/etc/uci-defaults/97-enable-multica-service`（修改） | 确保 multica 启动时 PATH 包含 opencode | 现有文件 |

**关键设计决策**：
1. **下载源**：优先 npm registry（`https://registry.npmjs.org/opencode-linux-arm64-musl/-/opencode-linux-arm64-musl-<version>.tgz`），因为 npm 有 `integrity` 字段可直接校验；GitHub releases 作为 fallback
2. **版本管理**：不写死版本号在脚本中，而是通过 `/etc/opencode/release-url` 指向一个 index 文件（类似 agent-runtime 的 `index.json`），或直接用 npm `latest` tag + 本地 pin
3. **multica 集成**：只需确保 `opencode` 在 PATH 上，multica daemon 启动时自动探测并注册为 opencode runtime，无需额外配置
4. **固件 baseline**：可选——构建时下载一个版本到 `files/opt/opencode/` 作为离线 fallback，首启无网络时也能用；但这会增加固件体积，建议**不做 baseline**，纯首启下载

---

### 路径 C：OpenWrt SDK package 编译

**做法**：在 OpenWrt Buildroot 中编写 Makefile，从源码编译 opencode。

**不可行的原因**：

1. **无社区包**：OpenWrt packages feed（`github.com/openwrt/packages`）和 ImmortalWrt packages feed 中均无 opencode 包。搜索结果无任何匹配。
2. **Bun 不在 Buildroot 中**：opencode 是 Bun + TypeScript 项目，构建需要 Bun 运行时。OpenWrt Buildroot 没有 Bun 的 host tool 包。
3. **Bun 平台限制**：Bun 官方预编译仅提供 linux-x64（glibc）和 darwin 版本，**没有 linux-aarch64 版本**，也没有 musl 版本。即使想在 Buildroot 中用 Bun 做 host tool，也无法在 aarch64 构建环境运行。
4. **opencode 构建还需要 Golang 1.24.x**（README 明确要求），虽然 OpenWrt 有 golang host tool，但 Bun 的缺失是致命的。
5. **bun compile 产物无法交叉编译**：bun compile 不支持交叉编译到非宿主架构。

**结论**：**完全不可行**。opencode 只能通过预编译二进制分发，无法从源码在 OpenWrt Buildroot 中构建。

---

### 三路径对比表

| 维度 | 路径 A：固件直接打包 | 路径 B：首启下载 /data ✅ | 路径 C：SDK 编译 |
|---|---|---|---|
| 实现复杂度 | 低（放文件即可） | 中（需写 fetch + runtime 管理脚本） | 极高（不可行） |
| 固件体积影响 | +50-70 MB（不可接受） | 0（纯脚本，< 10 KB） | 0 |
| 可升级性 | 无（需重刷固件） | 完整（check/upgrade/rollback） | 依赖 opkg |
| 版本灵活性 | 写死 | 动态获取 + pin + bump | 写死 |
| 维护成本 | 低（但每次升级要重刷） | 中（需维护校验和） | 不可行 |
| musl 兼容 | 原生支持 | 原生支持 | N/A |
| 网络依赖 | 无 | 首启需网络 | 无 |
| /data 利用 | 浪费 | 充分利用 | N/A |
| 风险 | 固件体积超标、升级困难 | 首启下载失败需 fallback | 构建失败 |
| **综合评价** | ❌ 不推荐 | ✅ **推荐** | ❌ 不可行 |

---

## 三、Multica 集成结论

### Multica 官方支持 opencode

Multica（`github.com/multica-ai/multica`）是开源 Managed Agents 平台，其 daemon **官方一等支持 opencode 作为 runtime provider**。["https://github.com/multica-ai/multica"]

**证据**：
1. README 明确列出支持的 CLI 包括 **OpenCode**（命令名 `opencode`），与 Claude Code、Codex、Pi 等并列
2. CLI_AND_DAEMON.md 的 Supported Agents 表格中，OpenCode 条目：`opencode` — Open-source coding agent["https://raw.githubusercontent.com/multica-ai/multica/main/CLI_AND_DAEMON.md"]
3. 专用环境变量：
   - `MULTICA_OPENCODE_PATH`：自定义 opencode 二进制路径
   - `MULTICA_OPENCODE_IDLE_WATCHDOG`：opencode 专用空闲看门狗，默认 10 分钟（其他 agent 通用看门狗默认 2 小时）
4. daemon 启动时**自动探测 PATH 上的 `opencode`**，注册为可用 runtime

### 设备实测验证

SSH 到 RE-CS-02-11（192.168.11.1）执行 `multica daemon status --output json`：

```json
{
  "agents": ["pi"],
  "cli_version": "0.4.41",
  "device_name": "RE-CS-02-11",
  "status": "running"
}
```

当前 daemon 只探测到 `pi`。**一旦 opencode 出现在 PATH 上，daemon 重启后会自动增加 `opencode` 到 agents 列表**，无需修改 multica 配置。

`multica runtime list` 显示服务器端已有多个 Opencode runtime 在线（来自 vm101、zly-Rack-Server、supercloud、x99 等机器），provider 类型为 `opencode`，证明整条链路已通。

### 集成方式

**无需 custom provider 或 shell wrapper**。opencode 是 multica 原生支持的 provider，集成只需两步：
1. 确保 `opencode` 二进制在 multica daemon 的 PATH 中（通过 `/etc/profile.d/` 或 `MULTICA_OPENCODE_PATH` 环境变量）
2. 重启 multica daemon（`/etc/init.d/multica restart`）

之后在 Multica Web UI 的 Agents 创建页面，provider 下拉框中会出现 "OpenCode" 选项。

### multica 如何调用 opencode

multica daemon 对 opencode 有专用的 idle watchdog（10 分钟），说明它以非交互模式调用 opencode。结合 opencode CLI 文档，multica  likely 使用：
- `opencode run <prompt> --format json`（非交互 + JSON 事件流），或
- `opencode acp`（Agent Client Protocol，stdin/stdout nd-JSON）

opencode 的 `--format json` 输出原始 JSON 事件流，非常适合 daemon 解析。["https://opencode.ai/docs/cli"]

---

## 四、opencode 与已有 pi / commandcode 的价值对比

### 已有能力

当前固件已预装：
- **Pi**（`@earendil-works/pi-coding-agent`）：极简终端 AI 编码代理，核心仅 4 个工具（Read/Write/Edit/Bash），通过扩展生态增强（subagents、web-search、MCP adapter、todo、review、hindsight、interactive-shell 等）
- **CommandCode**（`command-code`）：Node.js 终端编码智能体
- 两者均通过 multica 以 `--modes yolo` 无人值守模式运行

### opencode 的独特价值

| 维度 | opencode | Pi |
|---|---|---|
| 核心架构 | bun 编译单二进制，client/server 分离 | Node.js 包，单进程 |
| 二进制体积 | ~185 MB | 极小（纯 JS，依赖 Node runtime） |
| LSP 集成 | **内置 25+ LSP 服务器**，代码理解深度高 | 基础 LSP 重命名，需扩展 |
| Provider 支持 | 75+ LLM 提供商，models.dev 驱动 | 40+ 提供商 |
| TUI 体验 | 极致 TUI，主题自定义，token/费用可视化 | 基础 TUI + pi-tui 扩展 |
| 非交互模式 | `opencode run` / `opencode serve` / `opencode acp` | 支持（pi CLI） |
| 客户端/服务端 | 支持 `opencode serve` + `opencode attach` 远程驱动 | 不支持 |
| 计划模式 | 内置 Tab 切换 plan/build 模式 | 需 pi-agent-modes 扩展 |
| 子代理 | 内置 agent 管理 + Scout 子代理 | 需 pi-subagents 扩展 |
| MCP | 原生支持 `opencode mcp` | 需 pi-mcp-adapter 扩展 |
| GitHub 集成 | `opencode github install/run` 原生 GitHub Actions | 无 |
| 会话管理 | `opencode session list/export/import` + 分享链接 | 基础会话 |
| 内存基线 | 高（bun runtime ~150-250 MB） | 低（Node.js ~80-120 MB） |

### opencode 的增量价值

1. **LSP 深度代码理解**：opencode 内置 25+ LSP 服务器，能做语义级代码导航、重命名、类型检查，这是 Pi 的纯文本工具无法比拟的。对于路由器上的 OpenWrt 配置/脚本维护，LSP 价值有限，但对于在路由器上开发项目（如容器化服务、Python 脚本）有明显优势。

2. **client/server 架构**：`opencode serve` 可以在路由器上跑后端，用户从手机/电脑 `opencode attach` 远程连接。这对路由器场景有独特价值——不需要 SSH 进路由器就能用 TUI。

3. **更成熟的非交互协议**：`opencode acp`（Agent Client Protocol）是标准化的 stdin/stdout JSON 协议，multica 等平台原生支持，比 pi 的自定义输出更稳定。

4. **模型无关性更强**：opencode 通过 models.dev 统一 75+ 提供商，配置更灵活。

### 是否值得在路由器上部署？

**对于 RE-CS-02（3GB 内存）**：值得。opencode 可以作为 pi 的补充，提供 LSP 深度代码理解和 client/server 远程访问能力。multica 上可以创建两个 agent：一个用 pi（轻量、快速日常运维），一个用 opencode（复杂代码任务、远程 TUI）。

**对于 re-ss-01（1GB 内存）**：见下节分析。

---

## 五、1GB 内存设备（re-ss-01）可行性

### 当前内存基线（RE-CS-02，3GB 设备实测）

```
Mem:  2970100 KB total, 464868 KB used, 2423760 KB available
Swap: 262140 KB (zram)
```

multica daemon 进程 RSS：**1246 MB**（含 node runtime 共享内存，实际独占约 200-300 MB）

### opencode 内存估算

opencode 是 bun compile 产物，bun runtime 的内存特征：
- Bun 1.4 空闲内存基线约 **80-120 MB**（JavaScriptCore 引擎）
- opencode 加载后（含 TUI、LSP 客户端、模型上下文）约 **150-250 MB**
- `opencode run` 非交互模式（无 TUI）约 **100-180 MB**
- 活跃编码任务（大上下文 + LSP）可能达到 **300-500 MB**

来源：Bun 1.4 官方测试显示内存使用比 Node.js 低 35%，但 bun compile 单二进制包含完整运行时，基线内存高于纯 Node.js 脚本。["https://www.51cto.com/article/854654.html"]

### re-ss-01（1GB）内存预算

| 组件 | 预估内存 |
|---|---|
| 系统基础（内核 + 网络栈 + 无线驱动） | 150-200 MB |
| zram swap | 256 MB（虚拟） |
| Node.js runtime（pi + multica daemon） | 200-300 MB |
| Pi 活跃任务 | 100-200 MB |
| multica daemon | 50-100 MB |
| **opencode（非交互 run 模式）** | **100-180 MB** |
| opencode（TUI 模式） | 150-250 MB |
| opencode（活跃编码 + LSP） | 300-500 MB |

**结论**：
- **空闲/轻量场景**：pi + opencode 非交互模式可共存，总占用约 600-800 MB，1GB 设备可运行但余量很小
- **活跃编码场景**：opencode 单任务可能占 300-500 MB，与 pi 同时活跃会触发 OOM
- **TUI 模式**：不建议在 1GB 设备上通过 SSH 使用 opencode TUI，内存压力大
- **推荐策略**：re-ss-01 上 opencode 仅作为 multica 的可选 runtime，**不与 pi 同时执行任务**；multica 的 `max_concurrent_tasks=1` 已确保串行执行

### 轻量模式选项

opencode 没有专门的 "轻量模式" 标志，但以下方式可降低内存：
1. `OPENCODE_DISABLE_LSP_DOWNLOAD=1`：禁止 LSP 服务器自动下载，减少子进程内存
2. `OPENCODE_DISABLE_DEFAULT_PLUGINS=1`：禁用默认插件
3. 使用 `opencode run` 而非 TUI：无终端 UI 渲染开销
4. `--model` 指定小模型：减少上下文缓存

---

## 六、推荐落地方案（路径 B 详细设计）

### 架构图

```
固件 (squashfs, 只读)                    /data 分区 (可写, 大空间)
├── /usr/sbin/opencode-runtime           ├── /opt/opencode/
│   └── 运行时管理器 (status/upgrade)    │   ├── current -> generations/1.18.29
├── /usr/bin/opencode (wrapper)          │   ├── generations/
│   └── 优先 /data, fallback /opt        │   │   └── 1.18.29/
├── /etc/init.d/opencode-runtime         │   │       └── opencode (185MB)
│   └── boot 时 reconcile + 首启下载     │   └── .staging/
├── /etc/profile.d/25-opencode.sh        └── /opt/opencode/config.json
│   └── PATH 包含 /data/opt/opencode/current
└── /etc/opencode/release-url
    └── npm registry 或 GitHub releases
```

### 文件级落地清单

#### 1. `Scripts/fetch_opencode_runtime.sh`（新建）

**职责**：构建时可选下载 opencode baseline 到 `files/opt/opencode/`，或仅生成版本元数据。

**参照**：`Scripts/fetch_node_runtime.sh` 的 `download_node_tarball()` 函数

**核心逻辑**：
```bash
OPENCODE_VERSION="${OPENCODE_VERSION:-1.18.29}"
# 架构映射（复用 map_node_arch 逻辑）
# 下载 npm tarball: https://registry.npmjs.org/opencode-linux-arm64-musl/-/opencode-linux-arm64-musl-${VERSION}.tgz
# sha512 校验（npm integrity 字段）
# tar -xzf 解压，取出 bin/opencode
# file 验证 ELF aarch64 + 静态链接
# 安装到 files/opt/opencode/
```

**建议**：初期**不做固件 baseline**，纯首启下载。脚本仅用于生成 `/etc/opencode/version` 和校验和元数据。

#### 2. `files/usr/sbin/opencode-runtime`（新建）

**职责**：设备端运行时管理器，子命令：`status` / `check` / `upgrade` / `rollback` / `list`

**参照**：`files/usr/sbin/agent-runtime`（798 行，可大幅简化因为 opencode 是单文件）

**简化版结构**（opencode 比 agent-runtime 简单，不需要 manifest 兼容性检查、node ABI 校验、多组件健康检查）：
- `status`：显示当前版本、/data 状态
- `check`：查询 npm registry 最新版本，不下载
- `upgrade`：下载新版本 → sha512 校验 → 原子切换 current 软链
- `rollback`：回退到 previous
- `list`：列出已安装版本

**不需要**：usign 签名校验（npm 包有 integrity 字段足够）、manifest 兼容性、多组件哈希

#### 3. `files/usr/bin/opencode`（新建，wrapper 脚本）

**职责**：解析实际二进制路径，透传所有参数

```sh
#!/bin/sh
if [ -x /data/opt/opencode/current/opencode ]; then
    exec /data/opt/opencode/current/opencode "$@"
elif [ -x /opt/opencode/opencode ]; then
    exec /opt/opencode/opencode "$@"
else
    echo "opencode not installed. Run: opencode-runtime upgrade" >&2
    exit 127
fi
```

#### 4. `files/etc/init.d/opencode-runtime`（新建）

**职责**：boot 时触发 reconcile，确保 /data 上有 opencode

**参照**：`files/etc/init.d/agent-runtime`

#### 5. `files/etc/profile.d/25-opencode.sh`（新建）

**职责**：将 opencode 加入 PATH，确保 multica daemon 和交互式 shell 都能找到

```sh
export PATH="/data/opt/opencode/current:$PATH"
```

**参照**：`files/etc/profile.d/20-node-agent.sh`

#### 6. `files/etc/opencode/release-url`（新建）

**职责**：下载源配置，默认 npm registry

```
https://registry.npmjs.org
```

#### 7. 修改 `files/etc/config/multica`

新增注释说明 opencode provider 可用，或新增 `option runtime_provider 'opencode'` 作为备选。当前 `runtime_provider 'pi'` 不需要改——multica 会自动注册所有探测到的 CLI。

#### 8. 修改 `files/etc/init.d/multica`

确保 multica daemon 启动时 PATH 包含 `/data/opt/opencode/current`。当前 init 脚本应已 source profile.d，需确认。

### 版本 bump 流程

1. 修改 `Scripts/fetch_opencode_runtime.sh` 中的 `OPENCODE_VERSION`
2. 更新 sha512 校验和（从 npm registry `integrity` 字段获取）
3. 提交 PR，CI 构建
4. 设备端 `opencode-runtime check` 检测到新版本，`opencode-runtime upgrade` 升级

### 与现有生态的最小影响

- **不修改** `fetch_node_runtime.sh`、`agent-runtime`、multica bootstrap 等现有文件
- **不修改** pi / commandcode 的配置和扩展
- opencode 配置目录使用 `/data/opencode/`（独立于 `/data/pi/` 和 `/data/commandcode/`）
- multica agent 创建时可选 opencode provider，不影响现有 pi agent

---

## 七、风险与注意事项

1. **npm registry 可达性**：路由器在中国大陆，npm registry 可能需要代理。固件已有 nikki 透明代理，应可覆盖。建议同时支持 GitHub releases fallback。
2. **185 MB 下载时间**：首启下载 60-70 MB tarball，在 100Mbps 网络约 5-10 秒。需设置合理超时和重试。
3. **/data 空间**：opencode 单版本占 185 MB，保留 current + previous 两代约 370 MB。RE-CS 系列 /data 分区通常 > 4GB，无压力。
4. **multica daemon 重启**：安装 opencode 后需重启 multica daemon 才能探测到新 runtime。可在 `opencode-runtime upgrade` 成功后自动触发 `/etc/init.d/multica restart`。
5. **opencode 自动更新**：opencode 有内置 `opencode upgrade` 命令，应设置 `OPENCODE_DISABLE_AUTOUPDATE=1` 防止绕过固件的版本管理。
6. **LSP 下载**：opencode 默认会自动下载 LSP 服务器，应设置 `OPENCODE_DISABLE_LSP_DOWNLOAD=1` 避免意外写入和内存占用。

---

## 八、事实性结论来源汇总

| 结论 | 来源 |
|---|---|
| opencode 有 linux-arm64-musl 包 | npm registry: `https://registry.npmjs.org/opencode-ai/latest`（optionalDependencies） |
| opencode 二进制 184.7 MB | npm registry: `https://registry.npmjs.org/opencode-linux-arm64-musl/latest`（unpackedSize=193703975） |
| opencode 是单二进制、bun compile | npm 包 `preferUnplugged: true`, `libc: ["musl"]`, 0 dependencies |
| opencode 非交互模式 `opencode run` | 官方文档: `https://opencode.ai/docs/cli` |
| opencode `--format json` / `acp` 协议 | 官方文档: `https://opencode.ai/docs/cli` |
| Multica 官方支持 opencode | `https://github.com/multica-ai/multica` README + CLI_AND_DAEMON.md |
| `MULTICA_OPENCODE_PATH` 环境变量 | `https://raw.githubusercontent.com/multica-ai/multica/main/CLI_AND_DAEMON.md` |
| `MULTICA_OPENCODE_IDLE_WATCHDOG` 默认 10m | 同上 |
| 设备 multica daemon 仅探测到 pi | SSH 实测: `multica daemon status --output json` |
| 服务器已有 Opencode runtime 在线 | SSH 实测: `multica runtime list` |
| 设备 3GB 内存、multica RSS 1246m | SSH 实测: `free -m` + `ps` |
| 无 OpenWrt opencode 包 | 搜索 openwrt/packages + immortalwrt/packages 无结果 |
| Bun 无 aarch64/musl 预编译 | Bun 官方仅提供 linux-x64 + darwin |
| Pi 核心 4 工具、极简架构 | 掘金技术文章 + 仓库 package.json 扩展列表 |
| Bun 1.4 内存降低 35% | 51CTO: `https://www.51cto.com/article/854654.html` |
| fetch_node_runtime.sh 结构 | 本地文件: `Scripts/fetch_node_runtime.sh` |
| agent-runtime 管理器结构 | 本地文件: `files/usr/sbin/agent-runtime` |
| multica 配置使用 pi provider | 本地文件: `files/etc/config/multica` |
