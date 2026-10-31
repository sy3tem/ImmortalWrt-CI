#!/bin/bash
# SPDX-License-Identifier: MIT
# Boot the freshly built armsr/armv8 image under QEMU with real UEFI firmware
# (edk2 / AAVMF) and verify that it comes up as the VM side-router/router image
# we expect. Called from WRT-CORE for ARMSR builds only.
#
#   ./Scripts/verify-armsr.sh <dir-with-images>
#
# Hard checks (job fails): UEFI boot, lan up with an address (QEMU user-net
# hands out 10.0.2.15), rootfs grown to the 8 GiB virtual disk, LuCI reachable,
# rtp2httpd + quickstart installed and the quickstart gate patched.
# Soft checks (warn only): dockerd running, argon theme.

set -uo pipefail

IMGDIR="${1:-./upload}"
WORK="$(mktemp -d)"
SSH="sshpass -p password ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR -p 2222 root@127.0.0.1"
FAIL=0
WARN=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; WARN=$((WARN + 1)); }

cleanup() {
	[ -f "$WORK/qemu.pid" ] && kill "$(cat "$WORK/qemu.pid")" 2>/dev/null
	sleep 1
	[ -f "$WORK/serial.log" ] && { echo "---- serial (tail) ----"; tail -n 20 "$WORK/serial.log"; }
	rm -rf "$WORK"
}
trap cleanup EXIT

echo "== armsr/UEFI smoke test =="
# 优先验证 squashfs qcow2（开 CONFIG_QCOW2_IMAGES 时生成，虚拟化导入最友好）；
# 否则 fallback 到任意 combined-efi.img.gz（解压后转 qcow2 测试）。
# 注意：必须真能找到可启动镜像，否则明确失败 —— 不能再像以前那样只找
# *ext4-combined-efi.qcow2（本项目从不生成 ext4），导致测试空跑却显示“成功”。
IMG="$(ls "$IMGDIR"/*squashfs-combined-efi.qcow2 2>/dev/null | head -n1)"
if [ -z "$IMG" ]; then
	IMG="$(ls "$IMGDIR"/*combined-efi.img.gz 2>/dev/null | head -n1)"
fi
if [ -z "$IMG" ]; then
	echo "no bootable armsr image (*squashfs-combined-efi.qcow2 or *combined-efi.img.gz) in $IMGDIR"
	ls -l "$IMGDIR"
	exit 1
fi
echo "disk: $IMG"
# 若拿到的是 .img.gz，解压后转成 qcow2 再测（QEMU 跑 qcow2 最稳）
if [[ "$IMG" == *.img.gz ]]; then
	echo "decompressing + converting .img.gz -> qcow2 ..."
	gunzip -c "$IMG" > "$WORK/disk.raw"
	qemu-img convert -f raw -O qcow2 "$WORK/disk.raw" "$WORK/disk.qcow2"
else
	cp -f "$IMG" "$WORK/disk.qcow2"
fi
cp -f /usr/share/AAVMF/AAVMF_VARS.fd "$WORK/vars.fd"

qemu-system-aarch64 \
	-M virt -cpu cortex-a72 -smp 4 -m 1024 \
	-drive if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.fd \
	-drive if=pflash,format=raw,file="$WORK/vars.fd" \
	-drive if=virtio,format=qcow2,file="$WORK/disk.qcow2" \
	-netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:8080-:80 \
	-device virtio-net-pci,netdev=n0 \
	-device virtio-rng-pci \
	-display none -serial "file:$WORK/serial.log" \
	-pidfile "$WORK/qemu.pid" -daemonize || { echo "qemu failed to start"; exit 1; }

echo "waiting for ssh ..."
# 注意：不能用 nc -z 探测 —— QEMU 的 hostfwd 端口在宿主机一侧总是立刻 accept，
# 即使 guest 的 dropbear 还没起来，nc 也会“成功”，于是老逻辑会在开机第 1 秒就
# 判定就绪，紧接着所有命令拿到的都是空字符串（整屏 FAIL 却又看不出原因）。
# 这里改成真跑一次 ssh，只有真正连上 guest 才算就绪。
READY=0
for _ in $(seq 1 120); do
	if $SSH true 2>/dev/null; then READY=1; break; fi
	sleep 5
