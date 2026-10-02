# DSP probe 根因(精确定位) — 2025-09-26

## 固件时序问题:已解决
- defer 修复 + initrd 预装固件 → DSP autoload 时 firmware ENOENT 7→0。
- 11.3s autoload: firmware 正常加载(dsp_request_firmware ret 0)。

## 真正的卡点:DSP 不 boot,不回 DSP_CMD_READY
探针流程(全成功):
  es_dsp_clk_enable(ret 0) → win2030_tbu_power(true, ret 0) →
  es_dsp_hw_init(ret 0) → dsp_boot_firmware(halt0/reset0/release0) →
  dsp_request_firmware(固件已就位) → dsp_release →
  dsp_synchronize → es_dsp_sync(wait_event_timeout 3s 等 dsp->off!=true)

es_dsp_sync 等的是 DSP 固件启动后 mailbox 回的 DSP_CMD_READY
(irq handler: msg->return_value==DSP_CMD_READY → dsp->off=false → wake_up)。
DSP 3s 内没发 ready → 超时返回 -ENODEV → 探针失败 → 4 核 NOT-BOUND → NPU 也 defer。

## DSP 已具备 boot 条件却不启动,可能原因(需串口/厂商文档判定):
1. DSP 的 SMMU/IOMMU 固件映射错 → DSP 取到脏指令(日志:device is behind an iommu)。
2. 固件交付(dsp_load_firmware)后的 boot 触发 DSP 硬件未响应。
3. DSP 固件版本/内容与 StarPro64 这块 die 不匹配。
4. 需要 mcu_dump(mcudfx) 前置两段式 boot,板上 mcudfx/ 空目录。
5. DSP 硬件在该板实际不可用/未上电到位。

电源域 D0_DSP1/2/3 在 1.79s 已是 power on → 电源 OK。
