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
if [ -f "$FW_CONF" ] && ! grep -q "^	option name		itv$" "$FW_CONF"; then
	cat "$PATCH_DIR/firewall.append" >> "$FW_CONF"
	echo "[1] itv zone appended -> $FW_CONF"
elif [ ! -f "$FW_CONF" ]; then
	echo "[1] WARNING: firewall.config not found ($FW_CONF) — zone only via uci-defaults"
else
	echo "[1] itv zone already present, skip"
fi

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

echo "===== Inject ITV done ====="
