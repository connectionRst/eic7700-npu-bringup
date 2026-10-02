# 外部资料索引

> 整理自工作区 `eswin-nntools/reference.txt`（原文照录在 A–C 节，括号内为作者当时的备注），
> D 节是本次复盘补充的、写 `docs/90-postmortem-dtb-pmic.md` 时用到过的链接。
> 本仓库不附带任何厂商 SDK / 固件 / 预编译包，需要请走下面这些官方渠道。

## A. SDK、镜像与包索引

| 链接 | 说明（原文备注） |
|---|---|
| <https://mirror.iscas.ac.cn/rockos/20251030/rockos-gles/dists/rockos-gles/main/binary-riscv64/Packages> | where packages is downloaded |
| <https://mirror.iscas.ac.cn/rockos/nn_tools/EIC7x_Release_20250130/> | where npu sdk is downloaded, a mirror of the archive below |
| <https://pine64.org/documentation/StarPro64/_full/> | contains bare npu sdk & model examples, if the local files is missing check this |
| <https://fast-mirror.isrc.ac.cn/rockos/images/generic/latest/> | RockOS 最新镜像（bootloader / boot / root ext4）← D 节补充 |

## B. 上手指南与手册

| 链接 | 说明（原文备注） |
|---|---|
| <https://github.com/milk-v/milkv.io/blob/main/docs/megrez/development-guide/ENNP-SDK/es_run_model.md> | some user guides（作者偏好这份） |
| <https://github.com/eswincomputing/ebc7700-sbc-ubuntu/blob/main/documents/ENNP_User_Manual_EN_v1.3.pdf> | another user guide, in PDF, i prefer milkv one rather than this |
| <https://github.com/DC-DeepComputing/Framework/blob/main/FML13V03/DC-ROMA%20RISC-V%20AI%20PC%20Install%20AI%20Models(Deepseek-7B)%20Guide.md> | quickstart guide, useless before can access the device |

## C. 社区讨论

| 链接 | 说明（原文备注） |
|---|---|
| <https://forums.sifive.com/t/npu-tutorials-and-workflow-for-p550-eswin-som/7675> | discourse discussion about the npu docs, may not accessible without browser as discourse is CSR? |

## D. 本次复盘补充（硬件 / 社区 / 源码）

| 链接 | 用途 |
|---|---|
| <https://wiki.pine64.org/wiki/STARPro64> | StarPro64 板级信息：12 V/3–5 A 供电、16 MB XSPI NOR、eMMC/microSD、boot DIP 开关语义 |
| <https://nuttx.apache.org/docs/latest/platforms/risc-v/eic7700x/boards/starpro64/index.html> | 串口接法（UART0 = 排针 Pin 6/8/10，115200）与从 U-Boot 引导第三方镜像 |
| <https://lupyuen.github.io/articles/starpro64> | 上手实录：OpenSBI/U-Boot 启动日志、从 USB 刷 eMMC、`es_burn write … flash`、**过热会写坏 SPI flash** 的警告 |
| <https://files.pine64.org/doc/starpro64/StarPro64_schematic_v2.0-20250310.pdf> | StarPro64 v2.0 原理图（查供电链路 / LED / 保险丝用） |
| <https://files.pine64.org/doc/starpro64/StarPro64_v2.0_Component_Placement_Top-20250310.pdf> | 元件位置图（顶层） |
| <https://github.com/eswincomputing/EIC7700X-SoC-Technical-Reference-Manual> | EIC7700X SoC TRM（Part 1–4，PLIC / 内存映射 / UART / 外设寄存器） |
| <https://github.com/eswincomputing/linux-stable> | 厂商内核（branch `linux-6.6.18-EIC7X`），NPU/DSP/mailbox/iommu 驱动参考源码的公开位置 |
| <https://github.com/eswincomputing/eic7x-images> | 厂商 Debian 镜像与刷写手册（`Development_board_image_installation_and_upgrade_manual.pdf`） |
| <https://github.com/riscv/meta-riscv> | Yocto 层；`linux-eswin-ebc77-mainline` recipe 是 `patches/0032/0033` 的投稿目标 |

## 备注

- 部分链接（Discourse、PINE64 文档站）在无浏览器的纯 HTTP 抓取下可能失败或返回裁剪内容，
  属于站点侧限制，不代表链接失效。
- 链接如已失效，欢迎开 issue 告知，或直接提 PR 更新本文件。
