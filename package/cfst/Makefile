# SPDX-License-Identifier: GPL-3.0-or-later

include $(TOPDIR)/rules.mk

PKG_NAME:=cfst
PKG_VERSION:=2.3.5
PKG_RELEASE:=1

CFST_ARCH:=$(ARCH)

ifeq ($(filter x86_64,$(CFST_ARCH)),x86_64)
CFST_ASSET:=cfst_linux_amd64
CFST_HASH:=c4c8fc76b4e1bf2bdb5ced8b765956d82dda7bc4eb59df5c04053f0f7db98d90
else ifneq ($(filter i386 i486 i586 i686,$(CFST_ARCH)),)
CFST_ASSET:=cfst_linux_386
CFST_HASH:=e0706d0301deed9dad8c9c8c116e1b8e21f09abc0d5ec859c3308d1880574802
else ifneq ($(filter aarch64%,$(CFST_ARCH)),)
CFST_ASSET:=cfst_linux_arm64
CFST_HASH:=0ac992fcf24d4684caed33620deb9b83ce82f32d2418dc1f90be490ce5900300
else ifneq ($(filter arm_cortex-a% armv7%,$(CFST_ARCH)),)
CFST_ASSET:=cfst_linux_armv7
CFST_HASH:=73386234fe07a766071709859168e19b37f6878345317ccaa992efe35f4ef5f0
else ifneq ($(filter arm_arm1176jzf-s_vfp% armv6%,$(CFST_ARCH)),)
CFST_ASSET:=cfst_linux_armv6
CFST_HASH:=a176a78b7883c92fe04b29e1682af2ce76ef0ca57a5b0abfc85c423fc27ff836
else ifneq ($(filter arm%,$(CFST_ARCH)),)
CFST_ASSET:=cfst_linux_armv5
CFST_HASH:=ffe209c1cf654e8e08fc7135cc6135195215d55ebe6b8c34c2afa7a33c58d145
else ifneq ($(filter mips64el% mips64le%,$(CFST_ARCH)),)
CFST_ASSET:=cfst_linux_mips64le
CFST_HASH:=8df76aa0639fc23f3004b9ae0fb28fc7db0f9b93b6349bda6deeab83b90af9bf
else ifneq ($(filter mips64%,$(CFST_ARCH)),)
CFST_ASSET:=cfst_linux_mips64
CFST_HASH:=01441efc723bd06506943384ca962ada504498cacaa17d773b04623c6ad1d09d
else ifneq ($(filter mipsel% mipsle%,$(CFST_ARCH)),)
CFST_ASSET:=cfst_linux_mipsle
CFST_HASH:=405ac8f8d0ae018163f9acf6e1b7185b20b8539adf4f9302474e3336a29785ee
else ifneq ($(filter mips%,$(CFST_ARCH)),)
CFST_ASSET:=cfst_linux_mips
CFST_HASH:=fe8f21157bc5862a2cdc417253984cd97e2ed6f52d6c0314c37c0e191d72b7fd
else
$(error Unsupported cfst target architecture: $(CFST_ARCH))
endif

PKG_SOURCE:=$(CFST_ASSET).tar.gz
PKG_SOURCE_URL:=https://github.com/XIU2/CloudflareSpeedTest/releases/download/v$(PKG_VERSION)
PKG_HASH:=$(CFST_HASH)
PKG_BUILD_DIR:=$(BUILD_DIR)/$(CFST_ASSET)

PKG_LICENSE:=GPL-3.0-or-later
PKG_MAINTAINER:=XIU2 <xiu2@users.noreply.github.com>

include $(INCLUDE_DIR)/package.mk

define Package/cfst
  SECTION:=net
  CATEGORY:=Network
  TITLE:=CloudflareSpeedTest command-line client
  URL:=https://github.com/XIU2/CloudflareSpeedTest
  PKGARCH:=$(ARCH)
endef

define Package/cfst/description
  Pinned CloudflareSpeedTest binary for the target architecture. The archive
  hash is checked during firmware builds.
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
