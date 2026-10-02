# Session memo — 方案 D：零新增保留区，把 NPU 内存池改由 CMA 支撑

## 存档 / Pivot 笔记（2026-09-26）

- **基底改为 6.6.88（kernel-rockos）开发**，不再走 7.2 整树 boot（mmc/dt/boot infra
  由另一 session 负责）。7.2 整树端口已验证可编（Image.gz/vmlinux/模块/dtb 全过），
  存在 `eswin-nntools/linux-master/` + 构建日志 `logs/build-72.log`。
- **首个 NPU 驱动特性 = 本方案 D（CMA mmz 池）**：把 vendor 固定 6GiB no-map mmz
  (`eswin-reserve-memory`) 换成可回收 CMA 后端，未占用时内存还给系统 page allocator。
- **当前阻塞（非驱动代码，归 dt session）**：6.6.88 上 DSP probe `load firmware failed
  ret=-2` (ENOENT) —— 因 dt dsp 节点 `firmware-name` 指向 `/lib/firmware` 不存在的文件，
  驱动只是照 dt 拿名，无 bug。等 dt 修好后 NPU 基底才能 load。
- **参考对照**：milkv Megrez（同 ENNP）文档有"下载改过 dtb 回收 NPU 内存"的做法，
  即方案 D 的现实范本。源码/文档 clone 于 `eswin-nntools/milkv-docs/`（github.com/milk-v/milkv.io）。
- 方案 D 原始技术细节（D1 mem_block 动态化 / dt / es_buddy 绕 buddy / mmz_vb 几乎不动）
  见下方正文，照此在 6.6.88 驱动上实现即可。

---

给新 session 的交接备忘。**前置：方案 C 先跑通**（驱动移植 + NPU 节点启用 +
真实 NPU 能跑模型），方案 D 是在 C 的基础上把 `mmz_nid_0_part_0` 这个
no-map 硬保留区换成可回收的 CMA，让系统 RAM 不被 NPU 预扣。
背景与证据链见同目录 `NOTES-npu-mmz-boot-mem.md`。

## 动机

- vendor 默认 mmz = 6GiB no-map（16GiB 板子直接少 37.5% RAM）；
  MilkV 社区已有人因这 6GB 把 mmz 缩到 4KiB 来"还我内存"。
- CMA（reusable）在未被 NPU 占用前完全可被系统 page allocator 使用 →
  "不动启动内存配置"的最接近解：dtb 里保留/复用已有的 `linux,cma`
  （我们 dtb 已有 512MiB，alloc-ranges 0x80000000..0x140000000），
  不加任何 no-map 区。
- 物理可行性依据：NPU DMA 带 SMMU（官方 win2030 dtsi：
  `iommus = <&smmu0 WIN2030_SID_NPU_DMA>`）时任意 DRAM 页可映射；
  老 starpro64 dtb 无 iommus 时走直接窗口（npu 节点 dma-ranges 物理起点
  0xc0000000）→ **CMA 的 alloc-ranges 必须整体落在 ≥0xc0000000 内**
  （我们当前 CMA 从 0x80000000 起，要上调）。

## 现状（为什么要改驱动）

vendor 栈把 "mmz" 当成**固定物理区域的静态页表**：

1. `eswin_memblock.c`（`npu_drv/eswin_memblock.c`）：
   `RESERVEDMEM_OF_DECLARE(eswin_rsvmem, "eswin-reserve-memory", rmem_eswin_setup)`
   只在 boot 时注册 `no-map && !reusable` 的节点为 `struct mem_block`
   （`kPageStart = phys_to_page(base)`、`page_num` 固定）。
   **CMA 节点（reusable）会被 rmem_eswin_setup 直接 -EINVAL 拒掉。**
2. `es_buddy/`：在 mem_block 的固定页集上建私有 buddy 分配器
   （`es_alloc_pages(memblock, order)` / `es_free_pages`）。
   页集在 fs_initcall 时整块建立（`esPagesStart`）。
3. `mmz_vb.c`（`npu_drv/mmz_vb.c`）：`/dev/mmz_vb`，
   `vb_get_memblock(pool_cfg->mmzName)` 按名字找 mem_block，
   建池时 `vb_blk_pages_allocate` 从 mem_block 里一次性抠出固定大小块。
4. `eswin_rsvmem_heap.c`：为每个 rsvmem mem_block 建同名 dma-buf heap
   （用户态 libes_memory 也走 /dev/dma_heap）。
5. 用户态运行时**写死名字** `mmz_nid_0_part_0` / `mmz_nid_1_part_0`
   （libedla_runtime.so、libes_memory.so 的 strings 证实）——名字不能改，
   只能让这个名字在 kernel 侧指向 CMA 支撑的池子。

## 设计（推荐 D1：mem_block 动态化）

**核心思路**：`mem_block` 增加 CMA 后端；名字映射 `mmz_nid_0_part_0` →
一个（可新增的、reusable 的）CMA 节点。池子创建时从 CMA 分配、销毁时归还
（归还后内存回到系统 page allocator——这是与 no-map 的本质区别）。

改动点（文件都在 `npu_drv/`，完整树在 vendor repo @da228da）：

