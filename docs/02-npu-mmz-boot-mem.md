# ENNP (Eswin NPU) — can it run without touching boot memory config?

Investigation date: 2026-09-22. (This file lives in eswin-nntools/; new artifacts
belong there — see AGENTS.md.) Sources: local essdk-1.10.1/ + rockos/nn_tools/
(sibling dirs), vendor kernel `eswincomputing/linux-stable` @ da228da
(branch linux-6.6.18-EIC7X, SRCREV from meta-riscv linux-eswin-ebc77-dev.bb),
web (milkv community, DC-ROMA guide, pine64, sifive forum).

## Question
Does the NPU work on the board without modifying the boot-time memory
configuration (i.e. without adding the vendor's reserved-memory nodes to our
mainline dtb)?

## Verdict
**No — not with the unmodified vendor stack. The runtime hard-depends on a
boot-time reserved-memory node named `mmz_nid_0_part_0` (per die).** But the
carve-out is flexible (size/location), and there are lower-cost alternatives
(U-Boot fdt env, CMA-backed driver patch, x86 simulator).

## Evidence chain (why mmz is mandatory on real HW)

1. User-space runtime `libedla_runtime.so` (es-sdk-npu) hardcodes memblock
   names — `strings` shows `esAllocDmaBufMem` adjacent to
   `mmz_nid_0_part_0` / `mmz_nid_1_part_0` (die selected by `es_run_model -d`).
   Also `libes_memory.so` (es-sdk-memory) uses `/dev/mmz_vb` and
   `/dev/dma_heap`, same names + `secure_memory_nid_*`. `es_run_model --help`
   prints `open_mmz_vb_dev: open /dev/mmz_vb failed!` (milkv doc shows this).
2. Kernel `drivers/memory/eswin/eswin_memblock.c`: registers a `mem_block`
   ONLY for DT nodes with `compatible = "eswin-reserve-memory"` that are
   `no-map` and NOT `reusable` (rmem_eswin_setup returns -EINVAL otherwise).
   Registration is boot-time (`RESERVEDMEM_OF_DECLARE`, of_reserved_mem early
   parse). Node name is stored with the `@address` suffix stripped
   (`mmz_nid_0_part_0@1c,0000000` → `mmz_nid_0_part_0`), matching the runtime
   string. Post-boot DT overlays do NOT re-run reserved-mem parsing → the
   node cannot be added at runtime.
3. `drivers/memory/eswin/es_mmz_vb/mmz_vb.c`: pools are built per named
   memblock (`vb_get_memblock(pool_cfg->mmzName)`; "%s NOT found!" if absent),
   pages come from a fixed buddy-allocated region of that memblock
   (es_buddy). So the region must be statically reserved at boot.
4. NPU driver (`drivers/soc/eswin/ai_driver/npu/`, CONFIG_ESWIN_NPU=m,
   matches `eswin,npu`): in HW mode (NPU_DEV_SIM=0) it does not allocate DRAM
   itself — user space passes dmabuf fds (dla_import_dmabuf_from_model).
   Probe requires: `npu` regulator (npu-supply, fatal if missing), IO resource,
   12 clocks (from npu_dt_node_resources / llc node), reset e31_core,
   mailbox node (npu_mbox, lock-bit/irq-bit), `firmware-name`
   (official win2030 dtsi: `"eic7700_die0_e31_fw"` → request_firmware;
   es-sdk-npu deb installs `lib/firmware/eic7700_die0_e31_fw` via
   `es-sdk-npu/* /`), `spram-region` phandle (llc node → 4 MB SRAM no-map at
   0x59000000), `dma_coerce_mask_and_coherent(DMA_BIT_MASK(41))`,
   `npu_dma_sid_cfg` (SMMU stream id). NPU SRAM = 4 MB on-die, split as
   15/16 ways SRAM + 1/16 cache (npu_spram.c).
5. DMA window: official win2030 dtsi npu node has `iommus = <&smmu0
   WIN2030_SID_NPU_DMA>` (SMMU, mainline arm,smmu-v3 driver exists); the
   OLDER starpro64 vendor dtb npu node has no iommus but `dma-ranges =
   <0x01 0x00 0x00 0xc0000000 0x1ff 0x00>` (bus 0x1_0000_0000 → phys
   0xc0000000) → NPU-reachable DRAM starts at phys 3 GiB. Vendor always puts
   mmz at the TOP of each die's DRAM (StarPro64 16 GiB: mmz
   0x300000000..0x480000000 = top 6 GiB; DC-ROMA constraint
   "start_address + memory_size = end of die").

