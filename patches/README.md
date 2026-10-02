# patches/

| 文件 | 内容 | 规模 | 许可 |
|---|---|---|---|
| `0032-riscv-dts-eswin-add-NPU-LLC-mbox-nodes-and-EBC77-board.patch` | DTS：新增 NPU / LLC / mailbox 节点 + EBC77（StarPro64）板级文件 | 220 行 | `GPL-2.0 OR MIT` |
| `0033-soc-memory-mailbox-iommu-add-Eswin-NPU-LLC-DSP-drivers.patch` | 驱动：mailbox / memory(rsvmem,memblock) / iommu(win2030-sid) / soc 移植 | 62 552 行 | `GPL-2.0` |
| `meta-riscv-local.diff` | meta-riscv 本地改动：`linux-mainline.bb` 的 SRC_URI +2 行、`hifive-premier-p550_defconfig` +15 行 | 1.8 KB | 随 meta-riscv（MIT） |

## 来源

两个 `0032/0033` 是准备提交到 meta-riscv 的 `linux-eswin-ebc77-mainline` 补丁队列的
候选补丁，用于在**主线内核**上启用 EIC7700 的 NPU/LLC/MBX/DSP。驱动部分由厂商
`linux-stable`（branch `linux-6.6.18-EIC7X`，公开）移植而来。

## checkpatch 现状

用 `linux-master/scripts/checkpatch.pl --no-tree --terse --no-signoff` 实测：

| 补丁 | errors | warnings | 结论 |
|---|---|---|---|
| 0032 | **1**（`code indent should use tabs`） | 11 | 修掉缩进基本可提上游 |
| 0033 | **1286** | 5781 | 仅适合做**下游**可用补丁；离上游化很远，建议按驱动逐个重做 |

## 注意

- 再分发/上游化时**不要删除**文件头的 SPDX 与 ESWIN 版权声明。
- 上游提交需要版权方的 `Signed-off-by`；建议先作为下游补丁队列/fork 发布。
- 这些补丁在板子损坏前**未完成真机回归**，请自行评估。
