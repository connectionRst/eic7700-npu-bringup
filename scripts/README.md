# scripts/

多为一次性调试/构建工具，按需取用；未经清理，**不要直接用在生产环境**。

| 脚本 | 用途 |
|---|---|
| `merge_dts.py` | 把 SoC `eic7700.dtsi` 与板级 DTS 合并成可编译的 `merged.dts` |
| `dts_struct_check.py` | DTS 结构自检 |
| `build_modules.sh` / `build_npu_test.sh` | 针对 `kernel-rockos` 的模块/NPU 测试构建 |
| `make_recipe_patch.sh` | 生成 meta-riscv recipe 补丁 |
| `fetch_vendor_kernel.sh` | 拉取厂商 `linux-stable`（`linux-6.6.18-EIC7X`）参考源码 |
| `rebuild_initrd_fw.sh` | 重打包 initrd（塞入 DSP/NPU 固件与新模块） |
| `npu_boot_check.sh` / `npu-boot-check.service` | 上板开机自检（DSP/NPU 绑定状态） |
| `restore-boot-files.sh` | **救砖用**：把被改坏的 DTB / initrd / NPU 模块回滚成原厂 |
| `fix_dtb.py` | ⚠️ **反面教材** |

## ⚠️ 关于 `fix_dtb.py`

这个脚本就是造成本仓库冻结的那次事故的一部分。它有两个致命习惯：

1. 直接解码、修改并**覆盖板子的 `/boot` DTB**（没有可回滚的原子操作）；
2. 用字符串替换处理设备树，且历史上最终导致事故的那次改动是
   `sed 's/reg = <0x10>;/reg = <0x0f>;/g'` —— **全局替换**，
   把同一个地址上的**另一个设备（音频 codec）**也改了。

保留它只为说明教训：改别人的 DTB 时，请按节点精确修改，并在动 PMIC/regulator
这类会被驱动**写寄存器**的节点前，先确认地址真的对应那颗芯片。
完整分析见 `docs/90-postmortem-dtb-pmic.md`。

## 路径变量

脚本里的 `$KDIR`（主线内核树）、`$WORKSPACE`（本笔记工作区）等是占位符，
运行前请按自己的目录结构设置；这里做了打码，不含作者本机路径。
