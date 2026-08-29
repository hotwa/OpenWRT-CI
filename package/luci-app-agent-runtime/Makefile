# SPDX-License-Identifier: Apache-2.0

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-agent-runtime
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=OpenWRT-CI

LUCI_TITLE:=LuCI Agent Runtime Manager
LUCI_DESCRIPTION:=Safe management interface for signed Agent Runtime generations
LUCI_DEPENDS:=+rpcd-mod-ucode +ucode-mod-fs +usign +jsonfilter +flock +wget-ssl +tar
LUCI_PKGARCH:=all

define Package/$(PKG_NAME)/postinst
#!/bin/sh
root="$${IPKG_INSTROOT:-}"
chmod 0755 "$$root/usr/libexec/agent-runtime-rpcd-job"
[ -n "$$root" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
}
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
