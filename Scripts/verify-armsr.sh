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
IMG="$(ls "$IMGDIR"/*ext4-combined-efi.qcow2 2>/dev/null | head -n1)"
if [ -z "$IMG" ]; then
	echo "no *ext4-combined-efi.qcow2 in $IMGDIR"
	ls -l "$IMGDIR"
	exit 1
fi
echo "disk: $IMG"
cp -f "$IMG" "$WORK/disk.qcow2"
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
READY=0
for _ in $(seq 1 120); do
	if nc -z 127.0.0.1 2222 2>/dev/null; then READY=1; break; fi
	sleep 5
done
if [ "$READY" -ne 1 ]; then
	echo "guest never opened ssh within 600 s"
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
[ "$PROTO" = "dhcp" ] && pass "single NIC detected: lan($PORTN) proto=dhcp" || fail "expected lan dhcp on a 1-NIC guest, got '${PROTO}'"

ADDR="$(q "ip -4 -o addr show dev $PORTN 2>/dev/null | awk '{print \$4}' | head -n1")"
case "$ADDR" in
	10.0.2.*) pass "lan address from QEMU DHCP: $ADDR" ;;
	*) fail "lan address: ${ADDR:-<none>}" ;;
esac

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
