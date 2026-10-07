# 本机 Pi 与 OpenWrt 插件差异（2026-10-07）

比较本机 Windows 和 WSL root 的 settings.json 加载清单，与固件 catalog；这不是全部磁盘已安装包的清单。版本和 npm/Git 安装来源差异不视为缺包。

| 本机插件/扩展 | 固件情况 | 说明 |
|---|---|---|
| pi-plan-mode | 未预装 | 固件已有 pi-agent-modes，作用有重叠，不能简单视为等价 |
| remote-pi | 未预装 | 远程 Pi 操作；需另验 musl 与服务资源 |
| @eko24ive/pi-ask | 未预装 | 需检查无人值守任务的交互行为 |
| @cortexkit/pi-magic-context | 本次加入可选预装 | Windows 有，WSL root 清单没有；固件默认不加载 |
| extensions/codex-subagent.ts | 未预装 | 本机定制桥接，不可直接搬用 Windows/WSL 路径 |
| hindsight-windows-home.ts | 未预装 | Windows 专用路径适配，OpenWrt 不需要 |
| @aaronkyriesenbach/pi-package-manager | 有替代包 pi-package-manager | 旧 scoped 包有意不重复预装 |
| @monotykamary/pi-tps（Git 来源） | 独立包未预装 | CLIProxyAPI provider 自带 TPS 扩展，避免双重统计 |
| @luxusai/pi-hindsight（Windows 本地路径） | 已预装同名 npm 包 | 路径不同不代表缺少；仍需后端配置 |
| pi-cost / pi-cache-graph / pi-inspect（Git 来源） | 已预装同名 npm 包 | 安装来源不同 |
| pi-mcp-adapter | 本次从固件移除 | 启用 Pi 内置 MCP；本机 Windows/WSL 设置本次未修改 |

固件另有 pi-lazy-extensions、pi-tool-search、pi-subagents、@capdiem/pi-todo、@zephyrdeng/pi-review、pi-interactive-shell、@narumitw/pi-statusline；pi-web-access 安装后惰性加载。以上未因本次比较自动删除或添加。

## MCP 迁移边界

固件默认启用 builtin:mcp。开机 settings 合并明确删除适配器 npm 名称和已知 nicobailon Git 来源，移除 -builtin:mcp，保留其它插件、模型、配置及认证文件。未知本地路径适配器保持不动，避免误删自定义扩展。

迁移仅处理加载配置：适配器专有配置不会自动转换为 Pi 原生服务器配置；原生 MCP 应读取 ~/.pi/agent/mcp.json 或项目 .pi/mcp.json。尚需真实服务器调用验收。旧的不可变 generation 不原地卸载 npm 包，新编译的 generation 才不包含该依赖。
