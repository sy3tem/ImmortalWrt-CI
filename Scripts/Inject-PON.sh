#!/bin/bash
# SPDX-License-Identifier: MIT
# PON 系列的几个小修：
#   1) /sbin/tempinfo —— LuCI 概览的「温度」行来自它，上游没装这个文件
#   2) luci-app-pon 的 hardware 页 —— ri/bosa 卷读不到内容时前端空值崩溃
#   3) airoha-xpon 模块参数 xgpon_stock_bwmap=1 —— 联通 XG-PON 卡 O2-O3 的修复
#   4) /etc/config/pon 默认 OMCC 版本 0x86 —— 同上，界面「兼容性」项
#   5) uci-defaults 兜底 —— 升级保留配置时也把 omcc_version 拉回 0x86
#
# Called from Scripts/Settings.sh with CWD = source tree root.

echo "===== Inject PON extras ====="

# ---- 1) /sbin/tempinfo ----
install -D -m 755 "$GITHUB_WORKSPACE/target-patch/pon/files/sbin/tempinfo" \
	./package/base-files/files/sbin/tempinfo
echo "[1] /sbin/tempinfo installed (overview temperature: CPU + PON)"

# ---- 1b) rpcd ACL：允许 luci.getTempInfo / getCPUInfo ----
# 光有 /sbin/tempinfo 也不显示：LuCI 概览通过 ubus 调 luci.getTempInfo，而
# /usr/share/rpcd/acl.d/luci-mod-status*.json 里的白名单没有 getTempInfo /
# getCPUInfo，rpcd 直接回 -32002 Access denied，前端拿不到值就不渲染那两行。
# 这里补一份独立 ACL（root 的 login 段是 list read '*'，会自动并入）。
install -D -m 644 "$GITHUB_WORKSPACE/target-patch/pon/files/usr/share/rpcd/acl.d/90-luci-tempinfo.json" \
	./package/base-files/files/usr/share/rpcd/acl.d/90-luci-tempinfo.json
echo "[1b] rpcd ACL installed (luci.getTempInfo / getCPUInfo)"

# ---- 2) luci-app-pon hardware.js 空值兜底 ----
# /usr/libexec/pon-board-identity read <target> <field> 在没有数据时（例如 ri/bosa
# 卷被重建 UBI 清空）返回空且 rc=0；LuCI 的 fs.exec 这时不带 stdout 字段，
# 前端的 result.stdout.trim() 就抛 "Cannot read properties of undefined"，
# 整个「硬件身份」页白屏。改成空串兜底，页面能开、字段留空。
HW=$(find ./feeds -path '*luci-app-pon/htdocs/luci-static/resources/view/pon/hardware.js' 2>/dev/null | head -n 1)
if [ -n "$HW" ] && [ -f "$HW" ]; then
	sed -i "s/result\.stdout\.trim()/(result.stdout || '').trim()/g" "$HW"
	if grep -q "(result.stdout || '')" "$HW"; then
		echo "[2] hardware.js patched: $HW"
	else
		echo "::warning::hardware.js 里没找到 result.stdout.trim()，上游可能改了写法"
	fi
else
	echo "::warning::没找到 luci-app-pon 的 hardware.js，跳过"
fi

# ---- 3) airoha-xpon 模块参数：xgpon_stock_bwmap=1 ----
# 联通 XG-PON 线路下默认 bwmap 会让 ONU 停在 O2-O3 注册不上；论坛的临时办法
# 是手改 /etc/modules.d/airoha-xpon。这里在编译期把参数写进 kmod 包的
# MODPARAMS，生成的 modules.d 首启就是 "airoha-xpon xgpon_stock_bwmap=1"，
# 无需刷机后再改文件（sysupgrade 时该文件也会被新包覆盖成带参数版本）。
XPON_MK=$(find ./feeds -path '*airoha-xpon/Makefile' 2>/dev/null | head -n 1)
if [ -n "$XPON_MK" ] && [ -f "$XPON_MK" ]; then
	if grep -q '^MODPARAMS\.airoha-xpon' "$XPON_MK"; then
		echo "[3] MODPARAMS already present: $XPON_MK"
	else
		sed -i '/^define KernelPackage\/airoha-xpon$/i MODPARAMS.airoha-xpon:=xgpon_stock_bwmap=1' "$XPON_MK"
		if grep -q '^MODPARAMS\.airoha-xpon:=xgpon_stock_bwmap=1$' "$XPON_MK"; then
			echo "[3] airoha-xpon MODPARAMS added (xgpon_stock_bwmap=1)"
		else
			echo "::warning::airoha-xpon Makefile 注入失败，上游可能改了结构"
		fi
	fi
else
	echo "::warning::没找到 airoha-xpon 的 Makefile，跳过模块参数注入"
fi

# ---- 4) /etc/config/pon 默认 OMCC 版本 0x86 ----
# 界面「PON - 配置 - 兼容性 - OMCC 版本」= config omci '<line>_omci' 的
# option omcc_version，上游默认 0xb0；联通实测要 0x86。
PONCFG=$(find ./feeds -path '*airoha-ponctl/files/pon.config' 2>/dev/null | head -n 1)
if [ -n "$PONCFG" ] && [ -f "$PONCFG" ]; then
	sed -i "s/^\([[:space:]]*\)option omcc_version .*/\1option omcc_version '0x86'/" "$PONCFG"
	if grep -q "option omcc_version '0x86'" "$PONCFG"; then
		echo "[4] pon.config omcc_version -> 0x86"
	else
		echo "::warning::pon.config 里没找到 omcc_version，上游可能改了键名"
	fi
else
	echo "::warning::没找到 airoha-ponctl/files/pon.config，跳过默认 OMCC 版本"
fi

# ---- 5) 运行期兜底：sysupgrade 保留旧配置时也把 omcc_version 拉回 0x86 ----
# 遍历所有 config omci 段（section 名不写死），避免只改到第一个。
install -d -m 755 ./package/base-files/files/etc/uci-defaults
cat > ./package/base-files/files/etc/uci-defaults/99-pon-omcc <<'EOS'
#!/bin/sh
[ -f /etc/config/pon ] || exit 0
for s in $(uci -q show pon | sed -n 's/^pon\.\([^.=]*\)=omci$/\1/p'); do
	uci -q set "pon.$s.omcc_version='0x86'"
done
uci -q commit pon
exit 0
EOS
chmod 755 ./package/base-files/files/etc/uci-defaults/99-pon-omcc
echo "[5] uci-defaults 99-pon-omcc installed"

echo "===== Inject PON extras done ====="
