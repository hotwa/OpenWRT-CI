# cloud-secret → CNB build: read-only inventory and guarded import plan

2026-09-26 初始盘点：在登录的 CNB Web UI 查看 `b2233/cloud-secret/projects/openwrt-ci`，只提取键名和 ACL 文本；未将值写入本仓库。后续手动门禁的 ACL 更新和设备 key 意外显示事件见下文，不能再称整个过程“未改动密钥仓库/未显示值”。该目录存在 `env.build.yml`、`env.cd.yml`、`env.release.yml`。后两文件的浏览器代码视图未呈现内容，**不能据此判定为空或验证字段**；保持原样，留待独立发布/CD 阶段。

`env.build.yml` 的键名：`HEADSCALE_OPENWRT_AUTHKEY`、`HEADSCALE_URL`、`MULTICA_TOKEN`、`MULTICA_SERVER_URL`、`MULTICA_APP_URL`、`MULTICA_WORKSPACE_ID`、`NIKKI_SUBSCRIPTION_URL`、`OPENWRT_DROPBEAR_AUTHORIZED_KEYS`、`OPENWRT_WAN_PPPOE_USERNAME`、`OPENWRT_WAN_PPPOE_PASSWORD`、`COMMANDCODE_API_KEY`、`CLIPROXYAPI_API_KEY`、`CLIPROXYAPI_BASE_URL`、`SAMBA_DEFAULT_PASSWORD`。能看到键**不证明对应值真实有效**；本清单不核对/输出值。`HEADSCALE_CI_AUTHKEY` 不在该 build 文件中，普通固件构建不需要它。

## 私有构建手动输入门禁（CNB 已验证可引用）

用户已确认：`SAMBA_DEFAULT_PASSWORD` 在密钥仓库配置完成；暂不填写 `HEADSCALE_OPENWRT_AUTHKEY`；本轮接受迁移分支不加严格分支审查，以优先诊断构建。这**不等于验证了值在 Samba 运行时可用或免除 ACL**。在当前私人 CNB 仓库的迁移分支上，先实测手动 `web_trigger_re_private_build` 事件的 build-only 输入检查：只检查 Samba 非空/非明显占位，不打印密钥；之后同一事件扩为 RE-CS-07 的仅编译/校验/私有附件任务，始终不发布或访问设备。该阶段的受保护分支风险由用户接受；此决定**不扩展**到生产 main、发布或真实设备 CD。第一次 `cnb-6pu-1k3f02geb` 因 `allow_events` 拒绝；Web UI 将 ACL 限到此私库、此手动事件、`main` 和迁移分支后，`cnb-f54-1k3f22j0u` 的输入门禁通过。

文件 ACL 已在 Web UI 配为 `allow_slugs` 精确匹配 `b2233/openwrt-ci`、`allow_events` 精确匹配 `web_trigger_re_private_build`、`allow_branches` 仅 `main` 与 `migration/cnb-shadow-20260926`。不得为了后续构建通过而删除 ACL 或加入 push/cron/PR 事件。**重要安全事项**：检查中发现设备 key 一度非空且意外出现在代理工具输出；当前 build 文件已清空该字段，但历史提交仍存，必须由用户在 Headscale 吊销/轮换旧 key；不在此文记录或复述任何值。

## 早期授权规则不可被迁移分支引用

该文件声明 `allow_slugs`、`allow_events`、`allow_branches`：`allow_slugs` 仍是 `<组织>/<私有编译仓库>` 占位符；`allow_events` 仍是两个 `<手动构建事件名>`、`<定时构建事件名>` 占位符；`allow_branches` 只有 `main`。CNB 官方 [密钥仓库文档](https://docs.cnb.cool/zh/repo/secret.html) 明确：一旦有 `allow_*`，将**忽略触发者角色权限**并要求所有规则通过。因此目前即使仓库负责人触发迁移分支流水线也**不得期待 imports 成功**，更不能为“先跑通”删除 ACL。

官方引用语法（仅放入独立手动私有构建任务，不是 push/schedule 探针）：

```yaml
imports:
  - https://cnb.cool/b2233/cloud-secret/-/blob/main/projects/openwrt-ci/env.build.yml
```

进入私有构建时，建议在 cloud-secret 的受审计 Web 编辑页面**仅修改 ACL 元数据，不覆盖任何现有值**，并由用户/独立评审者核对最终 diff：

```yaml
allow_slugs:
  - "b2233/openwrt-ci"
allow_events:
  - "web_trigger_re_private_build"
allow_branches:
  - "migration/cnb-shadow-20260926"
```

- 不允许 `push`、`pull_request`、`crontab`、`api_trigger` 引用这份 build 密钥；不把 `env.cd.yml`、`env.release.yml` 混入 build。只允许必要任务、经过审查的 Docker 镜像和受控角色。CNB 的 `imports` 是**任务/流水线级**环境变量，整个文件一次注入，不能宣称逐字段隔离；如须更严格最小权限，应在 Web UI 新建更细的构建密钥文件，经审计迁移值（不在本机复制）。
- CNB `main` 仍无分支保护；用户已允许本轮迁移分支使用宽松权限。**仅**手动私有 build-only 任务（含输入门禁）导入 build 密钥；无密钥 profile 按钮、push 和 weekly monitor 不导入。每个 PR/陌生分支都必须拒绝引用，绝不添加 CD/release 值。
- `SAMBA_DEFAULT_PASSWORD` 对现有 `Config/GENERAL.txt` 的默认 Samba 构建是**必填**，空值应失败；其余可按功能可选（详见 [`cnb-secret-entry-checklist.md`](cnb-secret-entry-checklist.md)）。即使仅有 Samba 密码，固件仍是私有制品，生成后必须限制附件访问、做 metadata/checksum 覆盖校验；不能发布到公开 release。
- `HEADSCALE_OPENWRT_AUTHKEY` 是设备首启 preauth key，和只用于 CI/debug/CD 入网的 `HEADSCALE_CI_AUTHKEY` 严禁合并。旧设备上的 key 可能失效，嵌入固件 SquashFS 后仍可恢复；优先一机一次短期 key 或无需内嵌 key 的 provisioning URL。
- 真机 CD 需单独受保护的 `env.cd.yml`、主机公钥 pin、审批和串行锁；本次仅建档，不引用、不执行。

密钥 ACL 精确生效且输入门禁已通过；在实际运行 RE-CS-07 私有 build 前/后均需核对引用审计、仓库安全边界、阶段日志及私有制品校验。GitHub Actions 保持 fallback；任何缺少输入必须阻断构建/附件而非伪造占位固件。
