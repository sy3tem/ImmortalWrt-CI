#!/bin/bash
# SPDX-License-Identifier: MIT
# Inject the armsr/armv8 (UEFI VM) support into the ImmortalWrt source tree.
#
# Called from Scripts/Settings.sh with CWD = the cloned source tree root.
#
# What it does
#   1. copies target-patch/armsr/files/** into package/base-files/files
#      (nic autoconfig, growroot, netfallback, VM defaults)
#   2. removes the "pgrep quickstart" gate from luci-app-quickstart so the
#      dashboard is reachable without the iStoreOS quickstart daemon
#   3. makes sure the growroot / netfallback init scripts are executable
#
# Nothing here touches other targets: Settings.sh only calls this for *ARMSR*.

set -e

TREE="${GITHUB_WORKSPACE}/wrt"
SRC="${GITHUB_WORKSPACE}/target-patch/armsr/files"

echo "===== Inject armsr / UEFI VM support ====="

if [ ! -d "$SRC" ]; then
	echo "ERROR: $SRC not found"
	exit 1
fi

DEST="$TREE/package/base-files/files"
mkdir -p "$DEST"
cp -a "$SRC/." "$DEST/"
find "$DEST/etc/uci-defaults" -type f -exec chmod 0755 {} \; 2>/dev/null || true
chmod 0755 "$DEST/etc/init.d/growroot" "$DEST/etc/init.d/netfallback" 2>/dev/null || true
echo "overlay installed into package/base-files/files:"
( cd "$SRC" && find . -type f | sort | sed 's/^/   /' )

# ---- quickstart: let the dashboard render without the iStoreOS daemon ------
QS="$TREE/package/luci-app-quickstart/luasrc/controller/quickstart.lua"
if [ -f "$QS" ]; then
	sed -i 's/if luci\.sys\.call("pgrep quickstart [^"]*") == 0 then/if true then/' "$QS"
	# the daemon-backed auto_setup/taskd endpoints stay dormant without taskd;
	# guard them so a missing /etc/init.d/tasks cannot break the page
	# 替换后必须是 cmd = "true "，不能带 ".." —— 原句形如
	#   cmd = "/etc/init.d/tasks task_add auto_setup " .. luci.util.shellquote(cmd)
	# 这里只替换左边的字符串字面量，右边的 ".." 要原样保留。以前写成
	#   ...|cmd = "true " ..|  会留下两个相邻的连接符：
	#   cmd = "true " .. .. luci.util.shellquote(cmd)
	# Lua 解析失败：quickstart.lua:136: unexpected symbol near '..'，进而让
	# LuCI 整个打不开（HTTP 500 Unhandled exception during request dispatching）。
	sed -i 's|cmd = "/etc/init.d/tasks task_add auto_setup "|cmd = "true "|' "$QS" 2>/dev/null || true
	echo "quickstart: daemon gate removed"
else
	echo "quickstart: package not present, skipped"
fi

# ---- 让虚拟机图形控制台有输出 ----------------------------------------------
# 默认内核配置（target/linux/generic/config-6.18）里 "# CONFIG_VT is not set"，
# 而 armsr 又设了 CONFIG_FRAMEBUFFER_CONSOLE=y —— 两者矛盾，VT 关闭时 fbcon 无法
# 工作，内核日志和 login 只能走串口 ttyAMA0，虚拟机的图形控制台因此一片黑。
# 这里在 armsr 的 target 配置中显式开 VT + VT_CONSOLE + VT_HW_CONSOLE_BINDING，
# 配合 Config/ARMSR-UEFI.txt 的 CONFIG_GRUB_BOOTOPTS="console=tty0"，
# 内核日志与登录提示才能显示在虚拟显示器（fnOS/KVM/Proxmox）上。
#
# 关键坑：OpenWrt 的 Kernel/Configure 只把 generic + target 配置做 kconfig.pl 合并，
# 不跑 oldconfig；随后内核自己的 syncconfig 一旦遇到“新符号”（依赖刚被打开、而
# generic 配置里从没出现过的符号）就会进入交互式 Restart config，CI 无 tty 直接
# Error 1。开 VT 会连带给 INPUT 子树带出新的可见符号，所以必须像 x86 的
# config-6.18 那样，把依赖符号一并写死，做到“零新符号”。
# （首次失败即 syncconfig 在 CONSOLE_TRANSLATIONS (NEW) 处中断。）
KCFG="$TREE/target/linux/armsr/config-6.18"
if [ -f "$KCFG" ]; then
	for opt in \
		CONFIG_INPUT=y \
		CONFIG_INPUT_VIVALDIFMAP=y \
		CONFIG_VT=y \
		CONFIG_VT_CONSOLE=y \
		CONFIG_VT_HW_CONSOLE_BINDING=y \
		CONFIG_CONSOLE_TRANSLATIONS=y
	do
		key="${opt%%=*}"
		if grep -q "^${key}=" "$KCFG"; then
			sed -i "s|^${key}=.*|${opt}|" "$KCFG"
		elif grep -q "^# ${key} is not set" "$KCFG"; then
			sed -i "s|^# ${key} is not set|${opt}|" "$KCFG"
		else
			echo "$opt" >> "$KCFG"
		fi
	done
	echo "armsr: enabled VT/VT_CONSOLE + deps in kernel config (framebuffer console for VM display)"
