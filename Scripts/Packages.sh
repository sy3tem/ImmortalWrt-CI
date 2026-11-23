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

	# ---- 编译前把版本改成上游 latest --------------------------------------
	# 上游发新版会把旧 release 直接删掉，只留最近若干个。写死版本过几周必然 404：
	#   2026-11-09  RK-ALL / QCA-ALL 七个作业全挂在
	#   curl: (22) ... 404  ->  dl/open-box-v0.1.412-linux-arm64.tar.gz  Error 2
	# 这里用 Releases API 取 tag + 该 asset 的 digest，改写 Makefile 里的
	# PKG_VERSION / PKG_HASH；解析不出来就沿用 Makefile 的兜底版本，不阻塞构建。
	ob_mk="$PKG_PATH/open-box/Makefile"
	ob_latest="$(python3 - "$ob_mk" <<'PYEOF' 2>/dev/null
import json, os, sys, urllib.request

api = "https://api.github.com/repos/liandu2024/Open-Box/releases/latest"
req = urllib.request.Request(api, headers={
    "Accept": "application/vnd.github+json",
    "User-Agent": "immortalwrt-ci",
})
tok = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
if tok:
    req.add_header("Authorization", "Bearer " + tok)
rel = json.load(urllib.request.urlopen(req, timeout=30))
tag = (rel.get("tag_name") or "").lstrip("v")
want = "open-box-v%s-linux-arm64.tar.gz" % tag
for a in rel.get("assets", []):
    if a.get("name") == want:
        dg = (a.get("digest") or "").replace("sha256:", "")
        if tag and len(dg) == 64:
            print(tag, dg)
        break
PYEOF
)"
	if [ -n "$ob_latest" ]; then
		set -- $ob_latest
		ob_ver="$1"; ob_sum="$2"
		if [ "$ob_ver" != "$(sed -n 's/^PKG_VERSION:=//p' "$ob_mk")" ]; then
			echo "open-box: 上游最新 v$ob_ver（Makefile 里是 v$(sed -n 's/^PKG_VERSION:=//p' "$ob_mk")），改用最新"
		fi
		sed -i "s|^PKG_VERSION:=.*|PKG_VERSION:=$ob_ver|" "$ob_mk"
		sed -i "s|^PKG_HASH:=.*|PKG_HASH:=$ob_sum|" "$ob_mk"
		echo "open-box pinned to upstream latest v$ob_ver ($ob_sum)"
	else
		echo "::warning::open-box: 解析上游 latest 失败，沿用 Makefile 兜底版本 v$(sed -n 's/^PKG_VERSION:=//p' "$ob_mk")"
	fi
fi

# ---- luci-theme-7dollar（可选第三方主题）------------------------------------
# 默认主题是 argon（官方 feeds 自带）；把某条 workflow 的 WRT_THEME 改成 7dollar
# 就现场 clone 这个主题进 package/。默认配色是蓝色：主题自带的
# /etc/config/7dollar 写的是 palette 'clay'（陶土），这里换成 'mist'（雾蓝），
# uci-defaults 里那份 printf 兜底也一起改，保证首次开机就是蓝色。
if [ "${WRT_THEME:-}" = "7dollar" ] && [ ! -d "$PKG_PATH/luci-theme-7dollar" ]; then
	echo " "
	git clone -q --depth=1 --single-branch --branch main \
		"https://github.com/itsmaiGe/luci-theme-7dollar.git" "$TREE_ROOT/7dollar-tmp"
	cp -rf "$TREE_ROOT/7dollar-tmp" "$PKG_PATH/luci-theme-7dollar"
	rm -rf "$PKG_PATH/luci-theme-7dollar/.git" "$TREE_ROOT/7dollar-tmp"
	for f in "$PKG_PATH/luci-theme-7dollar/root/etc/config/7dollar" \
	         "$PKG_PATH/luci-theme-7dollar/root/etc/uci-defaults/30_luci-theme-7dollar"; do
		[ -f "$f" ] && sed -i "s/palette 'clay'/palette 'mist'/g" "$f"
	done
	# 关掉模板预编译。luci.mk 的 UtMin 会在构建机上用 host ucode 编译 .ut，
	# 而主题的模板里 require('luci.7dollar') 依赖运行时装在
	# /usr/share/ucode/luci/7dollar.uc 的模块，构建机解析不到，直接报
	# "Unable to resolve path for module 'luci.7dollar'"。主题自己已经关掉了
	# CSS/JS 压缩，这里把 UT 一起关掉，模板留源码、运行时再编。
	sed -i '/^LUCI_MINIFY_CSS:=0/a LUCI_MINIFY_UT:=0' "$PKG_PATH/luci-theme-7dollar/Makefile"
	grep -q '^LUCI_MINIFY_UT:=0' "$PKG_PATH/luci-theme-7dollar/Makefile" || \
		echo 'LUCI_MINIFY_UT:=0' >> "$PKG_PATH/luci-theme-7dollar/Makefile"
	echo "luci-theme-7dollar injected (default palette = mist / blue, UT precompile off)"
fi

# ---- luci-app-pon-status：概览页的 PON 光功率/速率卡片 -----------------------
# 来自 naoki66/OpenWrt_ONU_CONFIG（pbs05 pon 用户态的一个超集），只取这一个包：
# 它是 view/status/include/29a_pon.js，状态→概览里自动多一张「光功率 + 端口速率」
# 卡片，没有 xpon 配置时自己隐藏；数据源就是我们的 ponctl --json。
# 同仓里的 luci-app-onu 是整套 ONU 管理界面（internet/iptv/voice），会和
# luci-app-pon 的菜单重叠，需要时再单独加。
if [[ "${WRT_CONFIG^^}" == PON-* ]] && [ ! -d "$PKG_PATH/luci-app-pon-status" ]; then
	echo " "
	git clone -q --depth=1 --single-branch --branch main \
		"https://github.com/naoki66/OpenWrt_ONU_CONFIG.git" "$TREE_ROOT/onuui-tmp"
	if [ -d "$TREE_ROOT/onuui-tmp/luci-app-pon-status" ]; then
		cp -rf "$TREE_ROOT/onuui-tmp/luci-app-pon-status" "$PKG_PATH/"
		echo "luci-app-pon-status injected (optics + port rate card on the overview page)"
	else
		echo "::warning::naoki66 仓库里没找到 luci-app-pon-status"
	fi
	rm -rf "$TREE_ROOT/onuui-tmp"
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
