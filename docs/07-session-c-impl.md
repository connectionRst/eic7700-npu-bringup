# Session C implementation notes (in-progress)

Implements `session-c-dtb-mmz.md`: minimal dtb change + full NPU enablement on
our mainline dtb/kernel. See `NOTES-npu-mmz-boot-mem.md` for background.

## Decisions (this session)

1. **DMA route: direct window (no SMMU).** The da228da `eswin,npu` driver never
   reads `iommus`; it programs the SID register directly
   (`npu_dma_sid_cfg(base, WIN2030_SID_NPU_DMA)` in npu_main.c edla_probe).
   The old vendor starpro64 dtb worked with `dma-ranges` and no SMMU.
   Therefore: no `iommus` in the npu node, smmu0 stays disabled, and
   `mmz_nid_0_part_0` must sit at/above phys 0xc0000000 →
   top-aligned 1 GiB: `reg = <0x04 0x40000000 0x00 0x40000000>`
   (0x440000000..0x480000000).
2. **npu-supply: fixed regulator, 900 mV, + `apply_npu_1G_freq`.**
   Mainline mps,mpq8785 is hwmon-only; a fixed-regulator cannot change
   voltage. Checked mainline drivers/regulator/core.c
   `regulator_set_voltage_unlocked()`: for a no-change regulator the call
   succeeds only if the requested range contains the current voltage.
   With 900/900 mV + `apply_npu_1G_freq` (npu_main.c edla_probe low-freq
   path sets freq_tbl[freq_idx_1G].volt = 900000, no-OPP fallback
   1.04 GHz/900 mV) probe succeeds. 1.5 GHz tier unreachable until a real
   adjustable rail is wired — acceptable for bring-up.
3. **NPU only, no DSP** (open question in memo; es_run_model reports
   dsp-avail-num but we see the runtime error first).

## Clock / reset mapping (verified)

Vendor da228da driver `npu_dt_node_resources()` (nvdla_hw.c:874) gets these
DT clock names, all fatal: e31_core_clk, core_clk, clk_npu_llc_aclk,
cfg_clk, mux_u_npu_core_3mux1_gfree, mux_u_npu_llclk_3mux1_gfree,
fixed_rate_clk_spll2_fout2, fixed_rate_clk_spll1_fout1, clk_clk_npu_llc_src0,
clk_clk_npu_llc_src1, fixed_rate_clk_vpll_fout1. (No "aclk" lookup.)

Mainline clk-eic7700.c (in-tree, verified):
- MUX_NPU_LLCLK parents = {DIV_NPU_LLC_SRC0_DYNM, DIV_NPU_LLC_SRC1_DYNM,
  VPLL_FOUT1}; MUX_NPU_CORE parents = {SPLL1_FOUT1, VPLL_FOUT1, SPLL2_FOUT2}.
- No-OPP fallback table: tier0 (1.04G/900mV) wants llc parent = SRC0/SPLL0
  path, tier1 (1.5G/1050mV) wants VPLL_FOUT1 → all present in mainline mux
  parents, so `clk_set_parent` will succeed.
Mainline binding IDs (include/dt-bindings/clock/eswin,eic7700-clock.h):
- aclk→148 GATE_NPU_ACLK, cfg_clk→149, clk_npu_llc_aclk→150,
  core_clk→151 GATE_NPU_CLK, e31_core_clk→152 GATE_NPU_E31_CLK,
  mux_u_npu_core_3mux1_gfree→27, mux_u_npu_llclk_3mux1_gfree→26,
  fixed_rate_clk_spll2_fout2→9, fixed_rate_clk_spll1_fout1→5,
  clk_clk_npu_llc_src0→63 DIV_NPU_LLC_SRC0_DYNM,
  clk_clk_npu_llc_src1→64 DIV_NPU_LLC_SRC1_DYNM,
  fixed_rate_clk_vpll_fout1→11.
