#!/bin/bash
# SPDX-License-Identifier: MIT
# ImmortalWrt unified build — third-party package post-processing.
#
# Almost everything lives in the OFFICIAL immortalwrt/packages + immortalwrt/luci
# feeds already, so no vendoring is needed. This script only:
#   - patches the few packages that need a nudge to build cleanly
#   - pulls the two genuinely external packages:
#       · iStore   (luci-app-store + its 3 deps)  -> linkease/istore
#       · athena-led (RE-CS-02 点阵屏)             -> unraveloop/JDC-AX6600-Athena-LED-Controller
#
# CONVENTION: this script runs with CWD = <tree>/package  (like the upstream CI),
# so "./" is the package directory and "$GITHUB_WORKSPACE/wrt" is the tree root.

cd "$GITHUB_WORKSPACE/wrt/package" || exit 1
PKG_PATH="$(pwd)/"
TREE_ROOT="$GITHUB_WORKSPACE/wrt"

echo "===== Custom Packages (cwd=$PKG_PATH) ====="

# ---- homeproxy: refresh the bundled rule data -------------------------------
HP_PATH=$(find "$TREE_ROOT/feeds" "$TREE_ROOT/package" -maxdepth 6 -type d -wholename "*homeproxy/root/etc/homeproxy" 2>/dev/null | head -1)
if [ -n "$HP_PATH" ]; then
	echo " "
	HP_RULE="surge"
	rm -rf "$TREE_ROOT/$HP_RULE"
	git clone -q --depth=1 --single-branch --branch "release" \
		"https://github.com/Loyalsoldier/surge-rules.git" "$TREE_ROOT/$HP_RULE/"
	cd "$TREE_ROOT/$HP_RULE/"
	RES_VER=$(git log -1 --pretty=format:'%s' | grep -o "[0-9]*")
	echo "$RES_VER" | tee china_ip4.ver china_ip6.ver china_list.ver gfw_list.ver
	awk -F, '/^IP-CIDR,/{print $2 > "china_ip4.txt"} /^IP-CIDR6,/{print $2 > "china_ip6.txt"}' cncidr.txt
	sed 's/^\.//g' direct.txt > china_list.txt ; sed 's/^\.//g' gfw.txt > gfw_list.txt
	rm -rf "$HP_PATH/resources"/* 2>/dev/null
	mv -f ./{china_*,gfw_list}.{ver,txt} "$HP_PATH/resources/" 2>/dev/null
	cd "$PKG_PATH" && rm -rf "$TREE_ROOT/$HP_RULE"
	echo "homeproxy rule data updated!"
fi

# ---- passwall: drop the lyaml dependency (not in the official feeds) --------
PW_FILE="$PKG_PATH/luci-app-passwall/Makefile"
if [ -f "$PW_FILE" ]; then
	echo " "
	sed -i 's/ +lyaml//g' "$PW_FILE"
	echo "passwall lyaml dependency removed!"
fi

# ---- rust: disable ci-llvm (avoids the llvm-bpf host toolchain) -------------
RUST_FILE=$(find "$TREE_ROOT/feeds/packages/" -maxdepth 3 -type f -wholename "*/rust/Makefile" 2>/dev/null | head -1)
if [ -n "$RUST_FILE" ] && [ -f "$RUST_FILE" ]; then
	echo " "
	sed -i 's/ci-llvm=true/ci-llvm=false/g' "$RUST_FILE"
	echo "rust ci-llvm disabled!"
fi

# ---- rtp2httpd: make sure the versioned Makefile is the active one ----------
for D in rtp2httpd luci-app-rtp2httpd; do
	for BASE in "$PKG_PATH" "$TREE_ROOT/feeds/packages/net" "$TREE_ROOT/feeds/luci/applications"; do
		[ -f "$BASE/$D/Makefile.versioned" ] && mv -f "$BASE/$D/Makefile.versioned" "$BASE/$D/Makefile" && echo "$D Makefile.versioned applied!"
	done
done

# ---- iStore 应用商店 — external (linkease/istore), always -------------------
# 官方 feeds 都没有这 4 个包, 必须从 linkease/istore 现场提取, 否则依赖不满足
# 会被 defconfig 静默丢弃 (CONFIG_PACKAGE_luci-app-store 变成"配置残留")。
# 依赖链: luci-app-store -> luci-lib-taskd -> luci-lib-xterm + taskd(二进制后端)
# 其余 curl/tar/mount-utils/script-utils(=util-linux) 官方源都有。
if [ ! -d "$PKG_PATH/luci-app-store" ]; then
	echo " "
	git clone -q --depth=1 --single-branch --branch "main" \
		"https://github.com/linkease/istore.git" "$TREE_ROOT/istore-tmp"
	cp -rf "$TREE_ROOT/istore-tmp/luci/luci-app-store" "$PKG_PATH/"
	cp -rf "$TREE_ROOT/istore-tmp/luci/luci-lib-taskd" "$PKG_PATH/"
	cp -rf "$TREE_ROOT/istore-tmp/luci/luci-lib-xterm" "$PKG_PATH/"
	cp -rf "$TREE_ROOT/istore-tmp/luci/taskd" "$PKG_PATH/"
	rm -rf "$TREE_ROOT/istore-tmp"
	echo "iStore (luci-app-store + luci-lib-taskd + luci-lib-xterm + taskd) extracted!"
fi

# ---- athena-led (雅典娜 RE-CS-02 点阵屏) — external, pinned to v2.4.0 -------
# Two packages: athena-led (core) + luci-app-athena-led (LuCI).
# Device-scoped: only pulled for RE-CS-02 configs.
if [[ "${WRT_CONFIG^^}" == *RE-CS-02* ]] && [ ! -d "$PKG_PATH/athena-led" ]; then
	echo " "
	git clone -q --depth=1 --single-branch --branch "v2.4.0" \
		"https://github.com/unraveloop/JDC-AX6600-Athena-LED-Controller.git" "$TREE_ROOT/athena-tmp"
	cp -rf "$TREE_ROOT/athena-tmp/athena-led" "$PKG_PATH/"
	cp -rf "$TREE_ROOT/athena-tmp/luci-app-athena-led" "$PKG_PATH/"
	rm -rf "$TREE_ROOT/athena-tmp"
	echo "athena-led (v2.4.0) extracted for RE-CS-02!"
fi

cd "$PKG_PATH"
echo "===== Custom Packages done ====="
