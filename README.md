# ImmortalWrt-CI

自己用的固件云编译仓库，跑在 GitHub Actions 上。想编哪台就进 Actions 点一下，产物直接发 Release。

## 有哪些机器

| 机器 | 平台 | 源码 |
|---|---|---|
| NanoPi R28S | rk3528 | `immortalwrt/immortalwrt` |
| Hugsun RT28 | rk3528 | 同上，外加 `target-patch/rt28` 里的补丁 |
| 京东云 亚瑟 RE-SS-01 | ipq6000 | 同上 |
| 京东云 雅典娜 RE-CS-02 | ipq6010 | 同上 |
| Nokia XG-040G-MF、FiberHome HG5585F 等光猫 | Airoha AN7581 / AN7583 | `pbs05/ponwrt` |

光猫的源码不一样，原因写在下面「光猫」那一节。

## 怎么开编

Actions → 选 workflow → Run workflow。

- `CONFIGS`：JSON 数组，比如 `["R28S-WIFI"]`，留空就全编
- `TEST`：只出 `.config` 不编译，几分钟，产物在运行页面的 Artifacts 里
- `PACKAGE`：临时加插件，一行一个

| workflow | 干什么 |
|---|---|
| `RK-ALL` | R28S-WIFI、R28S-NOWIFI、RT28 |
| `QCA-ALL` | 亚瑟、雅典娜各两个变体 |
| `PON-ALL` | 光猫，默认只编 `PON-AN7583` |
| `R28S-7DOLLAR` | R28S 换 7Dollar 主题那一版 |
| `WRT-TEST` | 单个配置试跑 |
| `Auto-Clean` | 每天清旧 Release，清完顺带重编一轮 |
| `Cache-Clean` | 每周清 ccache |

## 文件名

```
<源码>-<分支>-[wifi-no-]<平台>-<子目标>-<设备>-<文件系统>[-full]-sy3tem-<日期时间>.<扩展名>
```

比如：

```
immortalwrt-master-rockchip-armv8-friendlyarm_nanopi-r28s-squashfs-sysupgrade-sy3tem-26.11.22-09.51.21.img.gz
```

带 WiFi 的版本文件名里没有 wifi 段，只有 `-NOWIFI` 变体会插一个 `wifi-no-`。每次还会附一份配置快照：`Config-<配置名>-<源码>-<分支>-<时间>.txt`。

## 各平台上踩过的坑

**无 WiFi 变体**：光在 `.config` 里写 `=n` 不够。`kmod-ath`、`mac80211`、`wpad`、`wifi-scripts` 这些会被设备的 `DEVICE_PACKAGES` 强行装进 rootfs，所以 defconfig 之后还得裁一遍设备包（`Scripts/Post-Defconfig.sh`）。编完会去翻最终镜像的 `.manifest`，还剩无线包就直接失败、不发 Release。

**R28S / RT28 的 /opt**：这两台 eMMC 上有大分区，首启脚本自己找分区、格式化、挂到 `/opt`。代码在 `target-patch/r28s/` 和 `target-patch/rt28/`。

**亚瑟 / 雅典娜**：除了 `/opt`，还有 LED 点阵屏（athena-led）。`factory.bin` 的写法参考了 VIKINGYFY 那套。

**主题**：默认 argon。`R28S-7DOLLAR` 用第三方 [7Dollar](https://github.com/itsmaiGe/luci-theme-7dollar)，配色默认改成蓝色（`mist`）。这主题不在官方 feeds 里，编译时现场 clone 进 `package/`。

## 光猫

光猫用 [pbs05/ponwrt](https://github.com/pbs05/ponwrt)，不是官方 immortalwrt。PON 的驱动和用户态（`airoha-ponctl`、`airoha-pond`、`luci-app-pon`）只在它那两个 feed 里，换别的分支编出来是空的 —— 试过 Loong1996 那棵树，defconfig 之后这几个包一个都没有。

几件跟硬件有关的账：

- **1G 内存**：ponwrt 自带的 U-Boot 只会把 DTS 里的 512M 报给内核，1G 的机器也只认一半。设备上的 FIP 换成了 [Loong1996](https://github.com/Loong1996/ImmortalWrt-Airoha) 发的 `an7583-nokia-xg-040g-mf-bl31-uboot.fip`（带 DRAM 地址回绕探测），串口能看到 `dram: 1024 MiB probed`，内核 `Memory: 948640K/1048576K`。固件本身不用按容量分档。
- **不挂载**：光猫没有 eMMC，也没有独立数据分区，所以不装 block-mount / automount / mmc-utils / f2fs-tools 那一串，也没有 `/opt` 脚本。
- **不带 open-box**：那个面板要解到 `/opt`，光猫上没意义。
- **flow offload 会让防火墙挂掉**：airoha 上开 `flow_offloading` 时，`nft` 会报 `flow offload @fb: Protocol error`，整份规则事务回滚，fw4 只剩半套 —— input 链里没有 zone 分发，LAN 侧的 DHCP、SSH、LuCI 全不通。PON 配置里已经关掉，其它平台不受影响。
- **温度**：镜像里补了 `/sbin/tempinfo`，概览会显示 CPU 和光模块温度。
- **ri / bosa**：这两个 UBI 卷存 MAC、SN 和光模块校准，重建 UBI 会清空。清空之后 `ponctl status` 显示 `serial_configured: 0`、`calibration: missing`，PON 注册不上，得从整片备份写回去。

刷机按上游流程：U-Boot 网页「刷写系统」刷 `.itb`，救砖用同名的 `-initramfs-recovery.itb`。

## 登录

- 地址 `192.168.10.1`；RT28 是 `192.168.20.1`，光猫是 `192.168.86.1`
- root / `password`
- WiFi `DWRT` / `12345678`
- 主机名 `ImmortalWrt`

## 目录

```
.github/workflows/   WRT-CORE.yml 是编译核心，其它只是传参数调它
Config/              每个配置一个 txt；GENERAL.txt 拼在前面，PON 用 GENERAL-PON.txt
Scripts/             Settings.sh 管默认值，Packages.sh 管第三方包，Inject-*.sh 是各平台注入
target-patch/        各平台的增量文件：dts、init.d、uci-defaults
```

## 许可

MIT。设备适配和脚本是这个仓库自己的，源码归上游。
