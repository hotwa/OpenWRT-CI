# 集客 AP 自动配置

`gecoosac-auto` 使用固件自带集客 AC 程序的模板和下发接口，支持
`jdcloud,re-cs-07`、`jdcloud,re-ss-01`、`jdcloud,re-cs-02`。
不需要再进入 LuCI 手动启用 AC 或绑定 Wi-Fi 模板。

## 行为

- 开机运行一次，每两分钟检查一次。AP 每分钟向 AC 上报，接入和启动后
  通常需要等待一个检查周期加一次 AP 上报；这不是精确的时限保证。
- 初始管理以下两台 AP，并默认开启 `auto_adopt=true`：同一 LAN IPv4 子网内
  在线且版本受 AC 支持、具有完整 `GCOAP-...` 标识的新增集客 AP 自动加入。
  自动保存 MAC 和设备标识后绑定管理模板，后续新增 AP 不需要重新编译或手填 MAC。
  不接纳其他网段、缺少版本判断、离线、标识异常或标识与已管理设备冲突的设备。
  设备标识来自集客协议，不是密码学认证；启用自动加入意味着管理该 LAN 内符合条件的集客 AP。
  设置 `auto_adopt=false` 可回到仅管理已保存名单的模式。
- 对已管理设备要求 MAC 和设备标识同时匹配。设备不在线、标识不符、
  固件过旧时跳过，不发送配置指令。IP 来自 AC 上报，不固定绑定 DHCP 地址。
- 集客会自动给新 AP 分配默认模板，因此首次启动时先在临时端口准备数据库、
  禁用默认模板，再启动正式 60650 服务。未被自动接纳或列入名单的 AP 不会被配置。
- 主路由有已启用且运行中的 LAN Wi-Fi 时，复制 SSID、密码和加密方式。
  同名同密码的频段合并；RE-CS-02 的多个不同 SSID 则分别保留，最多四个。
  不复制访客 VLAN、STA 上联或关闭的无线接口。配置存在但无线尚未启动时等待，
  不提前用预设覆盖它。主路由配置的频段映射也予以保留。
- 主路由没有已启用的 LAN Wi-Fi 时，用预设 `RE-AP`，WPA2，2.4GHz 和所有
  可用的 5GHz 射频同名同密码。当前两台 AP 均支持 2.4GHz 和 5GHz。
- 管理模板明确设置自动信道和自动发射功率，开启集客 k/v/r 漫游辅助
  （`disablekvr=no`），漫游触发阈值固定为 `-79 dBm`。这些值不依赖上游
  默认模板，后续检查会修复管理模板中被改变的值。
  自动信道的选择由 AP 固件执行；本脚本不额外实现跨 AP 射频协调。
  漫游效果还取决于终端支持、信号覆盖和 AP 实现，不能保证所有终端无感切换。
- 只在模板内容发生改变或 AP 未绑定管理模板时写配置。AP 重新启动后，
  集客原生上报协议继续同步已保存的模板，不需要循环重启 AP。
- 在 LAN 设备上添加 `6.7.8.9/32` 作为集客发现地址，不改 LAN 地址、DHCP
  网关、WAN 或代理配置，不需要重启网络。这个地址必须保持 LAN 内唯一；
  一条 LAN 上不能部署多台争用该地址的本地 AC。

## 初始设备列表

| 型号 | MAC | 设备标识 |
|---|---|---|
| Newifi D2 / AP243P | `20:76:93:40:56:45` | `GCOAP-M1708-23F77-222F9-9D498` |
| AX1800S | `DC:D8:7C:24:FC:86` | `GCOAP-M113D-FA19A-826AB-20197` |

