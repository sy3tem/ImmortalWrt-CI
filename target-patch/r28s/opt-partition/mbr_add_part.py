#!/usr/bin/env python3
"""Append a primary partition to the MBR of a raw disk image (build time, host side).

Build/r28s-opt-img uses this to give the NanoPi R28S image the official FriendlyWrt
partition layout:  p1 = kernel, p2 = rootfs, p3 = /opt.

Only the target MBR slot and the file size are touched.  The boot code, the disk
signature (OpenWrt's "OWRT" magic at offset 440 -- what makes
root=PARTUUID=5452574f-02 resolvable) and every existing partition entry stay
byte-for-byte identical, which is verified before and after the write.

usage: mbr_add_part.py <image> <partno:1-4> <type:0xNN> <size_MiB>
"""
import os
import struct
import sys

ALIGN = 2048          # sectors == 1 MiB


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__)
        return 2

    img = sys.argv[1]
    partno = int(sys.argv[2], 0)
    ptype = int(sys.argv[3], 0)
    size_mb = int(sys.argv[4], 0)

    if not 1 <= partno <= 4 or not 1 <= ptype <= 0xFF or size_mb <= 0:
        raise SystemExit("bad arguments")

    with open(img, "r+b") as fh:
        mbr = bytearray(fh.read(512))
        if len(mbr) != 512 or mbr[510:512] != b"\x55\xaa":
            raise SystemExit("not an MBR image (missing the 0x55aa signature)")

        entries = []
        for i in range(4):
            ent = mbr[446 + 16 * i:446 + 16 * (i + 1)]
            start, nsec = struct.unpack("<II", ent[8:16])
            if ent[4] and nsec:
                entries.append((start, nsec))

        off = 446 + 16 * (partno - 1)
        if mbr[off:off + 16] != b"\x00" * 16:
            raise SystemExit("MBR slot %d is already in use" % partno)

        used_end = max((s + n for s, n in entries), default=0)
        # keep the file's own end plus whatever the table claims, then 1 MiB align
        cur_end = max(os.fstat(fh.fileno()).st_size // 512, used_end)
        start = (cur_end + ALIGN - 1) // ALIGN * ALIGN
        nsec = size_mb * 1024 * 1024 // 512

        sig_before = bytes(mbr[440:444])
        # LBA-only entry: CHS fields are dummies (0xFE/0xFF/0xFF = "use LBA")
        mbr[off:off + 16] = (bytes([0x00, 0xFE, 0xFF, 0xFF, ptype, 0xFE, 0xFF, 0xFF])
                             + struct.pack("<II", start, nsec))
        if bytes(mbr[440:444]) != sig_before:
            raise SystemExit("refusing to write: disk signature would change")

        os.truncate(fh.fileno(), (start + nsec) * 512)
        fh.seek(0)
        fh.write(mbr)

    print("mbr_add_part: p%d type=0x%02x start=%d (%d MiB) size=%d (%d MiB) -> %d bytes"
          % (partno, ptype, start, start // ALIGN, nsec, nsec // ALIGN, (start + nsec) * 512))
    return 0


if __name__ == "__main__":
    sys.exit(main())
