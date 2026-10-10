#!/bin/bash
# SPDX-License-Identifier: MIT
# Inject NanoPi R28S (RK3528A) support into an ImmortalWrt source tree.
#
# 1) kernel DTS              rk3528-nanopi-r28s.dts
# 2) device definition       appended to target/linux/rockchip/image/armv8.mk
# 3) U-Boot build device     nanopi-zero2-rk3528 BUILD_DEVICES += r28s
#    (R28S reuses the in-tree NanoPi Zero2 U-Boot — same RK3528A SoC)
# 4) board.d network / leds mapping
# 5) clean auto-mount of the boot partition (match the vendor's tidy layout)
# 6) /opt big partition, the vendor's own way: the image already carries the
#    partition (Build/r28s-opt-img) and a first-boot uci-defaults script
#    formats + grows it (99-auto-resize-and-mount-opt).  No reboot anywhere.
#
# Called from WRT-CORE "Custom Settings" with CWD = source tree root.
set -e

PATCH_DIR="$GITHUB_WORKSPACE/target-patch/r28s"
RK_DIR="./target/linux/rockchip"
DTS_DIR="$RK_DIR/files/arch/arm64/boot/dts/rockchip"
IMG_MK="$RK_DIR/image/armv8.mk"
BOARD_D="$RK_DIR/armv8/base-files/etc/board.d"

echo "===== Inject NanoPi R28S support ====="

# ---- 1) kernel device tree ----
mkdir -p "$DTS_DIR"
cp -f "$PATCH_DIR/rk3528-nanopi-r28s.dts" "$DTS_DIR/rk3528-nanopi-r28s.dts"
echo "[1] dts installed -> $DTS_DIR/rk3528-nanopi-r28s.dts"

# ---- 2) device definition ----
if ! grep -q "friendlyarm_nanopi-r28s" "$IMG_MK"; then
	cat "$PATCH_DIR/armv8-device-r28s.mk" >> "$IMG_MK"
	echo "[2] device def appended -> $IMG_MK"
else
	echo "[2] device def already present, skip"
fi

# ---- 3) let r28s trigger the Zero2 U-Boot build ----
# Without this, pine64-img cannot find nanopi-zero2-rk3528-u-boot-rockchip.bin,
# because that U-Boot's BUILD_DEVICES only lists friendlyarm_nanopi-zero2.
UBOOT_MK="./package/boot/uboot-rockchip/Makefile"
if [ -f "$UBOOT_MK" ] && ! grep -A3 "define U-Boot/nanopi-zero2-rk3528" "$UBOOT_MK" | grep -q "friendlyarm_nanopi-r28s"; then
	sed -i '/define U-Boot\/nanopi-zero2-rk3528/,/endef/ s/friendlyarm_nanopi-zero2$/friendlyarm_nanopi-zero2 \\\n    friendlyarm_nanopi-r28s/' "$UBOOT_MK"
	echo "[3] nanopi-zero2-rk3528 U-Boot BUILD_DEVICES += r28s"
	grep -A5 "define U-Boot/nanopi-zero2-rk3528" "$UBOOT_MK" | head -8
else
	echo "[3] zero2 U-Boot already covers r28s or mk missing, skip"
fi

# ---- 4) board.d network mapping ----
# compatible prefix must match the DTS = "friendlyelec,nanopi-r28s"
# 02_network has TWO `case "$board" in` blocks (interfaces + macs) -> insert only
# once, into the FIRST one (guarded by the `done` flag).
NET="$BOARD_D/02_network"
if [ -f "$NET" ] && ! grep -q "friendlyelec,nanopi-r28s" "$NET"; then
	awk '!done && /case "\$board" in/ {
		print;
		print "\tfriendlyelec,nanopi-r28s)";
		print "\t\tucidef_set_interfaces_lan_wan \x27eth1\x27 \x27eth0\x27";
		print "\t\t;;";
		done=1;
		next
	} 1' "$NET" > "$NET.tmp" && mv "$NET.tmp" "$NET"
	cnt=$(grep -c "friendlyelec,nanopi-r28s" "$NET")
	echo "[4] 02_network mapping added (r28s count=$cnt, expect 1)"
else
	echo "[4] 02_network already has r28s or file missing, skip"
fi

