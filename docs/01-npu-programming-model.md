# Session memo — Eswin ENNP (EIC7700) NPU 编程模型与计算模型

给新 session 的交接备忘。本文件聚焦"**这个 NPU 怎么编程 + 它是怎么算的**"，
并特别标注了与 **MoE (Mixture-of-Experts) 适配** 直接相关的 API 和坑。

来源：`essdk-1.10.1/es-sdk-npu/usr/include/essdk/`（es_npu_interface.h /
es_npu_types.h）、`es-sdk-memory`（es_sys_memory.h）、
`essdk-1.10.1/es-sdk-sample-npu-runtime/.../src/sample_npu*.{cpp,h}`（运行时样例）、
`npu_drv/`（内核驱动源码，含 dla_* / nvdla_* / sdp / pdp / rubik / scheduler）。

---

## 1. 总体定位：离线编译型的 NVDLA 派生 DPU

不是即插即用的 GPU，也不是能直接吃 TF/PyTorch graph 的加速器。

- **内部结构（从 `npu_drv/` 源码可证）**：
  - `rubik.c` = **离线编译器**（对应 x86 端的 `esaac` / `esquant`），把框架图
    降成一个 `.model` 二进制。
  - `nvdla_hw.c` / `dla_buffer.c` / `dla_driver.c` = NVDLA 内核。
  - `sdp.c` = **SDP** (Systolic Data Processor，脉动阵列)：卷积 / 矩阵乘主力。
  - `pdp.c` = **PDP** (Parallel Data Processor)：逐元素 / pooling / 激活等并行算子。
  - `scheduler.c` / `engine.c` = 任务调度与引擎管理。
- **含义**：模型必须先用 x86 工具链 `esaac/esquant` **离线量化 + 编译成
  `.model`**，再烧到板子上跑。fp32 图不能直接上，INT8 是一等公民（官方
  yolov3 sample 就是 int8 量化模型）。

---

## 2. 计算模型（最关键的底层特征）

**纯 DMA / 以内存为中心的加速器**——CPU 不直接把指针喂给 NPU，而是传
**dma-buf 文件描述符 (fd)**，内存从 **mmz 保留池**里分配。三条铁律：

### 2.1 内存来自 mmz 保留区（决定能跑多大模型）
- 板子上由 `reserved-memory { mmz_nid_0_part_0 { compatible = "eswin-reserve-memory"; }; }`
  划出 512MiB–1GiB（本 session 已配）。驱动用 `mmz_vb.c` / `eswin_memblock.c`
  管理这个池子。
- 用户态分配：
  ```c
  ES_S32 ES_SYS_MemAlloc(ES_U64 *memFd, SYS_CACHE_MODE_E cacheType,
                         const ES_CHAR* pStrMmb, const ES_CHAR* strZone, ES_U64 len);
  ES_S32 ES_SYS_MemFree(ES_U64 memFd);
  ```
  `memFd` 是 `ES_U64`，代表 mmz 池里的一块物理连续的 dma-buf。**池子不够 →
  `ES_SYS_MemAlloc` 失败 / 内核 `mmz_vb` 报找不到 pool**，第一反应是调大 mmz。

### 2.2 传的是 fd，不是指针
- 张量通过 `ES_DEV_BUF_S`（含 `ES_U64 memFd / ES_U64 offset / ES_U64 size`）
  在 `NPU_TASK_S.inputFd[] / outputFd[]` 里交给任务。
- CPU 普通内存（`malloc` 的）对 NPU 不可见，必须走 `ES_SYS_MemAlloc`（或
  `ES_USER_Malloc_To_MemFd(orig, len, &dma_fd, cacheType)` 把既有内存包装成 fd）。

### 2.3 缓存一致性要手动维护（最容易漏、最难 Debug 的一步）
NPU 做 coherent DMA，CPU cache 与 NPU 所见内存是两回事：
- **喂输入前**：`ES_SYS_MemFlushCache(memFd)`（writeback，保证 NPU 读到最新输入）。
- **取输出后**：`ES_SYS_MemInvalidate(memFd)`（invalidate，保证 CPU 读到 NPU 结果）。
  （还有 `ES_SYS_MemFlushCacheAllByNid(nid)` / `ES_SYS_MemFlushCacheAll()` 刷全部。）
- 分配时可选 `SYS_CACHE_MODE_NOCACHE`（sample 默认这么做）或 cached 模式。
- 漏了 flush/invalidate → "输出全 0 或脏数据"，且定位困难。**这是 MoE 适配时要
  重点盯的**（多专家、多 tensor、buffer 复用）。