done
if [ "$READY" -ne 1 ]; then
	echo "guest never accepted ssh within 600 s"
	echo "---- last ssh error ----"
	$SSH true || true
	exit 1
fi
sleep 5

q() { $SSH "$1" 2>/dev/null; }

REL="$(q 'cat /etc/openwrt_release | grep -m1 DISTRIB_DESCRIPTION')"
case "$REL" in
	*ImmortalWrt*) pass "release: $REL" ;;
	*) fail "release: ${REL:-<empty>}" ;;
esac

EFI="$(q '[ -d /sys/firmware/efi ] && echo yes')"
[ "$EFI" = "yes" ] && pass "booted through UEFI (efi vars present)" || fail "not booted through UEFI"

PROTO="$(q 'uci get network.lan.proto')"
PORTN="$(q 'uci get network.lan.device')"
[ "$PROTO" = "dhcp" ] && pass "single-arm detected: lan($PORTN) proto=dhcp" || fail "expected lan dhcp on a VM guest, got '${PROTO}'"

ADDR="$(q "ip -4 -o addr show dev $PORTN 2>/dev/null | awk '{print \$4}' | head -n1")"
case "$ADDR" in
	10.0.2.*) pass "lan address from QEMU DHCP: $ADDR" ;;
	*) fail "lan address: ${ADDR:-<none>}" ;;
esac

# ---- 显示输出：虚拟机图形控制台必须能看到内核日志 / 登录提示 --------------
# 这要求 (a) 内核 cmdline 有 console=tty0，(b) 内核真正开启了 VT（generic 配置
# 默认 "# CONFIG_VT is not set"，必须由 Inject-ARMSR 显式打开），(c) /dev/tty0
# 存在。三者缺一，虚拟机里就是一片黑屏 —— 这正是用户反馈的问题。
CMD="$(q 'cat /proc/cmdline')"
case "$CMD" in
	*console=tty0*) pass "kernel cmdline has console=tty0" ;;
	*) fail "kernel cmdline lacks console=tty0: ${CMD:-<empty>}" ;;
esac
q '[ -c /dev/tty0 ]' && pass "/dev/tty0 present (VT enabled)" || fail "/dev/tty0 missing (CONFIG_VT not enabled)"
q '[ -c /dev/tty1 ]' && pass "/dev/tty1 present" || warn "/dev/tty1 missing"

ROOTMB="$(q "df -m / | awk 'NR==2 {print \$2}'")"
if [ -n "$ROOTMB" ] && [ "$ROOTMB" -ge 7000 ] 2>/dev/null; then
	pass "rootfs grown to ${ROOTMB} MiB (8 GiB virtual disk)"
else
	fail "rootfs size ${ROOTMB:-?} MiB, growroot did not run"
fi

CODE="$(q "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/cgi-bin/luci/")"
case "$CODE" in
	200|302|403) pass "LuCI answers on :80 (HTTP $CODE)" ;;
	*) fail "LuCI HTTP $CODE" ;;
esac

q 'command -v rtp2httpd >/dev/null' && pass "rtp2httpd installed" || fail "rtp2httpd missing"

q '[ -f /www/luci-static/quickstart/index.js ]' && pass "quickstart assets installed" || fail "quickstart assets missing"
q 'grep -q "if true then" /usr/lib/lua/luci/controller/quickstart.lua' \
	&& pass "quickstart daemon gate patched out" \
	|| fail "quickstart controller still gated on the iStoreOS daemon"

THEME="$(q 'uci get luci.main.mediaurlbase 2>/dev/null')"
[ "$THEME" = "/luci-static/argon" ] && pass "luci theme: argon" || warn "luci theme: ${THEME:-?}"

if q 'pgrep -x dockerd >/dev/null'; then
	pass "dockerd running"
else
	warn "dockerd not running yet (slow under TCG, check after boot)"
fi

echo
echo "hard failures: $FAIL, warnings: $WARN"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
