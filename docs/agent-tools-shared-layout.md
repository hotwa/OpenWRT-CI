# Pi / CommandCode / Multica 共享工具目录

## 目录布局

```text
/data/shared/agent-tools/
├── skills/<name>/SKILL.md
├── mcp.json                 # 可选，仅供 CommandCode user scope
└── README.md
```

`/data/shared/agent-tools` 是唯一真源。Pi 和 CommandCode 的入口由
`/usr/sbin/agent-tools-link` 管理：

```text
/data/pi/agent/skills         ─┐
/data/commandcode/skills      ─┼─> shared/agent-tools/skills
/data/commandcode/mcp.json    ─┘    (仅当目标不存在且共享 mcp.json 存在)
```

脚本是幂等的：不存在入口时创建目录软链接；入口已是普通目录时，只为缺失的
Skill 创建单项软链接；已有 Skill、普通 `AGENTS.md` 或 MCP 文件不会被覆盖。
`/data` 挂载和 Multica 启动阶段都会运行一次，管理员新增 Skill 后也可以手动运行
`agent-tools-link` 刷新。

## 三个智能体的职责

- **CommandCode**：读取 `~/.commandcode/skills`（本机为 `/data/commandcode/skills`）
  和用户级 `AGENTS.md`；MCP 由 `cmd mcp add --scope user` 管理。
- **Pi**：读取 `/data/pi/agent/skills` 与 `APPEND_SYSTEM.md`；Pi 本身没有内置 MCP，
  需要扩展或 Skill/CLI 封装。
- **Multica**：只负责队列、Agent 注册和把任务交给 Pi，不直接解析 Skills/MCP。

共享目录禁止放入密码、Token、Cookie、私钥或生产凭据。MCP 配置中的命令和 URL
也必须先审阅；凭据通过 root-only 环境变量或外部密钥机制注入。

## 维护基线

当前固件角色卡基线为 `04cc174`（包含 `5cfbcb3` 的 runtime、DNS、bootstrap 与
自动升级改动）。实际刷入镜像以 `/etc/openwrt-ci/firmware-commit` 为准。
