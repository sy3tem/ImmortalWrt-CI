#!/bin/bash
# SPDX-License-Identifier: MIT
# Inject Hugsun RT28 (RK3528 + RTL8367B switch + MT7916 WiFi) into ImmortalWrt.
#
# Everything here is an INCREMENTAL change onto the official master tree:
#   - new files are copied in
#   - existing files are only touched where strictly needed
#     (patch first, fall back to an in-place sed/awk edit if the upstream
#      context has drifted — never wholesale file replacement)
#
# Called from WRT-CORE "Custom Settings" with CWD = source tree root.
set -e
# NOTE: intentionally NOT `set -u`: OpenWrt output dir vars are unset in CI.

PATCH_DIR="$GITHUB_WORKSPACE/target-patch/rt28"
RK_DIR="./target/linux/rockchip"

echo "===== Inject Hugsun RT28 support ====="

# ---- 1) board DTS (new files) ----
mkdir -p "$RK_DIR/files/arch/arm64/boot/dts/rockchip"
cp -f "$PATCH_DIR"/dts/rk3528-hugsun-rt28.dts   "$RK_DIR/files/arch/arm64/boot/dts/rockchip/"
cp -f "$PATCH_DIR"/dts/rk3528-hugsun-rt28.dtsi  "$RK_DIR/files/arch/arm64/boot/dts/rockchip/"
echo "[1] DTS installed"

# ---- 2) kernel patches (dwmac-rk set_speed + rtl8365mb RTL8376RB) ----
mkdir -p "$RK_DIR/patches-6.18"
cp -f "$PATCH_DIR"/patches-6.18/998-dsa-rtl8365mb-add-rtl8376rb.patch        "$RK_DIR/patches-6.18/"
cp -f "$PATCH_DIR"/patches-6.18/999-dwmac-rk-3528-setspeed-before-dma-reset.patch "$RK_DIR/patches-6.18/"
echo "[2] kernel patches installed"

# ---- 3) device definition (append Device/hugsun_rt28 to armv8.mk) ----
IMG_MK="$RK_DIR/image/armv8.mk"
if ! grep -q "define Device/hugsun_rt28" "$IMG_MK"; then
	cat >> "$IMG_MK" <<'EOF'

define Device/hugsun_rt28
  $(Device/rk3528)
  DEVICE_VENDOR := Hugsun
  DEVICE_MODEL := RT28
  DEVICE_DTS := rk3528-hugsun-rt28
  SUPPORTED_DEVICES := hugsun,rk3528-rt28
  DEVICE_PACKAGES := kmod-dsa-rtl8365mb kmod-mt7915e kmod-mt7916-firmware wpad-openssl
  UBOOT_DEVICE_NAME := hugsun-rt28-rk3528
  BOOT_SCRIPT := rk3528-hugsun-rt28
  # RT28 factory boot flow (0513 stock): bare kernel Image + separate rockchip.dtb,
  # booted via 'booti' by the stock 2017.09 U-Boot (its bootm cannot read a FIT fdt).
  KERNEL = kernel-bin
  IMAGE/sysupgrade.img.gz = boot-common | rockchip-dtb | boot-script $$(BOOT_SCRIPT) | $$(BOOT_FLOW) | gzip | append-metadata
endef
TARGET_DEVICES += hugsun_rt28
EOF
	echo "[3] Device/hugsun_rt28 appended"
else
	echo "[3] Device/hugsun_rt28 already present, skip"
fi

# ---- 4) image/Makefile: add Build/rockchip-dtb ----
IMG_MKFILE="$RK_DIR/image/Makefile"
if ! grep -q "define Build/rockchip-dtb" "$IMG_MKFILE"; then
	awk '/^define Build\/boot-script/ && !done {
		print "define Build/rockchip-dtb";
		print "\t# Copy the compiled board DTB to the boot partition as rockchip.dtb";
		print "\t# (legacy Rockchip boot flow: booti kernel.img - rockchip.dtb)";
		print "\t$(CP) $(KDIR)/image-$(firstword $(DEVICE_DTS)).dtb $@.boot/rockchip.dtb";
		print "endef";
		print "";
		done=1;
	} {print}' "$IMG_MKFILE" > "$IMG_MKFILE.tmp" && mv "$IMG_MKFILE.tmp" "$IMG_MKFILE"
	echo "[4] Build/rockchip-dtb added"
