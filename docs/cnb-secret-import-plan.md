# cloud-secret → CNB build: read-only inventory and guarded import plan

2026-09-26：已在登录的 CNB Web UI 查看 `b2233/cloud-secret/projects/openwrt-ci`，**只提取键名和 ACL 文本**；未将值下载、显示、复制、写入本仓库或改动该密钥仓库。该目录存在 `env.build.yml`、`env.cd.yml`、`env.release.yml`。后两文件的浏览器代码视图未呈现内容，**不能据此判定为空或验证字段**；保持原样，留待独立发布/CD 阶段。

`env.build.yml` 的键名：`HEADSCALE_OPENWRT_AUTHKEY`、`HEADSCALE_URL`、`MULTICA_TOKEN`、`MULTICA_SERVER_URL`、`MULTICA_APP_URL`、`MULTICA_WORKSPACE_ID`、`NIKKI_SUBSCRIPTION_URL`、`OPENWRT_DROPBEAR_AUTHORIZED_KEYS`、`OPENWRT_WAN_PPPOE_USERNAME`、`OPENWRT_WAN_PPPOE_PASSWORD`、`COMMANDCODE_API_KEY`、`CLIPROXYAPI_API_KEY`、`CLIPROXYAPI_BASE_URL`、`SAMBA_DEFAULT_PASSWORD`。能看到键**不证明对应值真实有效**；本清单不核对/输出值。`HEADSCALE_CI_AUTHKEY` 不在该 build 文件中，普通固件构建不需要它。

## 当前授权规则尚不能被构建引用

该文件声明 `allow_slugs`、`allow_events`、`allow_branches`：`allow_slugs` 仍是 `<组织>/<私有编译仓库>` 占位符；`allow_events` 仍是两个 `<手动构建事件名>`、`<定时构建事件名>` 占位符；`allow_branches` 只有 `main`。CNB 官方 [密钥仓库文档](https://docs.cnb.cool/zh/repo/secret.html) 明确：一旦有 `allow_*`，将**忽略触发者角色权限**并要求所有规则通过。因此目前即使仓库负责人触发迁移分支流水线也**不得期待 imports 成功**，更不能为“先跑通”删除 ACL。

官方引用语法（示例，仅在通过下述门禁后放入**独立手动私有构建任务**，不是现有 push/schedule 探针）：

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
  - "<已建立禁止强推/删除且限制写入的可信构建分支>"
```

- 不允许 `push`、`pull_request`、`crontab`、`api_trigger` 引用这份 build 密钥；不把 `env.cd.yml`、`env.release.yml` 混入 build。只允许必要任务、经过审查的 Docker 镜像和受控角色。CNB 的 `imports` 是**任务/流水线级**环境变量，整个文件一次注入，不能宣称逐字段隔离；如须更严格最小权限，应在 Web UI 新建更细的构建密钥文件，经审计迁移值（不在本机复制）。
- 目前 CNB `main` 没有分支保护，迁移分支也不是受审查保护分支；现有按钮仅做**无密钥**的设备 profile 与工具链依赖预检。绝不把包含真实 build 值的 imports 加进这些按钮、push 或 weekly monitor。
- `SAMBA_DEFAULT_PASSWORD` 对现有 `Config/GENERAL.txt` 的默认 Samba 构建是**必填**，空值应失败；其余可按功能可选（详见 [`cnb-secret-entry-checklist.md`](cnb-secret-entry-checklist.md)）。即使仅有 Samba 密码，固件仍是私有制品，生成后必须限制附件访问、做 metadata/checksum 覆盖校验；不能发布到公开 release。
- `HEADSCALE_OPENWRT_AUTHKEY` 是设备首启 preauth key，和只用于 CI/debug/CD 入网的 `HEADSCALE_CI_AUTHKEY` 严禁合并。旧设备上的 key 可能失效，嵌入固件 SquashFS 后仍可恢复；优先一机一次短期 key 或无需内嵌 key 的 provisioning URL。
- 真机 CD 需单独受保护的 `env.cd.yml`、主机公钥 pin、审批和串行锁；本次仅建档，不引用、不执行。

待用户确认可信分支保护/审批和密钥文件 ACL 后，再对照实际引用审计记录跑单设备私有 RE-CS-07 build。GitHub Actions 保持 fallback；任何缺少输入必须阻断构建/附件而非伪造占位固件。
