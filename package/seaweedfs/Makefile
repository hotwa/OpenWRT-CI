include $(TOPDIR)/rules.mk

PKG_NAME:=seaweedfs
PKG_VERSION:=3.97
PKG_RELEASE:=1

# 从源码构建（优先方案）
PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=https://github.com/seaweedfs/seaweedfs.git
PKG_SOURCE_VERSION:=$(PKG_VERSION)
PKG_MIRROR_HASH:=

PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE

PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1

# Go 构建包（主程序）
GO_PKG:=github.com/seaweedfs/seaweedfs/weed
GO_PKG_LDFLAGS:=-s -w

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/seaweedfs
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=SeaweedFS (weed) distributed filesystem
  URL:=https://github.com/seaweedfs/seaweedfs
  DEPENDS:=$(GO_ARCH_DEPENDS) +ca-bundle
endef

define Package/seaweedfs/description
  SeaweedFS is a simple and highly scalable distributed filesystem. This package builds the 'weed' binary from source for the target.
endef

define Package/seaweedfs/install
  $(call GoPackage/Package/Install/Bin,$(1))
endef

$(eval $(call GoBinPackage,seaweedfs))
$(eval $(call BuildPackage,seaweedfs))
