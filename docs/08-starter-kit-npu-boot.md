# STARTER KIT — Eswin NPU boot on Pine64 StarPro64 / EBC77

> Purpose: hand-off notes so a new session can pick up the NPU enablement task
> immediately without re-deriving everything. Last updated after the MPQ8785
> PMIC root-cause was found.

## 0. One-paragraph status
- **Goal**: get the Eswin NPU (`eic7700_npu`) functional on the board.
- **What works**: the **DSP** (`eic7700_dsp`) boots & binds fine **when loaded after boot** (all 4 cores). Its boot-time autoload at ~11s times out (busy-boot race), but that's a timing issue, not a hardware one.
- **Hard blocker**: the **NPU defers** because it cannot get its supply regulator `npu`. That regulator is a channel (`npu_svcc`) of the **MPQ8785 PMIC**, and **the MPQ8785 driver fails to probe** (`probe of 2-0010 failed with error -5`, I2C errors `-121`/`EREMOTIO`). So **no regulator is registered** (only `regulator.0 = regulator-dummy`, no `of_node`).
- **Key insight for "why not fix via DT"**: the DT node `npu_svcc` is declared *correctly* — it's a PMIC child, bound by the parent `mps,mpq8785` compatible. The break is **hardware/I2C** (PMIC not responding), not a DT declaration problem. DT alone can't un-break an unresponsive PMIC.

---

## 1. Board & access
- Target: `debian@<board-ip>` (SSH key auth, no password). `sudo` needed for `insmod`, `modinfo`, `dmesg`, `/proc`, `/sys` regulator reads.
- Board: EZN-Schwitch / Pine64 StarPro64, EIC7700 SoC. 32 GiB DRAM (~24 GiB usable + mmz).
- eMMC: `mmcblk0p1` (2 GiB, `/boot`) + `mmcblk0p2` (58 GiB, rootfs).
- **initrd is Zstandard-compressed** (not gzip).
- Kernel running: **6.6.88-win2030** (rockos, boots reliably). `vermagic: 6.6.88-win2030 SMP mod_unload riscv`.
- mmz reserved region (verify each session — values have drifted in notes): `dmesg` shows `mmz_nid_0_part_0 eswin reserve memory at 0x300000000, size 6144 MiB`. `/dev/mmz_vb` exists (10,124).

---

## 2. Toolchain & source layout (all under `eswin-nntools/`)
- Cross compiler wrapper dir: `eswin-nntools/crossbin/`
  - `riscv64-linux-gnu-gcc` is a clang wrapper (`clang --target=riscv64-linux-gnu`, clang ~22).
- Kernel source we build against: **`eswin-nntools/kernel-rockos/`** = 6.6.88 vendor subset (has `Makefile` VERSION 6 PATCHLEVEL 6 SUBLEVEL 88).
  - Build cmd (from inside `kernel-rockos/`):
    ```
    make ARCH=riscv CROSS_COMPILE=../crossbin/riscv64-linux-gnu- LOCALVERSION=-win2030 -j16
    ```
  - Single in-tree module (unprefixed modinfo — the reliable path): add it to the build via `make modules` or `M=`; see §6 pitfalls.
- Vendor driver source (reference / `da228da`, branch `linux-6.6.18-EIC7X`): `eswin-nntools/npu_drv/`. The NPU/dsp sources are mirrored into `kernel-rockos/drivers/soc/eswin/ai_driver/{npu,dsp}/`.
- **Module paths**:
  - NPU: `kernel-rockos/drivers/soc/eswin/ai_driver/npu/eic7700_npu.ko`
  - DSP: `kernel-rockos/drivers/soc/eswin/ai_driver/dsp/eic7700_dsp.ko`
  - Deploy path on board: `/lib/modules/6.6.88-win2030/kernel/drivers/soc/eswin/ai_driver/<subdir>/<name>.ko`

---

