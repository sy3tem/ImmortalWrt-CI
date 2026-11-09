# SPDX-License-Identifier: MIT
#
# open-box — 预编译的闭源代理面板（Open-Box 面板 + sing-box 内核 + Node + GeoSite/GeoIP）。
#
# 上游只发 tar.gz，没有源码可编：
#   https://github.com/liandu2024/Open-Box/releases
# 官方装法是刷完机 SSH 上去 curl | sh，这里改成「固件里带包、首启解到 /opt」，
# 刷完即用，不需要联网。
#
# 为什么不在编镜像时直接铺到 /opt：
#   R28S / RT28 的 /opt 是开机才挂载的独立分区(p3)，镜像里 /opt 下的东西会被挂载盖住。
#   所以这个包只把原始 tar.gz 放进 /usr/share/open-box/，由
#   /etc/init.d/open-box-firstboot 在首次开机时解到 /opt/open-box，
#   再按官方 install.sh 的动作铺 init 脚本 / LuCI / 软链。
#
# 版本：上游只保留最近若干个 release，旧 tag 会被删掉（0.1.412 已 404），
# 所以 Scripts/Packages.sh 在编译前会用 Releases API 把 PKG_VERSION / PKG_HASH
# 改写成 latest。下面的值只是离线兜底（API 不通时用），升级时同步改一下即可：
# hash 取 Release 里同名 .sha256 的第一列，或用 API 的 asset.digest。

include $(TOPDIR)/rules.mk

PKG_NAME:=open-box
PKG_VERSION:=0.1.422
PKG_RELEASE:=1

PKG_SOURCE:=open-box-v$(PKG_VERSION)-linux-arm64.tar.gz
PKG_SOURCE_URL:=https://github.com/liandu2024/Open-Box/releases/download/v$(PKG_VERSION) \
	https://gh-proxy.com/https://github.com/liandu2024/Open-Box/releases/download/v$(PKG_VERSION)
PKG_HASH:=ab733d4fc53f1af8cb1259806a7d8fc082eb1ec28e64d8eab613e0e815a09f3b

PKG_LICENSE:=LicenseRef-Open-Box-Proprietary
PKG_MAINTAINER:=sy3tem

# 只是搬运一个 tar.gz，不需要解包到 build_dir
PKG_UNPACK:=true

include $(INCLUDE_DIR)/package.mk

define Package/open-box
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Open-Box (proprietary proxy panel; unpacked to /opt on first boot)
  URL:=https://github.com/liandu2024/Open-Box
  DEPENDS:=@aarch64 +kmod-tun +kmod-nft-queue +kmod-nft-nat +kmod-veth +ip-full +ca-bundle +tar +gzip
endef

define Package/open-box/description
  Open-Box 路由器端：浏览器面板 + sing-box 内核 + Node 运行时 + 完整 GeoSite/GeoIP。
  上游只有 aarch64 预编译包，且是闭源专有软件（见其 LICENSE）。
  本包把发布包原样放进固件，首次开机解到 /opt/open-box 并铺好服务与 LuCI 入口。
endef

define Build/Compile
endef

define Package/open-box/install
	$(INSTALL_DIR) $(1)/usr/share/open-box
	$(INSTALL_DATA) $(DL_DIR)/$(PKG_SOURCE) $(1)/usr/share/open-box/payload.tar.gz
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/open-box-firstboot $(1)/etc/init.d/open-box-firstboot
	# 显式建 /etc/rc.d 链接：不依赖 opkg postinst 的自动 enable，保证首启一定跑到
	$(INSTALL_DIR) $(1)/etc/rc.d
	$(LN) ../init.d/open-box-firstboot $(1)/etc/rc.d/S99open-box-firstboot
endef

$(eval $(call BuildPackage,open-box))