上游 AC 2.2 要求 AP 固件 7.6 或更新，见
[插件上游](https://github.com/laipeng668/luci-app-gecoosac)。实测两台 AP 均为
`8.0_2025080600`，AC 为 `V2.2_202510151606`。未注册状态未妨碍本次 Wi-Fi 下发。

## 持久化与构建

有效配置位于 `/data/gecoosac-auto/profile.json`，权限 600；AC 数据库在
`/data/gecoosac-auto/ac-db`，绑定挂载到插件支持的 `/etc/gecoosac`。
仅在确认 `/data` 是可写的独立持久化文件系统后才运行，未挂载时等待下次检查，
不把文件写到根 overlay 上伪装成持久化数据。

固件的 `/etc/gecoosac-auto/profile.json` 用于首次初始化；已保存的本机配置优先。
早期没有 `auto_adopt` 字段的持久化配置会补入新固件的默认值；显式配置为 `false`
则保持关闭。自动加入的设备列表写入 `/data`，随其持久化保存。
普通保留配置升级另有 `/lib/upgrade/keep.d/gecoosac-auto` 备份清单。
清空 overlay 升级时，只要 `/data` 分区仍保留，配置和模板会恢复。
格式化 `/data` 或更换路由器不属于该恢复范围，需要私有固件预置密码或重新配置。

仓库内预设密码为空。RE-CS-07、RE-Mesh、RE 容器测试、通用 QCA、WLG RE-CS-07
和 CPE B 构建调用通过 repository secret
`GECOOSAC_WIFI_PASSWORD` 注入初始预设。注入器为 `Scripts/GecoosacAutoConfig.sh`，
`PrivateFirmwareGuard.sh` 将含密码的镜像分类为 private，禁止走公共固件发布。
无功能 overlay 的 CPE A 隔离基线不注入 AP 配置或密码。运行时仍只启用上述三个型号。
不要将本机有效配置、AC 数据库或带密码的固件提交到仓库。

自启动服务只使用 `/opt/node/bin/node` 的固件基线，不依赖 SSH profile、
全局 npm 更新或 `/data/node` 的可写性。它在 S89 禁用上游 S90 自启动，
准备好数据库和持久化挂载后再显式启动 `/etc/init.d/gecoosac`。
服务启动与 cron 调用通过 PID 锁避免重叠。

## 检查与修改

```sh
/usr/sbin/gecoosac-auto
cat /var/run/gecoosac-auto.status.json
grep '#gecoosac-auto' /etc/crontabs/root
logread -e gecoosac-auto
```

状态只包含 SSID、频段、目标状态及同步时间，不包含密码。`queued` 表示 AC 已接受
模板或绑定请求，仍须等待 AP 上报并核对 AP 实际 Wi-Fi；`unchanged` 表示 AC
保存的模板和绑定已一致；`absent` 表示本次未找到在线目标。

修改 `/data/gecoosac-auto/profile.json` 中的 `fallback_ssid`、`fallback_key`、
`targets`、`auto_adopt` 后运行一次脚本即可。不要修改默认模板的 enable；自动管理要求它保持
`no`。如改变 AC 管理密码，需同步修改本机 profile 的 `ac_password`。

## 2026-10-03 实机验证

在 RE-CS-07（`192.168.10.1`）完成：

- AC 发现两台 AP，MAC 与设备标识均匹配。
- 默认模板禁用期间，Newifi 保持原 `WRT` / `WRT_5G`，没有接收到默认开放 SSID。
- 给两台 AP 单独绑定管理模板；随后分别登录 AP 的 HTTPS 管理 API，确认
  `RE-AP`、WPA2、预设密码一致、2.4GHz / 5GHz 都启用，AC 地址为 `6.7.8.9`。
- 两台 AP 实际配置均为自动信道、自动功率、漫游辅助开启、阈值 `-79 dBm`；
  没有进行携带终端走动的漫游切换测试。
- 数据库迁移到 `/data` 后重启 AC，模板绑定保留，AP 重新上报并同步成功。
- 重复运行的模板和绑定为 unchanged；未匹配目标的行为由本地回归和实机检查覆盖。
- 自动加入验证：临时从本机名单移除 AX1800S，下一次检查从 LAN 自动发现、
  识别并重新保存其 MAC / 设备标识；已有 Wi-Fi 模板保持一致，未造成重复下发。

本次没有重启或刷写主路由，也没有把 AP 移到 RE-SS-01 / RE-CS-02 实测。
后两者的 Wi-Fi 复制、同名合并、三射频、多 SSID、未就绪等待逻辑由回归覆盖。

```bash
bash tests/test_gecoosac_auto.sh
bash tests/test_wrtbak_private_firmware_guard.sh
bash tests/test_re_cs_07_workflow.sh
bash tests/test_single_device_workflows.sh
```
