# 连接与本机引用

使用 [profile.example.json](profile.example.json) 建立本机 profile；放在仓库外，例如 `/root/.config/cpe-5g/profile.json`，目录 `0700`、文件 `0600`。它只保存目标、已验证 known_hosts、维护私钥位置、仓库位置与凭据文件引用，不填密钥内容。脚本默认使用此位置，也可传 `--profile`。

当前维护私钥为 `/root/project/OpenWrt-Config-Backup/ops/ssh/openwrt_config_backup_maintainer_ed25519`，既可连接当前 Mac `lingyuzeng@192.168.11.219`（已核对与 `mac.pi.jmsu.top` 相同指纹），也可连接 CPE 的 `root`。脚本将相同密钥用于目标与 Mac ProxyCommand，并分别指定已验证 known_hosts。先从现有受信 SSH 配置/验收记录复用指纹；不要用 `StrictHostKeyChecking=no` 或把未经核对的 `ssh-keyscan` 结果当作身份验证。

若有可用 Tailnet，把 profile 的 `ssh.host` 改为 `cpe-5g-s13.hs.jmsu.top` 并删除 `jump`。完整 `.hs.jmsu.top` 后缀避免进入 Nikki 的 Fake-IP。是否能直连须实测；不要因域名已知就假设本机已有 Tailnet 路由或授权。

Windows agent 通过实际可用的 `Ubuntu-22.04` WSL 运行脚本。复杂参数先写 JSON 文件，避免 PowerShell/Bash 多层转义：

```powershell
wsl.exe -d Ubuntu-22.04 -- python3 /mnt/c/Users/pylyz/.codex/skills/cpe-5g/scripts/cpe5g.py status --profile /root/.config/cpe-5g/profile.json
```

Windows 路径 `C:\Users\pylyz\...` 对应 `/mnt/c/Users/pylyz/...`。不得把 `C:\...` 直接传给 Linux 参数。Linux agent 直接使用 `python3`，无需再次嵌套 WSL。

profile 的 `repositories` 用于找到持久仓库；不要依赖历史 `/tmp` 工作树。已知固件仓库通常位于 `/mnt/c/Users/pylyz/Documents/project/OpenWRT-CI`，备份仓库位于 `/root/project/OpenWrt-Config-Backup`。两者可能有未提交改动，修改前确认当前工作树/分支并保留他人工作。

`credential_refs` 为人工/agent 定位本机凭据的引用，状态/规划脚本不会读取它们。Lucky 管理 token 位于 CPE `/etc/lucky/cert-sync/lucky.token`，管理 API 使用 `openToken` header；不要误用 Bearer。云凭据只在备份仓库既有私有配置和本机 vault 中读取，token/secret 仅在内存或受限临时文件中传递，不写聊天、命令行、公共 git 或 action 日志。

## 状态含义

`status` 的输出经过固定远端字段抽取与本地二次白名单，只显示 WAN 协议/地址可用性、IPv6 设置、wan6/cpe6 是否存在、mwan3 wan/5G 状态、SIM 控制器 phase/detail/address/配额、UDX 源站 readiness 和系统版本。字段缺失显示 `null`，不等同于正常。

`public_origin_open` 与 `udx_origin.ready` 不能替代 ESA 到源站和应用到上游的完整调用验收。mwan3 的 SIM `online` 也不能证明出口实际吞吐或 LAN 新连接成功。检查实际掉线时关联现有探针日志、接口路由/marks、配额与信号，不运行会明显消耗 SIM 流量的测速。

`api-status` 复用同一 SSH/指纹策略，额外读取固定 `cpe-api` UCI/init enabled、disabled marker、nerdctl binary/version、containerd socket、固定本地 image alias 的 platform 与 `RepoDigests` 精确 manifest 匹配布尔值、固定 container 的运行状态/资源限额及其内核 cgroup-v2 资源计数，以及 `api-ready.json` 白名单字段。所有查询有超时，不拉镜像、不启动/停止容器、不发 API 请求、不扫描 LAN、不读 config/credentials/auth/logs。缺少 runtime、container 或支持的 template 输出时显示 `null`，不应当作成功。

