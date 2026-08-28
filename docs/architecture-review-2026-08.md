# OpenWRT-CI 系统级架构审查报告

审查对象：`hotwa/OpenWRT-CI`（本地工作树，截至 2026-08-28）
审查范围：Multica Edge Agent、Headscale 异地组网、eMMC `/data` 持久化、CI 工作流与密钥链路
审查方法：逐文件源码审查 + `multica-ai/multica` 上游 `CLI_AND_DAEMON.md` / `CLI_INSTALL.md` 行为核对

---

## 0. 结论摘要

整体架构成熟度较高：Headscale 自动注册的 wrtbak 恢复栅栏、PID 锁、hotplug 重试，Tailscale↔Nikki 的 DNS/路由多层 guard，以及双 Bin 产物校验都体现了生产级考量。但存在 **2 个阻断级（P0）** 问题使核心特性在当前构建产物中不可用或会泄露凭证，另有若干 P1 设计缺陷会在实机上触发 OOM、根分区写满或路由冲突。

| 级别 | 编号 | 问题 | 位置 |
|---|---|---|---|
| **P0** | M-1 | `multica` 二进制从未被下载/打包进固件，daemon 永远起不来 | `Scripts/`、`WRT-CORE.yml` |
| **P0** | S-1 | `PrivateFirmwareGuard` 不扫描 Multica PAT；RE-CS-07 默认公开发布，带 PAT 的固件可被公开 Release | `Scripts/PrivateFirmwareGuard.sh`、`.github/workflows/RE-CS-07-BUILD.yml` |
| **P1** | M-2 | `max_concurrent_tasks:2` 写进 `config.json` 但上游不读该字段，procd 也未传 flag/env，实际默认并发 **20** | `files/etc/init.d/multica:80-108` |
| **P1** | D-1 | `/root/.multica`、`/root/.pi` 在 overlay 中已存在，`99-auto-mount-data` 的软链接被 `[ ! -e ]` 跳过，Pi 会话/缓存写根分区 | `files/etc/uci-defaults/99-auto-mount-data:77-82` |
| **P1** | D-2 | `fetch_node_runtime.sh` 在 CI 中覆盖提交版 `20-node-agent.sh`，丢失 `UV_CACHE_DIR`/`MULTICA_WORKSPACE` 导出 | `Scripts/fetch_node_runtime.sh:181-185` |
| **P1** | D-3 | `uv-storage` 只识别 `/mnt/mmc` 或 `/mnt/*`，不认 `/data`，UV 缓存实际落 `/opt/uv`（rootfs overlay） | `files/etc/init.d/uv-storage:8-22` |
| **P1** | N-1 | RE-SS-01 与 RE-CS-07 默认 `LAN_IP` 均为 `192.168.10.1`，同建会通告重复 `/24` 造成路由冲突 | 两个设备 workflow |
| **P1** | S-2 | `actions/checkout@main` 未 pin SHA；CPE-5G `permissions: write-all` | `WRT-CORE.yml:259`、`CPE-5G.yml:30` |
| **P1** | S-3 | RE-CS-07 未 pin `WRT_COMMIT`，跟踪移动的 `main` 分支，不可复现 | `RE-CS-07-BUILD.yml` |
| **P2** | M-3 | PAT 永久明文存放（UCI 644 + config.json 600），90 天过期无续期，失败不轮转 | `files/etc/config/multica` |
| **P2** | N-2 | Headscale `autoApprovers` 放行整个 `192.168.0.0/16` + 可复用 authkey，泄露即路由劫持 | `docs/tailnet-mesh-multi-site.md` |
| **P2** | S-4 | `viewturbocore` 经 `curl -k` 无校验下载、rc.local 以 root 开机自启 | `Scripts/fetch_viewturbocore.sh:96`、`files/etc/rc.local:6` |

---

## 1. Multica 认证与生命周期审查

### 1.1 阻断：`multica` 二进制不在固件中（M-1，P0）

`files/etc/init.d/multica` 期望二进制位于 `/usr/local/bin/multica`，并在 `start_service()` 中检查：

```sh
[ -x "$PROG" ] || command -v multica >/dev/null 2>&1 || { logger ...; return 1; }
```

