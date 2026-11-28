#!/bin/bash
# SPDX-License-Identifier: MIT
# Inject the ITV (IPTV) multicast support into an ImmortalWrt source tree.
#
# "Firmware-fixed" means the zone really lives in the shipped /etc/config/firewall,
# not just in a first-boot script:
#   1) append the `itv` zone to package/network/config/firewall/files/firewall.config
#      -> present in the image from the very first boot, visible in LuCI -> Firewall
#   2) install /etc/uci-defaults/97-itv-multicast  (idempotent re-assert)
#   3) install /etc/hotplug.d/iface/97-itv-multicast (covers late-created ifaces)
#
# Called from the WRT-CORE "Custom Settings" stage with CWD = source tree root.
set -e

PATCH_DIR="$GITHUB_WORKSPACE/target-patch/itv"
FW_CONF="./package/network/config/firewall/files/firewall.config"

echo "===== Inject ITV (IPTV) support ====="

# ---- 1) firewall zone baked into the shipped config ----
# PON 系列跳过：那边接口叫 iptv（br-iptv），zone 由 98-pon-net 首启时一起建，
# 这里再塞一个没有接口的 itv zone 只会在防火墙页多出一行空 zone。
case "${WRT_CONFIG,,}" in
pon-*)
	echo "[1] PON: skip static itv zone (iptv zone comes from 98-pon-net)"
	;;
*)
	if [ -f "$FW_CONF" ] && ! grep -q "^	option name		itv$" "$FW_CONF"; then
		cat "$PATCH_DIR/firewall.append" >> "$FW_CONF"
		echo "[1] itv zone appended -> $FW_CONF"
	elif [ ! -f "$FW_CONF" ]; then
		echo "[1] WARNING: firewall.config not found ($FW_CONF) — zone only via uci-defaults"
	else
		echo "[1] itv zone already present, skip"
	fi
	;;
esac

# ---- 2) uci-defaults (first boot, idempotent) ----
UDIR="./package/base-files/files/etc/uci-defaults"
mkdir -p "$UDIR"
cp -f "$PATCH_DIR/97-itv-multicast" "$UDIR/97-itv-multicast"
chmod +x "$UDIR/97-itv-multicast"
echo "[2] uci-defaults 97-itv-multicast installed"

# ---- 3) hotplug (interface created / renamed / re-upped later) ----
HDIR="./package/base-files/files/etc/hotplug.d/iface"
mkdir -p "$HDIR"
cp -f "$PATCH_DIR/97-itv-multicast.hotplug" "$HDIR/97-itv-multicast"
chmod +x "$HDIR/97-itv-multicast"
echo "[3] hotplug.d/iface/97-itv-multicast installed"

# ---- 4) rtp2httpd: turn the service on (upstream conffile ships enabled=0) ----
# 上游 rtp2httpd.config 默认 `option enabled '0'`，包编进去了但守护进程不监听，
# 用户会以为“装了没用”。这里首启打开；端口沿用 conffile 里的 0.0.0.0:5140。
# 组播上游接口不写死：由 97-itv-multicast hotplug 在 itv 接口 up 时按实际设备
# 名写入 upstream_interface_multicast（VLAN / PPPoE / DHCP 设备名都不同）。
# 没编 rtp2httpd 的平台没有这个 conffile，脚本空转。
cat > "$UDIR/98-rtp2httpd-enable" <<'EOS'
#!/bin/sh
[ -f /etc/config/rtp2httpd ] || exit 0
if uci -q get rtp2httpd.@instance[0] >/dev/null 2>&1; then
	uci -q set rtp2httpd.@instance[0].enabled='1'
	uci -q commit rtp2httpd
fi
exit 0
EOS
chmod +x "$UDIR/98-rtp2httpd-enable"
echo "[4] uci-defaults 98-rtp2httpd-enable installed"

echo "===== Inject ITV done ====="
