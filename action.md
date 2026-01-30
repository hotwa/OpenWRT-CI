# OpenWrt CI 编译监控与自愈记录

## 概述
- 仓库: hotwa/OpenWRT-CI
- 任务: 修复编译失败并成功生成固件
- 最大重试次数: 10

## 运行实例状态

### Run 21483330970 (VIKINGYFY)
- **状态**: completed, failure
- **触发事件**: repository_dispatch (build-request)
- **时间**: 2026-01-29 15:05:59 ~ 17:23:35
- **分支**: main
- **提交**: 9702a76 - feat: 实现方案B - 升级 Go 到 1.25.6 解决 tailscale 编译问题

### Run 21482969100 (VIKINGYFY)
- **状态**: completed, cancelled
- **时间**: 2026-01-29 14:55:53 ~ 21:00:57

### Run 21482819185 (VIKINGYFY)
- **状态**: completed, cancelled
- **时间**: 2026-01-29 14:51:31 ~ 20:56:35

---

## 问题诊断

### 失败 Run 21483330970 详细分析

#### 错误信息
1. **Kconfig 循环依赖错误** (发生在 make world 阶段):
```
tmp/.config-package.in:319:error: recursive dependency detected!
...
```

受影响的包:
- `PACKAGE_luci-app-firewall depends on PACKAGE_luci-app-firewall`
- `PACKAGE_dockerd depends on PACKAGE_dockerd`
- `PACKAGE_luci depends on PACKAGE_luci`
- `PACKAGE_luci-app-docker depends on PACKAGE_luci-app-docker`

2. **Go 源码下载 hash 不匹配**:
```
Hash of the downloaded file does not match
file: 58cbf771e44d76de6f56d19e33b77d745a1e489340922875e46585b975c2b059
requested: fba2dd661b7be7b34d6bd17ed92f41c44a5e05953ad81ab34b4ec780e5e7dc41
```

#### 根因分析

**主要问题**: Go 版本配置不一致
- Packages.sh 从 24.x 分支克隆 golang，然后尝试用 sed 修改版本为 1.25.6
- 24.x 分支的 PKG_HASH 是 `fba2dd...`（对应 Go 1.24.12）
- 但 sed 只修改了版本号，没有更新 PKG_HASH
- 导致 Makefile 期望 hash 与实际下载的 Go 1.25.6 文件不匹配

**次要问题**: feeds 中的 LuCI Kconfig 文件存在循环依赖定义

---

## 修复方案

### 方案: 直接使用 sbwml 的 25.x golang 分支

**修复步骤**:
1. 修改 `Scripts/Packages.sh`，直接克隆 25.x 分支而不是 24.x
2. 移除手动 sed 修改版本的代码块

---

## 修复执行

### [2026-01-30 08:10:00] Check #1
- Current Run ID: 21483330970
- Status/Conclusion: completed / failure
- Step/Reason: golang download hash mismatch
- Retry: 0/10
- Next: 正在修复代码
- Links: https://github.com/hotwa/OpenWRT-CI/actions/runs/21483330970

#### Key Log Lines
- ERROR: package/feeds/packages/golang [host] failed to build.
- Hash of the downloaded file does not match
- make: *** [/home/runner/work/OpenWRT-CI/OpenWRT-CI/wrt/include/toplevel.mk:233: world] Error 1

#### Diagnosis
- 主要问题: Packages.sh 克隆 24.x golang 分支后用 sed 改为 1.25.6，但 PKG_HASH 未更新
- 次要问题: feeds 中的 kconfig 循环依赖

#### Fix Applied
- 文件: Scripts/Packages.sh
- 修改: 
  1. 将 `git clone -b 24.x ...` 改为 `git clone -b 25.x ...`
  2. 移除 sed 修改 GO_VERSION 的代码块
