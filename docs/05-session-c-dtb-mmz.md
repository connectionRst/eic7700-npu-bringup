# Session memo — 方案 C：最小 dtb 改动启用 ENNP NPU

给新 session 的交接备忘。背景调查见同目录 `NOTES-npu-mmz-boot-mem.md`
（结论链、证据、各方案对比），本文件是方案 C 的**实施清单**。

## 状态（2026-09-23，实施基本完成，待上板验证）

- ✅ DTS（步骤 1-3）：`merged.dtb`（workspace 根）已含 mmz 1GiB@0x440000000、
  完整 npu/llc/mbox/scu-sys-con 节点、900mV 固定 npu-supply +
  apply_npu_1G_freq；in-tree `eic7700.dtsi` + `eic7700-sbc-a1.dts` 同步完成。
- ✅ 驱动移植（步骤 4）：vendor da228da 的 ai_driver(NPU+DSP)、memory/eswin
  全套、eswin-mailbox、iommu/eswin SID/TBU 驱动 + 2 个 shim 已移植到 mainline
  7.x 并**全量编译通过**（clang 交叉，详见 `NOTES-session-c-impl.md` 的 API
  修复清单）。产物在 `board-assets/kernel/`（Image + 3 个 .ko + dtb + .config）。
- ✅ Recipe 集成：补丁 0032/0033 + defconfig 已放入
  `meta-riscv/recipes-kernel/linux/linux-eswin-ebc77-mainline/` 并接入
  linux-mainline.bb（干净套用已验证）。
- ✅ 固件（步骤 5）：`board-assets/lib-firmware/`（eic7700_die0_e31_fw、
  mcudfx/mcu_dump）；yolov3 .model 已解包到 essdk-1.10.1/es-sdk-sample-npu-runtime/。
- ⏳ 上板测试（步骤 6）：见 `BOARD-TEST-npu.md`（insmod 顺序、dmesg 期望、
  es_run_model 命令、故障对照表）。
- 开放问题的答案（本 session 已查证）：DSP **不是** NPU CNN 的硬依赖
  （dsp-avail-num 该驱动版本根本不读；DSP 模块需加载以解决符号，但无需
  DSP 节点/固件）；直接 DMA 窗口路线（无 SMMU）与 vendor 老 starpro64 dtb
  一致，可行；npu-supply 用固定 900mV + apply_npu_1G_freq（regulator core
  对不可调压 rail 只接受包含当前电压的 set_voltage 请求，已核 core.c）。

## 目标

在我们自己的 mainline dtb（`../starpro64.dts` → `../merged.dts` → `../merged.dtb`）
+ mainline kernel 上启用真实 NPU（eswin_npu 驱动 + es-sdk-npu 运行时），
跑通 `es_run_model`（yolov3/rtmpose 样例），**只加一个小型 mmz 保留区**
（512MiB–1GiB，而非 vendor 默认 6GiB）。

## 当前 dtb 状态（StarPro64，16GiB DRAM: 0x80000000..0x480000000）

已有（reserved-memory 下）：`linux,cma`(512MiB, alloc-ranges 0x80000000..0x140000000)、
`sprammemory@59000000`(4MiB no-map)、`lpcpu@a0000000`(1MiB no-map)、
`g2d_{4,8,12}GB_boundary_reserved_4k`。
**缺**：`mmz_nid_0_part_0`（NPU DRAM 池，vendor 默认 6GiB）。

`npu@51c00000` 节点目前 `status="disabled"` 且只有 reg/interrupts/resets ——
缺 clocks(12 个)、npu_mbox、spram-size、firmware-name、iommus、
operating-points-v2、npu-supply 等（对照下方官方节点）。
`llc@51c00000`（eswin,llc）、`mbox`（eswin,npu0-mailbox）节点缺失。
`smmu0`（arm,smmu-v3 @0x50c00000）在 `../sifive_eic7700.dtsi` 里存在但
`status="disabled"`。
`npu_svcc` regulator 只有 hwmon stub（`regulator@10`，mps,mpq8785）——
vendor 里 npu 供电是 900mV always-on，mainline mpq8785 驱动只暴露 hwmon，
需要 fixed-regulator 包装（参照我们 vrgmii 的做法）。

