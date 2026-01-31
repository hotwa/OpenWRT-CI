# OpenWRT-CI 
云编译OpenWRT固件，开启内核eBPF，支持DAED 内核级透明代理

官方版：
https://github.com/immortalwrt/immortalwrt.git

高通版：
https://github.com/VIKINGYFY/immortalwrt.git

LiBWrt：
https://github.com/LiBwrt/openwrt-6.x

京东云亚瑟 AX1800 Pro DAED 需要更换分区表和uboot,具体使用方法详见恩山帖子:
https://www.right.com.cn/forum/thread-8402269-1-1.html

# 固件简要说明：

固件每天早上4点自动编译。

固件信息里的时间为编译开始的时间，方便核对上游源码提交时间。

MEDIATEK系列、QUALCOMMAX系列、ROCKCHIP系列、X86系列。

# 目录简要说明：

workflows——自定义CI配置

Scripts——自定义脚本

Config——自定义配置

# 开发与推送指南

本仓库配置了双端推送，分别对应 GitHub 和 Gitea。

## 分支对应关系

- **`main` 分支**
  - **对应平台**: GitHub
  - **推送地址**: `https://github.com/hotwa/OpenWRT-CI.git`
  - **用途**: 公网主仓库，使用 GitHub Actions。

- **`gitea-actions` 分支**
  - **对应平台**: Gitea
  - **推送地址**: `http://100.64.0.27:8418/lingyuzeng/OpenWRT-CI.git` (内网)
  - **用途**: 私有化部署，使用 Gitea Actions (Runner)。

## 如何推送

Git 已配置 upstream，切换分支后直接 push 即可自动匹配目标：

**推送到 Gitea:**
```bash
git checkout gitea-actions
git push
# 如果需要强制覆盖远程： git push -f
```

**推送到 GitHub:**
```bash
git checkout main
git push
```