但全仓库检索显示，**没有任何脚本下载、编译或打包 `multica` 二进制**：
- `Scripts/Packages.sh` 未引用 multica（它是 Go 二进制，不在 OpenWrt feeds 中）；
- 没有 `fetch_multica_runtime.sh`；
- `fetch_node_runtime.sh` 的 npm 全局包列表不含 multica；
- `Config/*.txt` 无 multica 包；
- `tests/test_multica_auto_enroll.sh` 只断言脚本/配置“存在”，不验证二进制被打入。

上游 `CLI_INSTALL.md` 明确：multica 以 Go 二进制形式通过 GitHub Releases 分发（`multica-cli-${VER}-linux-arm64.tar.gz`），需显式下载 `mv /usr/local/bin/multica`。

**后果**：即使注入了 `MULTICA_TOKEN` 且 `enabled=1`，procd 启动时 `return 1`，daemon 不运行；`multica-agent-bootstrap` 中 `command -v multica` 失败静默退出。整个“零触摸入网 + Agent 自动创建”链路在当前固件中是死代码。

**修复方向**：新增 `Scripts/fetch_multica_runtime.sh`，按 `map_node_arch` 同样的 aarch64/x86_64 映射，从 `github.com/multica-ai/multica/releases` 下载 musl 兼容的静态 arm64 二进制（Go 静态编译可直接跑），校验 SHA256 后安装到 `files/usr/local/bin/multica`，并在 `WRT-CORE.yml` 的 Custom Packages 步骤调用；测试中增加二进制存在性断言。

### 1.2 并发限制未生效，512MB 设备可能 OOM（M-2，P1）

init.d 渲染的 `config.json` 包含：

```json
"max_concurrent_tasks": 2,
"poll_interval": "30s",
"heartbeat_interval": "15s"
```

但核对上游 `CLI_AND_DAEMON.md` 的配置表，这三项只受 **CLI flag 或环境变量** 控制：

| 设置 | Flag | Env | 默认 |
|---|---|---|---|
| Max concurrent tasks | `--max-concurrent-tasks` | `MULTICA_DAEMON_MAX_CONCURRENT_TASKS` | **20** |
| Poll interval | `--poll-interval` | `MULTICA_DAEMON_POLL_INTERVAL` | `3s` |
| Heartbeat interval | `--heartbeat-interval` | `MULTICA_DAEMON_HEARTBEAT_INTERVAL` | `15s` |

`config.json` 是认证/Profile 配置（`server_url`/`token`/`workspace_id`/`device_name` 等），上游文档未记载它读取 `max_concurrent_tasks` 等调优字段。而 init.d 的 `procd_set_param env` 只导出了 `MULTICA_SERVER_URL`、`MULTICA_DAEMON_DEVICE_NAME`、`MULTICA_AGENT_RUNTIME_NAME`、`MULTICA_WORKSPACES_ROOT`、`MULTICA_WORKSPACE_ID`，**未导出并发/轮询相关 env，也未在 command 行传 flag**。

**后果**：daemon 以默认 20 并发认领任务。每个任务会 `exec` 一个 `pi`/`opencode`/`hermes` 子进程，这些 Node/Python Agent 在 512MB RAM 的 IPQ6000 上单实例就可能占用百 MB 级；20 并发必然触发 OOM Killer，可能连带杀死 `tailscaled`/`nikki`/`dropbear`，导致设备失联。这与角色卡中“监控 OOM”的承诺直接冲突。

**修复方向**：在 procd command 行追加 `--max-concurrent-tasks "$max_tasks" --poll-interval "$poll_interval" --heartbeat-interval "$heartbeat_interval"`，或导出对应 env；并建议在 512MB 机型上设为 1（而非 2），同时设置 `MULTICA_AGENT_TIMEOUT` 与 `MULTICA_OPENCODE_IDLE_WATCHDOG` 兜底。

### 1.3 死锁、越权与重启策略分析

