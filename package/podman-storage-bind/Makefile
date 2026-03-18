include $(TOPDIR)/rules.mk

PKG_NAME:=podman-storage-bind
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Preseed podman storage bind skeleton
  PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
  Precreate eMMC storage directories and install a safe bind-mount
  helper for podman persistent storage.
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/mnt/emmc
	$(INSTALL_DIR) $(1)/mnt/emmc/bin
	$(INSTALL_DIR) $(1)/mnt/emmc/project
	$(INSTALL_DIR) $(1)/mnt/emmc/share
	$(INSTALL_DIR) $(1)/mnt/emmc/podman_storage
	$(INSTALL_DIR) $(1)/var/lib/containers/storage
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/podman-storage-bind.init $(1)/etc/init.d/podman-storage-bind
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/99-podman-storage-bind $(1)/etc/uci-defaults/99-podman-storage-bind
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