## 实施步骤

### 1. reserved-memory 加 mmz 节点

```dts
mmz_nid_0_part_0 {
	compatible = "eswin-reserve-memory";
	/* 1 GiB，DRAM 顶对齐（0x440000000..0x480000000），物理 >= 0xc0000000 */
	reg = <0x04 0x40000000 0x00 0x40000000>;
	no-map;
};
```

- 名字必须精确为 `mmz_nid_0_part_0`（用户态 libedla_runtime 写死；内核
  eswin_memblock 会把 `@addr` 后缀剥掉后按名字匹配）。
- 单 die 板子只有 nid_0；nid_1 是 EIC7702 双 die 用。
- 尺寸：先 1GiB；yolov3/rtmpose 不够再往上加（vendor 默认 6GiB，
  DeepSeek-7B 单 die 要 ≥11GiB）。地址必须落在 NPU 可达窗口内：
  老 starpro64 dtb 的 npu `dma-ranges` 物理起点是 0xc0000000（3GiB），
  vendor 惯例都是 DRAM 顶部起放。若启用 SMMU（iommus）则任意 DRAM 均可。
- 约束（eswin_memblock.c）：必须 no-map、不可 reusable；base/size 需对齐到
  `max(MAX_ORDER-1, pageblock_order)+1` 个 page（实际 2MiB 级对齐即可，
  1GiB 顶对齐没问题）。

### 2. 启用/补全 NPU 相关节点（对照官方 win2030 dtsi）

参考源文件：`npu_drv/win2030-die0-soc.dtsi`（官方 npu/llc 节点全文）、
`npu_drv/hifive-p550.dts`（board 级 reserved-memory + npu-supply 接法）、
`../VENDOR-eic7700-pine64-starpro64.dts`（本板老版本节点：phandle 值不同，
但结构一致：npu 节点 1820-1835 行、llc 节点 1837-1850、
mbox@50a40000 2323-2337）。

需要补齐（clock 名 → mainline ID 映射用 `../eic7700-clock.h` /
`../vendor_clock.h`，我们做过一轮 clock audit，方法见 `../NOTES-reset-dtb.md`）：

**npu@51c00000**（compatible 用 `eswin,npu`——与 SRCREV da228da 驱动匹配；
老 starpro64 dtb 是 `eswin,npu0`，别混）：
- clocks ×12 + clock-names：`aclk, cfg_clk, core_clk, clk_npu_llc_aclk,
  e31_core_clk, mux_u_npu_core_3mux1_gfree, mux_u_npu_llclk_3mux1_gfree,
  fixed_rate_clk_spll2_fout2, fixed_rate_clk_spll1_fout1,
  clk_clk_npu_llc_src0, clk_clk_npu_llc_src1, fixed_rate_clk_vpll_fout1`
- resets：`e31_core`（我们已有：mainline ID 65）
- `npu_mbox = <&d0_mbox2>`（mbox 节点见下）、`spram-size = <0x400000>`
- `firmware-name = "eic7700_die0_e31_fw"`（es-sdk-npu 装到 /lib/firmware）
- `iommus = <&smmu0 SID_NPU_DMA>`（若走 SMMU 路线；SID 值在 vendor
  dt-bindings interconnect/eswin,win2030.h，需搬进 mainline）
- `npu-supply`（见步骤 3）、`numa-node-id = <0>`
- `operating-points-v2`（可省：驱动在无 OPP 时有 2 档 fallback 表
  1.04G/900mV、1.5G/1050mV）
- `#size-cells = <2>`、`dma-noncoherent`