## 3. The blocker, precisely (copy/paste these diagnostics)
```bash
ssh debian@<board-ip> '
echo "== NPU state =="; ls -d /sys/devices/platform/soc/51c00000.eswin-npu/driver >/dev/null 2>&1 && echo "npu BOUND" || echo "npu NOT-BOUND (deferred)"
echo "== deferred devices =="; sudo dmesg | grep -iE "deferred probe pending"
echo "== regulator devices =="; ls /sys/class/regulator/
echo "== mpq8785 probe log =="; sudo dmesg | grep -iE "mpq8785|probe of 2-0010" | tail -8
echo "== NPU supply phandle in running dtb =="; NPU=/sys/devices/platform/soc/51c00000.eswin-npu/of_node; od -An -tx4 $NPU/npu-supply
'
```
Expected (current reality): `npu NOT-BOUND`, `51c00000.eswin-npu: deferred probe pending`, only `regulator.0` (name `regulator-dummy`, no of_node), `mpq8785: probe of 2-0010 failed with error -5` with `-121` I2C errors, `npu-supply = <0x20>`.

`0x20` phandle → node `npu_svcc` (child of `mpq8785@10` on `i2c@50960000`, compatible `mps,mpq8785`), properties: `regulator-name="NPU_SVCC"`, min `0xaae60`=700mV, max `0x10c8e0`=1100mV, `regulator-always-on`. No standalone `compatible` on the channel node itself — it's bound by the parent PMIC driver.

---

## 4. DSP status (independent subsystem, mostly working)
- DSP autoload at ~11s fails: probe runs `halt/reset/release` OK, then `es_dsp_sync` (`wait_event_timeout(...,3000)`) waits for the DSP to deliver `DSP_CMD_READY`; during busy boot the DSP doesn't respond within 3s → `-ENODEV` → NOT-BOUND.
- **DSP binds cleanly when loaded after boot** (verified: all 4 cores `es_dsp@0..3` BOUND, `probe successful`, `hardware sync`). So DSP hardware/firmware are fine.
- Correct sysfs path for cores (NOT the obvious one):
  `/sys/devices/platform/soc/52280400.dsp_subsys/52280400.dsp_subsys:es_dsp@N/driver`
- Module is refcounted by NPU (`eic7700_dsp 1 eic7700_npu`) — unload NPU before DSP.
- DSP debug log level: module param `dsp_log_level` (0=off … 3=debug); also writable via `/proc/es_dsp/debug` (a digit). At default it's quiet, which hid the ready/sync messages early on.
- Options to make autoload work: raise `es_dsp_sync` timeout in `dsp_platform.c`, or load DSP later (boot-order) — see §8.

---

## 5. The NPU-driver workaround (already in source, NOT yet deployed)
In `kernel-rockos/.../npu/npu_main.c` we made the supply **optional** so the NPU can *bind* even with no PMIC regulator (workaround, not a real power fix):
- `devm_regulator_get(dev,"npu")` on `IS_ERR` → set `npu_regulator=NULL` + `dla_warning("... treating as optional")` (was previously a hard `return -EINVAL`).
- Added 4 no-op-guarded helpers `npu_reg_enable/disable/set_voltage/get_voltage(struct nvdla_device*)` that skip when the regulator is NULL/ERR, and wrapped **all** regulator call sites (17 in `npu_main.c`, 1 in `nvdla_proc.c`).
- Verified: no stray direct `regulator_(enable|disable|set_voltage|get_voltage)(nvdla_dev->npu_regulator|ndev->npu_regulator)` calls remain.
- **Effect**: with this module loaded, the NPU should stop deferring on the supply. **Caveat**: voltage control is skipped, so whether the NPU actually *runs inference* is unproven — this only unblocks binding.
- `.config` was left `CONFIG_REGULATOR_FIXED_VOLTAGE=y` (reverted — see §6).

To deploy & test the workaround:
```bash
# on board (DSP must be bound first — load it after boot, §8):
sudo rmmod eic7700_npu            # if loaded
sudo insmod <path>/eic7700_npu.ko # the rebuilt, modified module
sleep 4; ls -d /sys/devices/platform/soc/51c00000.eswin-npu/driver && echo BOUND || echo NOT-BOUND
```

---

