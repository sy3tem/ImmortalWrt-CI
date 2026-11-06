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
   `ipq-wifi` board 数据；`rtp2httpd` / `homeproxy` / `dockerman` /
   `argon-config` / `appfilter` 也都在官方 feeds 里。
2. **不带 OpenClash、不带 iStore 应用商店** — 代理（oc/clash/mihomo）和
   iStore 商店（`luci-app-store` + `taskd` 四件套）已从本仓库整体移除：
   `Config/GENERAL.txt` 不再选这两个包，`Scripts/Packages.sh` 也不再从
   `linkease/istore` 现场提取，`Scripts/Settings.sh` 里配套的 taskd 修复一并删掉。
   要装请自己刷完机后从 LuCI/软件包手动安装。
3. **固件文件名以上游命名为准** — 内核/镜像本身不重命名，只在前面加
   `<源码>-<分支>-<wifi-yes|wifi-no>`、末尾加构建时间（见 WRT-CORE 打包步骤），
   这样同一设备不同批次、带/不带 WiFi 一眼可分。
4. **IPTV 固化进防火墙** — `itv` zone 直接写进出厂的
   `/etc/config/firewall`，首次开机就在（详见下文）。
5. **平台注入都是增量** — 新增文件直接落盘，已有文件只用 patch /
   `awk` 定点插入，绝不整文件覆盖，尽量避免上游漂移。

## 变体与命名

| 配置（Config/*.txt） | 设备 | WiFi | 文件名里的变体标记 |
|---|---|---|---|
| `R28S-WIFI` | R28S | 有（AIC8800） | `wifi-yes` |
| `R28S-NOWIFI` | R28S | 无 | `wifi-no` |
| `RT28` | RT28 | 有（MT7916） | `wifi-yes` |
| `JDCLOUD-RE-SS-01-WIFI` | 亚瑟 | 有 | `wifi-yes` |
| `JDCLOUD-RE-SS-01-NOWIFI` | 亚瑟 | 无 | `wifi-no` |
| `JDCLOUD-RE-CS-02-WIFI` | 雅典娜 | 有 | `wifi-yes` |
| `JDCLOUD-RE-CS-02-NOWIFI` | 雅典娜 | 无 | `wifi-no` |

> 无 WiFi 版 = 关掉 `kmod-ath` / `mac80211` / `wpad` / `wifi-scripts` / 无线固件
> （见 `Scripts/Settings.sh`），**并裁剪设备的 `DEVICE_PACKAGES`**
> （`Scripts/Post-Defconfig.sh`，因为这些包会被强制装进 rootfs，只设
> `CONFIG_PACKAGE_x=n` 不足以移除）。**不修改 DTS**，所以除了文件名里的
> `wifi-yes` / `wifi-no` 段之外与有 WiFi 版一致。
>
> 光看 `.config` 判断不了有没有真去掉：被裁掉的包在 `.config` 里仍是 `=m`。
> 所以 WRT-CORE 编完会跑 `Verify no-WiFi image`，直接 grep 最终镜像的
> `.manifest`（实际装机清单），只要还剩 `wpad*` / `kmod-mac80211` /
> `wifi-scripts` / `kmod-aic8800*` / `ipq-wifi-*` 之类就**直接失败、不发 Release**。

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
  WRT-CORE.yml       编译核心（被下面两个复用）
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
  Packages.sh        第三方包处理（homeproxy 规则、rtp2httpd、athena-led…）
  Inject-ITV.sh      IPTV（itv）防火墙固化
  Inject-R28S.sh     R28S 设备树 / board.d / /opt 大分区
  Inject-RT28.sh     RT28 设备树 / 交换芯片补丁 / 预编译 U-Boot（跳过 configure+compile）
target-patch/
  itv/               itv zone（firewall 片段）+ uci-defaults + hotplug
  r28s/              rk3528-nanopi-r28s.dts、设备 mk 片段、/opt init.d
  rt28/              RT28 dts / bootscript / 内核补丁 / 预编译 U-Boot / board.d
  openbox/           Open-Box 预编译包（Makefile）+ 首启解包脚本
```

## Open-Box（闭源，随固件预装）

`target-patch/openbox/` 是一个「只搬运、不编译」的包：

- **Makefile** 从 `liandu2024/Open-Box` 的 Release 下 `open-box-v0.1.412-linux-arm64.tar.gz`，
  用 `.sha256` 里的值 pin 了 `PKG_HASH`；版本升级就是改 `PKG_VERSION` / `PKG_HASH`。
  下载走 GitHub，失败自动回落到 `gh-proxy.com` 镜像。
- 发布包（约 73 MB，解包后约 200 MB）原样放进 `/usr/share/open-box/payload.tar.gz`。
- `/etc/init.d/open-box-firstboot`（S99）**首次开机**解到 `/opt/open-box`，再做官方
  `install.sh` 那几步：铺 `/etc/init.d/openbox{,-panel}`、`/usr/bin/open-box` 软链、
  LuCI 视图 + `menu.d` + `rpcd` ACL、`data/panel-port`（3036）和 `data/channel`。
  完成后写 `/etc/open-box.installed`，之后开机不再重复解包。

为什么不编进镜像：**R28S / RT28 的 `/opt` 是开机才挂载的独立分区(p3)**，镜像里 `/opt`
下的内容会被挂载盖掉，所以四台机器统一走「首启解包」。

用法：

- 面板 `http://<LAN IP>:3036`，首次打开设置密码；LuCI「服务 → Open-Box」是兜底页。
- 只启用**面板**服务，内核（sing-box）不随开机启动，和官方 `install.sh` 一致。
- 卸载：`open-box uninstall`。卸载后重启不会自动装回来；想装回去删
  `/etc/open-box.installed` 再重启即可。
- 依赖（`kmod-tun` / `kmod-nft-queue` / `kmod-nft-nat` / `kmod-veth` / `ip-full` /
  `ca-bundle`）都已在 `Config/GENERAL.txt` 里，包本身也声明了。

> ⚠ **授权**：Open-Box 自有程序是闭源专有软件，其 LICENSE 明确禁止未经许可的复制、
> 传播与再分发。把发布包打进固件、再把固件发到公开 Release，等于在再分发它；
> 要公开发布请先确认自己拿到了授权，或把仓库 / Release 设为私有。

## 范围

只维护 **ARM 实机**（rockchip / qualcommax 两块板级），**不再编 armsr（飞牛 / KVM 虚拟机）
和 x86-64**。这两套的 workflow、Config、注入脚本和 `target-patch/armsr` 已整体删除；
要虚拟机镜像请直接用 immortalwrt 官方 releases，或从 git 历史里捞回来。


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