**llc@51c00000**（compatible `eswin,llc`）：
- reg 同 npu（51c00000, 400000）、clocks ×4（aclk/cfg_clk/llc_clk/core_clk）
- resets ×4（axi/cfg/core/llc，vendor group 6 bits 1,2,4,0x40 →
  mainline ID 需按我们 reset 映射规则换算：g6 b0=64? 见 vendor resets
  `<0x16 0x06 0x01 0x16 0x06 0x02 0x16 0x06 0x04 0x16 0x06 0x40>`）
- `spram-region = <&sprammemory>`（4MiB @0x59000000，llc/codacache 驱动用）
- `eswin,syscfg`、`eswin,syscrg_csr`（syscon phandles，vendor 有；
  mainline 可能没有 syscon 节点 → 需要补 scu_sys_con/syscrg syscon stub）

**mbox@50a40000**（compatible `eswin,npu0-mailbox`）：
- reg ×2（50a40000/50a50000 各 0x10000）、interrupts、clocks
  `pclk_mailbox_host`/`pclk_mailbox_device`、resets `rst`/`rst_device`、
  `#mbox-cells=<1>`、`lock-bit`、`irq-bit`（驱动从 mbox 节点读 lock/irq bit）

### 3. npu-supply regulator

vendor：npu 供电 900mV fixed、always-on（mpq8785 的某个 rail，mainline
驱动只出 hwmon）。做法参照我们的 vrgmii：root 加
`regulator-fixed`（900000/900000uV）+ npu 节点 `npu-supply` phandle。
驱动 probe 时 `devm_regulator_get(dev,"npu")` 必须成功，且会调
regulator_set_voltage（900↔1050mV）——若 fixed-regulator 不支持调压，
probe 后切频会失败；需要评估用 min==max==1050000 固定，或找真实可调
rail。

### 4. 内核驱动移植（vendor tree → 我们的 mainline）

源：`github.com/eswincomputing/linux-stable` @ da228da
（branch linux-6.6.18-EIC7X；meta-riscv recipe `linux-eswin-ebc77-dev.bb`，
里面有 build-fix patches 0001-0007，可直接参考）。
已拉到本地的文件在 `npu_drv/`（npu 驱动主文件、memory 驱动主文件、
defconfig、官方 dts 片段）。

需要的目录（整树搬 + 按 mainline API 修编译）：
- `drivers/soc/eswin/ai_driver/`（npu + dsp + common；DSP 是 NPU 的
  depends，可先只编 NPU：Kconfig `ESWIN_NPU depends on ESWIN_DSP`，
  要么一起搬 DSP，要么改 Kconfig 去掉 depends）
- `drivers/memory/eswin/`（eswin_memblock、es_buddy、es_proc、
  es_rsvmem_heap、es_mmz_vb、es_dev_buf、es_iommu_rsv、es_dma_memcp、
  es_malloc_dmabuf、codacache）
- `drivers/mailbox/eswin-mailbox`（ESWIN_MBOX）
- 依赖头：`include/dt-bindings/{memory,interconnect}/eswin-win2030-*`、
  `include/linux/es_*.h`（uapi：hetero_ioctl 等）

defconfig 增量（摘自 vendor eic7700_defconfig，行号见 `npu_drv/eic7700_defconfig`）：
```
CONFIG_ARCH_ESWIN_EIC770X_SOC_FAMILY=y
CONFIG_MEMORY=y
CONFIG_ESWIN_MBOX=y
CONFIG_ESWIN_DSP=m
CONFIG_ESWIN_NPU=m
CONFIG_ESWIN_BUS_ERROR=y
CONFIG_ESWIN_BUDDY=y
CONFIG_ESWIN_PROC=y
CONFIG_ESWIN_RSVMEM_HEAP=y
CONFIG_ESWIN_MMZ_VB=y
CONFIG_ESWIN_DEV_DMA_BUF=y
CONFIG_ESWIN_IOMMU_RSV=y
CONFIG_ESWIN_DMA_MEMCP=y
CONFIG_ESWIN_MALLOC_DMABUF=y
```
（ESWIN_MC/ESWIN_CODACACHE_CONTROLLER 在 defconfig 未显式列出：
ESWIN_MC 是 default y + depends ARCH_ESWIN…；codacache 的
ESWIN_CODACACHE_CONTROLLER 必须手动加 =y，llc 驱动靠它。）

