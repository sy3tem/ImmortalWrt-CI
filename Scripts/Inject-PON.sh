#!/bin/bash
# SPDX-License-Identifier: MIT
# PON 系列的两个小修：
#   1) /sbin/tempinfo —— LuCI 概览的「温度」行来自它，上游没装这个文件
#   2) luci-app-pon 的 hardware 页 —— ri/bosa 卷读不到内容时前端空值崩溃
#
# Called from Scripts/Settings.sh with CWD = source tree root.

echo "===== Inject PON extras ====="

# ---- 1) /sbin/tempinfo ----
install -D -m 755 "$GITHUB_WORKSPACE/target-patch/pon/files/sbin/tempinfo" \
	./package/base-files/files/sbin/tempinfo
echo "[1] /sbin/tempinfo installed (overview temperature: CPU + PON)"

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

echo "===== Inject PON extras done ====="