- **健康端口 fail-fast**：上游 daemon 启动时绑定 `127.0.0.1:19514` 做健康检查，端口占用即 fail-fast，防止同机重复 daemon。procd `respawn 3600 5 5`（崩溃后 5s 重启，3600s 内崩溃 5 次则放弃）与之配合基本合理。但放弃后 daemon 永久下线，只能等重启或人工 `service multica restart`——对“自愈边缘节点”建议加一个 procd 周期 watchdog 或 cron 兜底重新 enable。
- **前台模式无死锁**：`daemon start --foreground` 由 procd 直接托管 stdout/stderr，不经过 pid 文件，不存在后台模式 pid 残留导致的端口冲突；这一点选型正确。
- **权限越权（设计级风险）**：daemon 以 root 运行，任务子进程（pi/opencode）同样 root，且上游对工具调用“自动批准”（无人值守 accept）。`openwrt-agent.md` 的安全红线只是 prompt 级约束，无任何 cgroup/seccomp/namespace 强制。一旦 `multica.lucky.jmsu.top` 被攻破、PAT 泄露，或 Agent 被注入恶意指令，攻击者即获得所有入网路由器的 root RCE。这是本架构最大的安全面，建议：
  - 为 Agent 任务创建专用低权限用户（如 `multica`），用 sudoers 白名单仅放行 `uci`/`service`/`ip` 等只读或受限命令；
  - 或用 procd 的 `procd_set_param user` + cgroup memory limit 约束；
  - Multica 反代侧启用 mTLS/IP 白名单，PAT 按设备签发短生命周期 token。
- **bootstrap 与 daemon 启动顺序**：init.d 在 `procd_open_instance` **之前** 就 `/usr/sbin/multica-agent-bootstrap &`，随后才启动 daemon。bootstrap 内部先等网络再轮询 `multica runtime list`（30 次 × 4s = 120s），能覆盖 daemon 启动延迟，无死锁。但 bootstrap 内 `main()` 又把 `bootstrap_agent &` 二次后台化后脚本立即退出，该孙进程被 init 收养（Linux 下可存活），但依赖 shell 不发 SIGHUP——比直接用 procd oneshot 或 `start-stop-daemon -b` 脆弱。

### 1.4 PAT 生命周期与存储（M-3，P2）

- PAT 是 90 天有效期的个人访问令牌（`mul_...`），被 `MulticaAutoEnroll.sh` 写入 `/etc/config/multica`（默认 644，全局可读），init.d 再渲染到 `/root/.multica/config.json`（600）。与 Headscale authkey 不同，**PAT 永不删除、永不轮转**：90 天后 daemon 认证失败且无自动续期；任何能读到 `/etc/config/multica` 的本地进程/用户都能窃取 token。
- `MulticaAutoEnroll.sh` 用 `sed -i "s#...#${value}#"` 注入 token，若 PAT 含 `#`、`&`、单引号会破坏 sed 替换或 UCI 语法（Headscale 脚本同理）。应改用 `uci set` 或 awk/printf 安全转义。
- 建议：`chmod 600 /etc/config/multica`；token 不落 UCI，改为 init.d 从仅 root 可读的 `/etc/multica/token` 读取；或通过 `provision_url`（Headscale 脚本已有此机制，Multica 没有）首次启动换取短期 token。

### 1.5 网络就绪探测对 PPPoE 的容错度

- multica bootstrap：`60 × 3s = 180s`。PPPoE 慢协商（尤其 VLAN/IPv6CP）常见 30–90s，180s 通常够但不宽裕；超时后 `return 0` 继续执行，`runtime list` 再轮询 120s，总计约 5 分钟后放弃 Agent 创建（但 `.agent_initialized` 未写，下次 service restart 会重试，可接受）。
- 缺陷 1：无 curl 时 `return 0` 立即放行——只要有默认路由就认为在线，PPPoE 刚拿到 IP 但上游未通时会过早进入轮询（有重试兜底，影响小）。
- 缺陷 2：`multica agent create` 失败时无条件 `touch "$agent_init_flag"`（注释“may already exist”），若是服务端 5xx 等瞬时错误，将永远不再重试自动创建。应区分“already exists”与真失败。
- 对比 Headscale 脚本 `60 × 10s = 600s` WAN 等待 + 600s 注册重试 + hotplug iface 重试，Multica 侧容错明显偏弱，建议对齐到 600s 并复用 hotplug 机制。

---

## 2. 多地 Tailnet 子网路由与安全性审查

### 2.1 路由冲突：默认 LAN_IP 碰撞（N-1，P1）

- `RE-SS-01-BUILD.yml` 默认 `LAN_IP=192.168.10.1`，`RE-CS-07-BUILD.yml` **同样默认 `192.168.10.1`**。若两次都用默认派发，两台设备都会 `--advertise-routes=192.168.10.0/24`。
- Headscale 对重复路由的处理是非确定性的：两个节点都被 auto-approve 后，tailnet 客户端访问 `192.168.10.x` 会被 ECMP 到其中一个站点，表现为“时通时不通/连错站点”。
- 文档 `tailnet-mesh-multi-site.md` 规划的是 11/10/12 三段（11=office、10=home、12=dorm），但工作流默认值没有贯彻。建议：CI 中 `ValidateLanIp.sh` 增加“同批次/同 Headscale 下子网唯一性”校验，或把三台设备默认值改为 11/10/12 并在 README 中固化站点编号表。