### 5. 固件 + 用户态

- `es-sdk-npu` deb（`../essdk-1.10.1/` 是源码树；deb 在 RockOS 镜像里，
  本地 Packages 是 rockos 20251030 的）：装后得到
  `/opt/eswin/bin/es_run_model`、`/usr/lib/libedla_runtime.so*`、
  `/lib/firmware/eic7700_die0_e31_fw`、`/lib/firmware/mcudfx/mcu_dump`。
  也可以手工把 `essdk-1.10.1/es-sdk-npu/lib/firmware/*` 拷到 /lib/firmware。
- 样例模型：`essdk-1.10.1/es-sdk-sample-npu-runtime/opt/eswin/...`
  （yolov3 .model + 图片）、`es-sdk-sample-npu-rtmpose`。
- 需要 sudo（mmap /dev/npu0、/dev/mmz_vb）。

### 6. 测试与验证

1. `dmesg`：eswin_rsvmem "created mmz_nid_0_part_0 ... size 1024 MiB"；
   eswin_npu probe 成功（看 edla version 打印）；无 deferred probe。
2. `sudo /opt/eswin/bin/es_run_model -m <yolov3.model> -r 5`（路径按实际）。
3. 观察 ES_SYS_MemAlloc 失败 → 增大 mmz；观察 IOMMU/SMMU fault →
   检查 mmz 物理地址窗口。
4. /proc/eswin* procfs、debugfs（es_proc/eswin_debug_dmabuf_info）看池子状态。

## 开放问题

- mmz 最小可用尺寸（CNN 模型）未实测——已从 1GiB 起步（可按
  BOARD-TEST-npu.md 的故障对照表增减）。
- ~~SMMU 路线 vs 直接窗口~~ **已定：直接窗口**（驱动不读 iommus，直接写
  SID 寄存器；vendor 老 starpro64 dtb 同款配置；smmu0 保持 disabled）。
- ~~DSP 是否硬依赖~~ **已查证：不是**。该版驱动完全不读 dsp-avail-num；
  NPU↔DSP 胶合代码逐核判空。仅因符号依赖需加载 eic7700_dsp.ko（空闲无
  害，无 DSP 节点/固件也可）。
- ~~npu-supply 调压~~ **已定：fixed 900mV + apply_npu_1G_freq**（只跑
  1.04G 档；主核 regulator core 对不可调压 rail 只接受覆盖当前电压的
  set_voltage 请求——已核 core.c；要 1.5G 需接真实可调 mpq8785 rail）。

## 关键文件索引

- `NOTES-npu-mmz-boot-mem.md` — 完整调查（证据链、方案 a-e）
- `NOTES-session-c-impl.md` — 本 session 实施记录（决策、clock/reset 映射、
  全部 7.x API 修复清单、构建环境说明）
- `BOARD-TEST-npu.md` — 上板验证步骤（insmod 顺序、dmesg 期望、故障对照）
- `board-assets/` — 部署产物：kernel/{Image, Image.gz, 3×.ko, dtb, config}、
  lib-firmware/{eic7700_die0_e31_fw, mcudfx/mcu_dump}
- `vendor-kernel/` — vendor linux-stable @da228da 完整树（可 grep）
- `npu_drv/` — 早期拉取的 vendor 驱动源码 + defconfig + 官方 dts 片段
- `essdk-1.10.1/` — SDK 源码树（已解压部分：es-sdk-npu、escl-server 头文件、
  es-sdk-memory、es-numa-manager、sample 代码）
- `../starpro64.dts`、`../merged.dts`、`../merged.dtb` — 我们的 dtb
- `../NOTES-reset-dtb.md` — dtb bring-up 历史（reset/clock 映射方法）
- `../sifive_eic7700.dtsi` — mainline SoC dtsi（smmu0 @173 行）
- `../VENDOR-eic7700-pine64-starpro64.dts` — vendor 本板 dtb 全量