API 独立 readiness 仍依赖 UDX shared gate；本地 `ready=true` 不证明 OAuth/模型/ESA 公网可用。状态工具不自动建立管理隧道或登录；只有用户指定管理/登录任务才执行发布参考中的私有 SSH forward 和全新 provider OAuth。

nerdctl 2.4.1 不支持对此长 digest 引用进行 image inspect，`api-status` 改查固定本地 `v8.0.13` alias；只有 Linux ARM64 且 RepoDigests 含固定 manifest 才返回 `manifest_verified=true`。匹配失败为 `false`，无法查询为 `null`；不会创建 alias、拉取/修复镜像或回显原始 inspect。

实机 nerdctl 2.4.1 的 format 会先输出部分 native 字段，再输出完整 Docker-compatible 字段；状态 parser 只接受完整六字段或已验证的相同三字段前缀，防止 CPU/PID 限额错位。其 stats 在本机错误报告 0B/0B 与 0 PIDs，工具改从固定容器的 numeric PID 定位内核 cgroup-v2，只读 memory.current/max、pids.current 与 cpu.stat 的 usage_usec。CPU 值是累计微秒，不是瞬时百分比；计数缺失为 null，不报告伪零。

## 升级后的连接与 IPv6 复核

本机私有 profile 已使用 Mac `192.168.11.219` 跳板。CPE 重启期间 Mac 的 CPE
网卡可能暂落到 169.254 地址，使 192.168.13.1 错走默认网关；先检查实际网卡
地址和路由，不能只凭 SSH timeout 判断设备未启动。需要临时别名时仅使用已确认
空闲地址，保存 DHCP 状态，完成后删除自己添加的别名并恢复 DHCP。

Nikki Fake-IP AAAA 返回的 fc00 地址仅代表代理映射。实际 SIM 原生 IPv6 验收
需绕过 Nikki，并证明 usb0 双向流量；临时 procd cgroup 必须先存在再 reload Nikki，
否则 Nikki 会过滤掉不存在的 cgroup，造成错误验收。2026-10-05 国内阿里 IPv6
TLS/HTTP 与 usb0 双向抓包成功，Cloudflare 同类直连超时；不能推断所有目的地
可直连。临时服务、ACL 和抓包进程都需清理。WAN IPv6 保持禁用。


SIM 换前缀后必须分别检查受管地址、原生 DDNS 任务状态和实际公网认证响应。
公网恢复不能替代 DDNS 任务验收。2026-10-06 已核实专用 RAM 策略缺少
DescribeSubDomainRecords、DescribeDomainRecordInfo、UpdateDomainRecordRemark；
v3 只补到 cpe-origin.jmsu.top 域资源。原生任务和冷启动换前缀后的实际 AAAA 更新
均已通过。新错误仍须结合任务 Message 核对，不能把启动时连接拒绝当成权限回归。Lucky 原生 API 更新已有 DDNS 任务使用
PUT /api/ddns?key=<TaskKey>；POST /api/ddns 会创建新任务，即使 body 带旧 key。
修改前核对原 TaskKey、单条 origin 记录范围并保存私有备份，修改后核对任务数
与其它字段，不能靠猜测 URL 后缀删除任务。


## Lucky 与 SIM 额度的持久状态

Lucky 配置以 `/data/lucky` 为准，真实 bind mount 到 `/etc/lucky`，不能改成
符号链接；严格证书读取器会拒绝 symlink 父目录。检查同一 inode 和真实 eMMC
挂载，不把存在目录视作挂载成功。配置完整备份仍须包含 CPE 私有证书/受管清单
及 UCI；保留配置升级的迁移由 CPE B overlay 实现，工厂重分区不保证存活。

厂商 vnStat 曾在模块断电后回退并虚增。OpenWrt 的 `/data/cpe5g-quota/ledger.json`
保留历史已用量并累计原生蜂窝增量；状态中的 `quota.source` 可区分新计量。
账本缺失持久盘、损坏或同一模块 boot ID 内计数倒退时，SIM 双栈和公网门禁关闭，
WAN/LAN 保持。不要删除账本、重置模块统计或自动清零来解除限额；新账期需根据
用户授权和运营商实际窗口核对。连续计量是保守保护，断电时未采样尾段不能证明
等于运营商计费数。实机耗尽不得用消耗剩余额度或修改历史计数伪造。