## 6. Abandoned / wrong paths (don't redo these)
- **Building `regulator-fixed.ko` (CONFIG_REGULATOR_FIXED_VOLTAGE=m) was the WRONG fix.** The NPU supply is a `mps,mpq8785` channel, not a `regulator-fixed` node. (The workspace `starpro64.dts` *does* define an alternative fixed node `npu_svcc_fixed` @ line 110/594 — a 900mV always-on substitute — but the **running dtb uses the MPQ8785 channel**, not that node. Switching to the fixed node would be a genuine DT-level alternative, but requires rebuilding+deploying the dtb AND building regulator-fixed; see §8 option B.)
- Vendor Kbuild quirks that bit us (if you revisit module building):
  - `make M=drivers/regulator fixed.o` produced modinfo tags **prefixed with the module name** (`fixed.license=GPL`) → modpost's `get_modinfo("license")` returns NULL → `missing MODULE_LICENSE()` error. The **full `make modules`** build emits unprefixed tags and works; it also needs `auto.conf` in sync with `.config` (the `-k` flag can skip that sync and leave `fixed` out of `obj-m`).
  - `regulator-fixed` source in this tree is `drivers/regulator/fixed.c` (Makefile: `obj-$(CONFIG_REGULATOR_FIXED_VOLTAGE) += fixed.o`).

---

## 7. Two real fix directions (choose)

### A. Fix the MPQ8785 PMIC (proper fix) — RECOMMENDED FIRST
Investigate why the PMIC won't answer on I2C at probe time:
- Is the PMIC's **input power (VINA)** actually applied? A dead/untainted PMIC returns `-121` (EREMOTIO) on every read/write. Look for a GPIO/fixup regulator or reset that powers the MPQ8785 itself, and whether it's enabled before this I2C bus.
- Is address `0x10` correct for *this* board's I2C bus (`i2c@50960000` → adapter 2)? Confirm via `dtc` / other known-good probes on the same bus.
- Vendor props on the node: `eswin,regulator_default-microvolt=<0xf4240>` (600mV), `eswin,regulator_label`, `label="npu_vdd"`. The driver prints `min_uV:700000,max_uV:1100000` then errors — so it *reads* config then *fails* on register access → strong hint the chip isn't powered/acknowledging.
- Tooling: serial console on the other machine (ttyUSB0, root) is available if we need raw boot logs; ask the user how they want that surfaced.

### B. DT-level alternative: replace the channel with the fixed node
The workspace `starpro64.dts` already defines `npu_svcc_fixed` (`regulator-fixed`, 900mV, always-on, `regulator-name="npu-svcc"`) and wires `npu-supply = <&npu_svcc_fixed>`. If that dts is compiled into the deployed dtb, the regulator would come from `regulator-fixed` (no PMIC needed) — **but** requires: (1) the running dtb actually be that compiled tree, (2) `CONFIG_REGULATOR_FIXED_VOLTAGE` built/loaded. Currently the running dtb does *not* use that node.

---

## 8. Making the NPU bind end-to-end (boot order)
Regardless of A or B, the NPU needs **(1) DSP bound** and **(2) a usable supply**:
- DSP: either raise the `es_dsp_sync` timeout in `dsp_platform.c` and rebuild, or load DSP after boot (it autoloads at 11s and times out; load it later when the boot is quiet). DSP module depends-on is referenced by NPU, so unload NPU before DSP.
- Supply: Option A fixes the real rail; Option B (modified NPU driver, §5) lets it bind without one for testing.
- Then: rebuild NPU module (from `kernel-rockos/`), `scp` to board, reload NPU, confirm BOUND, then run inference (`es_run_model`) if tooling is present.

---

## 9. Notes & references in this dir
- `STARTER-KIT-npu-boot.md` — this file.
- `DSP-STATUS.md` — DSP boot/sync investigation.
- `BOARD-TEST-npu.md` — board-side test results.
- `NOTES-npu-mmz-boot-mem.md` — NPU boot memory / mmz config.
- `NOTES-npu-programming-model.md`, `NOTES-session-c-impl.md`, `session-c-dtb-mmz.md`, `session-d-cma-pool.md` — prior design/impl notes.

---

## 10. Immediate next action (recommended)
Start with **§7-A**: confirm whether MPQ8785 input power is enabled on this board. Quick first command:
```bash
ssh debian@<board-ip> '
echo "=== i2c bus2 devices present? ==="; ls /sys/bus/i2c/devices/ 2>/dev/null | grep -E "^2-"
echo "=== mpq8785 probe context ==="; sudo dmesg | grep -iE "i2c_designware 5096|mpq8785|2-0010" | head
echo "=== any fixup/gpio regulator for the pmic? ==="; find /sys/devices -iname "*mpq*" -o -iname "*npu*vdd*" 2>/dev/null | head
'
```
This tells us if the PMIC is powered/acked at all, which decides A (power/seq fix) vs B (bypass with fixed regulator).
