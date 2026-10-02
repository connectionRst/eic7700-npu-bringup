# Vendor -> Mainline clock/reset mapping (ESWIN EIC7700)

Root cause of merged.dtb boot errors: the DT was written in the OLD VENDOR
(SiFive-fork) clock/reset scheme. The booted kernel runs MERGED MAINLINE
drivers. Scheme mismatch:
  - clocks: vendor IDs (>=546) vs mainline onecell IDs 0..267 (EIC7700_NR_CLKS)
  - resets: vendor 2-cell (group+bit) vs mainline 1-cell (of_reset_n_cells=1)
  - sdhci clock-names: "clk_xin"/"clk_ahb" vs "core"/"bus"/"axi"
  - sdhci prop: "eswin,hsp_sp_csr" (underscore, 1 arg) vs "eswin,hsp-sp-csr"
                (hyphen, 2 args: status + host-voltage)

Mainline headers:
  include/dt-bindings/clock/eswin,eic7700-clock.h  (IDs 0..267)
  include/dt-bindings/reset/eswin,eic7700-reset.h  (IDs 0..280, 1-cell)

## Confirmed mainline driver requirements (from ~/pmb-workdir/cache_git/linux)
- sdhci-of-dwcmshc.c eic7700_init:
    clocks "core" (REQUIRED, clk_set_rate -> must be a DIVIDER),
           "bus" (optional gate), "axi" (optional, clk_bulk_get_optional)
    resets: devm_reset_control_array_get_optional_exclusive (positional, 4)
    eswin,hsp-sp-csr 2 args: args[0]=INT_CLK_STABLE status reg,
                             args[1]=HOST_VAL_STABLE voltage reg
    eswin,drive-impedance-ohms (enum 33/40/50/66/100; used if present)
    card clock set via clk_set_rate on "core" (divider), NOT crg register
- dw-axi-dmac: clocks "core-clk" (req, enable) + "cfgr-clk" (req, enable)
    resets: devm_reset_control_array_get_exclusive (positional, 2)
- dwmac-eic7700.c: eic7700_clk_names = {"tx","axi","cfg"}; bulk_get_optional
    "tx" is rate-settable -> must be a divider
- dw-wdt: clock "tclk" (req, fallback NULL-name first clock), reset optional
- dw-i2c: clock "pclk" optional; reset optional-exclusive (but a malformed
    2-cell specifier on a 1-cell controller => -EINVAL, so must be 1-cell)

## Clock mapping (vendor # -> vendor name -> mainline ID, mainline name)
emmc   core 0x22a=554 HSP_MSHC0_CORE_CLK      -> 58   DIV_MSHC_CORE_DYNM_0
emmc   bus  0x222=546 HSP_CFG_CLK             -> 171  GATE_HSP_CFG_CLK
sdio0  core 0x22b=555 HSP_MSHC1_CORE_CLK      -> 59   DIV_MSHC_CORE_DYNM_1
sdio1  core 0x22c=556 HSP_MSHC2_CORE_CLK      -> 60   DIV_MSHC_CORE_DYNM_2
sdio0/1 extra 0x0c/0x23 -> dropped (driver does not consume)
gmac0  tx  0x228=552 ETH0_CORE_CLK           -> 56   DIV_ETH_TXCLK_DYNM_0
gmac0  axi/cfg                       -> 193  GATE_HSP_ETH0_CORE_CLK
gmac1  tx  0x229=553 ETH1_CORE_CLK           -> 57   DIV_ETH_TXCLK_DYNM_1
gmac1  axi/cfg                       -> 194  GATE_HSP_ETH1_CORE_CLK
dma-hsp core 0x2b2=690 HSP_DMA0_CLK          -> 251  GATE_HSP_DMA0_CLK
dma-hsp cfgr                              -> 171  GATE_HSP_CFG_CLK   (est.)
dma-aon core 0x266=614 AONDMA_ACLK           -> 182  GATE_AONMA_ACLK
dma-aon cfgr                              -> 181  GATE_AONMA_CFG     (est.)
wdt    pclk 0x298=664 LSP_WDT0_PCLK          -> 228  GATE_LSP_WDT0_PCLK
i2c0   pclk 0x28e=654 LSP_I2C0_PCLK          -> 218  GATE_LSP_I2C0_PCLK
i2c1   pclk 0x28f=655 LSP_I2C1_PCLK          -> 219  GATE_LSP_I2C1_PCLK

## Reset mapping (function -> mainline 1-cell ID)
emmc:   txrx=75 MSHC0_TXRX  phy=72 MSHC0_PHY  prstn=88 HSP_EMMC_PRST  axi(=arstn)=92 HSP_EMMC_ARST
sdio0:  txrx=76 MSHC1_TXRX  phy=73 MSHC1_PHY  prstn=87 HSP_SD0_PRST   axi=91  HSP_SD0_ARST
sdio1:  txrx=77 MSHC2_TXRX  phy=74 MSHC2_PHY  prstn=86 HSP_SD1_PRST   axi=90  HSP_SD1_ARST
dma-hsp: arst=93 HSP_DMA_ARST  prst=89 HSP_DMA_PRST
dma-aon: arst=202 DMA1_ARST   prst=203 DMA1_HRST
gmac0:  ethrst=95 HSP_ETH0_ARST  (ignored by dwmac driver)
gmac1:  ethrst=96 HSP_ETH1_ARST
wdt:    rst=139 WDT0
i2c0:   rst=100 I2C0
i2c1:   rst=101 I2C1

## hsp-sp-csr 2-arg values [status, host-voltage]
emmc:  <&hsp_sp_csr 0x1038 0x508>   (status 0x1038 from maintainer v1 example; voltage 0x508 est.)
sdio0: <&hsp_sp_csr 0x103c 0x50c>   (voltage inferred 0x500+4*idx)
sdio1: <&hsp_sp_csr 0x1040 0x510>   (voltage inferred - NEEDS VALIDATION)

## drive-impedance-ohms
emmc 50 (0x32), sdio0 33 (0x21), sdio1 33 (0x21)

## Files to edit
- eic7700.dtsi : #reset-cells <0x02> -> <0x01>  (reset controller node ~line 372)
- starpro64.dts: all peripheral clocks/resets above + names + props
- then regenerate: python3 merge_dts.py ; dtc -> merged.dtb

## UNFLAGGED uncertainties (need hardware validation)
- dma cfgr-clk ids (171, 181)
- gmac axi/cfg both == core gate (193/194)
- mmc hsp host-voltage offsets (0x508/0x50c/0x510)
- dma-aon core-clk 182 vs 183 (GATE_AON_ACLK)