- llc node clocks: aclk 148, cfg_clk 149, llc_clk 150, core_clk 151.
- mbox@50a40000 (npu0 mailbox #4): pclk_mailbox_host 206 (GATE_MAILBOX_4),
  pclk_mailbox_device 207 (GATE_MAILBOX_5) [vendor 642/643 = MAILBOX_4/5];
  resets MBOX4=117 / MBOX5=118 [vendor g12 b4/b5]; IRQ 121 (0x79);
  lock-bit 1, irq-bit 8.
- llc resets: axi 62 / cfg 63 / core 64 / llc 68 (vendor g6 bits 1/2/4/0x40).
- npu reset: e31_core 65 (already in our dts).

spram: da228da npu driver reads `spram-region` phandle from the NPU node
itself (npu_spram_init, npu_spram.c:184) AND npu_spram_get calls
llc_user_register()/llc_spram_avail_size() (exported by the llc driver) →
the llc node/driver IS required. `spram-size = <0x400000>` also required
from the npu node (nvdla_hw.c:717).

## TODO / status

- [x] Sparse clone vendor tree (da228da68a38) into eswin-nntools/vendor-kernel/
- [x] DTS: mmz node, npu/llc/mbox nodes, npu-supply regulator, syscon stubs
      (starpro64.dts / eic7700.dtsi), regenerate merged.dts, dtc check
      → merged.dtb rebuilt 2026-09-22; in-tree eic7700.dtsi + eic7700-sbc-a1.dts
      (EBC77 board = our StarPro64; machine conf KERNEL_DEVICETREE) also done.
- [~] Driver port in $KDIR (branch npu-port-c,
      based on master 269b74c + recipe patches 0019-0031 applied):
      all modules compile; full `make ARCH=riscv` in progress.
- [ ] Recipe patches 0032+ into meta-riscv linux-eswin-ebc77-mainline +
      linux-mainline.bb SRC_URI (defconfig already updated)
- [ ] Boot test on board (user side): dmesg checks, es_run_model
- [x] Firmware staged: eswin-nntools/board-assets/lib-firmware/
      (eic7700_die0_e31_fw, mcudfx/mcu_dump); yolov3 sample .model extracted
      from essdk tarball into essdk-1.10.1/es-sdk-sample-npu-runtime/
- [x] Full kernel build SUCCESS (2026-09-23): vmlinux, Image, Image.gz,
      eic7700_npu.ko, eic7700_dsp.ko, eswin-mailbox.ko, eic7700-sbc-a1.dtb.
      Staged in eswin-nntools/board-assets/kernel/ (+config-npu-port).
- [x] Recipe patches: 0032 (dts: dtsi nodes + sbc-a1 board enablement),
      0033 (drivers + headers, 182 files) in
      meta-riscv/recipes-kernel/linux/linux-eswin-ebc77-mainline/,
      wired into linux-mainline.bb SRC_URI; defconfig updated. Both
      verified to apply cleanly on the reconstructed post-0031 base.

## Mainline 7.2 API fixes applied to the ported vendor code (6.6-based)

mailbox/eswin-mailbox.c:
- platform_driver .remove int → void
memory/eswin/eswin_memblock.c:
- reserved_mem ops: rmem_eswin_setup(fdt_node, rmem) via node_init in a
  reserved_mem_ops struct (rmem->fdt_node / name-via-setup removed in 7.x)
- MAX_ORDER removed → KMALLOC_MAX_ORDER (slab.h)
memory/eswin/es_buddy/es_buddy.h:
- folio->_folio_nr_pages → folio->_nr_pages under NR_PAGES_IN_LARGE_FOLIO
memory/eswin/es_dev_buf/es_dev_buf.c:
- attach->sgt (removed in 6.14) → cache sg_table in attach->priv
- MODULE_IMPORT_NS(DMA_BUF) removed (namespace gone in 6.15+)
memory/eswin/codacache/llc_spram.c:
- CONFIG_RISCV_DIE{0,1}/INTERLEAVE_{CACHED_OFFSET,MEM_MAX_SIZE} (vendor
  arch Kconfig, absent mainline) → new ESWIN_* hex Kconfig options in
  drivers/memory/eswin/Kconfig; single-die 16GiB defaults
  (DIE0: 0x80000000 / 0x400000000; DIE1+interleave: 0).
- dma_heap_ops.allocate: u64 heap_flags, u32 fd_flags (7.x prototypes)
- .remove int → void; vmalloc.h include
memory/eswin/es_mmz_vb/mmz_vb.c:
- vendor-only arch helpers shimmed (single-die): eic770x_memory_type_t,
  arch_get_mem_node_and_type() (DRAM=flat node0, 4MiB @0x59000000=spram
  node500), _do_arch_sync_cache_all(nid) → sync_cache_all()
- vmalloc.h include; no_llseek → noop_llseek; MODULE_IMPORT_NS removed
memory/eswin/es_rsvmem_heap/*:
- include/linux/dmabuf-heap-import-helper.h copied from vendor
- _PAGE_UNCACHE (vendor riscv page flag) → defined 0 (no uncached user
  mappings on mainline) → cache-flush branch disabled
- vmalloc.h, noop_llseek
memory/eswin/es_iommu_rsv/iommu_rsv.c: MAX_ORDER → PAGE_BLOCK_MAX_ORDER
memory/eswin/es_proc/es_proc.c: strncpy → strscpy (removed in 7.x)
soc/eswin/ai_driver/npu/*:
- MODULE_IMPORT_NS in 7.2 takes a STRING: MODULE_IMPORT_NS("DMA_BUF");
  (MODULE_INFO moved to moduleparam.h and no longer stringifies the 2nd
  arg — vendor's bare-token form fails to compile). DMA_BUF export
  namespace still exists in 7.2 (drivers/dma-buf/dma-buf.c), so the
  import is required for the npu + dsp modules.
- MODULE_IMPORT_NS(DMA_BUF) removed; <linux/vmalloc.h> added
  (7.x no longer includes it indirectly)
- edla_remove int → void; of_find_device_by_node → #include <linux/of_platform.h>
- dla_buffer.c: file->f_count.counter → file_count(file)
- xt_mld (mloader): xtmld_ptr raddr → Elf32_Addr raddr (void** passed where
  Elf32_Addr* expected — vendor relied on gcc warning-only), strncpy → strscpy,
  vmalloc.h
soc/eswin/ai_driver/dsp/*:
- same vmalloc.h; del_timer → timer_delete; .remove int → void;
  of_find_device_by_node → of_platform.h; sram attach->sgt → attach->priv;
  MODULE_IMPORT_NS removed; eswin-khandle.c/.h, eswin-dsp-subsys.h, eswin_timer.h
  copied from vendor (drivers/soc/eswin/) and ESWIN_KHANDLE=y in Kconfig/Makefile
headers:
- include/linux/mailbox/eswin-mailbox.h (dup of dt-bindings one; drivers
  include it via <linux/mailbox/...>)
- include/linux/win2030_noc.h, include/linux/dmabuf-heap-import-helper.h
- include/uapi/linux/{es_vb_user.h, mmz_vb.h, dma_memcp.h, malloc_dmabuf.h}

## Open — RESOLVED this session

- **DSP is NOT needed for NPU CNN runs.** The da228da NPU driver never reads
  `dsp-avail-num`; all DSP paths in npu/dsp.c are per-core conditional
  (fd < 3 / NULL checks), and engine.c tolerates NULL dsp_dev[]. The DSP
  *module* must still be loaded (eswin_npu links against its exported
  symbols: dsp_get_dma_buf_ex, dsp_unmap_dmabuf, dsp_get_sram_iova_by_addr,
  subscribe_dsp_device...), but no dsp_subsys/es_dsp DTS nodes or DSP
  firmware are required. → keep ESWIN_DSP=m, no DSP DTS, drop
  dsp-avail-num dependency worries.
- llc driver = drivers/memory/eswin/codacache/llc_spram.c (ported ✓).
  It needs `eswin,syscfg` (scu_sys_con 2-cell) — provided; `eswin,syscrg_csr`
  is only used by llc_clk_rst_print() whose return value is IGNORED in
  probe → omitted safely (one dev_err at probe).
- devfreq no-OPP: devfreq_recommended_opp returns -ENODATA err → target()
  returns it → NPU stays at probe tier (1.04G). Matches vendor behavior.
- Vendor-only SoC symbols resolved:
  - win2030_tbu_power / win2030_dynm_sid_enable → ported
    drivers/iommu/eswin/eswin-win2030-sid.c (early_initcall stream-ID + TBU
    power manager; guard CONFIG_ARCH_ESWIN_EIC770X_SOC_FAMILY→ARCH_ESWIN).
  - get_perf_timer_cnt → shim drivers/soc/eswin/eswin_perf_timer.c
    (ktime_get_ns; vendor's timer-eswin.c is a full clocksource, not ported).
  - win2030_noc_sideband_mgr_query → shim drivers/soc/eswin/
    eswin_noc_sideband_stub.c returning 1 (idle) — exactly the vendor
    behavior when its NoC driver is uninitialized.
- Full vendor tree materialized at eswin-nntools/vendor-kernel (blobless
  clone + depth-1 fetch of da228da, sparse-checkout disabled) — greppable.
- scu_sys_con syscon node: the eswin-win2030-sid driver (early_initcall!)
  matches compatible "eswin,win2030-scu-sys-con" and requires the node to
  sit under a node named "soc" with a numa-node-id property (or NUMA off).
  Our node carries both compatibles + numa-node-id = <0>. Missing the right
  compatible would make win2030_tbu_power() fail (NPU probe would die on
  TBU power-on). Both DTS trees (workspace eic7700.dtsi + in-tree) fixed.

## Build environment notes (for repro)

- No riscv64 gcc on this host; kernel built with clang 22 via wrappers in
  eswin-nntools/crossbin/ (riscv64-linux-gnu-gcc → clang --target=
  riscv64-linux-gnu; ld → ld.lld; objcopy/ar/nm → llvm-*; strip →
  llvm-objcopy positional-output wrapper for kernel STUBCPY).
- .config: riscv defconfig + ESWIN stack options (see defconfig diff in
  recipe) + CMA/DMA_CMA/DMABUF_HEAPS{,_SYSTEM,_CMA} (vendor's
dev_mem_alloc uses dma_heap_kalloc("linux,cma"/"system"));
- `make ARCH=riscv M=...` out-of-tree does NOT work for these drivers
  (their Makefiles use $(srctree)/$(src) -I paths); use full in-tree make.
- Permission system here intermittently denies bash ops on
  $PMB_WORKDIR — retry works; the `read`/`write` tools always work.

