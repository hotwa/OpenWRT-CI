include $(TOPDIR)/rules.mk
PKG_NAME:=cpe6-route-audit
PKG_VERSION:=1
PKG_RELEASE:=1
PKG_LICENSE:=MIT
include $(INCLUDE_DIR)/package.mk

define Package/cpe6-route-audit
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Read-only UDX710 IPv6 route ownership audit
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/route-audit.c $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -static -o $(PKG_BUILD_DIR)/route-audit $(PKG_BUILD_DIR)/route-audit.c
endef

define Package/cpe6-route-audit/install
	$(INSTALL_DIR) $(1)/usr/libexec/cpe5g-ipv6
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/route-audit $(1)/usr/libexec/cpe5g-ipv6/route-audit
endef
$(eval $(call BuildPackage,cpe6-route-audit))
