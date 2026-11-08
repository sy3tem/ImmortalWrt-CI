#!/bin/bash
# SPDX-License-Identifier: MIT
# Post-defconfig fixups. Runs AFTER `make defconfig`, with CWD = tree root.
#
# WHY this exists:
#   A device's DEVICE_PACKAGES (from image/*.mk or ipq60xx.mk) are emitted into
#   .config as CONFIG_TARGET_DEVICE_PACKAGES_<target>_DEVICE_<dev>="..." and are
#   FORCE-INSTALLED into the rootfs — setting CONFIG_PACKAGE_<x>=n does NOT
#   remove them. So for the *-NOWIFI* variants that string must be trimmed here,
#   after defconfig has regenerated it.

set -e

# ---- 主机工具链复用：确认没被 defconfig 静默丢掉 ----------------------------
# Scripts/Prepare-Build-Host.sh 在 defconfig 之前往 .config 里塞了这几项；
# 如果源码树不认这些符号，kconfig 会无声丢弃 —— 那就等于白改了，这里喊出来。
if [ -f .config ]; then
	if grep -q '^CONFIG_BPF_TOOLCHAIN_HOST=y' .config; then
		echo "post-defconfig: BPF toolchain = host LLVM（没编 llvm-bpf）"
	elif grep -q 'config BPF_TOOLCHAIN_HOST' toolchain/Config.in 2>/dev/null; then
		echo "::warning::CONFIG_BPF_TOOLCHAIN_HOST 被 defconfig 丢掉了，llvm-bpf 会照常自己编"
	fi

	if grep -q 'CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT=' .config; then
		echo "post-defconfig: Go bootstrap = runner GOROOT"
	elif grep -rqs 'CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT' feeds/packages/lang/golang/ 2>/dev/null; then
		echo "::warning::CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT 被丢掉了，Go bootstrap 会自己编"
	fi

	PY_MK=feeds/packages/lang/python/python3/Makefile
	if [ -f "$PY_MK" ] && ! awk '/^HOST_CONFIGURE_ARGS/{f=1} f{print} f && /^$/{exit}' "$PY_MK" | grep -q -- '--disable-optimizations'; then
		echo "::warning::host python 仍是 --enable-optimizations（PGO 会拖慢构建）"
	fi
fi

if [[ "${WRT_CONFIG^^}" != *NOWIFI* ]]; then
	echo "post-defconfig: not a NOWIFI config, nothing to trim"
	exit 0
fi

echo "post-defconfig: trimming WiFi packages from device package lists"
python3 "$GITHUB_WORKSPACE/Scripts/_trim_wifi.py"
echo "post-defconfig: done"