else
	echo "armsr: target config-6.18 not found, skipped VT patch"
fi

# ---- 兜底：让内核配置解析不再交互 ------------------------------------------
# OpenWrt 的 Kernel/Configure 只把 generic + target 配置做 kconfig.pl 合并，
# 不跑 oldconfig；内核自己的 syncconfig 一旦遇到「新符号」就进入交互式
# Restart config，CI 没有 tty，于是一句
#   Enable character translations in console (CONSOLE_TRANSLATIONS) [Y/n/?] (NEW)
# 之后直接 make[8]: *** syncconfig Error 1。
# 上面的符号清单已经把 VT 需要的依赖补齐（对齐 x86 的 config-6.18），这里再加
# 一层 olddefconfig 兜底：任何残留的新符号取默认值，并把 vermagic 按最终
# .config 重新算一遍，保证内核与模块的 vermagic 一致。
KDF="$TREE/include/kernel-defaults.mk"
if [ -f "$KDF" ] && ! grep -q 'CI_OLDDEFCONFIG_NET' "$KDF"; then
	python3 - "$KDF" <<'PY'
import sys

path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    src = f.read()

anchor = ("\tgrep '=[ym]' $(LINUX_DIR)/.config.set | LC_ALL=C sort | "
          "$(MKHASH) md5 > $(LINUX_DIR)/.vermagic")

ins = (
    "\t# CI_OLDDEFCONFIG_NET: OpenWrt 只合并配置不跑 oldconfig，内核 syncconfig\n"
    "\t# 遇到新符号会交互式提示（CI 无 tty -> Error 1）。olddefconfig 兜底，\n"
    "\t# 并把 vermagic 按最终 .config 重算，避免内核/模块 vermagic 不一致。\n"
    "\t$(KERNEL_MAKE) olddefconfig >/dev/null 2>&1 || true\n"
    "\tgrep '=[ym]' $(LINUX_DIR)/.config | LC_ALL=C sort | "
    "$(MKHASH) md5 > $(LINUX_DIR)/.vermagic\n"
)

if anchor in src:
    src = src.replace(anchor, ins, 1)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(src)
    print("armsr: kernel-defaults.mk -> olddefconfig safety net installed")
else:
    print("armsr: kernel-defaults.mk anchor NOT found, safety net skipped")
PY
else
	echo "armsr: kernel-defaults.mk safety net already present or file missing"
fi

# ---- fix: official master armsr image Makefile still references the dropped
#   kmod-thunderx-net (Cavium ThunderX NIC driver). The package no longer exists
#   in current master (netdevices.mk), but image/Makefile forces it into
#   DEVICE_PACKAGES via $(if $(CONFIG_aarch64),kmod-thunderx-net). That makes
#   every aarch64 armsr image fail at the target-dir stage with
#   "kmod-thunderx-net (no such package)". A VM image (fnOS/KVM/QEMU) never
#   needs this physical NIC driver, so just drop the reference.
IMG_MK="$TREE/target/linux/armsr/image/Makefile"
if [ -f "$IMG_MK" ]; then
	if grep -q 'kmod-thunderx-net' "$IMG_MK"; then
		sed -i 's/ $(if $(CONFIG_aarch64),kmod-thunderx-net)//g' "$IMG_MK"
		echo "armsr: dropped stale kmod-thunderx-net ref (official master bug)"
	else
		echo "armsr: kmod-thunderx-net ref not present, skipped"
	fi
else
	echo "armsr: image/Makefile not found, skipped"
fi

# ---- only emit the bootable VM disk image (combined-efi); drop the
#   non-bootable rootfs.img(.gz). For a VM (fnOS / KVM / QEMU) only the
#   combined-efi image (GPT + EFI + squashfs rootfs) is needed; rootfs.img
#   has no bootloader / partition table and just clutters the release.
IMG_MK2="$TREE/target/linux/armsr/image/Makefile"
if [ -f "$IMG_MK2" ]; then
	if grep -q 'IMAGES-y := rootfs.img.gz' "$IMG_MK2"; then
		sed -i 's/IMAGES-y := rootfs.img.gz/IMAGES-y := combined-efi.img.gz/' "$IMG_MK2"
		sed -i 's/IMAGES-y := rootfs.img/IMAGES-y := combined-efi.img/' "$IMG_MK2"
		echo "armsr: IMAGES-y restricted to combined-efi only (VM image)"
	else
		echo "armsr: IMAGES-y already patched, skipped"
	fi
else
	echo "armsr: image/Makefile not found, skipped"
fi

echo "===== Inject armsr done ====="
