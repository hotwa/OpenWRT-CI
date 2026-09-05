# Multica Agent bootstrap 与 runtime 重绑定

`multica-agent-bootstrap` 负责启动后让本机管理 Agent 存在于当前在线的
Multica Pi runtime。它不是 runtime 升级器；`agent-runtime` 负责切换签名的
Pi/Multica generation，bootstrap 负责升级后的恢复和绑定。

## Runtime 选择

- 优先使用配置的 runtime 名称、provider 和 `online` 状态。
- runtime 名称可能在固件升级、设备重命名或重新注册后变化；如果精确名称没有
  在线匹配，则按 provider 与本机 `device_info` 的稳定设备前缀匹配。
- 设备前缀比较不区分 ASCII 大小写；多个候选时选择 `last_seen_at` 最新者。
- 不依赖固定 runtime ID，也不把旧的 offline runtime 当作当前运行时。

## Agent 选择与恢复

1. 若 `/data/multica/.agent_state` 中的 Agent ID 仍可用，沿用该 ID。
2. 否则按 Agent 名称和当前 runtime 精确查找。
3. 若 runtime ID 已改变但 workspace 中存在唯一同名可用 Agent，则采用该 Agent，执行
   `multica agent update --runtime-id <current-runtime-id>`，并重新写入 state。
4. 只有没有可采用的同名 Agent 时才执行 create；多个同名候选保持失败并重试，避免
   猜错或覆盖其他设备。

因此，删除 `/data/multica/.agent_state` 不会再因为服务端已有同名 Agent 而进入
永久 409 重试循环。`/data` 上的 Agent 状态仍应保留；不要把 token 或完整配置写入
仓库、日志或角色卡。

## 现场检查

```sh
logread | grep multica-agent-bootstrap
multica runtime list --output json
multica agent list --output json
```

成功后日志包含 `default agent is registered on the expected online runtime`，且
`/data/multica/.agent_state` 记录新的 `runtime_id`。旧 runtime 可以保留作审计；删除
旧 runtime 不是 bootstrap 恢复的必要步骤，需单独确认没有其他 Agent 依赖。
