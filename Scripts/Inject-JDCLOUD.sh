#!/bin/bash
# SPDX-License-Identifier: MIT
# Inject JDCloud (亚瑟 RE-SS-01 / 雅典娜 RE-CS-02) tweaks into an ImmortalWrt tree.
#
# 1) 把 eMMC 上那块 ~110 GiB 的 ext4 数据分区在首次开机时挂到 /opt（R28S 同款做法）。
# 2) 给两台机器补一个 factory.bin，用于 U-Boot 直接刷入。
#    写法逐字抄自 VIKINGYFY/immortalwrt 的 ipq60xx.mk（他的 factory 在亚瑟/雅典娜上
#    实测能刷）：kernel 补齐到 KERNEL_SIZE(6144k) → 接 rootfs → append-metadata。
#    注意没有 pad-rootfs —— 上游那行就没有，别自作主张加。
#
# Called from Scripts/Settings.sh with CWD = source tree root.
set -e

PATCH_DIR="$GITHUB_WORKSPACE/target-patch/jdcloud"
UDIR="./package/base-files/files/etc/uci-defaults"
IMG_MK="./target/linux/qualcommax/image/ipq60xx.mk"

echo "===== Inject JDCloud ====="

# ---- 1) /opt 数据分区 ----
SRC="$PATCH_DIR/opt-partition/99-mount-opt"
if [ -f "$SRC" ]; then
	mkdir -p "$UDIR"
	cp -f "$SRC" "$UDIR/99-mount-opt"
	chmod +x "$UDIR/99-mount-opt"
	echo "[1] /opt uci-defaults installed -> $UDIR/99-mount-opt"
else
	echo "[1] $SRC not found, skip"
fi

# ---- 2) factory.bin（U-Boot 刷入用）----
dev_has_factory() {
	awk -v dev="$1" '
		$0 == "define Device/" dev { inblk = 1 }
		inblk && /IMAGE\/factory\.bin/ { ok = 1 }
		inblk && $0 == "endef" { inblk = 0 }
		END { exit !ok }
	' "$IMG_MK"
}

if [ -f "$IMG_MK" ]; then
	if dev_has_factory jdcloud_re-ss-01 && dev_has_factory jdcloud_re-cs-02; then
		echo "[2] factory.bin already present, skip"
	else
		awk '
			$0 == "define Device/jdcloud_re-ss-01" || $0 == "define Device/jdcloud_re-cs-02" { inblk = 1 }
			{
				if (inblk && $0 == "endef") {
					print "\tIMAGES += factory.bin"
					print "\tIMAGE/factory.bin := append-kernel | pad-to $$(KERNEL_SIZE) | append-rootfs | append-metadata"
					inblk = 0
				}
				print
			}
		' "$IMG_MK" > "$IMG_MK.new"
		mv -f "$IMG_MK.new" "$IMG_MK"
		echo "[2] factory.bin added to jdcloud_re-ss-01 / jdcloud_re-cs-02"
	fi
	for dev in jdcloud_re-ss-01 jdcloud_re-cs-02; do
		if dev_has_factory "$dev"; then
			echo "[2] $dev: factory.bin OK"
		else
			echo "[2] WARN: $dev 没有拿到 factory.bin"
		fi
	done
else
	echo "[2] $IMG_MK not found, skip"
fi

echo "===== Inject JDCloud done ====="
