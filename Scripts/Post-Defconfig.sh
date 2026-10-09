#!/bin/bash
# SPDX-License-Identifier: MIT
# Post-defconfig fixups. Runs AFTER `make defconfig`, with CWD = tree root.
#
# WHY this exists:
#   A device's DEVICE_PACKAGES (from image/*.mk or ipq60xx.mk) are emitted into
#   .config as CONFIG_TARGET_DEVICE_PACKAGES_<target>_DEVICE_<dev>="..." and are
#   FORCE-INSTALLED into the rootfs — setting CONFIG_PACKAGE_<x>=n does NOT
#   remove them. So for the *-NOWIFI* variants that string must be trimmed here,
#   after defconfig has regenerated it.

set -e

if [[ "${WRT_CONFIG^^}" != *NOWIFI* ]]; then
	echo "post-defconfig: not a NOWIFI config, nothing to trim"
	exit 0
fi

echo "post-defconfig: trimming WiFi packages from device package lists"
python3 "$GITHUB_WORKSPACE/Scripts/_trim_wifi.py"
echo "post-defconfig: done"
