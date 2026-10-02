# Board bring-up procedure — Eswin NPU on mainline (session C)

Prereqs (all staged in `board-assets/`):
- `board-assets/kernel/Image` (or Image.gz) — mainline riscv kernel with the
  Eswin NPU stack built in (branch `npu-port-c` in
  $KDIR; config in `board-assets/kernel/
  config-npu-port`).
- Modules: `board-assets/kernel/{eswin-mailbox.ko, eic7700_dsp.ko,
  eic7700_npu.ko}`.
  Built-in (in vmlinux): eswin_rsvmem/mmz_vb/dev_buf/buddy/proc/iommu_rsv/
  dma_memcp/malloc_dmabuf/codacache(llc), eswin_khandle, eswin_perf_timer,
  eswin_noc_sideband_stub, eswin-win2030-sid (early initcall).
- `board-assets/kernel/eic7700-sbc-a1.dtb` — in-tree dtb, functionally
  equivalent to `../merged.dtb` (workspace root): mmz_nid_0_part_0 1 GiB
  @0x440000000, npu/llc/mbox/scu-sys-con enabled, npu_svcc 900 mV fixed
  regulator, apply_npu_1G_freq. Use whichever your U-Boot flow consumes
  (our flow has used merged.dtb).
- Firmware staged in `board-assets/lib-firmware/`:
  - eic7700_die0_e31_fw  → /lib/firmware/eic7700_die0_e31_fw
  - mcudfx/mcu_dump      → /lib/firmware/mcudfx/mcu_dump
- Userspace (on the board): `es-sdk-npu` deb from the RockOS packages, or
  copy from `essdk-1.10.1/es-sdk-npu/` (opt/eswin/bin/es_run_model,
  usr/lib/libedla_runtime.so*).
- yolov3 sample model:
  `essdk-1.10.1/es-sdk-sample-npu-runtime/opt/eswin/data/npu/yolov3/
  git_yolov3_416_mix_1x3x416x416_dyn_npu_b1.model`

## 1. Boot

Boot the board with `merged.dtb` (U-Boot) + the new Image. Load the three
modules in this order (deps first: npu needs the mbox platform device probed
and the DSP module's exported symbols):

    insmod eswin-mailbox.ko
    insmod eic7700_dsp.ko
    insmod eic7700_npu.ko

## 2. dmesg checks (expected good output)

- `eswin_rsvmem: created mmz_nid_0_part_0 eswin reserve memory at 0x440000000,
  size 1024 MiB`
- llc (codacache) probe: spram start addr 0x59000000, len 0x400000
- `Eswin NPU version: ...` and `edla version: 0x...`
- mailbox probe at 50a40000
- no deferred probe, no `-EPROBE_DEFER`

## 3. Run the model

    sudo /opt/eswin/bin/es_run_model -m .../git_yolov3_416_..._b1.model -r 5

Failure modes:
- `open /dev/mmz_vb failed` → mmz_vb module not loaded
- `mmz_nid_0_part_0 NOT found` → dtb missing the mmz node (use merged.dtb!)
- `ES_SYS_MemAlloc` failures → grow mmz (edit merged.dts + in-tree dts,
  rebuild; e.g. 2 GiB: reg = <0x04 0x20000000 0x00 0x20000000>)
- IOMMU/NoC fault on NPU DMA → mmz phys window issue (must be ≥ 0xc0000000)
- regulator set-voltage error → fixed rail can't reach 1050 mV; ensure
  apply_npu_1G_freq is in the npu node (it is)
- `failed to get <clk name>` → clock ID mismatch in dtb (see NOTES mapping)

## 4. Diagnostics

- `ls /proc/ | grep eswin` (es_proc procfs entries)
- debugfs `eswin_debug_dmabuf_info` (eswin_debug_dmabuf_info.c, built-in
  with ESWIN_RSVMEM_HEAP)
- `devfreq` governor output in dmesg (should stay at 1.04 GHz tier)
