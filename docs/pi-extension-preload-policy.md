# Pi 扩展预装与兼容性策略

## 目标

OpenWRT-CI 在每次构建 Node.js 24 musl agent-runtime 时，从受控的包名目录解析
Pi、CommandCode 和扩展的最新版本。每一份候选 generation 都在构建临时目录中生成
自己的精确 `package-lock.json`、Peer 对齐记录和组件清单；镜像不在首启时联网安装
扩展，也不允许在不可变 generation 中执行 `npm install` 或 `pi update`。

## 当前预装清单

`Scripts/node-agent-runtime/package.json` 只保存允许预装的包名和 `latest` selector，
不固定 Pi 或插件版本。构建完成的精确版本记录在 generation 内的
`node/agent-runtime-resolved.json` 与 `node/agent-runtime-package-lock.json`：

| 包 | 构建策略 | 运行说明 |
|---|---|---|
| `pi-package-manager` | latest | `/packages` 管理界面；不再同时预装旧的 `@aaronkyriesenbach/pi-package-manager` |
| `pi-commandcode-provider` | latest | Pi 调用 CommandCode provider |
| `pi-agent-modes` | latest | 支持 `--modes yolo` 无人值守模式，Multica agent 通过 `--custom-args` 启用；交互式 pi 保持正常模式 |
| `pi-web-search` | latest | 联网搜索 |
| `pi-lazy-extensions` | latest | 只注册 `ext` 代理；按 manifest 激活重型扩展 |
| `pi-tool-search` | latest | 默认只公开紧凑工具清单；非核心工具须按名称解锁 |
| `pi-undo-redo` | latest | `/undo`、`/redo` 与工作区快照；非 Git 目录只覆盖显式 `write`/`edit` 路径 |
| `pi-mcp-adapter` | latest | 单一 MCP 代理入口；服务和 schema 按需发现、连接 |
| `pi-web-access` | latest，惰性 | 仅在 `lazy-extensions.json` 中登记；由 `ext` 按需加载，不写入 Pi 的 `packages` 启动列表 |
| `pi-lsp` | latest | LSP 诊断与导航；仅在受信配置声明语言服务器后启动外部进程 |
| `pi-cost` / `pi-inspect` | latest | 成本与会话检查面板；只在显式启动命令后监听本机 5461/5462 |
| `pi-cache-graph` | latest | `/cache` 图表、统计与导出；无运行时依赖 |
| `pi-subagents` | latest | 默认最多并发 1–2 个 |
| `@capdiem/pi-todo` / `@zephyrdeng/pi-review` | latest | 任务清单 / 代码审查 |
| `@luxusai/pi-hindsight` | latest | 需 `HINDSIGHT_BASE_URL` 与 root-only token 引用 |
| `pi-interactive-shell` | latest | 仅在明确需要 SSH/REPL 时调用 |
| `@narumitw/pi-statusline` / `btw-pi` | latest | 两者都触及 footer，视觉重叠时停用其一 |
| `pi-wechat-assistant`、Pi、CommandCode、pnpm | latest | 和扩展一起进入同一候选 generation |

构建中的 `ensure_pi_extension_peers.js` 先读取实际装入的 Pi 版本，扫描所有默认扩展
声明的 `@earendil-works/*` peer/dependency，再把这些 peer 精确对齐到**本次实际 Pi
版本**。这包含缺失的 `pi-tui` 等包；它只写构建临时目录，不把版本写死在仓库。
随后 `verify_pi_extensions.js` 使用 Pi 自己依赖的 Jiti 和等价 alias 映射逐个 import
启动扩展及登记为惰性的扩展入口。任何缺包、版本漂移、入口错误或 import throw 都会打印包名与原因并以非零退出。

明确不**启动预加载**：`pi-web-access`、`pi-mcp-extension`、`pi-code`、
`@narumitw/pi-subagents`、`@henryqw/pi-subagent`，以及无 scope 的旧版
`pi-hindsight`。`pi-web-access` 是受支持的例外：它会随 generation 安装并通过同一
Jiti import gate 校验，但只由 `/data/pi/agent/lazy-extensions.json` 以惰性方式激活；
其余包要么功能重复，要么使用旧的 Pi scope/peer 范围。
独立的 `@monotykamary/pi-tps` 也不默认预装：
`@router-for-me/pi-cliproxyapi-provider` 已声明并加载自己的 `tps.ts`，同时加载两套
TPS 扩展会重复统计、提示和状态展示。需要独立 `pi-tps` 时，应先停用 provider
包内的 TPS 入口并完成单独兼容性验证。

