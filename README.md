# OpenWrt 25.12 for BPI-R4 + BE14

本仓库面向 **Banana Pi BPI-R4 4GB、非 PoE 版**，并启用 BE14（三频 Wi-Fi 7）扩展板。不要把这里的引导器写入 BPI-R4 2.5GE/PoE、BPI-R4 Lite 或其他硬件变体。

## 功能与默认值

- MediaTek Filogic / MT7988、BE14（MT7996）固件与硬件流量卸载
- LuCI HTTPS、简体中文、Argon；MWAN3、SQM、nlbwmon 与 Bandix 流量统计
- QModem Next、MT5700 管理页、局域网/公网测速工具
- LAN：`192.168.66.1/24`；主机名：`BPI-R4-BE14`
- 硬件流量卸载默认开启，Bandix 默认关闭

镜像不预置 root 密码。首次启动后请只通过可信 LAN 接入，直接使用 `https://192.168.66.1/`，立即设置管理员密码（或在本地控制台执行 `passwd`），再配置 Wi-Fi 国家/地区、WPA2/WPA3 和强口令；配置完成前不要把管理面暴露到 WAN。初始 HTTPS 证书为设备自签名证书，HTTP 默认重定向到该 HTTPS 服务。MT5700 和 Speedtest-X 默认关闭；启用后会监听所有地址且默认无认证，只能放在受信 LAN/防火墙内。OpenClash 源码保留在 `package/custom` 供自行选择，但因其高权限更新流程仍使用不安全的固定临时路径，生产镜像明确不选入。

Bandix 的 TC/eBPF 原生统计看不到已经进入 MT7988 PPE 的数据。本项目不为统计关闭全局硬件加速，而是在 Bandix 实时/全部视图中合并 PPE/FOE MIB 计数；历史区间仍只显示 Bandix 自身持久化的数据。采集器仅在启用 Bandix“流量监控”时运行，默认 10 秒采样一次，状态保存在 `/tmp`，不会周期写闪存。限速、SQM 或其他必须经过软件路径的功能仍可能与硬件 flow offload 冲突，应只对需要的流量旁路，避免全局关闭。

为防止上游在线包覆盖本项目的 PPE 兼容层，Bandix 页面只允许检查版本，禁止直接安装未随固件校验的更新；升级请通过本仓库重新构建固件。

设备上可执行 `bpi-r4-offload-health`，检查 fw4 硬件 flowtable、MT7996 WED、PPE debugfs/MIB 和近期错误日志；运行检查时持续产生 WAN 流量，MIB 增长项才会显示 PASS。

## 从 SD 安装到 SPI-NAND，再安装到 eMMC