### 2.4 张量模型（`NPU_TENSOR_S`）
- `NPU_DIMS4_S { ES_S32 n,c,h,w }`（4D，batch 用 n）。
- `dataFormat`：`ES_NPU_DATA_FORMAT_NCHW / NHWC / NxHWx`。
- `dataType`：FLOAT / HALF(fp16) / INT8 / INT16 / INT32 / UINT8 …。
- `dataCategory`（input / output / weight / bias …）、`pixelFormat`、
  `pixelMapping`、`stride[8]`、`bufferSize`、`name`。
- 元信息接口：`ES_NPU_GetNumInputTensors(modelId,&n)` +
  `ES_NPU_GetInputTensorDesc(modelId,id,&NPU_TENSOR_S)`（output 同理）。

---

## 3. 编程方式

### 3.A 最快：`es_run_model` 一键跑（sanity check）
```
/opt/eswin/bin/es_run_model -m <model_dir> -i <图片目录> -o <结果目录> [-r <sample_id>]
```
把"预处理(NCHW 归一/缩放) → NPU 推理 → 后处理(检测框/分类)"全包，适合先验证驱动
和 mmz 是否通了。

### 3.B 正式：runtime API 完整生命周期（同步版）
```c
// 1. 设备 + 上下文
ES_NPU_SetDevice(id);
npu_context ctx;
ES_NPU_CreateContext(&ctx, id);
ES_NPU_SetCurrentContext(ctx);

// 2. 加载离线模型 + 查张量元信息
ES_U32 modelId;
ES_NPU_LoadModelFromFile(&modelId, "xxx.model");
ES_S32 nIn;  ES_NPU_GetNumInputTensors(modelId, &nIn);
NPU_TENSOR_S t;
ES_NPU_GetInputTensorDesc(modelId, 0, &t);

// 3. 从 mmz 池分配输入输出 buffer（拿 fd）
ES_U64 inFd, outFd;
ES_SYS_MemAlloc(&inFd, SYS_CACHE_MODE_NOCACHE, "npu", t.name, t.bufferSize);
… (输出同理) …

// 4. 预处理后 flush → Prepare（告诉 NPU 这些 fd 要参与 DMA）
memcpy(…inFd…, preprocessedData);
ES_SYS_MemFlushCache(inFd);
ES_DEV_BUF_S dbuf = { inFd, 0, t.bufferSize };
ES_NPU_Prepare(&dbuf);          // 与 ES_NPU_Unprepare 成对

// 5. 组 task + 提交（同步阻塞）
NPU_TASK_S task = {0};
task.modelId = modelId;
task.inputFdNum = 1; task.inputFd[0] = dbuf;
task.outputFdNum = 1; task.outputFd[0] = { outFd,0,<size> };
ES_NPU_Submit(&task, 1);        // 或 ES_NPU_ExecuteTaskSync(&task)

// 6. 取结果：invalidate 后读回
ES_SYS_MemInvalidate(outFd);
… read outFd …

// 7. 清理
ES_NPU_Unprepare(&dbuf);
ES_SYS_MemFree(inFd); ES_SYS_MemFree(outFd);
ES_NPU_UnloadModel(modelId);
```

### 3.C 异步版（多流/多 context 并发）
- `ES_NPU_CreateStream(&stream)` / `ES_NPU_DestroyStream`。
- `ES_NPU_SubmitAsync(&tasks, n, stream)`（非阻塞，立即返回）。
- 完成检测：`ES_NPU_ProcessReport(stream, timeoutMs)`（timeoutMs=-1 表示等到一个
  完成并触发回调）、`ES_NPU_SynchronizeStream(stream)`（等全流结束）、
  `ES_NPU_AbortStream(stream)`。
- `NPU_TASK_S` 带 `NPU_TaskCallback callback / callbackArg`（完成回调）和
  `NPU_TASK_STATE_E state`（NONE/READY/RUNNING/COMPLETED/ABORTED/FAILED/HW_ERROR）。
- sample_npu 的 `-s 2/3/4/5` 分别演示：异步任务、多 context、多 stream、多模型。

---

## 4. `NPU_TASK_S` 与 `ES_DEV_BUF_S` 要点
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
- 每个 fd 描述一块 dma-buf 的一片区域（offset/size），支持 `ES_SYS_SplitMemFd`
  拆分。
- 多输入多输出靠 `inputFdNum/outputFdNum` + 数组完成。

---

## 5. NPU 能力与拓扑（`NPU_DEVICE_PROP_S`）
```c
typedef struct {
  ES_U32 chipVer, memSize;
  ES_U32 isInt8Supported, isInt16Supported, isInt32Supported, isFp16Supported, isFp32Supported;
  ES_U32 computingCnt;                              // 脉动阵列/核心数量
  ES_CHAR *topologicalInfo[256];                    // 拓扑描述（die/核 布局）
} NPU_DEVICE_PROP_S;
ES_S32 ES_NPU_GetDeviceProperties(ES_S32 deviceId, NPU_DEVICE_PROP_S *prop);
ES_S32 ES_NPU_GetNumDevices(ES_U16 *deviceNum);
```
- `memSize` = NPU 可访问的片上/保留内存；`computingCnt`/`topologicalInfo` 描述
  **多 die / 多核布局**——这是 **MoE 跨 die 部署的关键输入**（决定专家怎么落到不同 die）。