1. **dtb**：把现有 `linux,cma` 改名/新增一个 CMA 节点：
   ```dts
   mmz_nid_0_part_0 {
       compatible = "shared-dma-pool";
       reusable;
       size = <0x0 0x20000000>;          /* 512MiB 起步 */
       alignment = <0x0 0x1000>;
       alloc-ranges = <0x0 0xc0000000 0x0 0x3c0000000>; /* 3GiB..18GiB */
   };
   ```
   注意：CMA 节点名即 dma-buf heap / cma_get_name 名字，必须与运行时
   写死的 `mmz_nid_0_part_0` 一致（eswin_memblock 剥 `@` 后缀的规则
   同样适用：节点名不要带 @ 段）。
2. **eswin_memblock.c**：
   - 新增 boot 时 CMA 后端注册：`of_node` 遍历 `shared-dma-pool` 且
     reusable 的节点（或用 `cma_for_each_area` 按名找），建
     `mem_block{ .cma = cma_get(name), .dynamic = true }`。
   - `es_alloc_pages(memblock, order)` → `cma_alloc(cma, order)`
     （返回 page* 数组首页 + 连续高阶页，sg 表从 page 构造）；
     `es_free_pages` → `cma_release`。
   - 现有固定区域路径保持（兼容 vendor 默认 mmz，两后端共存）。
3. **es_buddy**：若 buddy 层假设"页表来自固定区域"，D1 里可**绕过 buddy**：
   mem_block 带 `.ops = {alloc, free}`，CMA 后端直接用 cma_alloc(order)
   （CMA 自己解决碎片/高阶页）。固定后端继续走原 buddy。
4. **mmz_vb.c**：基本不用动（它只调 es_alloc_pages/es_free_pages +
   名字查找）——除非池子块大小 > 单次 cma_alloc 上限，则把
   `vb_blk_pages_allocate` 改成多段 order 循环（已有
   `alloc_largest_available` 结构，改数据源即可）。
5. **eswin_rsvmem_heap.c**：为 CMA 后端 mem_block 注册同名 dma-buf heap
   （或干脆不注册——用户态主路径是 /dev/mmz_vb；/dev/dma_heap 是备用）。
6. **缓存一致性**：CMA 页与普通 DRAM 相同（non-coherent PMA），
   现有 `ES_SYS_MemFlushCache` / mmz_vb flush 路径不变。

备选 **D2（改动更小、语义更脏）**：`vb_get_memblock()` 查不到
`mmz_nid_0_part_0` 时 fallback 到名为 `linux,cma` 的 CMA，把它包装成
临时 mem_block（每次 boot 固定从 CMA 抠最大连续块——退化回 no-map 行为，
只省了 dtb 改动，不推荐）。

## 风险与验证点

- **NPU 直接窗口**（若不走 SMMU）：CMA alloc-ranges 必须 ≥0xc0000000，
  且避开 vendor 注释里的 e31 firmware loader / NPU IPC 区域
  （win2030 npu-subsys-bus 注释：bus 0x80000000..0x9fffffff 预留给
  e31 loader 与 IPC，对应物理 0xa0000000..0xc0000000 一带——我们的
  CMA 从 3GiB 起放可避开）。
- **高阶连续分配失败**：CMA 512MiB 被系统长期占用后，NPU 建大池子可能
  失败（no-map 则不会）——这是 D 的代价：NPU 与系统抢内存。
  验证：跑模型前先 `echo 1 > /proc/sys/vm/drop_caches` 之类压力测试。
- **E31 固件/IPC 直接访问**：E31 核心不经 SMMU 直接摸 DRAM 的区域
  （program/emission dtim）与 mmz 数据面是否同一约束未完全确认——
  跑通 C 之后在 dmesg/性能数据里核对。
- **性能**：vendor 用独立 6GiB 区可能兼顾了 LLC 分区/带宽调优
  （npu_llc_interleave_enable 走 syscfg 0x324）；CMA 分散页可能影响
  NPU LLC 命中率——用 es_run_model `-s --save-perf` 对比。

## 实施顺序

1. （C 完成）确认 no-map mmz 跑通 yolov3 + perf 基线。
2. 拉全 vendor memory 树到本地（es_buddy/、codacache/ 等尚未全部下载，
   `npu_drv/` 只有部分文件；完整 clone：
   `git clone --depth 1 -b linux-6.6.18-EIC7X --filter=blob:none` 后
   sparse-checkout `drivers/memory/eswin drivers/soc/eswin`）。
3. 实现 D1（先只在 vendor 6.6 树上验证，再移到我们的 mainline）。
4. dtb：CMA 节点替换 no-map mmz（保留 sprammemory/lpcpu/g2d 不动）。
5. 回归：es_run_model 精度（-v verify）+ 性能 + 系统可用内存
   （`free -h`：期望 NPU 空闲时 CMA 512MiB 可被系统使用）。

## 关键文件索引

- `npu_drv/eswin_memblock.c`、`npu_drv/mmz_vb.c`、`npu_drv/eswin_rsvmem_heap.c`、
  `npu_drv/es_dev_buf.c`（dev_mem_alloc 的 policy→heap 映射，"x86 emulation"
  注释所在）、`npu_drv/iommu_rsv.c`
- `NOTES-npu-mmz-boot-mem.md` — 调查结论与证据
- `session-c-dtb-mmz.md` — 前置方案 C 的实施清单
- vendor repo：`eswincomputing/linux-stable` @ da228da（GPL，可改）