### 2.2 autoApprovers 过宽 + 可复用 authkey = 路由劫持（N-2，P2）

文档给出的 ACL：

```json
"autoApprovers": { "routes": { "192.168.0.0/16": ["tag:subnet-router","tag:openwrt"], "10.0.0.0/8": [...] } }
```

且 preauth key 勾选 **Reusable** 并一次性绑定 5 个 tag。风险链：
1. authkey 被写入固件 squashfs，即使首启 `rm /etc/tailscale/headscale.authkey` 只删 overlay，**squashfs 只读层中的 key 仍可通过 unsquashfs 提取**（文档已承认“artifact leaks 需轮转”）；
2. 任何人拿到该可复用 key，都能 enroll 一个恶意节点并 `--advertise-routes=192.168.10.0/24`（或更窄的 `192.168.10.0/25` 以最长前缀优先劫持）；
3. autoApprovers 自动批准，tailnet 流量被导向攻击者节点，实施中间人/嗅探。

**建议**：
- 路由器 key 改为 **单次使用（reusable=false）**，每台设备 CI 派发时通过 Headscale API 动态创建一次性 key（已有 `provision_url` 机制可扩展）；
- autoApprovers 收窄到具体站点 `/24` 而非整个 `/16`；
- Headscale ACL 限制 `tag:openwrt` 之间只能互访已批准子网，禁止 tag 节点直接互访 SSH 以外端口；
- 固件产物中的 authkey 用“首次开机从 provisioning URL 换取”替代烧录。

### 2.3 fw4 边界与子网路由穿透

- `90-tailscale-dropbear-access` 与 `tailscale-lan-tailnet` 设置 tailscale zone `input=ACCEPT output=ACCEPT forward=REJECT`，并仅添加 `lan→tailscale` forwarding。注释称“不做 tailnet→LAN forwarder”。
- 但设备同时 `--advertise-routes` + `--accept-routes`，tailscaled 在 `fw_mode=nftables` 下会自行插入子网路由的 forward accept 规则。这些规则在独立 chain、独立优先级，**会绕过 fw4 zone 的 forward=REJECT**。因此实际跨站点 LAN 互访完全由 Headscale ACL 决定，fw4 的 REJECT 只是“未批准路由”场景下的纵深防御，不能当作安全边界依赖。
- `masq=1` 对 `lan→tailscale` 做 SNAT：LAN 客户端访问 tailnet 时源被改成路由器 100.x 地址。这对“LAN 客户端访问远端”场景可用，但远端节点无法看到真实 LAN 客户端 IP，不利于审计；且若未来要让远端主动访问 LAN 客户端，masq 不影响该方向（该方向由子网路由处理）。当前设计可接受，但需在文档中明确。

### 2.4 accept_routes 策略不一致

- `AGENTS.md` 与 `docs/headscale-auto-enroll.md` 均要求 `headscale_auto_enroll.accept_routes` **默认 0**，理由是可能与 WireGuard/DAE/Nikki/WAN 策略路由冲突；
- `files/etc/config/headscale_auto_enroll` 默认确实是 0；
- 但 `Scripts/HeadscaleAutoEnroll.sh` 在 CI 注入时把它设为 `HEADSCALE_OPENWRT_ACCEPT_ROUTES`（默认 **1**），且 `tailscale-lan-tailnet` 又在 `tailscale.settings.accept_routes='1'`。
- 结果：所有带 authkey 的构建实际 accept_routes=1，与“默认 0、确认无冲突后再开”的策略相悖。建议 CI 默认也保持 0，由每站点 dispatch 输入显式开启，或在文档中更新策略说明。

### 2.5 DNS 链路与 Fake-IP 劫持分析

