# Pi 与 CommandCode 角色卡同步

OpenWRT-CI 将 Pi 和 CommandCode 的 OpenWrt 运维规则收敛到同一份动态角色卡：

```text
/data/multica/openwrt-agent.md
├── /data/pi/agent/APPEND_SYSTEM.md   (Pi)
└── /data/commandcode/AGENTS.md       (CommandCode)
```

`/root/.pi` 和 `/root/.commandcode` 只是指向 `/data` 的兼容软链接。`multica`
启动前会重新渲染角色卡，并调用 `/usr/sbin/pi-append-system-link` 与
`/usr/sbin/commandcode-role-link` 修复这两个入口。CommandCode 每轮请求重新读取
用户级 `AGENTS.md`，所以角色卡更新后不需要重启。

## 冲突处理

`commandcode-role-link` 只在 `AGENTS.md` 不存在时创建软链接；如果管理员已经有
普通文件或指向其他文件的软链接，它会保留原文件并记录提示，不会覆盖项目策略。
需要合并时由管理员明确编辑 `/data/commandcode/AGENTS.md`，并保留对
`/data/multica/openwrt-agent.md` 的引用。

## 固件基线

镜像会写入 `/etc/openwrt-ci/firmware-commit`。在 CI 构建中该值由当前
OpenWRT-CI `GITHUB_SHA` 自动生成；角色卡动态事实区会显示实际刷入的提交。
当前维护基线为 `04cc174`（包含前置提交 `5cfbcb3`），其中 `5cfbcb3` 的运行时/DNS/bootstrap 修复和本次提交的角色卡同步共同包含：

- 动态读取 Tailscale MagicDNS 名称的 Quad100 UDP 探针；
- runtime 更新后同名 Multica Agent 自动 rebind/adopt；
- 每日 03:00、无活动任务时才执行的签名 runtime 检查/升级；
- profile 临时文件清理和 CommandCode 角色卡入口同步。

诊断 runtime、DNS 或 bootstrap 异常时，先读取 `/etc/openwrt-ci/firmware-commit`
和 `/data/multica/openwrt-agent.md`，不要把历史提交、设备型号或分区号当成当前
事实。