else
	echo "[4] Build/rockchip-dtb already present, skip"
fi

# ---- 5) bootscript ----
cp -f "$PATCH_DIR/rk3528-hugsun-rt28.bootscript" "$RK_DIR/image/rk3528-hugsun-rt28.bootscript"
echo "[5] bootscript installed"

# ---- 6) board.d network / leds (incremental insert into the existing case) ----
BD="$RK_DIR/armv8/base-files/etc/board.d"
NET="$BD/02_network"
if [ -f "$NET" ] && ! grep -q "hugsun,rk3528-rt28" "$NET"; then
	awk '!done && /case "\$board" in/ {
		print;
		print "\thugsun,rk3528-rt28-route|\\";
		print "\thugsun,rk3528-rt28)";
		print "\t\tucidef_set_interfaces_lan_wan \x27lan1 lan2 lan3\x27 \x27wan\x27";
		print "\t\t;;";
		done=1;
		next
	} 1' "$NET" > "$NET.tmp" && mv "$NET.tmp" "$NET"
	echo "[6] 02_network rt28 case added ($(grep -c 'hugsun,rk3528-rt28' "$NET") hits)"
fi
LEDS="$BD/01_leds"
if [ -f "$LEDS" ] && ! grep -q "hugsun,rk3528-rt28" "$LEDS"; then
	awk '!done && /^case \$board in/ {
		print;
		print "hugsun,rk3528-rt28-route|\\";
		print "hugsun,rk3528-rt28)";
		print "\t# sys (work) LED uses the led-boot/led-running aliases;";
		print "\t# link LED is driven by /etc/hotplug.d/iface/99-rt28-link-led";
		print "\t;;";
		done=1;
		next
	} 1' "$LEDS" > "$LEDS.tmp" && mv "$LEDS.tmp" "$LEDS"
	echo "[6b] 01_leds rt28 case added ($(grep -c 'hugsun,rk3528-rt28' "$LEDS") hits)"
fi

# ---- 7) per-board base-files (uci-defaults / hotplug / init.d) ----
BFD="$RK_DIR/armv8/base-files/etc"
mkdir -p "$BFD/uci-defaults" "$BFD/hotplug.d/iface" "$BFD/init.d" "$BFD/rc.d"
cp -f "$PATCH_DIR"/base-files/uci-defaults/99-rt28-defaults     "$BFD/uci-defaults/"
cp -f "$PATCH_DIR"/base-files/uci-defaults/99-set-default-theme "$BFD/uci-defaults/"
cp -f "$PATCH_DIR"/base-files/hotplug.d/iface/99-rt28-link-led  "$BFD/hotplug.d/iface/"
cp -f "$PATCH_DIR"/base-files/init.d/opt-mount                  "$BFD/init.d/"
chmod +x "$BFD/uci-defaults/"99-* "$BFD/hotplug.d/iface/99-rt28-link-led" "$BFD/init.d/opt-mount"
ln -sf ../init.d/opt-mount "$BFD/rc.d/S98opt-mount"
echo "[7] per-board base-files installed"

# ---- 8) U-Boot: prebuilt variant (factory bootloader) ----
UBOOT_MK="./package/boot/uboot-rockchip/Makefile"
UBOOT_FILES="./package/boot/uboot-rockchip/files"
mkdir -p "$UBOOT_FILES"
cp -f "$PATCH_DIR/package/boot/uboot-rockchip/files/hugsun-rt28-rk3528-u-boot-rockchip.bin" "$UBOOT_FILES/"
if [ -f "$UBOOT_MK" ] && ! grep -q "U-Boot/hugsun-rt28-rk3528" "$UBOOT_MK"; then
	awk '/^define U-Boot\/nanopi-zero2-rk3528/ && !done {
		print "define U-Boot/hugsun-rt28-rk3528";
		print "  BUILD_SUBTARGET:=armv8";
		print "  NAME:=Hugsun RT28";
		print "  BUILD_DEVICES:= \\";
		print "    hugsun_rt28";
		print "endef";
		print "";
		done=1;
	} {print}' "$UBOOT_MK" > "$UBOOT_MK.tmp" && mv "$UBOOT_MK.tmp" "$UBOOT_MK"
	# append to UBOOT_TARGETS
	sed -i 's/^\(  nanopi-zero2-rk3528 \\\)$/\1\n  hugsun-rt28-rk3528 \\/' "$UBOOT_MK"
	# skip compiling: reuse the prebuilt factory bootloader from files/
	cat >> "$UBOOT_MK" <<'EOF'