防护链相对完整：
1. dnsmasq：`server=/hs.jmsu.top/100.100.100.100@tailscale0`（MagicDNS 走 tailscale0）；`server=/headscale.jmsu.top/223.5.5.5` 等控制面域名走公网 DNS，避免鸡生蛋；
2. mosdns：生成 `forward_tailscale_magicdns` snippet 并 `bind_to_device: tailscale0`；
3. Nikki guard：在 `router_dns_hijack` chain 插入 `ip daddr 100.64.0.0/10 return` / `ip6 daddr fd7a:115c:a1e0::/48 return`，把 Quad100 端点改写为 `udp://100.100.100.100:53#tailscale0`，并把 dnsmasq/mosdns/tailscaled 加入 router_access_control 免代理；
4. `tailscale-accept-dns-guard` 持续把 `accept-dns` 拉回 false，防止 MagicDNS 接管系统 DNS。

残留风险：
- **模板补丁脆弱**：`tailscale-nikki-guard` 用 awk 匹配 `^\tchain router_dns_hijack \{$` 注入 return 规则。Nikki 升级若改缩进/链名，补丁静默失效；虽有 `runtime_has_dns_bypass` 检测并重载，但若模板和运行时都未命中，DNS 到 Quad100 会被 Nikki 劫持到 Fake-IP，`*.hs.jmsu.top` 解析为 198.18.x.x，Tailnet 流量误入代理隧道。建议改为 Nikki 官方 UCI 接口（`nikki.mixin.fake_ip_filters` 已有）声明式配置，而非 awk 改模板。
- **dnsmasq `@tailscale0` 启动时序**：若 dnsmasq 先于 tailscale0 启动，设备绑定失败会周期性报错；OpenWrt 下 dnsmasq 通常重试，影响有限但会污染日志。
- **223.5.5.5 硬编码**：控制面域名解析依赖阿里 DNS，存在 DNS 污染/隐私泄露面；建议允许通过 UCI 配置 bootstrap DNS，或用 `1.1.1.1`/`8.8.8.8` 多上游。
- **潜在环路已规避**：dnsmasq→Quad100 是直连，mosdns/Nikki→dnsmasq 不会对 `hs.jmsu.top` 形成环路（该域名被 dnsmasq 短路到 Quad100）。设计正确。

---

## 3. eMMC `/data` 分区与 Agent 运行时稳定性

### 3.1 软链接被 overlay 既有目录击败（D-1，P1）

`99-auto-mount-data` 用 `[ ! -e /root/.multica ] && ln -sfn /data/multica /root/.multica` 创建链接。但：

- 仓库 overlay 本身就含有 `files/root/.multica/openwrt-agent.md`（提交进 Git）；
- `fetch_node_runtime.sh` 在 CI 中还会创建 `files/root/.pi/agent/settings.json`。

因此固件刷入后 `/root/.multica`、`/root/.pi` **已经是真实目录**，`[ ! -e ]` 为假，软链接永远不会创建。后果：

- `/root/.multica/config.json`（含 PAT）落在 rootfs overlay，而非 `/data/multica/config.json`（角色卡描述相反）；
- **Pi 的会话、缓存、状态全部写 `/root/.pi`（rootfs overlay）**，而 `/data/pi` 目录建了却无人使用。Pi 长期运行的会话数据可能撑满根分区；
- `/root/.opencode` 因 overlay 中不存在，软链接生效，OpenCode 数据正确落 `/data/opencode`。

**修复方向**：把软链接逻辑改为“若为真实目录则迁移内容到 /data 并替换为符号链接”，或在构建期把 `files/root/.multica`、`files/root/.pi` 下的静态文件搬到 `/etc/multica`、`/etc/pi` 等只读路径（bootstrap 已支持 `/etc/multica/openwrt-agent.md` 回退），保证 `/root/.multica`、`/root/.pi` 在 overlay 中不存在。

### 3.2 CI 覆盖 profile 脚本丢失 /data 环境变量（D-2，P1）

仓库提交版 `files/etc/profile.d/20-node-agent.sh` 含有：

```sh
export MULTICA_WORKSPACE=/data/multica
export MULTICA_DATA_DIR=/data/multica
export UV_CACHE_DIR=/data/uv_cache
```

但 `fetch_node_runtime.sh` 的 `configure_profiles()` 在 CI 中用 `cat > 20-node-agent.sh` **整体覆盖**为只剩 3 行 PATH/PNPM_HOME/NODE_PATH 的版本。由于该脚本在 `wrt/files` 尚不存在时回退写入 `$GITHUB_WORKSPACE/files`，随后 `cp -rf ./files/. ./wrt/files/` 把覆盖版带进固件。

