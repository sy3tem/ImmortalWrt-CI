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

# ---- 3) airoha-xpon BWmap 兼容补丁（AN7583 / 华为 OLT）----
# 现象：XG-PON 在 O2-O3 之间反复重注册（部分华为 OLT 上表现为 O5 后掉线、
#       再回到 O2_3 重新测距）。根因是开源驱动从不写
#       AIROHA_XGPON_DBG_BWM_CHK_CTRL（0x0804），BWmap 校验沿用上电或
#       bootloader 继承值；stock 固件写的是 0x00820000，两边不一致时 OLT 下发
#       的 O2/O3/O4/O9 授权会被判无效（BWM_O2349_NO_PLOAMU_GRANT、
#       BWM_ALLOC_HEC_UNCORRECTABLE 置位），状态机就退回去重试。
#
# 做法：移植 Zywz95/ponwrt-action 的 patch-airoha-xpon.py ——
#   · regs.h   加 AIROHA_XGPON_BWM_CHK_CTRL_STOCK = 0x00820000
#   · xgpon.c  加 bool 模块参数 xgpon_stock_bwmap，并在 MAC reset 释放后
#              写入该寄存器
#   · Makefile MODPARAMS 只在 CONFIG_TARGET_airoha_an7583 时置 1
#              （AN7581 是 GPON，保持继承值，不动）
#
# 关键：这个模块参数必须由补丁定义出来。只往 Makefile 加 MODPARAMS 而不打
# 源码补丁的话，/etc/modules.d/airoha-xpon 里会带上一个内核不认识的参数，
# kmodloader 走 insmod 直接拿 -EINVAL，模块可能根本装不上。
XPON_DIR=$(find ./feeds -maxdepth 3 -type d -name 'airoha-xpon' 2>/dev/null | head -n 1)
if [ -n "$XPON_DIR" ] && [ -f "$XPON_DIR/src/airoha-xpon-xgpon.c" ]; then
	if grep -q 'module_param(xgpon_stock_bwmap' "$XPON_DIR/src/airoha-xpon-xgpon.c"; then
		echo "[3] xgpon_stock_bwmap already present: $XPON_DIR"
	elif python3 "$GITHUB_WORKSPACE/Scripts/patch-airoha-xpon.py" "$XPON_DIR"; then
		echo "[3] airoha-xpon BWmap patch applied: $XPON_DIR"
	else
		echo "::warning::patch-airoha-xpon.py 执行失败，BWmap 继续沿用继承值"
	fi
	if grep -q 'module_param(xgpon_stock_bwmap' "$XPON_DIR/src/airoha-xpon-xgpon.c"; then
		echo "[3] verified: xgpon_stock_bwmap module_param exists"
	else
		echo "::warning::补丁后仍未找到 xgpon_stock_bwmap，参数注入会失败"
	fi
else
	echo "::warning::没找到 airoha-xpon 包目录，跳过 BWmap 补丁"
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

# ---- 6) 首启网络固化：删 wan6 + 建 IPTV 二层桥（pon0.30）----
# 以前这块交给 luci-app-iptv，但那个包只在 LuCI 里做一次性配置，刷完还得
# 手点一遍；而且它的接口名/zone 与 Inject-ITV.sh 那套重叠。现在两条都在
# 首启脚本里定死，包本身也一并去掉了（见 Config/GENERAL-PON.txt）。
install -D -m 755 "$GITHUB_WORKSPACE/target-patch/pon/files/etc/uci-defaults/98-pon-net" \
	./package/base-files/files/etc/uci-defaults/98-pon-net
echo "[6] uci-defaults 98-pon-net installed (wan6 removed, pon0.30 -> br-iptv)"

# ---- 7) PPE / 高并发调优 ----
# bind_rate 在驱动 probe 后会被重置成 0x1e，所以做成 init 服务每次开机重写，
# uci-defaults 只负责挂进 rc.d 并立刻跑一次。
install -D -m 755 "$GITHUB_WORKSPACE/target-patch/pon/files/etc/init.d/pon-perf" \
	./package/base-files/files/etc/init.d/pon-perf
install -D -m 755 "$GITHUB_WORKSPACE/target-patch/pon/files/etc/uci-defaults/98-pon-perf" \
	./package/base-files/files/etc/uci-defaults/98-pon-perf
echo "[7] pon-perf installed (bind_rate=2, conntrack 65536, backlog 8192)"

echo "===== Inject PON extras done ====="
