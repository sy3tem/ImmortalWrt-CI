#!/bin/bash
# SPDX-License-Identifier: MIT
# 把 NanoPi Zero2 (RK3528A) 的 board.d 映射与 /opt 分区脚本注入到 ImmortalWrt 源码树
#
# 背景: Zero2 的设备定义与内核 DTS 上游已原生支持, 本脚本只补上游缺的部分.
#   已上游支持(无需注入):
#     - Device/friendlyarm_nanopi-zero2  -> target/linux/rockchip/image/armv8.mk
#     - U-Boot/nanopi-zero2-rk3528       -> package/boot/uboot-rockchip/Makefile
#     - 内核 DTS                          -> patches-6.18 的 073-04(USB) 与 110(PCIe) 补丁
#   本脚本补:
#     - 02_network 单网口 lan 映射
#     - 01_leds LED 映射
#     - uci-defaults 首启清理 boot 分区自动挂载
#     - /opt 大分区 init.d (S98, 必须先于 S99open-box-firstboot)
#
# 调用时机: WRT-CORE 的 "Custom Settings" 阶段, 在源码树根目录执行

set -e

RK_DIR="./target/linux/rockchip"
BOARD_D="$RK_DIR/armv8/base-files/etc/board.d"

echo "===== Inject NanoPi Zero2 board mappings ====="

# ---- 1) 网口映射 ----
# Zero2 = 单网口 gmac1(RGMII -> RTL8211F), 内核枚举为 eth0.
# 单口板用 ucidef_set_interface_lan(而非 lan_wan 双口写法).
# ★compatible 前缀必须是 "friendlyelec,"(与 dts compatible 一致),
#   不是 "friendlyarm,"(那是 DEVICE_NAME 的前缀) —— 混用会导致分支永不命中★
NET="$BOARD_D/02_network"
if [ -f "$NET" ] && ! grep -q "friendlyelec,nanopi-zero2" "$NET"; then
	awk '!done && /case "\$board" in/ {
		print;
		print "\tfriendlyelec,nanopi-zero2)";
		print "\t\tucidef_set_interface_lan \x27eth0\x27";
		print "\t\t;;";
		done=1;
		next
	} 1' "$NET" > "$NET.tmp" && mv "$NET.tmp" "$NET"
	cnt=$(grep -c "friendlyelec,nanopi-zero2" "$NET")
	echo "[1] 02_network mapping added (zero2 count=$cnt, expect 1)"
else
	echo "[1] 02_network already has zero2 or file missing, skip"
fi

# ---- 2) LED 映射 ----
# Zero2 两个 LED: SYS(gpio4 PB0, heartbeat) + LED1(gpio4 PB1).
# 用 dts 里的 label 名(led1_led), 与官方 friendlywrt 的 LuCI 网口图标一致.
# ★必须在 'case $board in' 之后插入(分支要在 case 内部),
#   插到 case 外会 syntax error: unexpected )★
LEDS="$BOARD_D/01_leds"
if [ -f "$LEDS" ] && ! grep -q "friendlyelec,nanopi-zero2" "$LEDS"; then
	awk '!done && /^case \$board in/ {
		print;
		print "friendlyelec,nanopi-zero2)";
		print "\tucidef_set_led_netdev \"lan\" \"LAN\" \"led1_led\" \"eth0\" ;;";
		done=1;
		next
	} 1' "$LEDS" > "$LEDS.tmp" && mv "$LEDS.tmp" "$LEDS"
	cnt=$(grep -c "friendlyelec,nanopi-zero2" "$LEDS")
	echo "[2] 01_leds mapping added (zero2 count=$cnt, expect 1)"
else
	echo "[2] 01_leds already has zero2 or file missing, skip"
fi

# ---- 3) 首启清理 boot 分区自动挂载 ----
# block-mount 的 anon_mount 会把 boot 分区挂到 /mnt, 而 boot 分区(内核/dtb)
# 由 u-boot 直接读取, 挂出来没有意义. 对齐官方 friendlywrt 的干净挂载点.
UDIR="$RK_DIR/armv8/base-files/etc/uci-defaults"
mkdir -p "$UDIR"
cat > "$UDIR/99-zero2-clean-mount" <<'EOF'
#!/bin/sh
# Zero2: 清理 block-mount 自动挂载, 对齐官方干净挂载点
# 1) 关掉匿名挂载: anon_mount 会把未在 fstab 显式占位的分区自动挂到 /mnt/<dev>
uci set fstab.@global[0].anon_mount='0'
uci set fstab.@global[0].anon_swap='0'
# 2) 删掉非 /opt 的自动挂载项, 保留 /opt
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
# 3) 卸载已挂上的多余挂载 + 删除残留空目录
# Zero2 存储可能是 mmcblk0(SD) 或 mmcblk1(eMMC), 两种都覆盖
for m in /mnt/mmcblk0p1 /mnt/mmcblk1p1 /mnt/mmcblk2p1; do
	umount "$m" 2>/dev/null
	findmnt -n "$m" >/dev/null 2>&1 || rmdir "$m" 2>/dev/null
done
exit 0
EOF
chmod +x "$UDIR/99-zero2-clean-mount"
echo "[3] uci-defaults clean-mount installed"

# ---- 4) /opt 大分区 init.d ----
# 剩余空间做成 ext4 分区挂 /opt (两段式: 写分区表 -> reboot -> mkfs+mount)。
# ★链接必须排在 S99open-box-firstboot 之前★
#   首次启动本脚本写分区表后直接 reboot, S99 不会执行;
#   第二次启动 S98 先挂好 /opt, S99 再把 payload 解到 /opt/open-box。
#   若顺序反了, firstboot 会把 200MB 解到 rootfs 的 /opt, 随后被分区挂载盖住,
#   且它会写 installed 标记并删掉 payload —— Open-Box 就永久丢了。
OPT_SRC="$GITHUB_WORKSPACE/target-patch/zero2/zero2-opt.init"
INITD="$RK_DIR/armv8/base-files/etc/init.d"
RCD="$RK_DIR/armv8/base-files/etc/rc.d"
if [ -f "$OPT_SRC" ]; then
	mkdir -p "$INITD" "$RCD"
	cp -f "$OPT_SRC" "$INITD/zero2-opt"
	chmod +x "$INITD/zero2-opt"
	ln -sf ../init.d/zero2-opt "$RCD/S98zero2-opt"
	echo "[4] /opt partition init.d installed (S98, before open-box-firstboot)"
else
	echo "[4] WARN: $OPT_SRC not found, /opt will stay on rootfs"
fi

echo "===== Inject done ====="
