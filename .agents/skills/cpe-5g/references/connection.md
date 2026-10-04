# 连接与本机引用

使用 [profile.example.json](profile.example.json) 建立本机 profile；放在仓库外，例如 `/root/.config/cpe-5g/profile.json`，目录 `0700`、文件 `0600`。它只保存目标、已验证 known_hosts、维护私钥位置、仓库位置与凭据文件引用，不填密钥内容。脚本默认使用此位置，也可传 `--profile`。

当前维护私钥为 `/root/project/OpenWrt-Config-Backup/ops/ssh/openwrt_config_backup_maintainer_ed25519`，既可连接 Mac `lingyuzeng@mac.pi.jmsu.top`，也可连接 CPE 的 `root`。脚本将相同密钥用于目标与 Mac ProxyCommand，并分别指定已验证 known_hosts。先从现有受信 SSH 配置/验收记录复用指纹；不要用 `StrictHostKeyChecking=no` 或把未经核对的 `ssh-keyscan` 结果当作身份验证。

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