**后果**：实际固件的 `/etc/profile.d/20-node-agent.sh` 没有 `UV_CACHE_DIR=/data/uv_cache`（与 `test_auto_mount_data.sh` 的断言相反——测试只测仓库源文件，不测构建产物，形成“测试通过但固件错误”的假象）。

### 3.3 UV 缓存未指向 /data（D-3，P1）

`files/etc/init.d/uv-storage` 的 `mounted_uv_root()` 只识别 `/mnt/mmc` 或 `/mnt/*`，**完全不认 `/data`**。在本固件中 eMMC 大分区挂载在 `/data`，因此 UV 永远走 fallback `/opt/uv`：

- `UV_CACHE_DIR=/opt/uv/cache`、`UV_PYTHON_INSTALL_DIR=/opt/uv/python` 均在 rootfs overlay；
- `99-auto-mount-data` 创建的 `/data/uv_cache` 无人使用；
- Python 3.12 standalone 解释器（~100MB+）和 uv 缓存会写根分区，与“彻底杜绝根分区耗尽”的目标矛盾。

**修复方向**：`mounted_uv_root()` 优先识别 `/data`（`mount | grep ' on /data '`），返回 `/data/uv`；并在 `99-auto-mount-data` 中 `mkdir -p /data/uv`。

### 3.4 pnpm/npm 全局 store 同样不在 /data

`20-node-agent.sh` 设 `PNPM_HOME=/opt/node/bin`，pnpm 内容寻址 store 默认在 `~/.local/share/pnpm` 或 `/opt/node/lib/node_modules`，均在 rootfs overlay。`/data/pnpm` 目录建了但未通过 `PNPM_HOME`/`npm_config_cache`/`pnpm store` 指向它。Agent 频繁安装 npm 包会磨损/撑满根分区。建议导出 `PNPM_HOME=/data/pnpm/bin`、`npm_config_cache=/data/pnpm/cache`、`pnpm config set store-dir /data/pnpm/store`。

### 3.5 根分区写损耗与 OOM 结论

- **空间**：当前 `/data` 重定向只对 Multica workspaces（`workspaces_root=/data/multica/workspaces`，正确）和 OpenCode 生效；Pi 会话、UV 缓存/解释器、pnpm store 仍写 rootfs overlay。“彻底解决根分区 OOM”不成立。IPQ6000 雅典娜/哪吒的 eMMC 容量通常够大，但 overlay 分区容量未必等于整盘，需确认 `/data` 分区与 overlay 分区的实际边界。
- **写损耗**：F2FS + `noatime` 选型对 eMMC 友好，正确。但 Node/Python 生态的 `node_modules`、`__pycache__`、pytest 缓存是小写放大户，未全部迁出。
- **内存**：`max_concurrent_tasks=2` 方向合理但未生效（见 M-2）。512MB 机型上 Node 24 + Pi/OpenCode 单任务峰值可达 150–300MB，建议并发设 1 并加 zram/swap（若 eMMC 上有 swap 分区）或 `MULTICA_AGENT_TIMEOUT` 兜底。上游自托管部署的 GC 默认 `MULTICA_GC_COMPLETED_TASK_TTL=0`（永不清理已完成任务目录），长期会撑满 `/data`，应显式设为如 `72h` 并启用 artifact 清理。

---

## 4. 单设备 CI 工作流与固件产物安全

### 4.1 三套工作流解耦评估

- 雅典娜/哪吒/太乙各自是薄 wrapper，通过 `workflow_call` 复用 `WRT-CORE.yml`，依赖解耦良好；输入参数（config、commit、device、LAN_IP）分离清晰。
- 但三者共用同一个 `WRT-CORE` 串行作业，未用 matrix 并行，单设备编译失败不影响其他设备的配置（各自独立 dispatch），符合“快速编译”诉求；若要进一步提速可把 ccache/staging_dir 按 `WRT_ARCH` 缓存（已实现）。
- 测试门禁较完善：`Repository Smoke Tests` 跑全部 `tests/test_*.sh`，defconfig 后断言 tailscale/wrtbak/python3/uv 未被丢弃，`GuardReCs07Artifact` 校验单设备、manifest 必需包、SHA256SUMS。

### 4.2 Multica PAT 可被公开发布（S-1，P0）

