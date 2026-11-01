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
SSHCMD="sshpass -p password ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"
# guest 实际落到哪个地址要探测后才知道（见下方 netdev 注释），先留空
PORT_SSH=""
PORT_HTTP=""
SSH=""
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
	-netdev user,id=n0,net=192.168.10.0/24,host=192.168.10.2,dhcpstart=192.168.10.100,\
hostfwd=tcp:127.0.0.1:2222-192.168.10.254:22,hostfwd=tcp:127.0.0.1:2223-192.168.10.100:22,\
hostfwd=tcp:127.0.0.1:8080-192.168.10.254:80,hostfwd=tcp:127.0.0.1:8081-192.168.10.100:80 \
	-device virtio-net-pci,netdev=n0 \
	-device virtio-rng-pci \
	-display none -serial "file:$WORK/serial.log" \
	-pidfile "$WORK/qemu.pid" -daemonize || { echo "qemu failed to start"; exit 1; }

echo "waiting for ssh ..."
# 注意：不能用 nc -z 探测 —— QEMU 的 hostfwd 端口在宿主机一侧总是立刻 accept，
# 即使 guest 的 dropbear 还没起来，nc 也会“成功”，于是老逻辑会在开机第 1 秒就
# 判定就绪，紧接着所有命令拿到的都是空字符串（整屏 FAIL 却又看不出原因）。
# 这里改成真跑一次 ssh，只有真正连上 guest 才算就绪。
#
# guest 的地址取决于它有没有拿到 DHCP lease，所以要对两个候选都试：
#   2222 -> 192.168.10.254  (netfallback 的静态回落地址，QEMU 里通常就是这个)
#   2223 -> 192.168.10.100  (真的从 QEMU DHCP 拿到地址时的 dhcpstart)
READY=0
for _ in $(seq 1 120); do
	for cand in 2222 2223; do
		if $SSHCMD -p "$cand" root@127.0.0.1 true 2>/dev/null; then
			PORT_SSH="$cand"; READY=1; break
		fi
	done
	[ "$READY" -eq 1 ] && break
	sleep 5
done
if [ "$READY" -ne 1 ]; then
	echo "guest never accepted ssh within 600 s"
	echo "---- last ssh error ----"
	for cand in 2222 2223; do
		echo "[port $cand]"; $SSHCMD -p "$cand" root@127.0.0.1 true || true
	done
	exit 1
fi
case "$PORT_SSH" in
	2222) PORT_HTTP=8080 ;;
	2223) PORT_HTTP=8081 ;;
esac
SSH="$SSHCMD -p $PORT_SSH root@127.0.0.1"
echo "guest reachable on host port $PORT_SSH (ssh) / $PORT_HTTP (http)"
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
LANIP="$(q 'uci get network.lan.ipaddr')"
# 单臂模式下 lan 是 DHCP 客户端；QEMU 的 user-net 里 netifd 常常在首启时拿不到
# lease，netfallback 会在 ~60s 后按设计回落到静态 192.168.10.254/24
# （见 92-nic-autoconfig / netfallback）。两种结果都是「可被主路由/宿主机访问」
# 的合法终态，所以 dhcp 与回落后的 .254 都要判 pass。
case "$PROTO" in
	dhcp)   pass "single-arm detected: lan($PORTN) proto=dhcp" ;;
	static)
		if [ "$LANIP" = "192.168.10.254" ]; then
			pass "single-arm: no lease -> netfallback static $LANIP (by design)"
		else
			fail "static lan ${LANIP}, not the expected netfallback address"
		fi ;;
	*)      fail "expected lan dhcp on a VM guest, got '${PROTO}'" ;;
esac

ADDR="$(q "ip -4 -o addr show dev $PORTN 2>/dev/null | awk '{print \$4}' | head -n1")"
case "$ADDR" in
	192.168.10.*|10.0.2.*) pass "lan address: $ADDR" ;;
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

# 本镜像强制 squashfs（Config/ARMSR-UEFI.txt 里 EXT4FS=n），而 growroot 自己的
# 注释就写明 "squashfs installs are left alone —— growroot only touches ext2/3/4
# root filesystems"，所以 8 GiB 虚拟盘上的剩余空间对 squashfs 而言拿不到，
# df 显示 ~423 MiB 属正常；再用 ">= 7000 MiB" 去卡会必然 FAIL（把过严的期望当
# 成真 bug 查了很久）。真正该验的是：overlay（配置/数据写入区）挂上了、且有
# 可用空间，否则首启改动无处可落。
if [ "$(q 'mount | grep -c " /overlay "')" -ge 1 ] 2>/dev/null; then
	pass "squashfs overlay mounted at /overlay"
else
	fail "no /overlay mount — first-boot changes cannot persist"
fi
AVAILMB="$(q "df -m / | awk 'NR==2 {print \$4}'")"
if [ -n "$AVAILMB" ] && [ "$AVAILMB" -ge 256 ] 2>/dev/null; then
	pass "rootfs writable: ${AVAILMB} MiB available"
else
	fail "rootfs only ${AVAILMB:-?} MiB available"
fi

# 从宿主机一侧请求（走 hostfwd），这一步同时验掉防火墙有没有放行管理与 luCI
CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT_HTTP}/cgi-bin/luci/")"
case "$CODE" in
	200|302|403) pass "LuCI answers via http port $PORT_HTTP (HTTP $CODE)" ;;
	*) fail "LuCI HTTP $CODE via port $PORT_HTTP" ;;
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
