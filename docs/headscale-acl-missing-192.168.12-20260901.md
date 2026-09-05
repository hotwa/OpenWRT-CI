# Headscale ACL 缺失 192.168.12.0/24 授权导致跨站 LuCI 无法访问 — 诊断报告与方案 A 落地卡点

日期：2026-09-01
范围：Headscale（ECS `112.124.106.23`，`standalone-headscale` v0.29.3）policy ACL / Tailscale subnet 路由
相关仓库：`ops/headscale/policy.json`、`ops/headscale/policy-control.sh`

---

## 一、现象

办公网 `192.168.11.0/24`（RE-CS-02 / 100.64.0.47）访问宿舍 `192.168.12.1`（RE-SS-01 / 100.64.0.46）时：

- `root@RE-CS-02 ping 192.168.12.1`：**通**（0.5ms，ttl=253）
- `tailscale ping 100.64.0.46`：**通**（直连 218.199.162.115:41641）
- Edge 打开 `http://100.64.0.46/cgi-bin/luci/`：**可访问**
- Edge 打开 `http://192.168.12.1`：**打不开**

用户误判为"headscale 已批准路由"，但批准 ≠ ACL 授权，实际是 ACL 缺规则。

---

## 二、根因（最终结论）

**headscale 的 subnet route 只会分发给 ACL 允许「该节点 → 该网段」的节点。**

`approved_routes`（批准）只代表"允许广告方发布该路由"；ACL 才决定"哪些节点能用它"。

完整证据链：

| 层级 | 状态 | 证据 |
|---|---|---|
| 46 已 advertise `192.168.12.0/24` | ✅ | 46 `debug prefs` AdvertiseRoutes |
| headscale 已批准（approved） | ✅ | `nodes list-routes` node 70 `approved_routes: ["192.168.12.0/24"]` |
| 但 47 的 netmap 未收到该路由 | ❌ | 47 `status --json` 中 peer 70 AllowedIPs 只有 `100.64.0.46/32`+IPv6，无 `192.168.12.0/24` |
| 47 table 52 缺该路由 | ❌ | `ip route show table 52` 无 192.168.12.0/24 |
| LAN→12.1 走了错误路径 | ❌ | `ip route get 192.168.12.1 from 192.168.11.159 iif br-lan` → `via 122.205.79.254 dev pppoe-wan`（走 WAN，未进 tailscale0） |
| **ACL 无任何规则授权访问 192.168.12.0/24** | ❌ | `policy.json` acls 的 dst 只出现 8/9/10/11/101 网段，**无 12 网段** |

不对称佐证：46 的 table 52 **有** `192.168.11.0/24`（来自 47，ACL 有 dst 11 网段），而 47 没有 12 网段 —— 单向缺失，正是 ACL 缺失的典型形态。

**"批准了却不行"的解释**：批准与 ACL 授权是两回事。重启 tailscaled / 重启路由器均无效，因为问题在控制面（headscale），不在客户端。

---

## 三、已做的实测验证

1. **重启 47 tailscaled（nohup）**：`RESTART_DONE`，但 table 52 仍无 12 网段，`ip route get` 仍走 pppoe-wan。
   → 证明非客户端 netmap 陈旧，而是控制面未下发。
2. **headscale 侧核对**（ECS `docker exec standalone-headscale`）：
   - v0.29.3 路由命令已并入 `nodes`：`headscale nodes list-routes -o json`
   - node 70（46）/ node 71（47）approved_routes 均正常。
3. **本地 Windows 无 Tailscale**：无 `tailscale.exe`，路由表仅 `192.168.11.0/24`；`100.64.0.46` 能通完全靠 RE-CS-02 的 `lan_to_tailnet` masq 转发。

---

## 四、方案 A（推荐）内容

修改 `ops/headscale/policy.json` 规则 17：

```jsonc
// 原：
{ "action": "accept", "src": ["tag:openwrt", "192.168.11.0/24"],
  "dst": ["192.168.8.0/24:*", "192.168.9.0/24:*", "192.168.10.0/24:*", "192.168.101.0/24:*"] }
// 改（src 用 tag:openwrt，dst 扩到整个 192.168.0.0/16）：
{ "action": "accept", "src": ["tag:openwrt"], "dst": ["192.168.0.0/16:*"] }
```

