# CommandCode 模型动态选择机制

## 概述

固件不再硬编码默认模型（`defaultModel`），而是通过"预置缓存 + 动态更新"的方式自动选择 CommandCode 推荐的偏好模型，并在 CommandCode 更新模型列表后自动感知。偏好模型按通配符优先级选择：flash 模型（便宜、量大、速度快）优先，其中 deepseek/qwen/glm 的 flash 模型排在最前，然后是任意提供商的 flash 模型，最后是含 "pro" 的模型。

## 架构

```
编译时 (CI)                    首启 (first boot)              运行时 (runtime)
┌─────────────────────┐      ┌──────────────────────┐      ┌──────────────────────┐
│ CommandCodeProvider │      │ 99-auto-mount-data   │      │ commandcode-model-   │
│ Config.sh           │      │                      │      │ sync (init.d)        │
│                     │      │ 1. 拷贝缓存到 /data  │      │                      │
│ 1. 调用 API 获取    │─────▶│ 2. 拷贝 settings 到  │─────▶│ 1. 延迟 60s 后台启动 │
│    模型列表         │      │    /data             │      │ 2. 等待网络就绪      │
│ 2. 写入预置缓存     │      │ 3. 从缓存筛选开源    │      │ 3. 调用 API 获取最新 │
│    commandcode-     │      │    模型，写入        │      │    模型列表          │
│    models.json      │      │    defaultModel      │      │ 4. 更新缓存          │
│ 3. 筛选开源模型     │      │                      │      │ 5. 若设置未被用户    │
│ 4. 写入 settings    │      │                      │      │    修改，更新        │
│    defaultModel     │      │                      │      │    defaultModel      │
└─────────────────────┘      └──────────────────────┘      │ 6. 重启 Multica      │
                                                           └──────────────────────┘
```

## 组件说明

### 1. 编译时预置缓存 — `Scripts/CommandCodeProviderConfig.sh`

在 CI 构建时调用 `https://api.commandcode.ai/provider/v1/models` 获取模型目录，保存为固件中的 `/etc/pi/agent/commandcode-models.json`。

- **API 不可用时**：使用内置最小回退缓存（包含 `Qwen/Qwen3.8-Flash` 和 `Qwen/Qwen3.8-27B`）
- **模型选择**：从缓存中按通配符优先级选择偏好模型作为 `defaultModel`（见下方优先级列表）
- **不包含 API key**：缓存仅包含模型目录，不含任何密钥

偏好模型匹配优先级（大小写不敏感正则，可在脚本顶部 `MODEL_PREFERENCE_PATTERNS` 配置前三项）：
1. `deepseek/.*flash.*` — DeepSeek flash 模型（首选）
2. `qwen/.*flash.*` — Qwen flash 模型（次选）
3. `glm.*flash.*` — GLM flash 模型（三选，匹配 `z-ai/glm-*-flash` 等）
4. 任意含 `flash` 的模型（如 stepfun/Step-3.7-Flash、google/gemini-*-flash）
5. 任意含 `pro` 的模型（如 deepseek/deepseek-v4-pro、xiaomi/mimo-v2.5-pro）

> 无内置回退：线上模型目录始终包含 flash 模型；若缓存中既无 flash 也无 pro，编译时脚本会报错退出（提示 API 异常），设备侧则跳过本次更新、保持现有配置不变。

### 2. 首启选择 — `files/etc/uci-defaults/99-auto-mount-data`

首次启动时（或升级后），将固件中的预置缓存和 settings 拷贝到 `/data/pi/agent/`，然后从缓存按通配符优先级选择偏好模型写入 `defaultModel`。

- `select_model_from_cache()`：使用 grep/sed/tr 解析缓存（不依赖 jq），按 5 层通配符优先级选择模型
- `ensure_default_model_from_cache()`：仅在 settings 为固件管理状态时更新模型
- `migrate_commandcode_provider()`：升级设备时，同样从缓存选择模型而非硬编码

### 3. 运行时动态更新 — `files/etc/init.d/commandcode-model-sync`

开机后延迟 60 秒在后台启动，等待网络就绪后定期（重试 6 次，间隔 30 秒）获取最新模型列表。

- 更新 `/data/pi/agent/commandcode-models.json` 缓存
- 仅当 settings 仍为固件管理状态（用户未手动修改）时，按通配符优先级更新 `defaultModel`
- 更新后重启 Multica 使配置生效
- **尽力而为**：任何失败都不影响系统启动，仅记录日志

## 保守迁移与用户自定义保护

通过 `.firmware-settings-managed` 标记文件实现用户自定义保护：

1. 固件写入 settings.json 时，同时创建标记文件并同步 mtime
2. 任何自动更新（首启选择、运行时同步）前检查 mtime 是否匹配
3. 用户手动修改 settings.json 后 mtime 变化，自动更新被跳过

## 回退机制

| 场景 | 回退行为 |
|------|----------|
| 编译时 API 不可用 | 使用内置最小缓存（Qwen/Qwen3.8-Flash + Qwen/Qwen3.8-27B） |
| 首启时缓存缺失 | settings 保留编译时选择的模型 |
| 缓存中无 flash/pro 模型 | 编译时报错退出；设备侧跳过更新、保持现有配置 |
| 缓存格式错误/缺失 | 选择函数返回失败，调用者保守处理（不覆盖现有 settings） |
| 运行时 API 失败 | 保持当前缓存和 defaultModel 不变，记录日志 |
| 用户已修改 settings | 不覆盖用户自定义 |

## 手动修改默认模型

如果需要手动指定默认模型（覆盖自动选择）：

```sh
# 编辑 settings.json
vi /data/pi/agent/settings.json
# 修改 defaultModel 字段
# 保存后 mtime 自动更新，.firmware-settings-managed 标记不再匹配
# 后续 commandcode-model-sync 将跳过自动更新
```

如需恢复自动管理：

```sh
touch -r /data/pi/agent/settings.json /data/pi/agent/.firmware-settings-managed
```

## 相关文件

| 文件 | 作用 |
|------|------|
| `Scripts/CommandCodeProviderConfig.sh` | 编译时注入 key + 生成预置缓存 + 选择默认模型 |
| `files/etc/uci-defaults/99-auto-mount-data` | 首启迁移 + 缓存拷贝 + 模型选择 + 启用 sync 服务 |
| `files/etc/init.d/commandcode-model-sync` | 运行时后台动态更新缓存和默认模型 |
| `tests/test_commandcode_provider_config.sh` | 编译时缓存生成与模型选择测试 |
| `tests/test_auto_mount_data.sh` | 首启缓存拷贝与模型选择测试 |
| `tests/test_commandcode_model_sync.sh` | 运行时动态更新逻辑测试 |
