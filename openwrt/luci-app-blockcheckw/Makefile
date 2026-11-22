include $(TOPDIR)/rules.mk

LUCI_TITLE:=Zapret2Wizard - All-in-One DPI Bypass Engine & Autonomous LuCI Tuning Suite
LUCI_DEPENDS:=+luci-base +luci-compat +curl +coreutils-timeout +nftables +ca-bundle +kmod-veth +kmod-nfnetlink-queue +kmod-nft-queue
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-blockcheckw
PKG_VERSION:=0.37.9
PKG_RELEASE:=1
PKG_LICENSE:=MIT

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
