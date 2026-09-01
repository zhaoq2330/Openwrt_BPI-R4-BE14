include $(TOPDIR)/rules.mk

PKG_NAME:=bpi-r4-be14-defaults
PKG_VERSION:=1.0.0
PKG_RELEASE:=2
PKG_LICENSE:=Apache-2.0

include $(INCLUDE_DIR)/package.mk

define Package/bpi-r4-be14-defaults
  SECTION:=base
  CATEGORY:=Base system
  TITLE:=Safe defaults for BPI-R4 BE14
  DEPENDS:=+uci +luci-base +luci-theme-argon +firewall4 +uhttpd +ttyd
endef

define Package/bpi-r4-be14-defaults/description
  Project defaults for the BPI-R4 BE14 image, including LAN addressing,
  Argon, hardware flow offload, and conservative service startup.
endef

define Build/Compile
endef

define Package/bpi-r4-be14-defaults/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults $(1)/etc/sysctl.d
	$(INSTALL_BIN) ./files/99-bpi-r4-be14-defaults $(1)/etc/uci-defaults/
	$(INSTALL_DATA) ./files/99-bpi-r4-performance.conf $(1)/etc/sysctl.d/
endef

$(eval $(call BuildPackage,bpi-r4-be14-defaults))
