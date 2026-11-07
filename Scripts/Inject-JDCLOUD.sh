#!/bin/bash
# SPDX-License-Identifier: MIT
# Inject JDCloud (亚瑟 RE-SS-01 / 雅典娜 RE-CS-02) tweaks into an ImmortalWrt tree.
#
# 只做一件事：把 eMMC 上那块 ~110 GiB 的 ext4 数据分区在首次开机时挂到 /opt，
# 做法和 R28S 的 target-patch/r28s/opt-partition 一致。
#
# 不加这个的话，官方 fstab 里没有这块分区，block-mount 的 automount 会把它挂到
# /mnt/mmcblk0p19，而 /opt 一直留在 1.9 GiB 的 overlay 上 —— open-box(174M)、
# docker 数据全挤在 overlay 里。
#
# Called from Scripts/Settings.sh with CWD = source tree root.
set -e

PATCH_DIR="$GITHUB_WORKSPACE/target-patch/jdcloud"
UDIR="./package/base-files/files/etc/uci-defaults"

echo "===== Inject JDCloud /opt partition ====="

SRC="$PATCH_DIR/opt-partition/99-mount-opt"
if [ -f "$SRC" ]; then
	mkdir -p "$UDIR"
	cp -f "$SRC" "$UDIR/99-mount-opt"
	chmod +x "$UDIR/99-mount-opt"
	echo "[1] /opt uci-defaults installed -> $UDIR/99-mount-opt"
else
	echo "[1] $SRC not found, skip"
fi

echo "===== Inject JDCloud done ====="
