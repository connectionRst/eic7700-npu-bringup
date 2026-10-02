# EIC7700 StarPro64 merged.dtb — reset/clock verification notes

Continuation of session "i2c_designware 50960000.i2c: error -EINVAL: failed to acquire reset".

## Context
- Vendor DTS (VENDOR-eic7700-pine64-starpro64.dts, 2-cell resets `<group,mask>`)
  converted to mainline 1-cell reset IDs + 1-cell clock IDs.
- Files: eic7700.dtsi (SoC), starpro64.dts (board), merge_dts.py → merged.dts → merged.dtb.
- Mainline kernel tree: $KDIR (has full eic7700 support:
  drivers/reset/reset-eic7700.c, drivers/clk/eswin/clk-eic7700.c,
  include/dt-bindings/{reset,clock}/eswin,eic7700-*.h).

## Root cause of the runtime errors (previous dtb)
1. `i2c_designware 50960000.i2c: error -EINVAL: failed to acquire reset`
   → reset-controller node had #reset-cells = 2 while consumers use 1-cell phandles;
   of_count_phandle_with_args() → -EINVAL. Fixed: #reset-cells = 1 (matches driver
   `rcdev.of_reset_n_cells = 1` and the yaml schema `const: 1`).
2. `of_clk_get_by_index: invalid index 614` → raw vendor clock index (0x266=614) for
   dma-aon; mainline clock driver uses different numbering. All clock IDs re-mapped
   and verified registered in clk-eic7700.c (previous session).
3. `sdhci-dwcmshc: failed to get core clk` → clock-names were vendor names
   ("clk_xin"/"clk_ahb"); mainline eswin,eic7700-dwcmshc expects "core"/"bus". Fixed.

## Vendor(group,mask) → mainline ID mapping rule
Mainline driver table `eic7700_reset[]` uses (reg,bit) where reg == vendor group and
bit == position of the vendor mask bit. All verified 1:1.

## Reset ID audit (2026-09-19, this session)
Verified against include/dt-bindings/reset/eswin,eic7700-reset.h:
- gmac0 50400000: 95 HSP_ETH0_ARST (g7 b26, vendor 0x4000000) OK
- gmac1 50410000: **FIXED 96 → 94** HSP_ETH1_ARST (g7 b25, vendor 0x2000000)
- dma-hsp 50430000: **FIXED 93 → 83** HSP_DMA (g7 b14, vendor 0x4000); prst 89 HSP_DMA_PRST OK
- dma-aon 518c0000: 202/203 DMA1_ARST/DMA1_HRST OK
- emmc 50450000: 92/72/88/75 (HSP_EMMC_ARST/MSHC0_PHY/HSP_EMMC_PRST/MSHC0_TXRX) OK
- sdio0 50460000: 91/73/87/76 OK
- sdio1 50470000: 90/74/86/77 OK
- i2c 50950000/50960000: 100/101 I2C0/I2C1 OK
- bootspi 51800000: **FIXED 2-cell → 199** BOOTSPI (g36 b1)
- wdt 50800000: 139 WDT0 (g17 b0) OK
- pwm 50818000: **FIXED 2-cell → 136** TIMER (g15 b0; vendor pwmrst shares this line)
- npu 51c00000: **FIXED 2-cell → 65** NPU_E31CORE (g6 b3)
- gpu 51400000: **FIXED 2-cell → 17..21** GPU_AXI/CFG/GRAY/JONES/SPU (g1 b0-4)
- pcie 54000000: **FIXED 2-cell → 97,98,99** PCIE_CFG/POWEUP/PERST (g8 b0-2)

## Other fixes (previous session, kept)
- gmac hsp property name: eswin,hsp_sp_csr → eswin,hsp-sp-csr (driver reads hyphen).

## Mainline driver cross-check (this session) — driver code is ground truth
Verified against the in-tree drivers (not just schemas):
- dwmac-eic7700.c: clock names tx/axi/cfg (3, optional bulk) — our 3-clock
  setup is driver-correct; schema example (4 clocks incl. stmmaceth, axi=186,
  cfg=171, stmmaceth=40) is newer than driver. hsp offsets per driver source
  comments: gmac0 0x100/0x108/0x118/0x114/0x11c, gmac1 0x200/0x208/0x218/
  0x214/0x21c (indices 1-3 required, 4-5 optional). Vendor hsp values
  (0x1030/0x100/0x108) were WRONG for the mainline driver → fixed.
