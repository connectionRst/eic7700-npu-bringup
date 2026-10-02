# EIC7700 / Pine64 StarPro64 主线使能 + NPU/DSP 调试笔记

面向 **ESWIN EIC7700X** SoC（Pine64 StarPro64 / SiFive HiFive Premier P550 / EBC77）
的主线 Linux 适配与 NPU（NVDLA 系）启用工程记录。内容来自一台真机的实际调试，
包括硬啃出来的时钟/复位 ID 映射、eMMC 稳定性根因、NPU 电源链路排查和一次事故复盘。

> 维护者不是芯片原厂，欢迎纠错；尤其 **90-postmortem** 那篇的结论需要更多人复核。

## ⚠️ 状态说明（先读）

本仓库的快照冻结于 **2026-09-27**。调试用的 StarPro64 在该日因一次设备树改动
（把 PMIC 的 I2C 地址用**全局 sed** 替换，顺带误伤了音频 codec 的地址）后无法正常启动，
随后彻底不上电，至今未修复。因此：

- 「已验证」只代表**当时**在真机上成立，不是永久结论；
- 板子修好后会补测，但目前**部分结论无法复现**；
- 事故本身已完整记录在 `docs/90-postmortem-dtb-pmic.md`，连排查方法一起。

图例：**✅ 真机验证过** ｜ **⚠️ 仅静态分析 / 编译或 dtbs_check 通过** ｜ **❌ 未验证 / 已失效**

## 文档

