# Host-side helper: give the image the vendor's 3-partition layout,
#   p1 = kernel/boot (128 MiB)  p2 = rootfs (1024 MiB)  p3 = /opt
# FriendlyWrt ships a pre-formatted opt.img and builds its table from
# parameter.txt ("opt:grow"); we ship an empty p3 instead and let
# /etc/uci-defaults/99-auto-resize-and-mount-opt format + grow it on the first
# boot.  Same contract at runtime -- the point is that the partition must
# already exist when the board boots, because creating one on a live rootfs
# needs BLKRRPART (EBUSY) and therefore a reboot.
#
# mbr_add_part.py rewrites exactly two things: the 16-byte MBR entry at
# 446+32 and the file length.  Boot code and the "OWRT" disk signature at
# offset 440 (what makes root=PARTUUID=5452574f-02 resolvable) are re-checked
# and left byte-for-byte identical.  NEITHER parted NOR sfdisk is used here on
# purpose: libparted's msdos_write() memsets boot_code and regenerates
# mbr_signature, i.e. it can make the board unbootable.
define Build/r28s-opt-img
	$(TOPDIR)/scripts/r28s-mbr-add-part.py "$@" 3 0x83 64
endef

define Device/friendlyarm_nanopi-r28s
  $(Device/rk3528)
  DEVICE_VENDOR := FriendlyARM
  DEVICE_MODEL := NanoPi R28S
  DEVICE_DTS := rk3528-nanopi-r28s
  UBOOT_DEVICE_NAME := nanopi-zero2-rk3528
  DEVICE_PACKAGES := kmod-r8169 kmod-aic8800-sdio aic8800-sdio-firmware kmod-bluetooth wpad-openssl
  # sysupgrade 平台校验: 运行时 board_name 来自 dts compatible(friendlyelec,...),
  # 而镜像元数据默认用 DEVICE_NAME(friendlyarm,...), 两套命名独立. 不加这行 sysupgrade -T 会报
  # "Device friendlyelec,nanopi-r28s not supported by this image". 加上后正常刷写.
  SUPPORTED_DEVICES += friendlyelec,nanopi-r28s
  # 在 pine64-img 之后追加 p3(/opt)。必须整盘 dd 刷写才会带上这张新表;
  # sysupgrade 只写 rootfs 分区、不重写 MBR, 所以从旧固件 sysupgrade 上来时
  # 分区表还是旧的(没有 p3), 首启脚本会打日志并跳过(不会重启/死循环)。
  IMAGE/sysupgrade.img.gz = boot-common | boot-script $$(BOOT_SCRIPT) | $$(BOOT_FLOW) | r28s-opt-img | gzip | append-metadata
endef
TARGET_DEVICES += friendlyarm_nanopi-r28s