# hugsun-rt28-rk3528 reuses the prebuilt factory bootloader in files/
# (extracted from the vendor 0513 image), so skip compiling and just stage it.
define Build/Configure
	$(if $(filter hugsun-rt28-rk3528,$(BUILD_VARIANT)),@true,$(call Build/Configure/U-Boot))
endef

define Build/Compile
	$(if $(filter hugsun-rt28-rk3528,$(BUILD_VARIANT)),@true,$(call Build/Compile/U-Boot))
endef
EOF
	echo "[8] U-Boot/hugsun-rt28-rk3528 added (prebuilt)"
else
	echo "[8] U-Boot/hugsun-rt28-rk3528 already present, skip"
fi

# ---- 8b) U-Boot: reference-style InstallDev override for the prebuilt variant ----
# The generic InstallDev only knows the TPL / loaderimage paths. We need the
# prebuilt blob copied as <variant>-u-boot-rockchip.bin. Patch it in place,
# idempotently (anchored on the exact block so the *other* prebuilt branch we
# just added does not fool the guard).
if ! grep -q 'CURDIR)/files/hugsun-rt28-rk3528-u-boot-rockchip.bin' "$UBOOT_MK"; then
	python3 - "$UBOOT_MK" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

# Replace the WHOLE generic InstallDev block with one that knows about the
# prebuilt rt28 blob. Matching the exact block keeps this idempotent and safe
# when upstream adds other prebuilt variants.
MARK = "define Build/InstallDev"
i = s.find(MARK)
assert i >= 0, "Build/InstallDev not found"
j = s.find("\nendef", i)
assert j >= 0, "Build/InstallDev endef not found"
j += len("\nendef")

new_block = """define Build/InstallDev
	$(INSTALL_DIR) $(STAGING_DIR_IMAGE)
ifneq ($(filter hugsun-rt28-rk3528,$(BUILD_VARIANT)),)
	$(CP) $(CURDIR)/files/hugsun-rt28-rk3528-u-boot-rockchip.bin $(STAGING_DIR_IMAGE)/$(BUILD_VARIANT)-u-boot-rockchip.bin
else ifneq ($(TPL),)
	$(CP) $(PKG_BUILD_DIR)/u-boot-rockchip.bin $(STAGING_DIR_IMAGE)/$(BUILD_VARIANT)-u-boot-rockchip.bin
else
	$(STAGING_DIR_IMAGE)/loaderimage --pack --uboot $(PKG_BUILD_DIR)/u-boot-dtb.bin $(PKG_BUILD_DIR)/uboot.img 0x800000
	$(CP) $(PKG_BUILD_DIR)/uboot.img $(STAGING_DIR_IMAGE)/$(BUILD_VARIANT)-uboot.img
endif
endef"""

s = s[:i] + new_block + s[j:]
open(p, 'w', encoding='utf-8', newline='\n').write(s)
print("[8b] Build/InstallDev patched for prebuilt rt28 u-boot")
PY
else
	echo "[8b] InstallDev already patched, skip"
fi

# ---- 9) compatibility patches: mt76 eeprom + rtl8367b 0x0030 chip id ----
# Both are tiny, upstream-context based hunks. `git apply --3way` so that a
# small upstream drift can still merge; report loudly if it cannot.
if git -C . apply --3way --whitespace=nowarn "$PATCH_DIR/patches-compat.patch"; then
	echo "[9] compat patches applied (mt76 eeprom + rtl8367b 0x0030)"
else
	echo "[9] WARNING: patches-compat.patch did not apply — check upstream drift!"
fi

echo "===== Inject RT28 done ====="