## Vendor default config (what a "boot memory config" means here)
From vendor dtbs (hifive-premier-p550, starpro64, megrez):
- `linux,cma` 512 MiB reusable shared-dma-pool, alloc-ranges 0x80000000..
  (already in our starpro64.dts)
- `sprammemory@59000000` 4 MB no-map (NPU SRAM; already in ours)
- `lpcpu@a0000000` 1 MB no-map (DSP/LPCPU subsystem; already in ours)
- `g2d_*_4GB_boundary_*` 3×4 KiB no-map (G2D can't cross 4G/8G/12G; in ours)
- `mmz_nid_0_part_0` 6 GiB no-map eswin-reserve-memory ← **the only missing
  node in our dtb** (dual-die boards add mmz_nid_1_part_0; StarPro64/Megrez
  single die: nid_0 only)
- kernel defconfig: ESWIN_DSP=m, ESWIN_NPU=m, ESWIN_RSVMEM_HEAP=y,
  ESWIN_MMZ_VB=y, ESWIN_DEV_DMA_BUF=y, ESWIN_IOMMU_RSV=y,
  DMABUF_HEAPS_SYSTEM/CMA=y

## Size is flexible — community data points
- 6 GiB default = sized for LLM inference (single die).
- DC-ROMA (EIC7702, dual die, 32/64 GiB): "default 6GiB insufficient for
  DeepSeek-7B; expand to ≥11GiB per die" via U-Boot:
  `setenv fdt0_cmd "fdt mmz mmz_nid_0_part_0 <start> <size>"` + prepend to
  bootcmd + saveenv (no dtb rebuild).
- MilkV community ("Disable NPU on RockOS 2025-0423", megrez): user who
  hates the 6 GiB tax shrunk mmz reg to `0x1000` (4 KiB!) in the dtb — node
  stays, NPU allocs fail, RAM freed. MilkV also ships a "nodsp" DTB asset.
- CNN-class models (yolov3-416, rtmpose — the bundled samples) use far less
  than 6 GiB; 512 MiB–1 GiB mmz is plenty for them (unverified exact figure,
  estimate from model/buffer sizes; verify with es_run_model).

## Options, ordered by cost

a. **Vendor stock as-is** — if the goal is just "NPU works": vendor
   RockOS/Ubuntu dtb already carries mmz; install es-sdk-npu debs, load
   eswin_npu/eswin_mmz_vb modules, firmware lands in /lib/firmware. Zero
   config change, but 6 GiB gone from a 16 GiB board (~9 GiB usable).

b. **U-Boot env, dtb untouched** — `fdt` commands in env create/resize the
   mmz node per boot (documented DC-ROMA + MilkV paths). Boot images
   unmodified; memory map still altered at boot. (U-Boot `fdt create/set`
   can even add a missing node without rebuilding dtb.)

c. **Minimal dtb change (pragmatic)** — add ONE node to our
   starpro64.dts:
   ```dts
   mmz_nid_0_part_0 {
       compatible = "eswin-reserve-memory";
       reg = <0x03 0x00 0x01 0x80000000>;  /* 6 GiB, top of 16 GiB */
       no-map;
   };
   ```
   Shrink reg for CNN-only use (e.g. 1 GiB top-aligned:
   reg = <0x04 0x40000000 0x00 0x40000000> → 0x440000000..0x480000000,
   still inside the NPU window ≥3 GiB).
   This is the cheapest real-NPU path on our mainline dtb. (Remember the
   separate, bigger job: enable + wire the npu/llc/mbox/smmu/firmware nodes
   and port eswin_npu + memory drivers from the vendor tree; our current
   npu node is status="disabled" with no clocks/mbox/supply.)
   → full implementation checklist: session-c-dtb-mmz.md

d. **Truly no boot-memory change — patch the drivers** — NPU DMA goes via
   SMMU (win2030) or the ≥3 GiB direct window (starpro64), so arbitrary DRAM
   pages are mappable in principle. Port eswin_memblock.c + es_buddy +
   mmz_vb.c so the `mmz_nid_0_part_0` pool is backed by the EXISTING 512 MiB
   CMA (reusable → RAM stays system-usable until NPU allocs) instead of a
   no-map block: e.g. register CMA-backed mem_blocks by name and make
   vb_blk_pages_allocate use cma_alloc() (full design:
   session-d-cma-pool.md; prerequisite: option c works). Gotchas: CMA alloc-ranges must stay
   inside the NPU-reachable window (≥ 0xc0000000 on starpro64 dtb; our CMA
   is 0x80000000..0x140000000 → nudge), cache-coherency (ES_SYS_MemFlushCache
   already exists in the stack), 4K-aligned buddy orders. Drivers are GPL
   (eswincomputing/linux-stable) so patchable. Effort: ~hundreds of lines,
   then iterate on HW. 512 MiB CMA fits CNN models, not 7B LLMs (would need
   growing CMA → back to a dtb memory change).

e. **No board at all — simulation** — rockos/nn_tools has esquant/esaac/
   esimulator x86 docker images (EIC7x_Release_20250130); model
   quantization/compile/simulation runs on x86 CPU (kernel sim path
   nvdla_sim.c + `dev_mem_alloc` marked "only for x86 emulation", uses a
   CMA named "reserved"). The in-tree NPU_DEV_SIM=1 build for RISC-V looks
   incomplete (edla_probe still wants npu regulator + freq table; sim
   dt_node_resources is a no-op → clk fields NULL → npu_set_freq_req fails).
   Sim is for dev workflow, not 20 TOPS acceleration.

## Next (implementation memos, this directory)

- `session-c-dtb-mmz.md` — option c: small no-map mmz node + full NPU
  enablement on our mainline dtb (DTS checklist, defconfig, firmware, tests).
- `session-d-cma-pool.md` — option d: CMA-backed mmz pool (zero new
  reserved region); design + risk list; do after c is verified.

## Open questions / TODO
- Exact mmz size needed by the bundled yolov3/rtmpose models (run
  es_run_model with a small mmz and read ES_SYS_MemAlloc failures).
- Whether starpro64 (no SMMU on npu node in old dtb) truly requires mmz ≥
  0xc0000000, or whether the SMMU (mainline smmu0 in sifive dtsi) removes the
  restriction when we wire `iommus`.
- Full DTS enablement list for our tree (npu clocks names, llc node,
  mbox node, npu-supply regulator, smmu iommus, firmware-name).
- Porting: eswin_npu + eswin memory drivers onto our mainline kernel
  (meta-riscv linux-eswin-ebc77-dev recipe has build-fix patches 0001-0007).

## 2026-09-26：7.2 移植内核重新构建成功（里程碑）

- 丢失的 pmb-workdir（npu-port-c 树）已无法访问；base `269b74c50` 已从
  原 fork 重新 clone 到 `eswin-nntools/linux-master/`（= torvalds 7.2.0，
  HEAD 269b74c50，clean，自带 arch/riscv/boot/dts/eswin/ 三文件）。
- 重建移植：recipe patch `0018–0033`（来自
  meta-riscv/linux-eswin-ebc77-mainline/）+ `0015`（生成
  include/dt-bindings/riscv/physical-memory.h，dts 编译必需）。
  - 注意：`0001–0017` riscv mm/pte 回移植**不需要**——269b74c50 上游已自带
    （0002/0010/0011/0016 因与上游重复而 conflict，跳过正确）。
  - `0032`（NPU/LLC/mbox dts 节点）需用 `git apply --3way` 或先手补 Makefile
    sbc-a1 行，否则 "already exists in working directory" 残留挡重套。
- clang 22 (`eswin-nntools/crossbin/`)，`make ARCH=riscv -j16` **成功**：
  vmlinux/Image/Image.gz/System.map + 模块 eswin-mailbox/eic7700_dsp/
  eic7700_npu/llc（vermagic 全 = 7.2.0-g269b74c50885-dirty）。
- 部署包：`eswin-nntools/deploy-7.2/`（kernel/ Image-7.2 + eic7700-sbc-a1-7.2.dtb；
  modules/*.ko；firmware/ eic7700_die0_e31_fw + die1 + dsp_fw）。
- 板子 boot 待办：复用 rockos initrd + eMMC rootfs，只换 Image + dtb，booti；
  固件拷 /lib/firmware/；加载顺序 eswin-mailbox → eic7700_dsp → llc → eic7700_npu；
  然后 es_run_model 测试。