`PrivateFirmwareGuard.sh` 只扫描三类密钥：wrtbak R2 access/secret key、wrtbak proxy_url、headscale authkey。**不扫描 `/etc/config/multica` 中的 PAT**。

而 `RE-CS-07-BUILD.yml`：
- 未设 `WRT_BUILD_ONLY`（默认 `false`）→ 触发 `Release Firmware` 步骤创建**公开发布**；
- `secrets: inherit`，而 `WRT-CORE.yml` 顶层 env 无条件映射 `MULTICA_TOKEN: ${{secrets.MULTICA_TOKEN}}`；
- 若仓库配置了 `MULTICA_TOKEN` secret（这是使用 Multica 功能的前提），`MulticaAutoEnroll.sh` 会把 PAT 写入固件，而 guard 因未检出 wrtbak/headscale 密钥而标记 `WRT_PRIVATE_BUILD=false` → 带 PAT 的固件作为 public release 上传。

即使 RE-CS-02/SS-01 设了 `WRT_BUILD_ONLY=true`（仅 Actions artifact，14 天），公开仓库的 Actions artifact 也可被任何登录用户下载。

**修复方向**：
1. `PrivateFirmwareGuard.sh` 增加对 `etc/config/multica` 中 `option token '<非空>'` 的扫描；
2. `MulticaAutoEnroll.sh` 写入 token 后输出一个标记文件供 guard 识别；
3. 或更彻底：PAT 不烧录固件，首次开机通过 `provision_url`（已在 Headscale 脚本中实现的模式）短时换取。

### 4.3 供应链与权限（S-2、S-3，P1）

- `actions/checkout@main` 跟踪移动分支，若账号被盗可植入恶意 CI 步骤。应 pin 到完整 SHA（其他 action 如 `cache@v5`、`upload-artifact@v6` 同样建议 pin SHA）。
- `CPE-5G.yml` 顶层 `permissions: write-all` 违反最小权限；WRT-CORE 内部 job 已显式声明 `contents: write, actions: write`，wrapper 不应再放开。
- RE-CS-07 未设 `WRT_COMMIT`，直接跟踪 `VIKINGYFY/immortalwrt:main` 移动分支，产物不可复现，也违反 AGENTS.md 对 CPE 基线“必须 pin 完整 40 位 SHA”的精神（虽然该条明确针对 CPE，但生产固件同样应 pin）。RE-CS-02/SS-01 已 pin `a4638cd...`，应给 RE-CS-07 同样 pin。
- `viewturbocore`（S-4，P2）：`curl -fsSL -k https://assets.vtfly.com/...` 跳过 TLS 校验、无 SHA256/签名校验，下载的 ELF 由 `rc.local` 以 root 开机自启。第三方域名被劫持或投毒即全网 RCE。应去掉 `-k`、加版本 pin + checksum 校验，或评估是否必须开机自启。

### 4.4 其他密钥链路问题

- **Headscale authkey**：写入时 `umask 077`、目录 700、注册成功后 `rm -f`，且 guard 能识别并标记 private，链路设计良好。但如 2.2 所述，squashfs 中的 key 仍可提取；注册失败（60 次重试耗尽）时 key 文件不删除，会留在设备上。
- **wrtbak R2 密钥**：`WrtbakR2Config.sh` 做了换行/单引号校验、`chmod 600`、guard 识别，是仓库里最规范的密钥处理；但 `92-wrtbak-nikki-r2-bypass` 把 R2 endpoint host 加入 Nikki fake_ip_filter，合理。
- **WiFi 密码硬编码**：`WRT_WORD: asdzxc147369` / `12345678` 直接写在 workflow 并写入 Release 说明。虽是默认固件密码、预期用户首改，但弱密码 + 公开发布说明会让未改密设备被秒破。建议首次开机强制改密或随机生成。
- **Dropbear authorized_keys**：通过 secret 注入，未发现私钥泄露问题。

### 4.5 双 Bin 归档评估

- `GuardReCs07Artifact.sh stage` 同时拷贝 `*factory*.bin` 与 `*sysupgrade*.bin` + manifest + Config，重新生成 `SHA256SUMS` 并自校验；`verify_upload` 断言两类 bin 至少各一、manifest 唯一、config 唯一、SHA256 校验通过。
- `WRT-CORE.yml` 在 `WRT_REQUIRED_DEVICE` 设置时（RE-CS-02/SS-01）再次断言 factory/sysupgrade 都存在；`metadata.json` 记录 source commit；`SHA256SUMS` 覆盖 upload 目录全部文件。
- 该机制设计扎实，满足 factory（U-Boot 首刷）+ sysupgrade（系统内升级）双场景与完整性校验。唯一改进点：RE-CS-07 走 GuardReCs07 路径但未设 `WRT_REQUIRED_DEVICE`，两道校验有其一即可，建议统一显式设置。

