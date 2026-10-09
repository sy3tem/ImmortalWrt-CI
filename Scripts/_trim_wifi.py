#!/usr/bin/env python3
# Trim wireless packages out of CONFIG_TARGET_DEVICE_PACKAGES_*="..." lines.
# Run with CWD = OpenWrt tree root (reads/writes ./.config).

import re
import sys

# whole-token matchers for anything that drags in the wireless stack
DROP_PATTERNS = [
    r'kmod-ath\b',
    r'kmod-ath\d+k[-\w]*',
    r'ath\d+k-firmware[-\w]*',
    r'kmod-mac80211',
    r'ipq-wifi-[-\w]+',
    r'kmod-mt79\d+[-\w]*',
    r'kmod-mt792\d+[-\w]*',
    r'mt79\d+-firmware',
    r'wpad[-\w]*',
    r'wifi-scripts',
    r'kmod-aic8800[-\w]*',
    r'aic8800-sdio-firmware',
    r'kmod-bluetooth',
    r'kmod-rtw[-\w]*',
    r'kmod-brcmfmac',
    r'brcmfmac[-\w]*',
]
DROP = re.compile(r'^(?:' + '|'.join(DROP_PATTERNS) + r')$')

# NOTE: device names contain '-' (e.g. jdcloud_re-ss-01, friendlyarm_nanopi-r28s)
LINE = re.compile(r'^(\s*)(CONFIG_TARGET_DEVICE_PACKAGES_[A-Za-z0-9_-]+=")(.*)("\s*)$')

changed = 0
out = []
with open('.config', encoding='utf-8') as fh:
    for raw in fh:
        ln = raw.rstrip('\n')
        m = LINE.match(ln)
        if not m:
            out.append(raw)
            continue
        indent, key, val, tail = m.groups()
        pkgs = val.split()
        kept = [p for p in pkgs if not DROP.match(p)]
        dropped = [p for p in pkgs if DROP.match(p)]
        if dropped:
            changed += 1
            label = key.replace('CONFIG_TARGET_DEVICE_PACKAGES_', '').rstrip('="')
            print("  %s" % label)
            print("    dropped: %s" % ' '.join(dropped))
            print("    before : %s" % val)
            print("    after  : %s" % ' '.join(kept))
        out.append('%s%s%s%s\n' % (indent, key, ' '.join(kept), tail))

with open('.config', 'w', encoding='utf-8', newline='\n') as fh:
    fh.writelines(out)

print("post-defconfig: %d device package list(s) trimmed" % changed)
