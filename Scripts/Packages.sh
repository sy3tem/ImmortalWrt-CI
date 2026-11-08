#!/bin/bash
# SPDX-License-Identifier: MIT
# ImmortalWrt unified build — third-party package post-processing.
#
# Almost everything lives in the OFFICIAL immortalwrt/packages + immortalwrt/luci
# feeds already, so no vendoring is needed. This script only:
#   - patches the few packages that need a nudge to build cleanly
#   - pulls the one genuinely external package left:
#       · athena-led (RE-CS-02 点阵屏)             -> unraveloop/JDC-AX6600-Athena-LED-Controller
#
# OpenClash / iStore are intentionally NOT built any more (see Config/GENERAL.txt),
# so neither luci-app-openclash nor linkease/istore is fetched or patched here.
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

# ---- NOTE: no proxy stack at all --------------------------------------------
# passwall + xray-core was dropped earlier, then luci-app-openclash went too.
# Nothing to vendor, patch, or extract for a proxy now — keep it that way.

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

# ---- open-box：闭源预编译包，固件里带 tar、首启解到 /opt --------------------
# 上游只发 aarch64 发布包；本仓库现在只剩 ARM 实机，架构正好对上。
# 包本体在 target-patch/openbox/：Makefile 负责下载并校验发布包，
# /etc/init.d/open-box-firstboot 负责首次开机解到 /opt/open-box（R28S/RT28 的
# /opt 是开机挂载的分区，镜像里没法直接铺）。
if [ -d "$GITHUB_WORKSPACE/target-patch/openbox" ]; then
	rm -rf "$PKG_PATH/open-box"
	cp -rf "$GITHUB_WORKSPACE/target-patch/openbox" "$PKG_PATH/open-box"
	echo "open-box package injected (payload shipped in image, unpacked on first boot)"
fi

# ---- luci-app-quickstart：不装 ---------------------------------------------
# 它只是一个纯前端 SPA，所有接口都靠 iStoreOS 的 Go 守护进程；为了「网络向导」
# 能保存而把守护进程整套塞进固件，体积和依赖都不划算，现已整体移除。
# 旁路由配置请用 /usr/sbin/bypass-router 或原生「网络 → 接口」。

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

	# 出厂默认就开屏：包里 /etc/config/athena_led 写的是 enabled '0'
	# （VIKINGYFY 用的是另一份包，他那边默认就是 enable '1'）。
	# 这里把默认值改成 1，配合首启的 99-athena-led（负责 enable 出 S99 链接）双保险：
	# 就算 uci-defaults 没跑到，配置本身也是开的。
	if [ -f "$PKG_PATH/athena-led/files/athena_led.config" ]; then
		sed -i "s/^\([[:space:]]*option[[:space:]]\+enabled[[:space:]]*\)'0'/\1'1'/" \
			"$PKG_PATH/athena-led/files/athena_led.config"
		grep -q "option enabled '1'" "$PKG_PATH/athena-led/files/athena_led.config" \
			&& echo "athena_led default enabled -> 1" \
			|| echo "WARN: athena_led default enabled 没改成功"
	fi
fi

cd "$PKG_PATH"
echo "===== Custom Packages done ====="