| # | 文档 | 内容 | 状态 |
|---|---|---|---|
| 00 | [bringup-log](docs/00-bringup-log.md) | 主线 EIC7700 时钟/复位/DTB 移植全过程：`dtbs_check` 违规 123→32、vendor→mainline ID 映射规则、**eMMC `hsp-sp-csr` 偏移真相** | ⚠️ 部分上板验证 |
| 01 | [npu-programming-model](docs/01-npu-programming-model.md) | NVDLA 系离线编译型 DPU 的编程/计算模型：mmz 预留池、dma-fd、手动 cache、composite/distribute(MoE) API | ⚠️ 基于 SDK 头文件/示例静态分析 |
| 02 | [npu-mmz-boot-mem](docs/02-npu-mmz-boot-mem.md) | NPU 启动内存与 mmz 保留区（`eswin-reserve-memory`）配置调查 | ⚠️ 部分验证 |
| 03 | [dsp-status](docs/03-dsp-status.md) | DSP 子系统：启动后加载可 4 核全绑；autoload 在忙启动期 3s 同步超时的时序问题 | ✅ 上板验证 |
| 04 | [board-tests](docs/04-board-tests.md) | 上板测试记录与故障对照表 | ✅ 上板测试记录 |
| 05 | [session-c-dtb-mmz](docs/05-session-c-dtb-mmz.md) | 方案 C：最小 DTB 增量 + NPU 启用设计 | ⚠️ 设计备忘 |
| 06 | [session-d-cma-pool](docs/06-session-d-cma-pool.md) | 方案 D：CMA / 预留内存池路线 | ⚠️ 设计备忘 |
| 07 | [session-c-impl](docs/07-session-c-impl.md) | 方案 C 实施记录：驱动移植清单与决策 | ⚠️ 实施记录 |
| 08 | [starter-kit-npu-boot](docs/08-starter-kit-npu-boot.md) | 交接说明：NPU 卡点、DSP 现状、两条修复路线 | ⚠️ 交接快照 |
| 90 | [postmortem-dtb-pmic](docs/90-postmortem-dtb-pmic.md) | **事故复盘**：坏 DTB → PMIC 地址 → systemd 崩 → 彻底不上电的完整取证与分级恢复方案 | ✅ 基于会话/日志取证 |
| 91 | [cpu-isa-diagnosis](docs/91-cpu-isa-diagnosis.md) | EIC7700 CPU ISA 特性探测（基于 MIT 的 [ruapu](https://github.com/nihui/ruapu)） | ✅ 上板 |
| 92 | [clockreset-mapping](docs/92-clockreset-mapping.md) | vendor(group,mask) → mainline reset/clock ID 映射表 | ✅ 上板核对 |
| 93 | [references](docs/93-references.md) | 外部资料索引：SDK/镜像、上手指南、TRM、原理图、社区讨论（原 `reference.txt` + 复盘补充） | ✅ 链接核对 |

## 关键结论速览

1. **vendor 2-cell `resets = <group mask>` → mainline 1-cell ID** 的换算规则：
   mainline 驱动表 `eic7700_reset[]` 的 `(reg, bit)` 里 `reg`=vendor group、`bit`=vendor mask
   的置位下标；逐个核对见文档 00 与 92。
2. **eMMC/SDIO "Internal clock never stabilised" 的真根因不是时钟树，而是
   `eswin,hsp-sp-csr` 的两个偏移写错了**：MSHC n 的正确偏移是 `0x508/0x608/0x708`
   （`INT_CLK_STABLE` 握手），写成 `0x1038/0x1040` 会导致锁字写到错误寄存器、控制器
   永远不产生 SDCLK。SD 卡/HSP 上的同类问题都值得按这个模式查。
3. **NPU 拿不到电源不是 DT 写错**：`npu-supply` 指向 MPQ8785 PMIC 的 `npu_svcc` 通道，
   而该 PMIC 在 DT 给的地址上不应答（`-121 EREMOTEIO`）→ 驱动 probe 失败 → 无 regulator
   → NPU defer。DT 修不了一颗不应答的芯片。
4. **修 NPU 供电的两条路**：① 查 PMIC 为何不应答（供电/I2C 地址）；② DT 层换成
   `regulator-fixed` 900 mV 常开（工作区已有该节点），但需重编/部署 DTB。
5. **NPU 侧有三个硬规则**：内存必须从 mmz 保留池经 `ES_SYS_MemAlloc` 分配、传给驱动的是
   dma-buf fd 而不是指针、cache 必须显式 flush/invalidate。
6. **事故教训**：改别人的 DTB 时**绝不要用全局 sed 替换 `reg = <...>`**——同一个数值
   往往有多个设备在用（本例 `0x10` 同时属于 PMIC 和音频 codec），一处"想改的"会连带
   改掉另一处；而且 PMIC 驱动 probe 时会**写**电压寄存器，改错地址等于把电压写到别的
   芯片上。正确做法见文档 00 与 90。

## 仓库结构

```
docs/      工程笔记与复盘（本仓库主体）
scripts/   调试/构建/恢复脚本（多为一次性工具，按需取用）
patches/   主线化补丁与 meta-riscv 本地改动
```

`scripts/fix_dtb.py` 是**造成事故的那个脚本**，保留它是因为它有教育意义——
**不要在生产板子上照抄**，见 `scripts/README.md`。

原文档名到本仓库路径的映射：

| 原路径 | 本仓库 |
|---|---|
| `NOTES-reset-dtb.md` | `docs/00-bringup-log.md` |
| `eswin-nntools/NOTES-npu-programming-model.md` | `docs/01-npu-programming-model.md` |
| `eswin-nntools/NOTES-npu-mmz-boot-mem.md` | `docs/02-npu-mmz-boot-mem.md` |
| `eswin-nntools/DSP-STATUS.md` | `docs/03-dsp-status.md` |
| `eswin-nntools/BOARD-TEST-npu.md` | `docs/04-board-tests.md` |
| `eswin-nntools/session-c-dtb-mmz.md` | `docs/05-session-c-dtb-mmz.md` |
| `eswin-nntools/session-d-cma-pool.md` | `docs/06-session-d-cma-pool.md` |
| `eswin-nntools/NOTES-session-c-impl.md` | `docs/07-session-c-impl.md` |
| `eswin-nntools/STARTER-KIT-npu-boot.md` | `docs/08-starter-kit-npu-boot.md` |
| `eswin-nntools/BOARD-DAMAGE-REPORT.md` | `docs/90-postmortem-dtb-pmic.md` |
| `eswin-nntools/board-scripts/restore-boot-files.sh` | `scripts/restore-boot-files.sh` |
| `eswin-nntools/reference.txt` | `docs/93-references.md` |

## 复现前提

- 硬件：Pine64 StarPro64（或 EIC7700 EVB / P550）＋ USB-UART（CH340/CP2102，3V3）
  接 UART0，115200 8N1；供电 DC 12 V / 3–5 A，5.5/2.1 mm 中心正极。
- 内核树：主线 + 本仓库 `patches/`（`linux-master` 分支 `npu-port-c` 为当时工作树）。
  厂商参考：<https://github.com/eswincomputing/linux-stable>（branch `linux-6.6.18-EIC7X`）。
- 工具链：宿主 `dtc` + `dtschema`（`pip install dtschema`）跑 `make dtbs_check`；
  交叉编译按各脚本里的 `CROSS_COMPILE`。
- RockOS 镜像/固件：见 [PINE64 官方镜像](https://fast-mirror.isrc.ac.cn/rockos/images/generic/latest/)。

## 许可

分许可，详见 [`LICENSE`](LICENSE)：

- `docs/`：CC BY 4.0
- `patches/`：GPL-2.0（**保留各文件头部的 SPDX 与 ESWIN 版权声明，勿删**）
- `scripts/`：MIT（作者自有脚本）

本仓库**不包含**任何厂商 SDK 包、固件二进制、内核 deb 或模型文件——需要请走官方渠道。

## 纠错

板子已损坏，很多细节暂时无法复现；如果你在同样的板子上得到不同结果，
欢迎开 issue 把 `dmesg` / `dtc` 输出贴上来。