- stmmac core (stmmac_platform.c): MAC reset looked up by name "stmmaceth"
  (STMMAC_RESOURCE_NAME) → gmac reset-names ethrst→stmmaceth (was a real
  probe-fail: named lookup with wrong name = -EINVAL even on optional get).
- dw-axi-dmac-platform.c: REQUIRES dma-channels, snps,dma-masters,
  snps,data-width, snps,block-size(n), snps,priority(n) — probe returns error
  if any missing. Both DMA nodes were missing snps,priority (aon also
  block-size) → real probe fails. Restored from vendor values.
- i2c-designware-platdrv.c: clock "pclk" + NULL (both optional); reset NULL.
  Keep clock-names "pclk" (schema wants "ref" — driver wins).
- dw_wdt.c: clock MUST be named "tclk" (devm_clk_get_enabled, not optional)
  → wdt pclk→tclk (real probe fail otherwise). Reset NULL optional shared.
- sdhci-of-dwcmshc.c (eic7700 glue): resets positional array (no names),
  hsp = 2 fixed args (int_status, pwr_ctrl) — our values OK. No pullup
  props → enable-cmd/data-pullup removed (inert vendor props).
- pinctrl-eic7700.c: pin-based states only; eMMC/SDIO bus pins NOT in pin
  table (dedicated); LED gpios are GPIO-controller pins; rewrote rgmii0/1
  states with full pin lists + function "rgmii"; pwm → fan_pwm.
- mps,mpq8785.yaml: pmbus/hwmon only, additionalProperties:false → regulator
  props stripped to a comment (npu_svcc 900mV always-on; NPU disabled).

## dtbs_check round 1 → fixes applied (starpro64.dts / eic7700.dtsi)
- gmac0/1: hsp offsets, reset-names stmmaceth, removed id/numa-node-id/
  eswin,syscrg_csr/rst-gpios/snps,lpi_en; removed now-unused scu_sys_con
  syscon@51810000 node.
- DMA: node names → dma-controller@, #dma-cells 1, +snps,priority (12/16),
  +snps,block-size (aon 16×0x80000), reset-names dropped.
- wdt tclk; i2c reset-names dropped; mmc pullups dropped.
- leds → led-0/led-1 + labels, bogus int color + pinctrl dropped.
- rtc pcf8563: removed stray `rtc;` flag. bootspi spi-max-frequency
  3-cell → 0x0a27800 (16.9 MHz). es8388 → minimal stub.
- eic7700.dtsi: opp-table0 → opp-table; hsp_sp_csr #size-cells dropped.

## Known deliberate deviations (driver/runtime wins over schema)
- i2c clock-names "pclk" (schema: "ref") — driver reads "pclk".
- dma-channels 12/16 (schema max 8; driver supports up to 32).
- Disabled vendor nodes keep raw vendor clock indices (516..678) — remap
  before enabling.

## Build status
- Standalone dtc: merged.dtb compiles with 0 warnings.
- dt-schema (dtschema) installed via pip --user for mainline dtbs_check.
- Kernel tree: staged eic7700.dtsi (ours, upstream backed up as
  eic7700.dtsi.upstream-bak), starpro64.dts, Makefile += starpro64.dtb;
  `make ARCH=riscv defconfig ARCH_ESWIN=y` done (fresh .config, untracked).
- dtbs_check round 1: 123 violations (log: dtbs-check.log). Upstream P550
  reference board also fails (opp-table0, cache perfmon, hsp) → some issues
  are inherited upstream bugs.
- Round 2 (after driver-verified fixes): 75 violations.
- Round 3 fixes: gmac compatible += snps,dwmac-5.20 (verified SAFE: no
  driver of_match-es it; dwmac5.c is a core lib, dwmac-generic doesn't list
  5.20 — only dwmac-eic7700 matches the eswin string); gmac clocks → 4-clock
  upstream example form (186/171/40/193/194); pcie → schema/driver names
  (mstr/dbi/phy_reg/aux, resets dbi+pwr, reg elbi; PERST 99 deferred to a
  future Root Port child node per pcie-eswin.c); flash → jedec,spi-nor only
  (w25q128jw not in schema enum; driver probes JEDEC ID).
