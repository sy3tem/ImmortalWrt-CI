# ImmortalWrt-CI

统一维护的 **ImmortalWrt 云编译仓库**（GitHub Actions 驱动），把原先分散的多个
固件工程项目整合到一处：

| 设备 | 平台 | 源码 | 产物（官方命名） |
|---|---|---|---|
| **NanoPi R28S** | rockchip / rk3528 | 官方 | `immortalwrt-rockchip-armv8-friendlyarm_nanopi-r28s-squashfs-sysupgrade.img.gz` |
| **Hugsun RT28** | rockchip / rk3528 | 官方 + patch | `immortalwrt-rockchip-armv8-hugsun_rt28-squashfs-sysupgrade.img.gz` |
| **亚瑟 RE-SS-01** | qualcommax / ipq60xx | 官方 | `immortalwrt-qualcommax-ipq60xx-jdcloud_re-ss-01-squashfs-sysupgrade.bin` |
| **雅典娜 RE-CS-02** | qualcommax / ipq60xx | 官方 | `immortalwrt-qualcommax-ipq60xx-jdcloud_re-cs-02-squashfs-sysupgrade.bin` |

## 设计原则

1. **只用官方源码** — `immortalwrt/immortalwrt @ master`。
   不再依赖任何第三方 fork：亚瑟 / 雅典娜 官方树已自带设备定义、DTS、
   `ipq-wifi` board 数据；`rtp2httpd` / `homeproxy` / `passwall` /
   `dockerman` / `argon-config` / `appfilter` 也都在官方 feeds 里。
2. **固件文件名 100% 与官方一致** — 不做任何重命名。带/不带 WiFi 的差异
   通过 **Release 标签** 区分，而不是改文件名。
3. **IPTV 固化进防火墙** — `itv` zone 直接写进出厂的
   `/etc/config/firewall`，首次开机就在（详见下文）。
4. **平台注入都是增量** — 新增文件直接落盘，已有文件只用 patch /
   `awk` 定点插入，绝不整文件覆盖，尽量避免上游漂移。

## 变体与命名

| 配置（Config/*.txt） | 设备 | WiFi | Release 标签前缀 |
|---|---|---|---|
| `R28S-WIFI` | R28S | 有（AIC8800） | `R28S-WIFI-…` |
| `R28S-NOWIFI` | R28S | 无 | `R28S-NOWIFI-…` |
| `RT28` | RT28 | 有（MT7916） | `RT28-…` |
| `JDCLOUD-RE-SS-01-WIFI` | 亚瑟 | 有 | `JDCLOUD-RE-SS-01-WIFI-…` |
| `JDCLOUD-RE-SS-01-NOWIFI` | 亚瑟 | 无 | `JDCLOUD-RE-SS-01-NOWIFI-…` |
| `JDCLOUD-RE-CS-02-WIFI` | 雅典娜 | 有 | `JDCLOUD-RE-CS-02-WIFI-…` |
| `JDCLOUD-RE-CS-02-NOWIFI` | 雅典娜 | 无 | `JDCLOUD-RE-CS-02-NOWIFI-…` |

> 无 WiFi 版 = 关掉 `kmod-ath11k` / `mac80211` / `wpad` / 无线固件
> （见 `Scripts/Settings.sh`），**并裁剪设备的 `DEVICE_PACKAGES`**
> （`Scripts/Post-Defconfig.sh`，因为这些包会被强制装进 rootfs，只设
> `CONFIG_PACKAGE_x=n` 不足以移除）。**不修改 DTS**，所以固件名与有 WiFi 版
> 完全相同，靠 Release 标签区分。

## 触发编译

| Workflow | 说明 |
|---|---|
| **RK-ALL** | Rockchip 矩阵（R28S-WIFI / R28S-NOWIFI / RT28） |
| **QCA-ALL** | 高通矩阵（亚瑟 / 雅典娜 × WIFI / NOWIFI） |
| **WRT-TEST** | 单配置试跑，`TEST=true` 只产出 `.config`（约 5 分钟） |
| **Auto-Clean** | 每天清理旧 Release / tag / workflow run |
| **Cache-Clean** | 每周清 ccache 缓存 |

手动触发（Actions → 选 workflow → Run workflow）：

* `CONFIGS` — JSON 数组，如 `["R28S-WIFI"]`；留空 = 全部
* `TEST=true` — 只输出配置，不编译
* `PACKAGE` — 临时追加插件（换行分隔）

## 目录

```
.github/workflows/
  WRT-CORE.yml       编译核心（被下面三个复用）
  RK-ALL.yml         rockchip 设备矩阵
  QCA-ALL.yml        qualcommax 设备矩阵
  WRT-TEST.yml       单配置试跑
  Auto-Clean.yml     每日清理
  Cache-Clean.yml    每周清缓存
Config/
  GENERAL.txt        全局配置（附加到每个设备配置之后）
  R28S-WIFI/NOWIFI.txt
  RT28.txt
  JDCLOUD-RE-SS-01-WIFI/NOWIFI.txt
  JDCLOUD-RE-CS-02-WIFI/NOWIFI.txt
Scripts/
  Settings.sh        默认主题/IP/主机名/时区 + apk 源 + ITV 注入 + 平台注入分发
  Post-Defconfig.sh  defconfig 之后的收尾（无 WiFi 变体裁剪 DEVICE_PACKAGES）
  _trim_wifi.py      Post-Defconfig 的裁剪实现
  Packages.sh        第三方包处理（homeproxy 规则、passwall lyaml、athena-led…）
  Inject-ITV.sh      IPTV（itv）防火墙固化
  Inject-R28S.sh     R28S 设备树 / board.d / /opt 大分区
  Inject-RT28.sh     RT28 设备树 / 交换芯片补丁 / 预编译 U-Boot
target-patch/
  itv/               itv zone（firewall 片段）+ uci-defaults + hotplug
  r28s/              rk3528-nanopi-r28s.dts、设备 mk 片段、/opt init.d
  rt28/              RT28 dts / bootscript / 内核补丁 / 预编译 U-Boot / board.d
```

## IPTV / itv 说明

**itv zone 在出厂配置里**（`Scripts/Inject-ITV.sh` 把它追加进
`package/network/config/firewall/files/firewall.config`），开机即可见，
不需要等任何脚本执行：

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

三要素（真机验证）：

1. **独立 zone，按接口名匹配** — wan zone 的 `list network 'wan'` 只绑了上网口，
   IPTV 口进来的组播匹配不到任何 zone 会被丢；按接口名匹配也与运营商无关
   （各地组播地址不同，用固定 IP 段规则不通用）。
2. **`masq=0` / `mtu_fix=0`** — 组播绝不能过 fullcone NAT / conntrack。
3. **IGMPv2 + 组播路由** — `force_igmp_version=2` + `ip route replace 224.0.0.0/4 dev <itv设备>`。
   这两项依赖接口设备，由 `/etc/hotplug.d/iface/97-itv-multicast` 与
   `/etc/uci-defaults/97-itv-multicast` 在接口 up / 首启时补齐。

用法：把 IPTV 口建成名为 **`itv`** 的接口（VLAN / DHCP / PPPoE / 静态均可），
三要素自动就位；`rtp2httpd` 已内置。

## 登录

* 地址 `192.168.10.1`（RT28 首启为 `192.168.20.1`，见 `target-patch/rt28/.../99-rt28-defaults`）
* root / `password`
* WiFi SSID `DWRT`，密码 `12345678`

## 许可

MIT。设备适配与脚本整理自本项目历史工作；上游源码归属见
[immortalwrt/immortalwrt](https://github.com/immortalwrt/immortalwrt)。