# ---- 4b) board.d LED mapping ----
# LED names must match the DTS labels (wan_led/lan_led), matching vendor LuCI icons.
LEDS="$BOARD_D/01_leds"
if [ -f "$LEDS" ] && ! grep -q "friendlyelec,nanopi-r28s" "$LEDS"; then
	awk '!done && /^case \$board in/ {
		print;
		print "friendlyelec,nanopi-r28s)";
		print "\tucidef_set_led_netdev \"wan\" \"WAN\" \"wan_led\" \"eth0\"";
		print "\tucidef_set_led_netdev \"lan\" \"LAN\" \"lan_led\" \"eth1\" ;;";
		done=1;
		next
	} 1' "$LEDS" > "$LEDS.tmp" && mv "$LEDS.tmp" "$LEDS"
	cnt=$(grep -c "friendlyelec,nanopi-r28s" "$LEDS")
	echo "[4b] 01_leds mapping added (r28s count=$cnt, expect 1)"
else
	echo "[4b] 01_leds already has r28s or file missing, skip"
fi

# ---- 5) tidy auto-mount: drop the boot partition, keep /opt ----
UDIR="$RK_DIR/armv8/base-files/etc/uci-defaults"
mkdir -p "$UDIR"
cat > "$UDIR/99-r28s-clean-mount" <<'EOF'
#!/bin/sh
# R28S: clean up block-mount auto mounts so only /opt remains.
#  1) disable anon_mount/anon_swap: otherwise block-mount grabs the data
#     partition as /mnt/mmcblk0p3 before our init.d can mount it at /opt
#  2) drop every fstab mount entry except /opt
uci set fstab.@global[0].anon_mount='0'
uci set fstab.@global[0].anon_swap='0'
index=0
while uci -q get fstab.@mount[$index]; do
	target=$(uci -q get fstab.@mount[$index].target)
	case "$target" in
	/opt)
		index=$((index + 1)) ;;
	*)
		uci -q del fstab.@mount[$index] ;;
	esac
done
uci commit fstab
for m in /mnt/mmcblk0p1 /mnt/mmcblk0p3 /mnt/mmcblk2p1 /mnt/mmcblk2p3; do
	umount "$m" 2>/dev/null
	# busybox/OpenWrt has no findmnt (that is util-linux's mount-utils, which we
	# do not install), so ask /proc/mounts directly before rmdir'ing.
	awk -v m="$m" '$2 == m { found = 1 } END { exit !found }' /proc/mounts || rmdir "$m" 2>/dev/null
done
exit 0
EOF
chmod +x "$UDIR/99-r28s-clean-mount"
echo "[5] uci-defaults clean-mount installed"

# ---- 6) /opt big partition (vendor mechanism, no reboot) ----
# (a) first-boot script: format p3 + grow it to the end of the eMMC + fstab.
#     This is friendlywrt's own /etc/uci-defaults/99-auto-resize-and-mount-opt.
OPT_DEF_SRC="$PATCH_DIR/opt-partition/99-auto-resize-and-mount-opt"
mkdir -p "$UDIR"
if [ -f "$OPT_DEF_SRC" ]; then
	cp -f "$OPT_DEF_SRC" "$UDIR/99-auto-resize-and-mount-opt"
	chmod +x "$UDIR/99-auto-resize-and-mount-opt"
	echo "[6] /opt uci-defaults installed (vendor resize-and-mount)"
else
	echo "[6] 99-auto-resize-and-mount-opt not found, skip"
fi

# (b) host-side helper for Build/r28s-opt-img (adds the empty p3 to the image);
#     the device definition in target-patch/r28s/armv8-device-r28s.mk calls it
#     as $(TOPDIR)/scripts/r28s-mbr-add-part.py
MBR_SRC="$PATCH_DIR/opt-partition/mbr_add_part.py"
if [ -f "$MBR_SRC" ] && [ -d "./scripts" ]; then
	cp -f "$MBR_SRC" "./scripts/r28s-mbr-add-part.py"
	chmod +x "./scripts/r28s-mbr-add-part.py"
	echo "[6b] mbr helper installed -> scripts/r28s-mbr-add-part.py"
else
	echo "[6b] mbr_add_part.py / scripts dir missing, skip"
fi

# (c) drop the old self-made service for good.  It appended a new, unformatted
#     partition on *every* boot until the MBR ran out of the 4 primary slots,
#     and then rebooted unconditionally -- a ~30 s reboot loop.
INITD="$RK_DIR/armv8/base-files/etc/init.d"
RCD="$RK_DIR/armv8/base-files/etc/rc.d"
rm -f "$INITD/r28s-opt-partition" "$RCD/S99r28s-opt-partition"
echo "[6c] legacy r28s-opt-partition service removed (init.d + rc.d)"

echo "===== Inject R28S done ====="