- Remaining accepted violations (documented in DTS):
  * DMA: dma-channels 12/16 > schema max 8, block-size/priority arrays >8,
    resets maxItems 1 — schema lags hardware+driver (driver supports 32 ch,
    takes all resets positionally).
  * i2c: clock-names pclk (schema ref) — driver reads "pclk".
  * ~20 vendor nodes without upstream schemas (bootspi, pwm, es8388, npu,
    gpu, video, isp, dphy, display, sata, ddr, pmu, noc, hsp syscon, root
    board compatible) + inherited SoC items (cache perfmon).
- Mainline pcie-eswin.c EXISTS (drivers/pci/controller/dwc/): expects port
  child node with perst+num-lanes+ranges; current node kept disabled until
  the port restructure is verified on hw.

## Clock ID audit (this session)
- All clock IDs in enabled nodes match mainline header defines (171,181,182,
  190-194,218,219,228,251; gmac/dma/mmc/i2c/wdt).
- DISABLED nodes still carry raw vendor indices not in mainline header
  (516,517,523-525,562-565,588,589,591,678): bootspi, gpu, pcie, display,
  pwm. Inert while disabled; must be re-mapped before enabling those nodes.

## FINAL STATUS (2026-09-19)
- dtbs_check progression: 123 → 75 → 34 → **32** violations (final log:
  dtbs-check-final.log). Standalone dtc: 0 warnings.
- Final 32, all documented/accepted:
  * DMA 8 — schema lags hw (ch>8, arrays>8, resets>1); driver supports 32
    channels and takes all resets positionally.
  * i2c 2 — clock-names pclk (driver) vs ref (schema).
  * cache perfmon 2 — inherited from upstream SoC dtsi (upstream P550 board
    fails identically).
  * 20 — vendor nodes without upstream schema (bootspi, pwm, es8388, npu,
    gpu, video×2, isp×2, dphy, display, sata, ddr×2, pmu, hsp syscon, root
    board compatible ×2) + ddr ctrl-id type quirks.
- Kernel tree cleaned: eic7700.dtsi restored, starpro64.dts/.dtb removed,
  Makefile reverted, .config removed (gitignored include/config/ + scripts
  artifacts left; regenerated on next make).
- Deliverable: **merged.dtb** (workspace) — identical to the in-tree build.

## Boot test #1 (dmesg.log, after round-3 dtb) — diagnosis
Worked: i2c0/i2c1 probe (no more -EINVAL), both dw-axi-dmac probe
(12/16 channels), all 3 sdhci probe, plic/uart/rtc-bus OK.
Failed:
1. pinctrl-eic7700 probe -EINVAL: "supply vrgmii not found" → dummy
   regulator → "Failed to get voltage from regulator". Driver reads
   vrgmii-supply, must report exactly 1.8V or 3.3V (sets RGMII MS field;
   MS_1V8=0x3, MS_3V3=0). Vendor dts used eswin,rgmiisel <.. 0x3> = 1V8
   on BOTH gmacs → board RGMII IO = 1.8V.
   → gmac0/1 stuck in deferred probe (pinctrl supplier).
2. mmc0 (emmc) + mmc2 (sdio1): "Internal clock never stabilised" /
   "Reset 0x2 never completed" loop → initramfs emergency shell (root on
   emmc). Root cause: mainline eic7700_init() (Jan-2026 fix commit,
   "fix init for AXI clock and DMA 128MB boundary") enables an "axi"
   clock: "Accessing the High-Speed registers requires the AXI clock to
   be enabled." Without it, the HSP CSR writes (INT_CLK_STABLE at
   0x1038/0x103c/0x1040) silently fail → MSHC never gets the stability
   handshake. (Also found: HSP CSR 0x510/0x610/0x710 are the MSHC
   card-clock mux/gate regs in the in-flight HSP clock driver patch —
   our voltage offsets 0x508/0x50c/0x510 are in that block, plausible.)
   → FIX: clocks += <&clk 186> (HSP_ACLK) named "axi" on all 3 mmc nodes.
3. rtc-pcf8563 -121 (EREMOTEIO): i2c0 transactions NAK — i2c0/i2c1 pins
   were never muxed (no pinctrl states existed).
   → FIX: added i2c0-grp/i2c1-grp states (i2c0_scl/sda, i2c1_scl/sda,
   function "i2c") + pinctrl-0 on both i2c nodes.