安装会重建目标介质上的引导器、恢复系统和生产系统，**会清除 SPI-NAND/eMMC 上的现有数据**。先备份配置，接好 3.3V 串口（115200 8N1），并只在完全断电后切换启动拨码。拨码位置请以板卡丝印和 [Banana Pi 官方入门指南](https://docs.banana-pi.org/zh/BPI-R4/GettingStarted_BPI-R4) 为准。

1. 校验 `SHA256SUMS`，把 `openwrt-mediatek-filogic-bananapi_bpi-r4-sdcard.img.gz` 解压写入 SD 卡；务必把 `/dev/sdX` 换成整张卡的真实设备：

   ```sh
   sha256sum -c SHA256SUMS
   gzip -dc openwrt-mediatek-filogic-bananapi_bpi-r4-sdcard.img.gz \
     | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
   ```

2. 断电，将拨码设为 **SD 启动**，插卡并开机。在 SD U-Boot 菜单选择 **6 — `Install bootloader, recovery and production to NAND.`**。这一步格式化 SPI-NAND，并把下一阶段所需的 eMMC 安装包一并保存到 NAND。
3. 完成后断电，将拨码设为 **SPI-NAND 启动**，再开机。在 SPI-NAND U-Boot 菜单选择 **8 — `Install bootloader, recovery and production to eMMC.`**。这是必须的第二阶段，因为 SD 与 eMMC 共用控制器，不能直接从 SD 完成 eMMC 安装。
4. 完成后断电，将拨码设为 **eMMC 启动**，移除 SD 卡并开机。首次出现 `Initialize environment.` 时让 U-Boot 完成环境初始化；之后默认启动 production，菜单项 3 可启动 recovery。

不要用 SPI-NAND 菜单项 6/7 或 eMMC 菜单项 6/7 做首次安装：它们是通过 TFTP 单独更新 FIP/BL2 的维护入口，不等同于上述完整两阶段安装。

## 可复现构建与产物校验

建议使用全新的、大小写敏感的 GNU/Linux 工作目录。源码和 feed 固定值见 [`SOURCES.md`](SOURCES.md) 与 [`build-meta/versions.env`](build-meta/versions.env)。安装 OpenWrt 官方文档列出的构建依赖后运行：

```sh
git clone https://github.com/jasonBrom/Openwrt_BPI-R4-BE14.git
cd Openwrt_BPI-R4-BE14
JOBS="$(nproc)" ./scripts/bpi-r4/build.sh
```

脚本只接受 `feeds.conf.default`，会在安装锁定 feeds 后验证每个 checkout 的精确提交和干净状态；随后复制 `configs/bpi-r4-be14.config`、执行 `make defconfig`，并断言唯一启用的 Filogic 设备是非 PoE `bananapi_bpi-r4`。每次 make 调用都显式传入并核对固定的 `SOURCE_DATE_EPOCH`，正式编译前会删除 `bin/targets/mediatek/filogic`，避免旧产物混入校验结果。

发布构建默认要求项目 Git 工作树完全干净，执行时的 clean HEAD 就是本项目补丁、配置和自包含软件包的源码边界；不要求预先存在项目 release tag。只有开发调试时可显式放宽项目树检查：

```sh
ALLOW_DIRTY_PROJECT=1 JOBS="$(nproc)" ./scripts/bpi-r4/build.sh
```

该开关不会允许 feed 偏离固定提交或带有本地修改，脏树生成物也不应作为发布产物。也可单独运行产物校验：

```sh
./scripts/bpi-r4/verify-artifacts.sh
sha256sum -c bin/targets/mediatek/filogic/SHA256SUMS
```

校验覆盖全部 8 个设备产物、gzip 完整性、SD 镜像内各引导/恢复/生产 blob 的源码定义偏移、槽位上限，以及两个 FIT 中的 BPI-R4 基础配置和 SD/eMMC/RTC/BE14 overlays。相同哈希还依赖相同宿主工具链、文件系统语义和干净的项目提交；脚本会固定 `SOURCE_DATE_EPOCH`，但不会把不同宿主环境自动变成相同环境。

当前 `filogic.mk` 的 SD 原始镜像布局为：recovery @ 12 MiB、SPI-NAND BL2 @ 44 MiB、SPI-NAND FIP @ 45 MiB、eMMC BL2 @ 51 MiB、eMMC FIP @ 52 MiB、eMMC GPT @ 56 MiB、sysupgrade @ 64 MiB。恢复槽是 32 MiB；SPI-NAND FIP 虽到下一个对象间有 6 MiB，安装器实际只读取/创建 2 MiB，校验采用更严格的 2 MiB 上限。

## 参考

- [OpenWrt 构建系统](https://openwrt.org/docs/guide-developer/toolchain/start)
- [OpenWrt BPI-R4 设备页](https://openwrt.org/toh/sinovoip/bananapi_bpi-r4)
- [Banana Pi BPI-R4 文档](https://docs.banana-pi.org/en/BPI-R4/BananaPi_BPI-R4)
- [MediaTek OpenWrt feed](https://github.com/mediatek/mtk-openwrt-feeds)

本项目沿用 OpenWrt 的 GPL-2.0 许可；各 vendored 软件包仍适用其各自许可证。
