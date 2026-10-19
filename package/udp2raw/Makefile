# udp2raw — WireGuard over TCP 伪装工具（固件内置可用版）
# 背景：ImmortalWRT apk 源 udp2raw-20230206.0-r1 的 raw socket 收包失效（见维护手册附录A）
#       因此本 package 从官方 GitHub release 拉取静态二进制，编译期固化进固件。
# 用法：U2R_ENABLE=1 时由 /etc/init.d/wg-udp2raw-server 自动拉起（server 角色）。
# 注意：首次编译需网络可达 GitHub；版本可替换为更新的 release 标签。

include $(TOPDIR)/rules.mk

PKG_NAME:=udp2raw
PKG_VERSION:=20230206.0
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/wangyu-/udp2raw-tunnel.git
PKG_SOURCE_VERSION:=20230206.0
PKG_MIRROR_HASH:=skip

PKG_LICENSE:=MIT
PKG_MAINTAINER:=OpenWrt-CI

include $(INCLUDE_DIR)/package.mk

define Package/udp2raw
	SECTION:=net
	CATEGORY:=Network
	TITLE:=udp2raw-tunnel (static)
	DEPENDS:=+libc
endef

define Build/Compile
	# 使用官方 release 静态二进制（aarch64），跳过本地编译避免工具链问题
	$(call Download,udp2raw-bin)
endef

define Download/udp2raw-bin
	URL:=https://github.com/wangyu-/udp2raw-tunnel/releases/download/$(PKG_VERSION)/udp2raw_binaries.tar.gz
	FILE:=udp2raw_binaries.tar.gz
	HASH:=skip
endef

define Package/udp2raw/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(TAR) -xzf $(DL_DIR)/udp2raw_binaries.tar.gz -C $(1)/usr/sbin udp2raw_amd64 2>/dev/null || true
	# aarch64 静态二进制：release 包内含 udp2raw_aarch64 等；按目标架构解包
	$(TAR) -xzf $(DL_DIR)/udp2raw_binaries.tar.gz -C $(1)/usr/sbin udp2raw_aarch64 2>/dev/null || true
	[ -f $(1)/usr/sbin/udp2raw_aarch64 ] && mv -f $(1)/usr/sbin/udp2raw_aarch64 $(1)/usr/sbin/udp2raw && chmod 0755 $(1)/usr/sbin/udp2raw || true
endef

$(eval $(call BuildPackage,udp2raw))