要点：
- **dst = `192.168.0.0/16`**：未来任意新 192.168.x 网段（13、14…），只要 headscale 侧 approve，就自动分发给所有 `tag:openwrt` 路由器，无需再改 policy —— 满足"以后新增网段零改动"。
- **src 只留 `tag:openwrt`，不放 `192.168.0.0/16`**：LAN 裸客户端流量经 `lan_to_tailnet` masq 后源变成路由器节点（tag:openwrt），所以 src=tag:openwrt 即正确语义；同时**保留对 `192.168.1.1`（各站点本地 WAN 网关，README 明确必须保持本地、不得进 table 52）的隔离**。
  - 若把 src 也扩成 `192.168.0.0/16`，则 `192.168.11.100 → 192.168.1.1:80` 会被放行，破坏既有 deny 测试 —— 已在 ECS 实测复现。
- 全量改动 = live + 方案A，其余规则（含 tag:ci-debug）与 live 完全一致（`diff` 验证 IDENTICAL-EXCEPT-RULE17）。

---

## 五、落地的硬卡点（为何 apply 被阻塞）

`policy-control.sh apply` 报 `sync_state=conflict`，fail-closed 拒绝："refusing to overwrite a Headplane/live policy change"。

两个独立遗留问题：

### 卡点 1：孤儿 pending apply（已定位）
- 8-29 遗留 `.git/headscale-policy-pending.json`（state=`external-canary-pending`，policyHash=5efc49，applyBackupId=20260829-084531）。
- 其远端备份 manifest 显示 `phase: applied`、afterHash=5efc49 —— 即该操作**已完成**，且 live 已被后续 headplane 修改（422bb2）超越。
- 由于 `apply` 逻辑在 `pending_hash != local_hash` 处直接 return 73，孤儿 pending 会**永久阻塞**任何新 apply。
- 处理：已备份到 `.git/headscale-policy-pending.orphan-20260829.bak` 并删除该孤儿文件。（脚本 recovery 分支设计上到不了，因前置 hash 检查先拦截。）

### 卡点 2：外部 canary 节点 100.64.0.29 已退役/失联
- schema-2 的 `record-verified` 必须由外部节点 `100.64.0.29`（README 记为 node 49 / openwrt-dae-wrt-11）提交回执，才能把 live 确立为"已验证基线"。
- 但 headscale 节点列表里**已无 node 49 / 100.64.0.29**；现 node 52 同名 `openwrt-dae-wrt-11` 持有 `100.64.0.25` 且 **offline**（dae 已按 AGENTS.md 剪除改用 Nikki）。
- 直连与 ECS tailscale-gw 代理均不可达。
- **因此官方 `record-verified` 流程无法闭环** → `conflict` / `converged-unrecorded` 状态下无法自动记录基线，apply/sync 全部 fail-closed。

附加事实：基线 policy 的 `check` 本就有 4 条 `100.64.0.29 → 192.168.8/9/10/101:443` 失败（该节点已不存在）—— `check` 全绿在当前环境本就不可达。

---

## 六、已改动与未改动清单

**已改动（未 commit）**
- `ops/headscale/policy.json`：写入方案 A（含 ci-debug 对齐 live，规则 17 改 dst=/16）。
- 删除孤儿 `.git/headscale-policy-pending.json`（备份于 `.git/headscale-policy-pending.orphan-20260829.bak`）。

**未改动 / 未提交**
- live headscale policy 数据库：未变更（仍是 422bb2，含 ci-debug，无 12 网段授权）。
- `policy-sync-state.json`：未改动。
- 无任何 commit。

**注意**：仓库 `policy.json` 当前与 live 不一致（conflict），且相对原仓库还多出 tag:ci-debug 规则（原仓库本就落后于 live）。若暂不落地，需决定保留方案 A 改动还是还原仓库文件。

---

## 七、后续可选路径

1. **绕过 canary 直接应用（最快）**：ECS 上先备份 live，再
   `docker exec standalone-headscale headscale policy set -f /path/policy.json`；
   随后手动同步仓库 + 更新 `policy-sync-state.json`。
   缺点：绕过官方守卫，需人工确认无 side effect。
2. **迁移 canary 节点**：把外部回执来源从已退役的 100.64.0.29 迁到在线节点（如 RE-CS-02/RE-SS-01），
   更新 README 与 `record-verified` 依赖，再走官方 apply 闭环。较完整但工作量大。
3. **当前先不动 live**：仅保留方案 A 仓库改动与本文档，待用户决策。

---

## 八、验证方法（落地后）

```bash
# 47 上
ip route show table 52 | grep 192.168.12        # 应出现 192.168.12.0/24 dev tailscale0
ip route get 192.168.12.1 from 192.168.11.159 iif br-lan   # 应变为 dev tailscale0（不再 pppoe-wan）
# 办公 Win11 浏览器
http://192.168.12.1/cgi-bin/luci/                # 应可访问
```

若 headscale 侧已 approve 但 47 仍未拿到，`tailscale up --accept-routes` 强制刷新一次 netmap 即可。