## RE-CS-02 现场验收

2026-09-05 在 `root@192.168.11.1`（RE-CS-02，Pi 0.85.0，Node.js 24.20.0，aarch64）
完成以下检查：

1. 用 `pi install npm:<package>` 串行安装候选包，npm 审计结果为 0 vulnerabilities。
2. `/opt/node/bin/pi list` 能列出全部新增包；为避免重复注册，现场设置移除了旧的
   `@aaronkyriesenbach/pi-package-manager` 条目。
3. Pi 的 Jiti loader 已在 RE-SS-01 工作区逐一导入候选扩展，修复前能稳定复现
   `Cannot find module '@earendil-works/pi-tui'`。
4. `@napi-rs/keyring` 的 `linux-arm64-musl` 原生模块与 `zigpty` 的
   `linux-arm64-musl` 原生模块均可加载。

另外，现场曾复现 `@earendil-works/pi-tui` 缺失导致的扩展加载错误；后续不再依赖
人工指定 0.85.0，而是每次构建把它对齐到当前 Pi 版本并做实际 import。

这证明安装、Pi 启动解析和 musl/aarch64 原生模块加载通过；它不替代对某个具体 MCP
服务、Hindsight 后端或真实 subagent 任务的业务验收。

## 构建与升级边界

- `Scripts/fetch_node_runtime.sh` 以 `npm install --ignore-scripts --legacy-peer-deps`
  解析本次 latest catalog，生成临时 lockfile 后执行 peer 对齐和 Jiti import；随后才
  按目标架构清理外来平台二进制。
- `Agent-Runtime-Bump.yml` 在 arm64/x64 musl generation 中再次执行同一个 Jiti
  import 探针与原生模块加载探针；任一扩展加载失败都不发布新 generation。
- 禁止在设备的不可变 runtime 内单独升级某个扩展。需要试用新插件时应在独立项目树
  完成 peer 对齐和 Jiti import 后，再将包名加入 catalog；避免形成 Pi 核心与 peer
  版本漂移。
- 升级前后的 runtime generation 必须保留 `previous`；设备先完成无活动任务窗口
  的原子切换和 bootstrap rebind，异常时使用 `agent-runtime rollback` 回退整套
  Pi/CommandCode/Multica，而不是只回退一个 npm 包。
- Pi 设置写入包名，扩展在构建期进入 runtime 的全局 `node_modules`；因此镜像首启不
  依赖 npm registry。
- 固件默认 `settings.json` 注册全部 `openwrtPiExtensions`；`openwrtPiLazyExtensions`
  只安装且由 `/data/pi/agent/lazy-extensions.json` 注册，绝不写入 `packages`。每次启动时
  `agent-data-prep` 使用固件内 Node 解析 JSON，只把缺失的默认包追加到持久化
  `/data/pi/agent/settings.json`；用户选择的 provider、model、自定义字段和已有包均
  保留。无效 JSON 会告警并保持原文件不变，成功更新通过同目录临时文件原子发布。
  如果合并前普通文件 `.firmware-settings-managed` 的 mtime 与 settings 匹配，重写后
  会在再次确认 settings 的设备号、inode、mtime、大小均未变化后同步该既有 marker；
  缺失、过期或符号链接 marker，以及合并后被管理员再次修改的 settings，一律不创建、
  不更新 marker。
  该迁移严格为 **append-only**：以后从固件默认清单删除扩展，并不会自动从持久配置
  卸载它；如确需移除，必须同时提供独立、明确且经过审阅的持久配置迁移，不能仅靠
  删除 catalog 条目。
- `pi-tool-search` 使 `ext` 和 `mcp` 等非核心工具也经过名称解锁；这是预期的两阶段
  交互（先 `tool_search`，下一轮再调用已解锁工具）。默认不接入外部 `one-search` MCP：
  它需要单独审阅服务器地址、认证与数据出境策略，不能把凭据或不受控远程端点写入固件。
- runtime generation 更新必须走 `/usr/sbin/agent-runtime` 的验签、健康检查、原子切换
  和回滚；不要在 `/data/node`、`/opt/node` 或 `/data/agent-runtime/current` 原地更新。
- Hindsight 的 URL、API token、OAuth、Cookie 和业务密钥只能通过设备 root-only 环境
  注入，不能写入此清单、角色卡或固件。
