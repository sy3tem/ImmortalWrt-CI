# ImmortalWrt-CI

自用的 ImmortalWrt 云编译仓库，GitHub Actions 上跑。只编手上这几台机器：

- NanoPi R28S（rk3528）
- Hugsun RT28（rk3528）
- 京东云 亚瑟 RE-SS-01（ipq6000）
- 京东云 雅典娜 RE-CS-02（ipq6010）

源码一律用官方 `immortalwrt/immortalwrt` 的 master，不挂第三方 fork。亚瑟和雅典娜官方树里本来就有设备定义、DTS 和 ipq-wifi board 数据，不用自己补。

## 怎么编

进 Actions 手动点，`CONFIGS` 传 JSON 数组：

```
["JDCLOUD-RE-CS-02-WIFI"]
```

不填就全编。只想要配置文件不要固件，把 `TEST` 勾上，五分钟出 `.config`。

| workflow | 编什么 |
|---|---|
| `RK-ALL` | R28S-WIFI / R28S-NOWIFI / RT28 |
| `QCA-ALL` | 亚瑟、雅典娜各两个变体 |
| `WRT-TEST` | 单配置试跑 |
| `Auto-Clean` | 每天清旧 Release |
| `Cache-Clean` | 每周清 ccache |

`Auto-Clean` 跑完会自动带着重编一轮，所以每天有一批新固件。

## 固件在哪儿拿

按天合并到一个 Release，tag 是 `master-26.11.07` 这种。同一天不同平台的东西都在同一个 Release 下面，别按 workflow 找。

文件名不改，还是上游那套，只在前面加 `<源码>-<分支>`、末尾加构建时间。**默认（带 WiFi）文件名里没有 wifi 段**，只有无 WiFi 变体多插一个 `wifi-no-`：

```
immortalwrt-master-qualcommax-ipq60xx-jdcloud_re-cs-02-squashfs-sysupgrade-26.11.07-13.41.bin
immortalwrt-master-wifi-no-qualcommax-ipq60xx-jdcloud_re-cs-02-squashfs-sysupgrade-26.11.07-13.41.bin
```

京东云这两台（亚瑟 / 雅典娜）除了 `sysupgrade.bin`，还会多出一个 **`factory.bin`**，给 U-Boot 直接 `mmc write` 用：kernel 补齐到 `KERNEL_SIZE`（6144k）再拼 rootfs，和同平台 `link_nn6000-v1` 的 factory 布局一致。`Scripts/Inject-JDCLOUD.sh` 往 `target/linux/qualcommax/image/ipq60xx.mk` 的两个设备块里补的：

```make
IMAGES += factory.bin
IMAGE/factory.bin := append-kernel | pad-to $$(KERNEL_SIZE) | append-rootfs | pad-rootfs | append-metadata
```

配置快照是 `Config-<配置名>-<源码>-<分支>-<时间>.txt`，出问题可以对着看差异。

## WiFi / 无 WiFi

无 WiFi 版不是靠 `.config` 里写 `=n` 就能去掉的——`kmod-ath`、`mac80211`、`wpad`、`wifi-scripts` 这些会被 `DEVICE_PACKAGES` 强行装进 rootfs。所以 `Scripts/Post-Defconfig.sh` 会去裁设备的 `DEVICE_PACKAGES`，DTS 不动。

编完 `Verify no-WiFi image` 会直接翻最终镜像的 `.manifest`，只要还剩 `wpad*`、`kmod-mac80211`、`wifi-scripts`、`kmod-aic8800*`、`ipq-wifi-*` 就直接失败、不发 Release。看 `.config` 是看不出来的，裁掉的包在那里仍然是 `=m`。

## /opt 数据分区

四台机器的 eMMC 上都有一块大分区给 `/opt` 用，但京东云这两台的官方 fstab 里没写，`block-mount` 会把它 auto 到 `/mnt/mmcblk0p19`，于是 `/opt` 一直落在 1.9 GiB 的 overlay 上。Open-Box 解包 174 MB、docker 数据一堆，overlay 很快就满。