- `es_run_model` 还带 dump/perf：`ES_NPU_EnableDump`、`ES_NPU_DumpOpStatus`、
  `ES_NPU_EnablePerformance` / `ES_NPU_DumpPerformanceData(modelId, dir)`、
  `ES_NPU_GetDdrBandwidth(modelId,&rd,&wr)`（MoE 调带宽/通信开销有用）。

---

## 6. ⭐ 与 MoE 适配直接相关的 API（重点）

MoE 本质是"**多个子模型 / 专家 + 路由 + 专家间通信**"，对应这套 API：

### 6.1 Composite model（多子模型集合，同一进程/同一次推理）
- `ES_NPU_LoadCompositeModel(ES_U32 *modelId, const ES_CHAR *modelPath)`
  （modelPath 指向一个**目录**，内含若干 `.model` + `model.json`）。
- `model.json` 结构：
  ```json
  {"model_list":[{"model_batch":1,"model_cost":15.3,"model_device":1,
    "model_file":"xxx_npu_b1.model","model_type":"npu"}]}
  ```
- `ES_NPU_GetCompositeModelInfo(modelId, NPU_COMPOSITE_MODEL_INFO_S*)`：
  ```c
  typedef struct { ES_U32 modelNums;
    NPU_MODEL_INFO_S modelsInfo[MAX_MODELS_OF_SET]; } NPU_COMPOSITE_MODEL_INFO_S;
  // MAX_MODELS_OF_SET = 4  ← 复合模型最多 4 个子模型
  typedef struct { ES_CHAR modelName[512]; NPU_MODEL_TYPE_E modelType;
    ES_FLOAT modelCost; ES_U32 modelId; ES_U32 modelDevices; } NPU_MODEL_INFO_S;
  // modelType: MODEL_TYPE_NPU / DSP / GPU(reserved) / INVALID
  ```
- 卸载：`ES_NPU_UnloadCompositeModel(modelId)`。

### 6.2 Distribute model（跨 die / 分布式专家 + 通信）—— MoE 真正的重点
- `ES_NPU_LoadDistributeModel(ES_U32 *modelId, char *pBuffer, ES_U32 nBufLen,
  const eccl_comm comms);`
- `typedef void *eccl_comm;` —— **不透明句柄**。`comms` 是 **Eswin 通信库 (eccl)**
  的句柄，负责**多 die / 多核之间的专家路由通信**（MoE gate→expert 的 all-to-all）。
- ⚠️ **eccl 库不随 `essdk-1.10.1` 发布**（只在 x86 端 SDK / 独立运行时里）。
  本 session 研究 MoE 时**必须拿到 eccl 库及其初始化 API**（如何建 `eccl_comm`、
  配置 domain/通信拓扑），否则 distribute model 路径走不通。

### 6.3 Flexible task（可调度的灵活任务，利于专家批处理）
- `ES_NPU_SetFlexibleTaskAttr(modelId, NPU_FLEXIBLE_TASK_ATTR_S*{timeOut})`。
- `ES_NPU_AllocTaskMemory(modelId, n, NPU_TASK_MEM_S*)` / `ReleaseTaskMemory`：
  按 modelId 预分配一批输入/输出 fd，反复复用（**MoE 批处理多个专家、减少
  mmz 反复分配/flush 的开销**有用）。

---

## 7. 实战要点 / 踩坑清单
- 别传 CPU 指针；一律 mmz fd + `ES_NPU_Prepare/Unprepare`，否则 SMMU 出 fault。
- 别忘 flush/invalidate —— 尤其 MoE 多 tensor、buffer 复用时，顺序错了结果脏。
- mmz 不够 → 调大 `mmz_nid_0_part_0`（session-c 已配到 1GiB，MoE 可能还要加）。
- 模型必须离线 `esaac/esquant` 编译成 `.model`；INT8 优先（sample 就是 int8）。
- 多模型可同时 load（不同 `modelId` 并发），但复合模型上限 4 个子模型；>4 个专家
  要么走 distribute model，要么自己拆 batch。
- DSP 与 NPU 可协同（`model_type` 含 DSP）；composite/distribute 里专家可分布在
  NPU/DSP 上（heterogeneous）。`npu_drv/hetero_host.h` 即为此设计。

---

## 8. 相关交付物索引（本 repo）
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
