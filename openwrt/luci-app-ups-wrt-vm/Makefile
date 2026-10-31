include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-ups-wrt-vm
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=UPS-WRT-VM Team

LUCI_TITLE:=LuCI support for UPS-WRT-VM (APC & HID UPS Smart Power Orchestration for ESXi)
LUCI_DEPENDS:=+nut-server +nut-driver-usbhid-ups +nut-monitor
LUCI_PKGARCH:=all

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=$(LUCI_TITLE)
  DEPENDS:=$(LUCI_DEPENDS)
  PKGARCH:=$(LUCI_PKGARCH)
endef

define Package/$(PKG_NAME)/description
  Modern smart power orchestration and two-phase deadlock-free graceful shutdown system
  for VMware ESXi host and OpenWrt / ImmortalWrt virtual router with USB-HID UPS.
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_BIN) ./luasrc/controller/ups_wrt_vm.lua $(1)/usr/lib/lua/luci/controller/
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi
	$(INSTALL_BIN) ./luasrc/model/cbi/ups_wrt_vm.lua $(1)/usr/lib/lua/luci/model/cbi/
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/ups_manager $(1)/etc/config/ups_manager
	$(INSTALL_DIR) $(1)/etc/nut
	$(INSTALL_BIN) ./root/etc/nut/ups_scheduler.sh $(1)/etc/nut/ups_scheduler.sh
	$(INSTALL_DIR) $(1)/etc/ups_manager
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
	exit 0
}
endef

$(eval $(call BuildPackage,$(PKG_NAME)))

