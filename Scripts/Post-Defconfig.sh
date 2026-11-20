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

if [[ "${WRT_CONFIG^^}" != *NOWIFI* ]] && [[ "${WRT_CONFIG^^}" != PON-* ]]; then
	echo "post-defconfig: not a NOWIFI/PON config, nothing to trim"
	exit 0
fi

# ============================================================================
# PonWrt 系列：PON 栈必须在，挂载 / open-box 必须不在
# ----------------------------------------------------------------------------
# 这台设备没有 eMMC：/opt 数据分区、block-mount、open-box 全是别的机型的东西，
# 出现在这里就是配置残留。PON 那四个包反过来是命根子，被 defconfig 静默丢掉的话
# 固件能开机、能进 LuCI，插上光纤才发现不亮 —— 所以在这里就失败，别等 90 分钟。
# ============================================================================
if [[ "${WRT_CONFIG^^}" == PON-* ]]; then
	echo "post-defconfig: PON checks (stack / no-mount / no-open-box)"
	rc=0
	for sym in CONFIG_PACKAGE_kmod-airoha-xpon CONFIG_PACKAGE_airoha-ponctl \
		CONFIG_PACKAGE_airoha-pond CONFIG_PACKAGE_luci-app-pon; do
		if grep -qx "$sym=y" .config; then
			echo "  ok    $sym"
		else
			echo "::error::$sym 被 defconfig 丢了 —— PON 起不来，先查 feeds/依赖再编译"
			rc=1
		fi
	done
	for sym in CONFIG_PACKAGE_open-box CONFIG_PACKAGE_block-mount CONFIG_PACKAGE_automount \
		CONFIG_PACKAGE_mmc-utils CONFIG_PACKAGE_f2fs-tools; do
		if grep -qx "$sym=y" .config; then
			echo "::error::$sym 出现在 PON 配置里 —— 设备没有 eMMC，不该装挂载/面板"
			rc=1
		fi
	done
	if [ "$rc" -ne 0 ]; then
		echo "::error::PON 配置校验失败（见上面每一条）"
		exit 1
	fi
	echo "post-defconfig: PON checks passed"
fi

# ---- 请求了但被 defconfig 静默丢掉的包（"配置残留"的常见来源）--------------
# 只告警不失败：有些包本来就带平台门控（如 nand-utils 需要 NAND_SUPPORT），
# 在别的机型上请求它们属于配置写错，能看见就行。
if [ -f .config ]; then
	GEN="$GITHUB_WORKSPACE/Config/GENERAL.txt"
	if [ -f "$GITHUB_WORKSPACE/Config/GENERAL-${WRT_CONFIG%%-*}.txt" ]; then
		GEN="$GITHUB_WORKSPACE/Config/GENERAL-${WRT_CONFIG%%-*}.txt"
	fi
	miss=""
	for sym in $(sed -n 's/^\(CONFIG_PACKAGE_[^=]*\)=y$/\1/p' \
		"$GEN" "$GITHUB_WORKSPACE/Config/$WRT_CONFIG.txt" 2>/dev/null); do
		grep -qx "$sym=y" .config || miss="$miss $sym"
	done
	if [ -n "$miss" ]; then
		echo "::warning::这些请求被 defconfig 丢掉了（包不存在 / 平台门控 / 与别的包冲突）:$miss"
	fi
fi

if [[ "${WRT_CONFIG^^}" != *NOWIFI* ]]; then
	echo "post-defconfig: PON checks done; not a NOWIFI config, nothing to trim"
	exit 0
fi

echo "post-defconfig: trimming WiFi packages from device package lists"
python3 "$GITHUB_WORKSPACE/Scripts/_trim_wifi.py"
echo "post-defconfig: done"
