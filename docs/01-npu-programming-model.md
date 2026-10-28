# Session memo — Eswin ENNP (EIC7700) NPU 编程模型与计算模型

给新 session 的交接备忘。本文件聚焦"**这个 NPU 怎么编程 + 它是怎么算的**"，
并标注了与 **MoE (Mixture-of-Experts) 适配** 可能相关的 API 和待验证事项。

来源：`essdk-1.10.1/es-sdk-npu/usr/include/essdk/`（es_npu_interface.h /
es_npu_types.h）、`es-sdk-memory`（es_sys_memory.h）、
`essdk-1.10.1/es-sdk-sample-npu-runtime/.../src/sample_npu*.{cpp,h}`（运行时样例）、
`npu_drv/`（内核驱动源码，含 dla_* / nvdla_* / sdp / pdp / rubik / scheduler）。

---

## 1. 总体定位：离线编译型 NPU，驱动接口与 NVDLA 相关并带有 ESWIN 扩展

**Offline-compiled NPU with NVDLA-related driver interfaces and ESWIN-specific extensions**

This document describes the compiled-model NPU runtime path, not a
general-purpose GPU programming interface. Framework models require
conversion and compilation for that path.

ESWIN's public driver uses OpenDLA interfaces and NVDLA-style SDP/PDP/Rubik
programming conventions alongside ESWIN-specific execution structures. This
establishes software/interface lineage, not a complete account of the
hardware's origin or licensing. See ESWIN's pinned
[`sdp.c`](https://github.com/eswincomputing/linux-stable/blob/fc6038c00e006226e3bd504d2679c534eabf5503/drivers/soc/eswin/ai_driver/npu/sdp.c),
which includes `opendla.h` and uses the corresponding register-field
definitions.

- **内部结构（从 `npu_drv/` 源码可证）**：
  - `conv.c`：根据编译器生成的配置准备卷积执行数据，包括依赖关系、
    张量地址和 PEC 使用。
  - `sdp.c` = **SDP** (Single Data Point)：编程逐元素算术、缩放、
    激活相关控制和输出类型转换。**它不是卷积 MAC 阵列。**
  - `pdp.c` = **PDP** (Planar Data Processor)：编程 pooling 算子。
  - `rubik.c` = **Rubik**：编程硬件数据布局变换（contract / split /
    merge 模式）。**它不是离线编译器。**
  - `nvdla_hw.c`：面向硬件的驱动支持，包括 mailbox 传输。
  - `dla_buffer.c`：buffer 管理。
  - `dla_driver.c`：驱动侧执行支持。
  - `scheduler.c` / `engine.c`：任务调度与执行管理。
  - 离线编译与量化由 x86 端工具完成，与上述内核驱动源码无关：
    **EsAAC** 是离线模型编译器，**EsQuant** 是量化工具。

For EsAAC-based SDK releases, supported framework models are converted and
compiled into offline model artifacts for execution on EIC7700. Target
applications use ESSDK/NPU Runtime to load and execute those artifacts. See
Milk-V's ENNP SDK documentation:
[“EsAAC Model Compilation Tool,” tool introduction](https://milkv.io/zh/docs/megrez/development-guide/ENNP-SDK/esaac)
and [“ENNP Introduction,” software-stack section](https://milkv.io/zh/docs/megrez/development-guide/ENNP-SDK/introduction).
These pages do not show that every newer SDK uses EsAAC or has identical
packaging.

The documented deployment workflow converts supported models into compiled
`.model` artifacts, which are copied to the target and loaded by the runtime.
This is not firmware flashing.

Quantization and precision selection depend on the model and toolchain.
An INT8 sample does not establish an INT8-only hardware restriction.
Older documentation describes EsAAC; newer ENNP documentation describes
`ennc-compile`. Compiler, runtime, driver, and model versions must be recorded.

---

## 2. 计算模型

以内存为中心、基于 DMA 的加速器：CPU 不直接把指针喂给 NPU，而是通过
SDK 的 buffer 句柄（dma-buf 文件描述符 fd）传递张量，内存从 **mmz 保留池**分配。
以下各点均需对照所用 SDK 版本核实。

### 2.1 内存来自 mmz 保留区
- 板子上通过 `reserved-memory { mmz_nid_0_part_0 { compatible = "eswin-reserve-memory"; }; }`
  划出保留区。驱动用 `mmz_vb.c` / `eswin_memblock.c` 管理该池子。
- 用户态分配：
  ```c
  ES_S32 ES_SYS_MemAlloc(ES_U64 *memFd, SYS_CACHE_MODE_E cacheType,
                         const ES_CHAR* pStrMmb, const ES_CHAR* strZone, ES_U64 len);
  ES_S32 ES_SYS_MemFree(ES_U64 memFd);
  ```
  `memFd` 是 `ES_U64`，代表 mmz 池里的一块 dma-buf。

An allocation failure does not by itself prove that the MMZ reservation is
too small. Check the selected memory zone/die, available capacity, requested
size, allocation lifetime, and driver diagnostics first.

The 512 MiB–1 GiB figures describe the author's particular configuration,
not a hardware limit or a generally recommended setting. Changing reserved
memory requires checking the complete board memory map and boot configuration.
(Keep any "this session configured…" statement only if accompanied by the
author's actual board, image, configuration, and evidence.)

### 2.2 传的是句柄，不是指针
- 张量通过 `ES_DEV_BUF_S`（含 `ES_U64 memFd / ES_U64 offset / ES_U64 size`）
  在 `NPU_TASK_S.inputFd[] / outputFd[]` 里交给任务。

A CPU virtual pointer alone is not a valid NPU buffer descriptor.
The documented runtime path uses supported buffer handles and device
mappings. Whether existing CPU allocations can be imported depends on the
specific SDK and allocator; do not assume arbitrary malloc memory is usable.

- 头文件中出现 `ES_USER_Malloc_To_MemFd(orig, len, &dma_fd, cacheType)`，
  其适用条件须对照所用 SDK 版本核实。

### 2.3 缓存一致性

Cache coherency depends on the platform configuration, buffer exporter,
mapping attributes, and driver behavior. Do not describe the path as
hardware-coherent while also assuming mandatory manual cache maintenance.

For cached buffers on a noncoherent path, CPU/device ownership transfers
require the appropriate synchronization. Publish CPU input writes before
device access, wait for device completion, and synchronize before CPU reads
of output. Use the exact SDK's documented operations and ordering.

SDK 头文件中出现的相关接口（版本相关，不是通用规则，需对照所用版本核实）：
- `ES_SYS_MemFlushCache(memFd)`、`ES_SYS_MemInvalidate(memFd)`；
- `ES_SYS_MemFlushCacheAllByNid(nid)` / `ES_SYS_MemFlushCacheAll()`；
- 分配时的缓存模式：`SYS_CACHE_MODE_NOCACHE`（sample 使用）或 cached 模式。

### 2.4 张量模型（`NPU_TENSOR_S`）

These declarations require verification against the exact SDK headers.
They are not an independently established ABI specification.

A datatype enum does not prove that every operator executes in that datatype
on the NPU. Capability fields must be interpreted using the corresponding
SDK documentation and actual returned values.

- `NPU_DIMS4_S { ES_S32 n,c,h,w }`（4D，batch 用 n）。
- `dataFormat`：`ES_NPU_DATA_FORMAT_NCHW / NHWC / NxHWx`。
- `dataType`：FLOAT / HALF(fp16) / INT8 / INT16 / INT32 / UINT8 …。
- `dataCategory`（input / output / weight / bias …）、`pixelFormat`、
  `pixelMapping`、`stride[8]`、`bufferSize`、`name`。
- 元信息接口：`ES_NPU_GetNumInputTensors(modelId,&n)` +
  `ES_NPU_GetInputTensorDesc(modelId,id,&NPU_TENSOR_S)`（output 同理）。

---

## 3. 编程方式

### 3.A `es_run_model` 一键跑（sanity check）
```
/opt/eswin/bin/es_run_model -m <model_dir> -i <图片目录> -o <结果目录> [-r <sample_id>]
```
Command syntax and available preprocessing/postprocessing depend on the
installed SDK and selected sample. This example is not a verified universal
invocation. 可用于初步检查驱动和 mmz 是否可用。

### 3.B Runtime API 生命周期（同步版）

Runtime lifecycle outline — not a compilable example:

1. Initialize the device/context using the installed SDK's documented order.
2. Load the compiled model and query every input/output tensor descriptor.
3. Allocate appropriately sized input/output buffers.
4. Obtain CPU virtual mappings for CPU access; never treat buffer fds as pointers.
5. Fill inputs and perform the required CPU-to-device synchronization.
6. Prepare the buffers required by the SDK and submit the task.
7. Confirm successful completion before accessing outputs or releasing resources.
8. Perform required device-to-CPU synchronization, then read mapped outputs.
9. Unprepare buffers, release mappings and allocations, unload the model,
   and destroy created streams/contexts.

Check every API result and retain buffers until outstanding device access
has ended. Verify exact function signatures against the matching SDK headers.

### 3.C 异步版（多流/多 context 并发）

以下函数名及签名须对照所用 SDK 头文件核实；不要用名称相近的同步/异步函数
静默替换。

- `ES_NPU_CreateStream(&stream)` / `ES_NPU_DestroyStream`。
- `ES_NPU_SubmitAsync(&tasks, n, stream)`。
- 完成检测相关：`ES_NPU_ProcessReport(stream, timeoutMs)`、
  `ES_NPU_SynchronizeStream(stream)`、`ES_NPU_AbortStream(stream)`。
- `NPU_TASK_S` 带 `NPU_TaskCallback callback / callbackArg` 和
  `NPU_TASK_STATE_E state`（NONE/READY/RUNNING/COMPLETED/ABORTED/FAILED/HW_ERROR）。
- sample_npu 的 `-s 2/3/4/5` 分别演示：异步任务、多 context、多 stream、多模型。

---

## 4. `NPU_TASK_S` 与 `ES_DEV_BUF_S` 要点

These declarations require verification against the exact SDK headers.
They are not an independently established ABI specification.

A datatype enum does not prove that every operator executes in that datatype
on the NPU. Capability fields must be interpreted using the corresponding
SDK documentation and actual returned values.

```c
typedef struct {
  ES_U32 taskId; ES_U32 modelId;
  ES_U8 inputFdNum, outputFdNum;
  ES_DEV_BUF_S inputFd[ES_TASK_MAX_FD_CNT];   // ES_TASK_MAX_FD_CNT = 16
  ES_DEV_BUF_S outputFd[ES_TASK_MAX_FD_CNT];
  NPU_TaskCallback callback; ES_VOID *callbackArg;
  NPU_TASK_STATE_E state;
} NPU_TASK_S;
typedef struct { ES_U64 memFd; ES_U64 offset; ES_U64 size; } ES_DEV_BUF_S;
```
- 每个 fd 描述一块 dma-buf 的一片区域（offset/size）；头文件中有 `ES_SYS_SplitMemFd`。
- 多输入多输出靠 `inputFdNum/outputFdNum` + 数组表达。

---

## 5. NPU 能力与拓扑（`NPU_DEVICE_PROP_S`）

These declarations require verification against the exact SDK headers.
They are not an independently established ABI specification.

```c
typedef struct {
  ES_U32 chipVer, memSize;
  ES_U32 isInt8Supported, isInt16Supported, isInt32Supported, isFp16Supported, isFp32Supported;
  ES_U32 computingCnt;
  ES_CHAR *topologicalInfo[256];
} NPU_DEVICE_PROP_S;
ES_S32 ES_NPU_GetDeviceProperties(ES_S32 deviceId, NPU_DEVICE_PROP_S *prop);
ES_S32 ES_NPU_GetNumDevices(ES_U16 *deviceNum);
```
The units, scope, and interpretation of these fields remain to be verified.
Do not infer physical MAC count, available reserved memory, or cross-die
placement guarantees from field names alone.

- 头文件中还出现 dump/perf 接口：`ES_NPU_EnableDump`、`ES_NPU_DumpOpStatus`、
  `ES_NPU_EnablePerformance` / `ES_NPU_DumpPerformanceData(modelId, dir)`、
  `ES_NPU_GetDdrBandwidth(modelId,&rd,&wr)`，可用于带宽/性能测量（须核实版本）。

---

## 6. 可能与 MoE 适配相关的 API（待验证，非已确认支持）

以下接口是候选入口，其是否构成 MoE 支持需要另行证据。

### 6.1 Composite model（多子模型集合）
- `ES_NPU_LoadCompositeModel(ES_U32 *modelId, const ES_CHAR *modelPath)`
  （modelPath 指向一个目录，内含若干 `.model` + `model.json`）。
- `model.json` 示例结构：
  ```json
  {"model_list":[{"model_batch":1,"model_cost":15.3,"model_device":1,
    "model_file":"xxx_npu_b1.model","model_type":"npu"}]}
  ```
- `ES_NPU_GetCompositeModelInfo(modelId, NPU_COMPOSITE_MODEL_INFO_S*)`：
  ```c
  typedef struct { ES_U32 modelNums;
    NPU_MODEL_INFO_S modelsInfo[MAX_MODELS_OF_SET]; } NPU_COMPOSITE_MODEL_INFO_S;
  // MAX_MODELS_OF_SET = 4
  typedef struct { ES_CHAR modelName[512]; NPU_MODEL_TYPE_E modelType;
    ES_FLOAT modelCost; ES_U32 modelId; ES_U32 modelDevices; } NPU_MODEL_INFO_S;
  // modelType: MODEL_TYPE_NPU / DSP / GPU(reserved) / INVALID
  ```
- 卸载：`ES_NPU_UnloadCompositeModel(modelId)`。

Composite-model support does not by itself establish MoE support.
A limit on entries in a composite-model structure is not necessarily a
limit on experts. Expert routing, model partitioning, scheduling, and
communication require separate evidence.

### 6.2 Distribute model
- `ES_NPU_LoadDistributeModel(ES_U32 *modelId, char *pBuffer, ES_U32 nBufLen,
  const eccl_comm comms);`
- `typedef void *eccl_comm;`

The cited declaration uses an opaque communication handle. Its name and
type alone do not establish all-to-all communication, expert routing,
cross-die topology, or supported collectives.

The implementation, initialization API, target architecture, distribution
package, and licensing of this communication component have not been
verified here. Claims that it is absent from a particular SDK or available
only in an x86 package require a versioned package inventory.

### 6.3 Flexible task
- `ES_NPU_SetFlexibleTaskAttr(modelId, NPU_FLEXIBLE_TASK_ATTR_S*{timeOut})`。
- `ES_NPU_AllocTaskMemory(modelId, n, NPU_TASK_MEM_S*)` / `ReleaseTaskMemory`：
  按 modelId 预分配一批输入/输出 fd 以便复用。其语义与是否有利于批处理需对照
  SDK 文档核实。

---

## 7. 实战要点 / 待核实清单
- 不要把 CPU 指针当作 NPU buffer 描述符；使用 SDK 支持的 buffer 句柄，并按
  文档调用 `ES_NPU_Prepare/Unprepare`。
- 按所用 SDK 与平台的要求做 CPU/设备同步（见 2.3），多 tensor、buffer 复用时
  尤其注意顺序。
- 内存分配失败的排查：

  An allocation failure does not by itself prove that the MMZ reservation is
  too small. Check the selected memory zone/die, available capacity, requested
  size, allocation lifetime, and driver diagnostics first.

  The 512 MiB–1 GiB figures describe the author's particular configuration,
  not a hardware limit or a generally recommended setting. Changing reserved
  memory requires checking the complete board memory map and boot configuration.
- 模型需先由工具链离线编译为 `.model`；精度选择取决于模型与工具链（见第 1 节）。
- 多模型可同时 load（不同 `modelId`）。
- `hetero_host.h` contains NIM firmware-container and controller
  loading/activation support. Its presence does not prove MoE scheduling or
  expert placement across NPU and DSP. Those claims require evidence from
  the compiler, runtime, and model-execution interfaces.

---

## 8. 相关交付物索引

The following paths describe the original author's research environment.
They are not verified download locations or a guarantee that these files
are included in this repository. Record package versions, provenance, and
availability separately.

- 驱动源码：`eswin-nntools/npu_drv/`（eic7700 NPU 内核，移植自 vendor da228da）。
- 用户态 SDK：`eswin-nntools/essdk-1.10.1/es-sdk-npu/`（`es_npu_*` 头 + `libedla_runtime.so.1.0`）。
- 内存 SDK：`eswin-nntools/essdk-1.10.1/es-sdk-memory/`（`es_sys_memory.h`）。
- 样例：`eswin-nntools/essdk-1.10.1/es-sdk-sample-npu-runtime/.../sample_npu*`（C++）。
- 固件：`eswin-nntools/essdk-1.10.1/es-sdk-npu/lib/firmware/{eic7700_die0_e31_fw, mcudfx/mcu_dump}`。
- 离线工具链（x86）：`eswin-nntools/rockos/nn_tools/EIC7x_Release_20250130`（esaac/esquant）。
- 板子产物：`eswin-nntools/board-assets/kernel/{Image,Image.gz,eic7700_*.{ko},eic7700-sbc-a1.dtb,config-npu-port}`、`board-assets/lib-firmware/`。
- 驱动移植记录：`eswin-nntools/NOTES-session-c-impl.md`。
- DTS/mmz 配置：`eswin-nntools/session-c-dtb-mmz.md`。
- 上板步骤：`eswin-nntools/BOARD-TEST-npu.md`。