4. FIX: vrgmii regulator-fixed 1.8V node at root (no enable GPIO; rail
   is always-on) + vrgmii-supply = <&vrgmii> in &pinctrl.

## Boot test #2 pending (round-4 dtb)
Expect: pinctrl probe OK → gmac0/1 probe; mmc0/2 clock stabilises →
emmc rootfs found; rtc-pcf8563 probe OK (i2c muxed).
If mmc STILL fails: next suspects — (a) 1.8V vs 3.3V assumption is wrong
for the RGMII rail (only affects gmac, not mmc), (b) the "core" gate
(190/191/192) vs divider (58/59/60) choice for the MSHC xin — gate has
CLK_SET_RATE_PARENT so set_rate should propagate, but if xin is actually
the divider output pre-gate, switch core→58/59/60; (c) mmc1 (sdio0)
showed NO errors — if only emmc/sdio1 fail after fixes, compare their
HSP CSR offsets (0x1038/0x1040 vs 0x103c).

## Next steps (user side)
1. Boot with round-4 merged.dtb; check dmesg for the 4 items above.
2. If gmac link misbehaves: next suspects are phy-mode/PHY side (vendor
   rst-gpios removed — no mainline consumer) or the clk-inversion variant
   for gmac1 (upstream example uses it; we kept vendor behavior).
3. Future work: pcie Root Port child-node restructure (pcie-eswin.c
   expects it); re-map raw vendor clock indices (516..678) in disabled
   nodes before enabling them.

## 2026-09-19 18:37 — Official EWIN mainline emmc config (the real fix)
Found authoritative patch set in meta-riscv/linux-eswin-eic7700-mainline (EWIN +
EInfoChips, applied to mainline 6.19+ sdhci-of-dwcmshc.c):
- 0022 Add emmc node; 0030 "dts: add mmc axi clk" (Huan He, ESWIN).
Official emmc node final state:
  clocks = <&clk 190>, <&clk 171>, <&clk 186>;
  clock-names = "core", "bus", "axi";
  assigned-clocks = <&clk 190>;          <-- KEY: pre-program HSP divider
  assigned-clock-rates = <200000000>;    <-- 200 MHz
Traced driver (sdhci-of-dwcmshc.c): probe does clk_get("core")=190 + prepare;
eic7700_init enables "axi" (186) for HSP CSR handshake (INT_CLK_STABLE @0x1038).
dwcmshc_get_enable_other_clks({"axi"}). We ADD hsp-sp-csr (required by 6.19
eic7700_init: returns dev_err_probe if absent). Added assigned-clocks to emmc(190),
sdio0(191), sdio1(192). This is the missing piece vs earlier round-4 (axi only).
Core clock confirmed = 190 (GATE) per official, NOT the divider 58 (old mapping
note was wrong).

## 2026-09-19 19:05 — THE REAL FIX: wrong hsp-sp-csr offsets
User re-booted with 18:37 dtb -> STILL "internal clock never stabilised" for
emmc(mmc0,50450000) AND sdio1(mmc2,50470000). mmc1(sdio0,50460000) untested
(no card -> never clock-init'd, so not proof).

Found OFFICIAL EWIN emmc node in meta-riscv patch 0023 (Dts-changes-for-emmc-boot):
  eswin,hsp-sp-csr = <&hsp_sp_csr 0x508 0x50c>;   // INT_CLK_STABLE=0x508
  resets = <75,72,88,92> reset-names="txrx,phy,prstn,axi" (== mine: 92/72/88/75)
  assigned-clocks=<&clk190> 200M, assigned-clock-rates=200M
Official sdio0 (patch 0024) = <0x608 0x60c>. Pattern MSHC n: 0x508/0x608/0x708.
My emmc used <0x1038 0x508>, sdio1 <0x1040 0x510> -> the eic7700_init
INT_CLK_STABLE handshake UNLOCK was written to the WRONG register, so the
controller never generated SDCLK. FIXED all three:
  emmc 0x508/0x50c, sdio0 0x608/0x60c, sdio1 0x708/0x70c.
Rebuilt merged.dtb 19:05 (dtc-exit=0). ASKIING FRESH BOOT.
Still TODO if emmc boots-then-dies: emmc has no vcc/vccq-supply (mpq8785 is
hwmon-only in mainline) -> may need fixed regulator for card power.
