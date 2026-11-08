#!/bin/bash
# SPDX-License-Identifier: MIT
# 复用 runner 自带的主机工具链，别让构建现场去编（思路来自 VIKINGYFY/OpenWRT-CI 的
# .github/scripts/prepare-build-host.sh）。
#
# 三件事，都只影响「主机工具链」，不动固件内容：
#   1) BPF：CONFIG_BPF_TOOLCHAIN_HOST + runner 的 LLVM，不编 llvm-bpf（省 20–40 分钟）
#   2) Go ：把 CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT 指到 runner 的 GOROOT（省 10–15 分钟）
#   3) host python：把 --enable-optimizations 改成 --disable-optimizations（PGO 很慢，固件用不上）
#
# 任何一步做不了都只警告、不中断：最坏就是退回原来的「自己编」。
# Called from WRT-CORE "Custom Settings", CWD = source tree root, after feeds install,
# BEFORE `make defconfig`.

set -uo pipefail

say() { echo "[host-tools] $*"; }

# ---------------------------------------------------------------------------
# 1) BPF：用 runner 的 clang/llvm，不编 llvm-bpf
# ---------------------------------------------------------------------------
if grep -q 'config BPF_TOOLCHAIN_HOST' toolchain/Config.in 2>/dev/null; then
	LLVM_ROOT=""
	for c in llvm-config llvm-config-20 llvm-config-19 llvm-config-18; do
		if command -v "$c" >/dev/null 2>&1; then
			LLVM_ROOT=$("$c" --prefix 2>/dev/null) && [ -d "$LLVM_ROOT" ] && break
		fi
	done
	[ -n "$LLVM_ROOT" ] || LLVM_ROOT=""

	if [ -n "$LLVM_ROOT" ] && [ -x "$LLVM_ROOT/bin/clang" ]; then
		# 冒烟：真编一段 BPF 目标码，别等 40 分钟后才发现工具链不对
		SMOKE=$(mktemp -d)
		printf 'int wrt_bpf_smoke(void) { return 0; }\n' > "$SMOKE/s.c"
		ok=1
		"$LLVM_ROOT/bin/clang" --target=bpfel -O2 -emit-llvm -c "$SMOKE/s.c" -o "$SMOKE/s.bc" 2>/dev/null || ok=0
		[ "$ok" = 1 ] && "$LLVM_ROOT/bin/opt" -O2 -mtriple=bpfel < "$SMOKE/s.bc" > "$SMOKE/s.opt" 2>/dev/null || ok=0
		[ "$ok" = 1 ] && "$LLVM_ROOT/bin/llc" -march=bpfel -mcpu=v3 -filetype=obj -o "$SMOKE/s.o" < "$SMOKE/s.opt" 2>/dev/null || ok=0
		[ "$ok" = 1 ] && [ -s "$SMOKE/s.o" ] || ok=0
		rm -rf "$SMOKE"

		if [ "$ok" = 1 ]; then
			sed -i '/^CONFIG_BPF_TOOLCHAIN_/d; /^# CONFIG_BPF_TOOLCHAIN_/d' .config
			{
				echo 'CONFIG_BPF_TOOLCHAIN_HOST=y'
				printf 'CONFIG_BPF_TOOLCHAIN_HOST_PATH="%s"\n' "$LLVM_ROOT"
			} >> .config
			say "[1] BPF toolchain = $LLVM_ROOT（不编 llvm-bpf）"
		else
			say "[1] WARN: runner 的 LLVM 编不出 BPF 目标码，保持默认（会自己编 llvm-bpf）"
		fi
	elif [ -n "$LLVM_ROOT" ]; then
		say "[1] WARN: $LLVM_ROOT/bin/clang 不存在，保持默认"
	else
		say "[1] WARN: 没找到 llvm-config，保持默认"
	fi
else
	say "[1] 源码树里没有 BPF_TOOLCHAIN_HOST，跳过"
fi

# ---------------------------------------------------------------------------
# 2) Go：用 runner 的 GOROOT 当 bootstrap，不编 Go
# ---------------------------------------------------------------------------
if grep -rqs 'CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT' feeds/packages/lang/golang/ 2>/dev/null; then
	GO_ROOT=$(go env GOROOT 2>/dev/null || true)
	if [ -n "$GO_ROOT" ] && [ -x "$GO_ROOT/bin/go" ]; then
		sed -i '/^CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT=/d' .config
		printf 'CONFIG_GOLANG_EXTERNAL_BOOTSTRAP_ROOT="%s"\n' "$GO_ROOT" >> .config
		# 上游 openwrt 的 feeds 还有一个 CONFIG_GOLANG_BUILD_BOOTSTRAP 开关；有就一起关掉
		if grep -rqs 'CONFIG_GOLANG_BUILD_BOOTSTRAP' feeds/packages/lang/golang/ 2>/dev/null; then
			echo '# CONFIG_GOLANG_BUILD_BOOTSTRAP is not set' >> .config
		fi
		say "[2] Go bootstrap = $GO_ROOT"
	else
		say "[2] WARN: runner 没有可用的 go，保持默认（会自己编 bootstrap）"
	fi
else
	say "[2] feeds 里没有 GOLANG_EXTERNAL_BOOTSTRAP_ROOT，跳过"
fi

# ---------------------------------------------------------------------------
# 3) host python：关掉 PGO
# ---------------------------------------------------------------------------
PY_MK=feeds/packages/lang/python/python3/Makefile
if [ -f "$PY_MK" ]; then
	# 只改 HOST_CONFIGURE_ARGS 那一段，target 的 --enable-optimizations 保持原样
	sed -i '/^HOST_CONFIGURE_ARGS[[:space:]]*+=/,/^$/ s/--enable-optimizations/--disable-optimizations/' "$PY_MK"
	if awk '/^HOST_CONFIGURE_ARGS/{f=1} f{print} f && /^$/{exit}' "$PY_MK" | grep -q -- '--disable-optimizations'; then
		say "[3] host python PGO 已关闭"
	else
		say "[3] WARN: 没改到 host python 的 --enable-optimizations（上游写法变了？）"
	fi
else
	say "[3] 没找到 $PY_MK，跳过"
fi

exit 0