---

## 5. 改进与优化建议（按优先级）

### 立即修复（P0，阻断功能/安全）
1. **新增 `fetch_multica_runtime.sh`**：下载 multica arm64/x86_64 静态二进制到 `files/usr/local/bin/multica`，CI 调用，测试断言二进制存在；否则 Multica 全链路不可用。
2. **`PrivateFirmwareGuard.sh` 增加 Multica PAT 扫描**；同时审查所有 `WRT_BUILD_ONLY` 未设 true 的可发布 workflow，确保带密钥构建必为 private。

### 短期修复（P1，实机稳定性/安全）
3. **让并发限制真正生效**：procd command 追加 `--max-concurrent-tasks "$max_tasks" --poll-interval "$poll_interval" --heartbeat-interval "$heartbeat_interval"`，512MB 机型设 1；并导出 `MULTICA_DAEMON_MAX_CONCURRENT_TASKS` 双保险。设置 `MULTICA_GC_COMPLETED_TASK_TTL` 等 GC 参数防止 /data 膨胀。
4. **修复 /data 软链接**：构建期移除 overlay 中的 `files/root/.multica`、`files/root/.pi` 真实目录（静态文件改放 `/etc/multica`、`/etc/pi`），或在 uci-defaults 中做“迁移后替换”；修正 `fetch_node_runtime.sh` 不要覆盖提交版 profile 的 /data 导出；`uv-storage` 优先识别 `/data`；pnpm/npm cache 重定向到 `/data/pnpm`。
5. **统一站点 LAN_IP**：RE-SS-01/RE-CS-07 默认值错开为 10/11/12，CI 增加子网唯一性校验。
6. **供应链加固**：`actions/checkout` 等第三方 action pin 到完整 SHA；CPE-5G 收回 `write-all`；RE-CS-07 pin `WRT_COMMIT`；viewturbocore 去掉 `-k` 加 checksum。

### 中期加固（P2，纵深防御）
7. **Agent 权限降维**：Multica daemon 及子 Agent 以非 root 用户运行，sudoers 白名单 + cgroup memory limit；Multica 反代启用 mTLS/IP 白名单；PAT 改设备级短期 token，UCI 文件 `chmod 600`，sed 注入改安全转义。
8. **Headscale 密钥与 ACL**：preauth key 改单次使用、CI 动态签发；autoApprovers 收窄到站点 /24；固件不烧录 key，走 provisioning URL 换取；注册失败时也清理 key 文件。
9. **Nikki DNS guard 改声明式**：用 `nikki.mixin.fake_ip_filters` 等 UCI 选项替代 awk 改 `hijack.ut` 模板，避免 Nikki 升级后静默失效。
10. **bootstrap 健壮性**：Multica 网络等待对齐 Headscale 的 600s + hotplug；agent 创建失败区分“已存在”与瞬时错误，不盲目 touch 初始化标记；用 procd oneshot 替代嵌套 `&`。
11. **accept_routes 策略对齐**：CI 注入默认保持 0，dispatch 显式开启，与 AGENTS.md 文档一致。

### 长期演进
12. 增加实机集成测试门禁：在 QEMU/真机构建中验证 `multica daemon status` 为 running、`multica runtime list` 非空、`df /data` 使用率、`ip route show table 52` 路由数、`nft list chain inet nikki router_dns_hijack` 含 Tailscale return 规则。
13. 为 Agent 操作建立“断连保护”包装：所有 `uci set network/firewall/dropbear` 操作通过带超时自动回滚的封装执行（角色卡已有要求，但应在脚本层强制）。
14. 建立固件 SBOM 与构建溯源：metadata.json 已记录 source commit，建议进一步记录所有预下载二进制（node/uv/multica/viewturbocore）的版本与 SHA256。

---

*报告基于本地工作树源码与 multica-ai/multica 上游文档（2026-08 状态）生成。涉及上游字段行为的结论（M-2）建议在实机刷入后用 `multica daemon status --output json` 与 `/proc/<pid>/environ` 复核。*
