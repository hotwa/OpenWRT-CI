# SPDX-License-Identifier: GPL-3.0-or-later

include $(TOPDIR)/rules.mk

PKG_NAME:=cfst
PKG_VERSION:=2.3.5
PKG_RELEASE:=1

PKG_SOURCE:=cfst_linux_arm64.tar.gz
PKG_SOURCE_URL:=https://github.com/XIU2/CloudflareSpeedTest/releases/download/v$(PKG_VERSION)
PKG_HASH:=0ac992fcf24d4684caed33620deb9b83ce82f32d2418dc1f90be490ce5900300
PKG_BUILD_DIR:=$(BUILD_DIR)/cfst_linux_arm64

PKG_LICENSE:=GPL-3.0-or-later
PKG_MAINTAINER:=XIU2 <xiu2@users.noreply.github.com>

include $(INCLUDE_DIR)/package.mk

define Package/cfst
  SECTION:=net
  CATEGORY:=Network
  TITLE:=CloudflareSpeedTest command-line client
  URL:=https://github.com/XIU2/CloudflareSpeedTest
  PKGARCH:=aarch64_cortex-a53
endef

define Package/cfst/description
  Pinned ARM64 CloudflareSpeedTest binary for the RE-CS-02 Cloudflare IP
  speed-test client. The archive hash is checked during firmware builds.
endef

define Build/Prepare
	rm -rf $(PKG_BUILD_DIR)
	tar -xzf $(DL_DIR)/$(PKG_SOURCE) -C $(BUILD_DIR)
endef

define Build/Compile
endef

define Package/cfst/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/cfst $(1)/usr/bin/cfst
endef

$(eval $(call BuildPackage,cfst))