`target-patch/jdcloud/opt-partition/99-mount-opt` 在 S10boot 阶段（早于 S11fstab）自己找一块分区用，顺序是：

1. 按 `/proc/cmdline` 的 `root=PARTUUID=` 定位系统盘，找 ≥4 GiB 的 ext4（2 G 的 rootfs `p18` 自然排除）
2. 系统盘没有就扫另一块盘（NAND + eMMC 的机器）
3. 有够大的未格式化分区就格成 ext4
4. 都没有就从最后一个分区后面的空闲里补一个 GPT 分区再格式化

四步都不行就记条日志放弃，不影响开机。选定后写 fstab → `/opt`，把 overlay 上已有的 `/opt` 搬进去，再摘掉 `/mnt` 的 automount。

四种布局在 loop 设备上都测过。真机亚瑟走的是「已有 p19」那条；雅典娜首次开机看 `logread -e opt-partition` 就知道走了哪条。

> 已经刷过旧固件、`/opt` 还留在 overlay 上的机器，要么重刷，要么手工迁一次：备份 `/opt` → 停 `dockerd` 和 `openbox-panel` → 内容拷到数据分区 → `uci` 把该分区 fstab 改成 `/opt` 并启用 → `umount` 后挂上去 → 起服务、删掉 `/overlay/upper/opt`。

R28S 和 RT28 也各有自己的做法，分别在 `target-patch/r28s/` 和 `target-patch/rt28/`。

## Open-Box

`target-patch/openbox/` 不编译，只搬运：Makefile 从 `liandu2024/Open-Box` 的 Release 拉 `v0.1.412` 的 arm64 tar.gz，`PKG_HASH` 用官方 `.sha256` 锁住，下载走 GitHub，失败回落 `gh-proxy.com`。

发布包原样放进 `/usr/share/open-box/payload.tar.gz`，首启由 `open-box-firstboot`（S99）解到 `/opt/open-box`，再照官方 `install.sh` 铺 init.d、软链、LuCI 视图、menu.d 和 rpcd ACL。

不直接打进镜像的原因很简单：这四台的 `/opt` 都是开机才挂的独立分区，镜像里放什么都会被盖掉，只能首启解包。

面板在 `http://<LAN IP>:3036`，首次打开设密码。只启用面板，sing-box 内核默认不启动，和官方 install.sh 一致。卸载跑 `open-box uninstall`，卸载后重启不会自己装回来（压缩包铺完就删了）。

> Open-Box 是闭源专有软件，LICENSE 明确禁止未经许可的再分发。把发布包打进固件再发公开 Release 就是在再分发，公开发布前先确认拿到授权，或者把仓库和 Release 设私有。

## IPTV

`itv` zone 是编译时直接写进 `firewall.config` 的，开机就有，不依赖任何脚本：

```
config zone
	option name		itv
	list   network		'itv'
	option input		ACCEPT
	option output		ACCEPT
	option forward		DROP
	option masq		0
	option mtu_fix		0
```

三个要点：独立 zone 按接口名匹配（不按 IP 段，各地组播地址不一样）；`masq` 和 `mtu_fix` 必须关，组播不能过 NAT 和 conntrack；IGMPv2 和组播路由由 `/etc/hotplug.d/iface/97-itv-multicast` 和 `uci-defaults` 在接口 up 时补。

把 IPTV 口建成名字叫 `itv` 的接口就行，VLAN / DHCP / PPPoE / 静态都行，三样东西自动就位。`rtp2httpd` 已经内置。

## 登录

- `192.168.10.1`（RT28 首启是 `192.168.20.1`）
- root / `password`
- WiFi `DWRT` / `12345678`

## 目录

```
.github/workflows/  WRT-CORE.yml 是核心，RK-ALL / QCA-ALL 只是调它的矩阵
Config/             每台一个配置，GENERAL.txt 拼在设备配置前面
Scripts/            Settings.sh 管默认值、Packages.sh 管第三方包
target-patch/       各平台的增量改动：dts、init.d、uci-defaults
```

## 许可

MIT。设备适配和脚本是这个仓库自己的，上游源码归 [immortalwrt/immortalwrt](https://github.com/immortalwrt/immortalwrt)。
