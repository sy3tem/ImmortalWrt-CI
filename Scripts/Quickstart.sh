#!/bin/bash
# SPDX-License-Identifier: MIT
# 把 iStoreOS 的 quickstart 守护进程 + 官方 LuCI 前端移植进 armsr 固件。
#
# 为什么要移植
#   固件里的 luci-app-quickstart 只是前端（Vue SPA）。首页卡片、网络向导、
#   终端/磁盘/端口管理这些功能全部走相对根路径的 HTTP 接口：
#       POST /guide/gateway-router/    保存旁路由
#       GET  /u/network/status/        首页状态卡片
#       GET  /network/port/list/       端口列表
#   这些接口由 iStoreOS 自己的 Go 守护进程提供。没有守护进程时请求落到
#   uhttpd，返回 500 connect failed —— 用户点「保存配置」看到的就是这个。
#
# 为什么取官方 ipk 而不是自己编
#   上游 istoreos/quickstart 是纯 Go（CGO_ENABLED=0，静态 ELF），自己编也行，
#   但它要 iStoreOS 的 feeds（taskd / istore / bandix 的 ubus 对象）和一堆
#   交叉编译细节；官方已经提供 aarch64_generic 现成包，ABI 与 armsr/armv8
#   一致（同为 aarch64 静态 ELF），直接取用最可靠。版本与 sha256 全部锁定，
#   升级只需改下面的常量。
#
#   注：quickstart-netpolicy（eBPF 限速引擎）暂不引入 —— 它需要内核 BPF
#   相关选项，缺失只会让「设备限速」不可用，不影响向导/状态/磁盘等功能。
#
# 落盘位置
#   两个 data.tar.gz 直接解到 package/base-files/files（rootfs overlay），
#   不走 opkg/apk 数据库 —— 文件实际存在即可，包名不参与依赖求解。
#   守护进程的运行时依赖在 Config/ARMSR-UEFI.txt 里显式打开。
#
# 与 uhttpd 的关系
#   守护进程监听 127.0.0.1:3038（unix socket 另有一份给内部 CLI 用）。
#   浏览器访问的是 80 端口的 uhttpd，所以还需要 proxy_prefix 把 /guide /u
#   /nas 等前缀反代到 3038 —— 补丁在 Scripts/Inject-ARMSR.sh 里注入。

set -e

TREE="${GITHUB_WORKSPACE}/wrt"
DEST="$TREE/package/base-files/files"
CACHE="$TREE/.quickstart-cache"

QS_BASE="https://fw.koolcenter.com/iStoreOS/alpha/quickstart/1023-homepage/arm64/ipk"

QS_PKG="quickstart_0.17.0-test20261022-r1_aarch64_generic.ipk"
QS_SHA="e45612baeec5e0cc6c1ffc5fc737460d4f53d446595124577ae30bdf5910a745"

UI_PKG="luci-app-quickstart_0.17.0-test20261022-r1_all.ipk"
UI_SHA="d6ef4d0c9a77c9f562e1ff4682f07fda225f7516ae44bacc93f1e1f04ceaf209"

# 结果通过全局变量 FETCH_OUT 返回，不用 $(...) —— 函数里的提示信息一旦写进
# stdout，就会被命令替换一起捕获，返回值变成 "提示\n路径"，后面的 tar 拿着这
# 串东西当文件名，报 "tar (child): ...: Cannot open: No such file or directory"。
# （曾经因为这个把整次构建拖到 install 阶段才失败。）
FETCH_OUT=""
fetch() {
	local name="$1" sha="$2" out got
	out="$CACHE/$name"
	FETCH_OUT=""

	if [ ! -s "$out" ] || [ "$(sha256sum "$out" | cut -d' ' -f1)" != "$sha" ]; then
		printf 'quickstart: downloading %s\n' "$name" >&2
		if ! curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 20 -o "$out" "$QS_BASE/$name"; then
			printf 'ERROR: download failed: %s/%s\n' "$QS_BASE" "$name" >&2
			exit 1
		fi
	fi

	got="$(sha256sum "$out" | cut -d' ' -f1)"
	if [ "$got" != "$sha" ]; then
		printf 'ERROR: sha256 mismatch for %s\n  want %s\n  got  %s\n' "$name" "$sha" "$got" >&2
		exit 1
	fi
	FETCH_OUT="$out"
}

unpack() {
	local ipk="$1" tmp="$CACHE/unpack"

	if [ ! -s "$ipk" ]; then
		echo "ERROR: ipk not found: $ipk" >&2
		exit 1
	fi

	rm -rf "$tmp"
	mkdir -p "$tmp"

	# ipk 外层本身是 tar.gz（deb 风格三层），先取 data.tar.gz
	if ! tar xzf "$ipk" -C "$tmp"; then
		echo "ERROR: cannot unpack ipk: $ipk" >&2
		exit 1
	fi
	if [ ! -f "$tmp/data.tar.gz" ]; then
		echo "ERROR: $ipk has no data.tar.gz" >&2
		exit 1
	fi

	if ! tar xzf "$tmp/data.tar.gz" -C "$DEST"; then
		echo "ERROR: cannot extract data.tar.gz of $ipk" >&2
		exit 1
	fi
}

mkdir -p "$CACHE" "$DEST"

echo "===== quickstart daemon + official LuCI frontend ====="

fetch "$QS_PKG" "$QS_SHA"
QS_IPK="$FETCH_OUT"
fetch "$UI_PKG" "$UI_SHA"
UI_IPK="$FETCH_OUT"

unpack "$QS_IPK"
unpack "$UI_IPK"

# tar 已保留权限，这里再兜一次底（CI 上 umask / 解包工具差异）
chmod 0755 "$DEST/usr/sbin/quickstart" \
	"$DEST/etc/init.d/quickstart" \
	"$DEST/etc/init.d/startdhns" \
	"$DEST/etc/uci-defaults/09-quickstart" \
	"$DEST/usr/libexec/quickstart/dhcpvalid.sh" \
	"$DEST/usr/libexec/quickstart/auto_setup.sh" 2>/dev/null || true

# ipk 里 /etc/config/quickstart 是 0600，uci 读没问题，但和 OpenWrt 里其它
# uci 配置（0644）不一致，统一一下，避免 package 检查时被当成异常
chmod 0644 "$DEST/etc/config/quickstart" 2>/dev/null || true

echo "quickstart: installed files"
( cd "$DEST" && find usr/sbin/quickstart etc/init.d/quickstart etc/config/quickstart \
	www/luci-static/quickstart usr/lib/lua/luci/controller/quickstart.lua \
	-type f 2>/dev/null | sort | sed 's/^/   /' )

if [ ! -x "$DEST/usr/sbin/quickstart" ]; then
	echo "ERROR: quickstart binary missing after unpack"
	exit 1
fi
