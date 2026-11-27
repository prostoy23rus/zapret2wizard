include $(TOPDIR)/rules.mk

LUCI_TITLE:=Zapret2Wizard - All-in-One DPI Bypass Engine & Autonomous LuCI Tuning Suite
LUCI_DEPENDS:=+luci-base +luci-compat +curl +coreutils-timeout +nftables +ca-bundle +kmod-veth +kmod-nfnetlink-queue +kmod-nft-queue
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-blockcheckw
PKG_VERSION:=0.37.37
PKG_RELEASE:=1
PKG_LICENSE:=MIT

# SDK-built packages use the same removal owner as release IPK/APK builds.
define Package/luci-app-blockcheckw/prerm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] && exit 0
. /usr/share/zapret2wizard/lifecycle.sh || exit 1
if [ "$$1" = upgrade ]; then
    BCW_INTERNAL_STOP=1 /etc/init.d/zapret2wizard stop || exit 1
else
    bcw_lifecycle_prepare_remove || exit 1
fi
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
