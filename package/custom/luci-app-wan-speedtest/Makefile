include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI WAN speed test using LibreSpeed
# The feeds expose both Go and Rust implementations under the same virtual
# package name. The firmware config pins the Go implementation explicitly.
LUCI_DEPENDS:=+luci-base +jsonfilter +coreutils-stat +flock
LUCI_EXTRA_DEPENDS:=librespeed-cli (>=1.0.14-r1)
LUCI_PKGARCH:=all
PKG_VERSION:=1.0.0
PKG_RELEASE:=2
PKG_LICENSE:=Apache-2.0

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
