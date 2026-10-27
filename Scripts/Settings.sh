#!/bin/bash
# SPDX-License-Identifier: MIT
# ImmortalWrt unified build — per-config settings / source-tree injection.
#
# Called with CWD = the cloned source tree root ($GITHUB_WORKSPACE/wrt).
# Receives WRT_CONFIG / WRT_TARGET via env.

# ---- default theme + IP + hostname + timezone ----
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile" 2>/dev/null) 2>/dev/null
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile" 2>/dev/null) 2>/dev/null
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js" 2>/dev/null) 2>/dev/null

WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -n "$WIFI_SH" ] && [ -f "$WIFI_SH" ]; then
	sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" $WIFI_SH
	sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" $WIFI_SH
elif [ -f "$WIFI_UC" ]; then
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
	sed -i "s/country='.*'/country='CN'/g" $WIFI_UC
	sed -i "s/encryption='.*'/encryption='psk2+ccmp'/g" $WIFI_UC
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE
sed -i "s/timezone='GMT0'/timezone='CST-8'/g" $CFG_FILE
sed -i "s/zonename='UTC'/zonename='Asia\\/Shanghai'/g" $CFG_FILE
echo "default timezone set to Asia/Shanghai (CST-8)!"

# default root password = "password" (md5crypt)
echo 'root:$1$4C5K7.$KQSzgarR6TWvov9ZTlKPS0:0:0:99999:7:::' > ./package/base-files/files/etc/shadow
echo "default root password set to 'password'!"

# ---- luci / theme / language appended to .config ----
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config

# ---- apk feed = official (snapshots) ----
# dependency chain: IMAGEOPT -> VERSIONOPT -> VERSION_REPO (all three required,
# otherwise kconfig silently drops the repo and the source never takes effect).
echo 'CONFIG_IMAGEOPT=y' >> ./.config
echo 'CONFIG_VERSIONOPT=y' >> ./.config
echo 'CONFIG_VERSION_REPO="https://downloads.immortalwrt.org/snapshots"' >> ./.config

# ---- manual package tweaks ----
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

# ---- iStore taskd log dir + drop the 404 video feed ----
UDIR="./package/base-files/files/etc/uci-defaults"
mkdir -p "$UDIR"
cat > "$UDIR/99-fix-istore-taskd" <<'EOF'
#!/bin/sh
mkdir -p /var/log/tasks
sed -i '\#/aarch64_generic/video/packages.adb#d' /etc/apk/repositories.d/distfeeds.list 2>/dev/null
exit 0
EOF
chmod +x "$UDIR/99-fix-istore-taskd"

# ---- IPv6 relay (bridge ONT without DHCPv6-PD) ----
cat > "$UDIR/98-ipv6-relay" <<'EOF'
#!/bin/sh
if uci -q get network.wan6 >/dev/null && [ "$(uci -q get dhcp.lan.ra)" != "relay" ]; then
	uci set dhcp.lan.dhcpv6='relay'
	uci set dhcp.lan.ra='relay'
	uci set dhcp.lan.ndp='relay'
	uci -q delete dhcp.lan.ra_flags
	uci set dhcp.wan6='dhcp'
	uci set dhcp.wan6.interface='wan6'
	uci set dhcp.wan6.master='1'
	uci set dhcp.wan6.ra='relay'
	uci set dhcp.wan6.dhcpv6='relay'
	uci set dhcp.wan6.ndp='relay'
	uci commit dhcp
fi
exit 0
EOF
chmod +x "$UDIR/98-ipv6-relay"

# ==============================================================================
# ITV (IPTV) multicast — firmware-fixed into the firewall
#   zone lives in the shipped /etc/config/firewall (see target-patch/itv/),
#   uci-defaults + hotplug guarantee route + IGMPv2 at runtime.
# ==============================================================================
bash "$GITHUB_WORKSPACE/Scripts/Inject-ITV.sh"

# ==============================================================================
# Platform specific injection
# ==============================================================================
CFG_LC="${WRT_CONFIG,,}"

case "$CFG_LC" in
*armsr*)
	# armsr/armv8 — UEFI (edk2/AAVMF) 虚拟机镜像（fnOS / KVM）
	bash "$GITHUB_WORKSPACE/Scripts/Inject-ARMSR.sh"
	;;
*rt28*)
	# Hugsun RT28 (RK3528 + RTL8367B switch + MT7916 WiFi)
	bash "$GITHUB_WORKSPACE/Scripts/Inject-RT28.sh"
	;;
*r28s*)
	# NanoPi R28S (RK3528A, dual GbE + AIC8800 WiFi)
	bash "$GITHUB_WORKSPACE/Scripts/Inject-R28S.sh"
	;;
*re-ss-01*|*re-cs-02*)
	# 亚瑟 / 雅典娜 — already supported by the official tree, nothing to inject.
	echo "JDCloud device: using official in-tree support (no injection needed)"
	;;
esac

# ---- no-WiFi variant: strip all wireless packages (works for every platform) ----
if [[ "$CFG_LC" == *nowifi* ]]; then
	cat >> ./.config <<'EOF'
# --- no-WiFi variant: strip wireless stack ---
CONFIG_PACKAGE_kmod-ath=n
CONFIG_PACKAGE_kmod-ath11k=n
CONFIG_PACKAGE_kmod-ath11k-ahb=n
CONFIG_PACKAGE_kmod-ath11k-pci=n
CONFIG_PACKAGE_ath11k-firmware-ipq6018=n
CONFIG_PACKAGE_ath11k-firmware-ipq6018-ddwrt=n
CONFIG_PACKAGE_ath11k-firmware-qcn9074=n
CONFIG_PACKAGE_ath11k-firmware-qcn9074-ddwrt=n
CONFIG_PACKAGE_kmod-mac80211=n
CONFIG_PACKAGE_hostapd-common=n
CONFIG_PACKAGE_wpad-openssl=n
CONFIG_PACKAGE_wpad-basic-mbedtls=n
CONFIG_PACKAGE_wifi-scripts=n
CONFIG_PACKAGE_kmod-aic8800-sdio=n
CONFIG_PACKAGE_aic8800-sdio-firmware=n
CONFIG_PACKAGE_kmod-bluetooth=n
EOF
	echo "no-WiFi variant: wireless packages disabled"
fi

# ---- Qualcommax platform tweaks (NSS offload only exists on ipq807x) ----
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	echo "CONFIG_FEED_nss_packages=n" >> ./.config
	echo "CONFIG_FEED_sqm_scripts_nss=n" >> ./.config
	echo "CONFIG_NSS_FIRMWARE_VERSION_11_4=n" >> ./.config
	echo "CONFIG_NSS_FIRMWARE_VERSION_12_5=y" >> ./.config
	echo "CONFIG_PACKAGE_kmod-usb-serial-qualcomm=y" >> ./.config
fi
