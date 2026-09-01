# Source inventory

构建入口固定在 OpenWrt 25.12 基线；可执行机器可读值见 `build-meta/versions.env`。`feeds.conf.default` 中每个 feed 都使用 `^<commit>`。`scripts/bpi-r4/build.sh` 会拒绝本地 `feeds.conf` 覆盖，并在 update/install 后逐一确认 packages、LuCI、routing、telephony、video 和 MediaTek checkout 的 HEAD 等于声明提交且工作树干净。

## Project source boundary

OpenWrt 基线、feeds、内核归档和关键平台组件由下表及 `versions.env` 固定；本项目自身的补丁、配置、默认值和 `package/custom/` 则以执行构建时的**干净项目 Git HEAD** 为来源边界。这里不要求一个在首次项目提交前不可能存在的 release tag，也不虚构项目 tag/commit pin。完成首次项目提交后，该提交自然成为构建时记录的项目边界。

发布构建默认拒绝暂存、未暂存和未跟踪的项目文件。仅开发调试可显式使用 `ALLOW_DIRTY_PROJECT=1`；这不会放宽任何 feed 的 commit/clean 校验，且生成结果不能宣称为发布级可复现构建。

## Pinned repositories

| 组件 | 仓库 | 固定提交 |
| --- | --- | --- |
| OpenWrt 25.12 | <https://github.com/openwrt/openwrt> | `b6a820ea85d268ecbe55c0f803c8b2dbb811c8aa` |
| packages feed | <https://git.openwrt.org/feed/packages.git> | `3f6b95b5158040c8b0ef3e7d5e456589344694d5` |
| LuCI feed | <https://git.openwrt.org/project/luci.git> | `e60322bbe30d0fe4ceb43947252b028b109fede2` |
| routing feed | <https://git.openwrt.org/feed/routing.git> | `fa7256774a99af347c67cda938db2bb4265994e5` |
| telephony feed | <https://git.openwrt.org/feed/telephony.git> | `2618106d5846a4a542fdf5809f0d3ed228ce439b` |
| video feed | <https://github.com/openwrt/video> | `094bf58da6682f895255a35a84349a79dab4bf95` |
| MediaTek feed（`feed/` 子目录） | <https://github.com/mediatek/mtk-openwrt-feeds> | `a2b4bfee1e59650d3708468b8622d3969b5940f4` |

## Key platform archives

| 组件 | 版本/提交 | 构建校验值 |
| --- | --- | --- |
| Linux | `6.12.103` | SHA-256 `f143aaade8877ba5616e788b4482576db28481bcf557ef537f4fcc3938fc3176` |
| U-Boot MediaTek | `2025.10` | SHA-256 `b4f032848e56cc8f213ad59f9132c084dbbb632bc29176d024e58220e0efdf4a` |
| ARM Trusted Firmware MediaTek | `78a0dfd927bb00ce973a1f8eb4079df0f755887a` | mirror SHA-256 `72a5f3f00f9e368226bb779dc098aac6195a312b48cc22172987d494ccd135d1` |
| backports/mac80211 | `6.18.7` | SHA-256 `623e5cf46ca8e81fd413f4f465e2580a0143e24929f9c22ce1ba7c34f2872989` |
| mt76 | `9f95baf93a070692ed922a2fc57ef8bfde801c84` | mirror SHA-256 `eaca371ec6f8d0f089d098a3f7fc8c5819aea090e05f4f3d9e8a9b2a2d4f2ff8` |
| hostapd | `53d12cd44da765ee446b2834aad92e9670319f8c` | mirror SHA-256 `1a390746ee3c9233622a892e072467a0f6d0aac31d11d71c8cad1c03304ab46a` |

为兼容容器/受管文件系统中的归档属主，`rules.mk` 固定使用 `TAR_OPTIONS:=--no-same-owner -xf -`。构建脚本默认导出 `FORCE_UNSAFE_CONFIGURE=1` 以允许明确要求的 root 容器构建；在普通用户环境可显式覆盖该变量。

hostapd 的固定提交尚未进入 `sources.openwrt.org`；表中 mirror hash 是 OpenWrt host tool 的 zstd 1.5.7 对该提交归档所得，必须与同一归档流程配套使用。

本仓库已经保存并审阅所需的 MediaTek 平台集成；标准构建只安装固定 MediaTek checkout 的 `feed/` 子目录，故意不执行上游 `prepare_sdk.sh`。后者会再次改写核心源码和其他 feed，不能混入上述固定构建流程。即使 `feeds/mtk_openwrt_feed` 是指向外部 checkout 的符号链接，构建入口也会对其解析到的整个 Git 工作树执行同样的精确提交和 clean 检查。

## Vendored/custom packages

`package/custom/` 的内容随本项目源码提交保存；因此其可复现边界是**本项目提交本身**，下面的版本和链接是 Makefile/随包文档可确认的来源线索，并不表示所有目录都能从对应上游 tag 无损重建。

| 本地组件 | 本地版本 | 可确认的上游/来源线索 |
| --- | --- | --- |
| `luci-app-openclash` | `0.47.156` | <https://github.com/vernesong/OpenClash> |
| `luci-theme-argon` | `2.4.5` | <https://github.com/jerrykuku/luci-theme-argon> |
| `luci-app-argon-config` | `1.1` | <https://github.com/jerrykuku/luci-app-argon-config> |
| `speedtest-x-go` / LuCI | `1.0.2` / `1.0.3` | Makefile URL：<https://github.com/MortyFx/speedtest-x>；本仓库内为自包含 Go 实现 |
| `qmodem` / QModem LuCI | `3.2.0` | vendored 源码；当前 Makefile 未声明统一的远端提交，且 package release 由顶层 Git 历史动态计算 |
| `qfirehose` | `1.4.21` | Makefile URL：<https://github.com/nippynetworks/qfirehose> |
| `sms-tool_q` | 随 QModem `3.2.0` | Makefile URL：<https://github.com/obsy/sms_tool> |
| `ndisc6`（可选，当前配置不选） | `1.0.2` | Makefile source URL：<http://www.remlab.net/files/ndisc6>，仅有弱校验 MD5 `50cb4c19606ff2b7388e71832f579`，没有 SHA-256 |
| `mt5700-web-go` / LuCI | `1.3.0` / `1.2.0` | 后端为本项目自包含源码；modern UI 来自 <https://github.com/inotdream/mt5700webui-openwrt-server> 的 `feat/go-backend`，commit `f0223e619d24a5b4dff41f2db894e96f8c62ed65`（2026-08-28 构建后另有本地兼容修改） |
| `bpi-r4-be14-defaults` | `1.0.0` | 本项目自包含源码，无外部下载 |
| `luci-app-wan-speedtest` | `1.0.0` | 本项目自包含 LuCI；运行时使用 packages feed 的 `librespeed-cli` |

OpenClash 源码仅作为可选包保留，生产配置明确不选入；其代理核心、规则和用户订阅也不属于构建输入。原因是其高权限更新流程仍依赖不安全的固定临时路径，不满足本固件的发布安全边界。其默认下载端点还包含浮动分支、`latest` 和 `Pre-Alpha` 引用，不能视为本文固定来源的一部分。

已知版本标识差异：`speedtest-x-go` 的包版本为 `1.0.2`，当前程序内建版本字符串仍为 `1.0.0`；判断构建输入时以 Makefile/项目提交为准。
