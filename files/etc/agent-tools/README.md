# 共享 Agent 工具目录

这是 Pi、CommandCode 与 Multica 共享 Skills 的持久化真源：

```text
/data/shared/agent-tools/
├── skills/<name>/SKILL.md   # Agent Skills 标准目录，可由管理员维护
├── mcp.json                 # 可选：CommandCode user-scope MCP 配置（不放秘密）
└── README.md
```

固件不会预置业务 Skills 或 MCP 凭据。`/usr/sbin/agent-tools-link` 在 `/data`
挂载后把 `skills` 入口接到 Pi 与 CommandCode；管理员新增 Skill 后再次运行该命令
即可刷新入口。已有普通目录、Skill 或 `mcp.json` 不会被覆盖。

Pi 没有内置 MCP；需要 MCP 时请使用已安装扩展，或把 MCP 服务封装成带 README 的
Skill/CLI。CommandCode 的共享 MCP 建议使用 `cmd mcp add --scope user`，并把非
敏感配置审阅后放入此目录。
