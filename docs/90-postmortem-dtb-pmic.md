# StarPro64 (ESWIN EIC7700X) 事故复盘：板子怎么坏的、还剩什么、能不能修

> 生成依据：本工作区文件 + `~/.pi/agent/sessions/--home-na-AIPCAIPC-rrrrvvvvvveeeeehh--/` 下
> 10 份会话记录 + `.pi/tasks/*` + `~/.zsh_history`。所有结论都标了证据来源，可回查。
> 目的：① 说清模型改了什么；② 清点还有什么值钱的东西；③ 判断能不能修、怎么修。

---

## 0. 结论摘要（先看这段）

1. **模型从头到尾只改了 eMMC 上的文件**（`/boot` 里的 DTB / initrd / 内核模块）和本机源码。
   **没有写过 SPI NOR flash、没有改过 U-Boot 环境变量、没有写过分区表**（已把 10 份会话里
   所有 tool call 参数扫了一遍，只搜到"提到"w25q/saveenv，没有一条执行过 `flashcp`/`sf write`/
   `fw_setenv`/`saveenv`/`es_burn`/裸设备写）。
   → **BootROM → OpenSBI(SPI) → U-Boot(SPI) 这条链没被动过**，所以"改 DTB 把板子改砖"
   在原理上说不通；真正的风险点在别处（见第 3 节）。
2. **最后落盘的 DTB 里有一处"扫射式"替换**：模型用 `sed` 做了 **全局** 替换
   `reg = <0x10>;` → `reg = <0x0f>;`。原厂 DTB 里恰好有 **两个** 节点是这个值：
   - `mpq8785@10`（PMIC，在 `i2c@50960000`）—— 这是模型想改的；
   - `es8388-0@10`（音频 codec，在 `i2c@50950000`）—— **这是被误伤的**。
   → 这正好解释用户看到的 **"a lot of asoc error"**（codec 跑错地址）。
3. mpq8785 驱动 probe 时会**写 PMIC 寄存器**（`0x20` VOUT_MODE、`0x24` VOUT_MAX、
   `VOUT_COMMAND`）。如果 `0x0f` 上坐的是**另一颗**芯片，这些写操作就打错对象了 ——
   这是整起事故里**唯一可能碰到硬件**的路径。好消息：PMBus 稳压器寄存器是**易失**的，
   彻底断电（拔 12V + 等）应当恢复默认值。
4. **最重要的好消息**：原厂 DTB 里那颗 `power` LED 是 **软件驱动**的：
   ```dts
   leds { compatible = "gpio-leds";
       power  { function = "power";  linux,default-trigger = "default-on"; gpios = <&gpio 30 0>; };
       status { function = "status"; linux,default-trigger = "heartbeat";  gpios = <&gpio 27 0>; };
   };
   ```
   `default-on` 由 **Linux 的 gpio-leds 驱动**点亮。也就是说 **"电源灯不亮"更可能代表
   "Linux 没起来"，而不是"板子没供电"**。这一条把"硬件已死"的概率显著拉低了。
5. 能不能修：**大概率能**。分两层：
   - 软件层（DTB/initrd/模块被改坏）：**100% 可回滚**，原厂文件本地和板子上都有备份。
   - 硬件层（现在"没灯没串口"）：先按第 5 节的 L0/L1 做供电体检 + 串口确认。
     只要串口能看到 OpenSBI/U-Boot 任何一个字符，这事就结束在软件层。
6. **损失几乎为零**：19 GB 的 SDK/内核/工具链/笔记/自研 DTS 全在本地；唯一"不可再生"的
   只有 eMMC 里的运行环境，而这个能用本地 `kernel-official/` + RockOS 镜像重建。

---

## 1. 事故时间线（时间 = 本地 CST，UTC+8）

| 时间 | 事件 | 证据 |
|---|---|---|
| 09-26 23:57 | 本地重建 `merged.dtb`（20734 B，主线上移植版） | 工作区 `merged.dtb`；会话 rec344 |
| 09-26 23:57 | `scp merged.dtb` 到板子 | session `…a0de60…` rec343 |
| 09-26 23:58 | 先 `cp` 原厂 DTB → `.bak`，再把 `merged.dtb` 覆盖成 `/boot/dtbs/linux-image-6.6.88-win2030/eswin/eic7700-pine64-starpro64.dtb` | rec356–358 |
| 09-27 00:36 | 从 `.bak` 还原原厂 DTB（验证 `npu-supply = <0x20>`） | rec503–504 |
| 09-27 00:37 | `fix_dtb.py` 部署"加 `npu_svcc_fixed` "版（`npu-supply = <0x64>`） | rec525–539 |
| 09-27 01:27 | 再次从 `.bak` 还原原厂 DTB（`npu-supply = <0x20>` 确认） | rec622–623 |
| **09-27 01:38** | **关键动作：`sed 's/reg = <0x10>;/reg = <0x0f>;/g'` 全局替换后编译部署 + reboot** | **rec702** |
| 09-27 01:39 | 板子回到网络；`NPU BOUND`，但 `edla_probe → regulator_enable` 触发 **Oops #1**；dmesg 仍显示 `mpq8785 2-0010`（改动疑似未生效） | `.pi/tasks/…/b656ccb6c.output`、`bd61befdd.output`、rec716 |
| 09-27 01:40 | 用户："**在启动了，我看到有很多 asoc error**" | rec725 |
| 09-27 11:36 | 用户："**都没有**"（无灯/无串口/无输出） | session `…de60…` 用户消息 |
| 09-27 12:20 | 用户："**开机无法出现登录 shell，systemd 的其他服务无法启动；我短接复位，然后板子电源灯也不亮了，完全无法上电**" | 用户消息 |
| 09-27 12:39 | 会话最后一次活动，之后板子再没连上过 | 会话末条 |

> 备注：`~/.zsh_history` 里最后一次 `ssh debian@<board-ip>` 在 09-27 11:16；
> 之后本机路由里 `<board-subnet>` 的静态路由也没了（当时是靠
> `sudo ip ro add <board-subnet> via <gateway>` 才通的），**所以"连不上"里有一部分
> 只是本机网络没配路由**——排查时先别把它当板子故障。

---

## 2. 模型到底改了什么（逐项，含是否有备份）

| # | 位置 | 改了什么 | 备份 | 影响 | 可逆性 |
|---|---|---|---|---|---|
| 1 | 板子 `/boot/dtbs/linux-image-6.6.88-win2030/eswin/eic7700-pine64-starpro64.dtb` | 反复覆盖，**最终态 = 原厂 DTB + 全局把 `reg = <0x10>` 改成 `<0x0f>`**（误伤 `es8388-0@10`） | 板上有 `.bak`、`.orig2`（= 原厂） | 音频 codec 跑错地址（asoc error）；PMIC 被指到 `0x0f` | ✅ 可逆 |
| 2 | 板子 `/boot/initrd.img-6.6.88-win2030` | 重打包，塞入 DSP/NPU 固件 + 新 `eic7700_dsp.ko` | `.bak`、`.orig2`、`.without-fw.bak` | 影响 initramfs 阶段 | ✅ 可逆 |
| 3 | 板子 `/lib/modules/6.6.88-win2030/…/npu/eic7700_npu.ko` | 换成"regulator 可选"的魔改版（17 处调用包了 no-op helper） | `.ko.bak` | NPU 绑定行为改变；曾 Oops | ✅ 可逆 |
| 4 | 板子 `/home/debian/` | `fix_dtb.py`、`fix_addr.dts/dtb`、`vendor-modified.dts`、`boot.dts`、`running.dts`、`initrd*` 等杂项 | — | 无害 | ✅ |
| 5 | 板子 systemd | 加了 `npu-boot-check.service` + `npu_boot_check.sh` | — | 无害 | ✅ |
| 6 | 本机工作区 | `npu_main.c`、`nvdla_proc.c`、`.config`（`CONFIG_REGULATOR_FIXED_VOLTAGE`）、`fix_dtb.py`、`eic7700.dtsi`、`starpro64.dts`、`merged.dts/dtb` | git / 原厂文件在 `kernel-*`、`meta-riscv` | 仅开发机 | ✅ |
| — | SPI NOR flash / U-Boot env / 分区表 / 二进制裸写 | **没有动过**（审计通过） | — | — | — |

**审计方法（可复现）**：把 10 份会话 JSONL 里所有 `toolCall.arguments` 抽出来，
匹配 `es_burn|sf write|flashcp|fw_setenv|saveenv|/dev/mtd|dd (if|of)=|mmcblk0boot|es_fs update|gpt_partition|mkfs|sf probe|w25q`，
唯一命中的几条分别是：DTS 文件内容里出现 `w25q`（flash 节点名）、一条笔记里提到 `saveenv`、
以及一次本机的 `dd if=uboot-starpro64.bin … of=uboot-fdt1.dtb`（**本地解包**，不是写板子）。

---

## 3. 这些改动能解释"开不了机"吗？

分现象看：

| 现象 | 能否被 DTB/模块改动解释 | 说明 |
|---|---|---|
| systemd 其他服务起不来、没有登录 shell | ✅ **能** | DTB 错（设备/regulator 枚举错）+ initrd/模块被换，完全可能让 userland 崩 |
| 一堆 `asoc` error | ✅ **能，且已定位** | `es8388-0@10` 被 sed 误改成 `0x0f`（在 `i2c@50950000` 上），codec 找不到 |
| 电源灯不亮 | ⚠️ **很可能能** | 原厂 DTB 里 `power` LED 是 gpio-leds `default-on`，**由 Linux 点亮**；Linux 起不来它就不亮 |
| 串口连 OpenSBI/U-Boot 都没输出 | ❌ 不能（除非压到根因③） | ROM/OpenSBI/U-Boot 在 SPI flash 里，DTB 改动影响不到它们 |
| 完全无法上电 | ❌ 基本不能 | 见下 |

**唯一真正的硬件风险路径（根因③，必须说清楚）**：
`kernel-rockos/drivers/regulator/mpq8785.c` 的 probe 会主动写芯片：
```
#define MPQ8785_CMD_VOUT_MODE  0x20
#define MPQ8785_CMD_VOUT_MAX   0x24
mpq8785_write_byte(data, MPQ8785_CMD_VOUT_MODE, 0x20);   // 行 1140
mpq8785_set_vout(data, default_voltage/1000);            // 行 1167
```
在地址 `0x10` 上它每次都是 `-121 EREMOTEIO`（器件不应答）→ 什么都不写，安全。
但改成 `0x0f` 后，模型自己用 `i2cget` 证明 `0x0f` 上**确实有芯片应答**
（`MFR_ID=0x0089` 是 MPS 的厂商 ID，`VOUT≈0x0320`）。于是 probe 一旦绑上，
就会**对 `0x0f` 那颗芯片写 VOUT_MODE / VOUT_MAX / VOUT_COMMAND**。
如果 `0x0f` 其实是另一路电源（比如核心/DDR 轨），被写了 700–1100 mV 之外的值，
就会出现"电压被拉飞 → SoC/DDR 不稳 → systemd 崩"甚至更糟。
**注意**：这类寄存器是**易失**的（PMBus 标准），**拔掉 12V 彻底放电后应回到 NVM 默认**；
所以"断电也回不来"不能只用这一条解释，需要第 5 节的排查。

**还有一个必须承认的不确定性**：用户"**短接复位**"这个动作是在板子彻底死掉之前做的。
如果短接点选错（碰到相邻的电源/地/信号），完全可能真的造成硬件损伤（保险丝/
PMIC/SoC）。这一点从软件证据里无法排除，只能靠万用表 + 串口来区分。

---

## 4. 还剩什么有价值的东西（清点结果）

**总盘 19 GB，全部在本工作区。结论：几乎没有损失。**

### 4.1 救砖直接能用的（最关键）

| 资产 | 路径 | 大小 | 价值 |
|---|---|---|---|
| **原厂 DTB**（与板载 `.bak` 同源） | `eic7700-pine64-starpro64.dtb`<br>`eswin-nntools/board-assets/kernel/eic7700-pine64-starpro64.dtb`<br>`eswin-nntools/investigation/2026-09-24-uboot-fdt/eic7700-pine64-starpro64.dtb` | 158 544 B ×3 | 三份 **md5 完全一致** `8d139df31f829b13c738851bd3efbdaf`，就是被 sed 前的原厂文件 |
| **SPI 引导镜像**（OpenSBI+U-Boot 整包） | `eswin-nntools/investigation/2026-09-24-uboot-fdt/uboot-starpro64.bin`（md5 `1faeddc960c952b3437fa165256d71ef`）+ 从里面提取的 `uboot-fdt1.dtb` | 4 302 248 B | SPI flash 变砖时用（`es_burn write` 或外部编程器） |
| 原厂 6.6.88 内核套件 | `eswin-nntools/kernel-official/boot/{vmlinuz-6.6.88-win2030, System.map-6.6.88-win2030, config-6.6.88-win2030}` | 9.9 MB + 3.8 MB + 192 KB | 完整 `/boot` 内容，可整包恢复 |
| 官方内核 deb | `eswin-nntools/linux-image-6.6.88-win2030.deb` | 350 MB | 同上，含 initrd 生成脚本 |
| 板端资产包 | `eswin-nntools/board-assets/`（`es_run_model`、`es_qwen2`、`qwen2_models/`、`lib-firmware/`、`kernel/*.ko`、`Image-7.2`、`vmlinuz`、`config-npu-port`） | 110 MB | NPU/DSP 运行时、固件、模型 |
| 部署包 | `eswin-nntools/deploy-7.2/` | 11 MB | 7.2 内核 + DTB + 模块 + 固件 |

### 4.2 开发资产（可重建，但重建要花时间）

| 资产 | 路径 | 大小 |
|---|---|---|
| RockOS / Rockchip 相关总目录 | `eswin-nntools/rockos/`（含 `EIC7x_AI_Release_20250730.7z` 1.88 GB、`nn_tools/`） | 11 GB |
| ESSDK 1.10.1 源码树 + 原包 | `eswin-nntools/essdk-1.10.1/`、`essdk_1.10.1.tar.xz` | 177 MB / 1.2 GB |
| 内核源码树 | `eswin-nntools/kernel-rockos/`（2.6 GB，**能直接编模块**）、`kernel-rockos-build/`、`linux-master/`（2.9 GB）、`kernel-sifive/`（563 MB）、`kernel-official/`（351 MB） | — |
| Vendor NPU/DSP 驱动源码 | `eswin-nntools/npu_drv/` | 596 KB |
| 交叉工具链封装 | `eswin-nntools/crossbin/`（clang wrapper riscv64） | 36 KB |
| Meta 层（git 仓库） | `meta-riscv/` | 18 MB |
| Meta-riscv 补丁线索 | `eswin-nntools/.patch-staging/` | — |

### 4.3 知识资产（这才是真正不可再生的）

- `eswin-nntools/STARTER-KIT-npu-boot.md` —— NPU/DSP 上板现状 + MPQ8785 根因
- `eswin-nntools/NOTES-npu-programming-model.md` —— NPU 编程/计算模型（NVDLA 系、mmz、dma-fd、cache flush、MoE/composite/distribute 模型）
- `eswin-nntools/NOTES-npu-mmz-boot-mem.md` —— NPU 启动内存 / mmz 保留区
- `eswin-nntools/session-c-dtb-mmz.md`、`session-d-cma-pool.md`、`NOTES-session-c-impl.md`
- `eswin-nntools/DSP-STATUS.md`、`BOARD-TEST-npu.md`
- `NOTES-reset-dtb.md`（根目录）—— **主线上 EIC7700 时钟/复位/DTB 移植全过程**，含 dtbs_check 123→32 的收敛记录、emmc `hsp-sp-csr` 偏移真相
- 自研 DT：`eic7700.dtsi`、`starpro64.dts`、`merged.dts/dtb`、`eic7700-upstream.dtsi`、`merge_dts.py`
- 参考件：`VENDOR-eic7700-pine64-starpro64.dts`（188 KB 原厂 DTS 反编译）、`vendor_clock.h`、`sdhci-of-dwcmshc.c`
- 日志：`dmesg.log`、`ruapu_analysis/`（CPU 特性探测 + 时钟/复位映射）

**唯一真正丢掉的**：eMMC 上那份"能跑起来"的运行环境（rootfs + `/boot`）。
它可以用 `kernel-official/` + RockOS 镜像重建，不值钱。

---

## 5. 能不能修？——分级恢复方案

> 原则：**先确认"电"和"串口"，再谈软件**。串口是唯一能一锤定音的判据。

### L0. 供电体检（不需要电脑，万用表最好）
1. 电源必须是 **DC 12V / 3–5A，5.5 mm 外径 / 2.1 mm 内径，中心正极**；
   换一个**确认好的**适配器 + 线，先量空载电压（应 ≈12.0 V）。
2. 插上后**别只看灯**（见第 0 节第 4 条，power LED 是 Linux 驱动的）：
   - 摸 SoC / PMIC 有没有**异常发烫**；
   - 听有没有啸叫 / 电感声；
   - 看板上有没有**元件变色、鼓包、焦味**。
3. 万用表测板上：
   - **12 V 输入**（桶插座焊盘 / 保险丝两端）；
   - 板上 **5 V / 3.3 V / 1.8 V / DDR / VDD_CORE** 测试点；
   - 各主轨**对地电阻**（不通电测），排除短路。
   如果 12 V 进得来、后面主轨全没有 → 保险丝或 PMIC/时序问题（L6/L7）。

### L1. 串口（决定性一步，优先做）
按官方接法（[NuttX StarPro64 文档](https://nuttx.apache.org/docs/latest/platforms/risc-v/eic7700x/boards/starpro64/index.html)、
[lupyuen 上手文](https://lupyuen.github.io/articles/starpro64)）：
```text
USB-UART(CH340/CP2102, 电平 3V3)   StarPro64
GND  ────────────────────────────  Pin 6  (GND)
RXD  ────────────────────────────  Pin 8  (UART0 TX)
TXD  ────────────────────────────  Pin 10 (UART0 RX)

# 本机（之前就是这么连的，设备是 /dev/ttyUSB0）
minicom -D /dev/ttyUSB0 -b 115200     # 或 screen /dev/ttyUSB0 115200
```
**接好后再上电**，观察：
- 有 `OpenSBI v1.5 … Platform Name : ESWIN EIC7700 EVB` → **SoC/SPI/PMIC 全活**，
  后面全是软件问题，直接跳 L2/L3，**板子没坏**。
- 有 `U-Boot 2024.01…` → 同上，更好办。
- **一个字都没有** → 进 L4/L5/L6 硬件向排查（先别急着判定 SoC 死）。

### L2. U-Boot 层（能看到 U-Boot 就赢了一半）
上电时**连按任意键/Ctrl-C** 打断自动启动。启动项（来自 `/boot/extlinux/extlinux.conf`）：
```text
label l0   RockOS GNU/Linux 7.2-riscv64          fdtdir /dtbs/linux-image-7.2-riscv64/
label l0r  7.2 (rescue)                          fdt /eic7700-pine64-starpro64.dtb
label l1   7.0.10+deb13.1-riscv64
label l2   6.6.88-win2030   ← 默认项，用坏的 DTB  fdtdir /dtbs/linux-image-6.6.88-win2030/
label l2r  6.6.88 (rescue)                       fdtdir /dtbs/linux-image-6.6.88-win2030/
```
**注意**：`l2` 和 `l2r` 用的是**同一个 fdtdir**，所以坏 DTB 时这两个都救不了；
**`l0`（7.2）有自己的 DTB 目录，且模型从没碰过 → 首选救援入口**。
（板子上 `/boot/eic7700-pine64-starpro64.dtb` 这个根目录副本也是原厂未动的，见 `l0r` 的 `fdt` 行。）

> ⚠️ 每多启动一次坏 DTB，就可能再往 `0x0f` 那颗芯片写一次寄存器。
> 所以**优先选 `l0`，不要再反复重启 `l2`**。

### L3. 软件回滚（进得去系统就 3 条命令）
进系统后（`l0` 也行，rootfs 是同一个 `UUID=88cce02d-ea68-4d3d-8390-985557361d6d`）：
```bash
sudo cp /boot/dtbs/linux-image-6.6.88-win2030/eswin/eic7700-pine64-starpro64.dtb.bak \
        /boot/dtbs/linux-image-6.6.88-win2030/eswin/eic7700-pine64-starpro64.dtb
sudo md5sum /boot/dtbs/linux-image-6.6.88-win2030/eswin/eic7700-pine64-starpro64.dtb
#   期望 = 8d139df31f829b13c738851bd3efbdaf（原厂）

sudo cp /home/debian/initrd.img-6.6.88-win2030.bak          /boot/initrd.img-6.6.88-win2030
sudo cp /lib/modules/6.6.88-win2030/kernel/drivers/soc/eswin/ai_driver/npu/eic7700_npu.ko.bak \
        /lib/modules/6.6.88-win2030/kernel/drivers/soc/eswin/ai_driver/npu/eic7700_npu.ko
sudo depmod -a 6.6.88-win2030 && sudo reboot
```
现成脚本：`eswin-nntools/board-scripts/restore-boot-files.sh`（本报告一起产出）。

### L4. U-Boot 手工救（进不去系统时）
在 U-Boot 命令行里用**原厂 DTB 直接引导**（地址沿用官方：`kernel_addr_r=0x84000000`、
`fdt_addr_r=0x88000000`；rootfs UUID 抄 `l2` 的 append）：
```text
# 先把原厂 DTB 从 boot 分区（mmc 0:1）读出来
ext4load mmc 0:1 0x88000000 /dtbs/linux-image-6.6.88-win2030/eswin/eic7700-pine64-starpro64.dtb.bak
ext4load mmc 0:1 0x84000000 /vmlinuz-6.6.88-win2030
ext4load mmc 0:1 0x8a000000 /initrd.img-6.6.88-win2030
setenv bootargs root=UUID=88cce02d-ea68-4d3d-8390-985557361d6d console=ttyS0,115200 rootfstype=ext4 rootwait rw earlycon
booti 0x84000000 0x8a000000:${filesize} 0x88000000
```
（`initrd` 的实际大小用 `ext4load` 后的 `${filesize}`；也可以直接选 `l0`，比手敲稳。）

### L5. SPI flash 变砖的最后手段
只有在"串口连 OpenSBI 都没有"且确认 SPI 内容损坏时才做：
- 官方路径：U-Boot 里 `ext4load usb 0 <addr> bootloader_secboot_ddr5_pine64-starpro64.bin`
  → `es_burn write <addr> flash`（[官方刷写流程](https://lupyuen.github.io/articles/starpro64)）；
- 本地已有 `uboot-starpro64.bin`（4 302 248 B）可作素材，但**务必先跟官方镜像 md5 对齐**
  （Fast-mirror 的 `rockos/images/generic/latest/`），**写错 bootloader 是不可逆的**；
- 更保险：CH341A + SOP8 夹子直接读写那颗 16 MB 的 GD25LQ128E（板上就是它）。
- ⚠️ 官方文档明确警告：**过热会写坏 SPI Boot Flash**。刷写时务必加风扇散热。

### L6. eMMC / 系统重刷
eMMC 是可插拔模块（PINE64 eMMC module），可以：
- 用 PINE64 eMMC→USB 转接板挂到电脑上，直接改 `/boot`（**最快最稳的救砖方式**）；
- 或按官方文档 `es_fs update usb 0 boot.ext4 mmc 0:1` / `root.ext4 → mmc 0:3` 重写分区。
- 镜像来源：<https://fast-mirror.isrc.ac.cn/rockos/images/generic/latest/> 或
  PINE64 的 Alpha-ONE 32GB 镜像
  （`files.pine64.org/SDK/StarPro64/Alpha-ONE_OS_build_32GB-20250420.img.gz`）。

### L7. 硬件维修
若 L0 测到主轨缺失/短路、PMIC 不输出、或串口完全无输出且供电正常：
- 对照 [StarPro64 v2.0 原理图](https://files.pine64.org/doc/starpro64/StarPro64_schematic_v2.0-20250310.pdf) +
  [元件位置图](https://files.pine64.org/doc/starpro64/StarPro64_v2.0_Component_Placement_Top-20250310.pdf)
  定位保险丝/PMIC/PD 芯片，测 12 V→5 V→3.3 V 的转换链；
- 检查 **启动 DIP 开关**（wiki：StarPro64 的 boot DIP 开关语义同 Star64，"ON"=0，
  switch1 是最低位）——被误拨到无有效启动设备的组合，也会"什么都不出来"；
- 主板级返修（换 PMIC）或联系 PINE64/ESWIN 走 RMA。这类芯片级维修需要热风台/植球能力。

---

## 6. 今天就能做的 3 件事

1. **接串口**（L1）：USB-UART 3V3 接 Pin 6/8/10，`minicom -D /dev/ttyUSB0 -b 115200`，
   **接好再上电**，把第一个字符截图/复制下来 —— 这一条信息基本决定后面所有路线。
2. **量电压**（L0）：12 V 输入 + 板上 5 V/3.3 V 测试点；顺手确认适配器是 12 V/≥3 A 中心正极。
3. **别再反复上电试引导**：在 DTB 修好前，`l2` 每启动一次都可能再写一次 `0x0f` 那颗芯片；
   要试就进 U-Boot 选 `l0`。

### 需要你确认的信息（我据此收敛结论）
1. 现在插 12 V：板上**任何** LED 有没有一闪？风扇转吗？SoC/PMIC 有没有发烫？
2. 适配器规格？换过吗？空载量过 12 V 吗？
3. 串口线接了吗？上电瞬间**有没有任何字符**（哪怕乱码）？
4. 启动 DIP 开关现在的状态？之前动过吗？
5. "短接复位"具体短的是**哪两个点/哪个按键**？
6. 有没有焦味、变色、鼓包？

---

## 7. 红线 / 风险提示

- ❌ 不要再用带 `mpq8785@0f` 的 DTB 启动（会再写一次那颗芯片）。
- ❌ 不要带电插拔 eMMC / 短接任何未确认的测试点。
- ⚠️ 刷 SPI flash 前必须对齐官方镜像 md5，并做好散热。
- ⚠️ 本机"连不上板子"有时只是**静态路由没配**：
  `sudo ip ro add <board-subnet> via <gateway>` 后再试。

---

## 附录 A：本次分析的关键证据位置

| 内容 | 位置 |
|---|---|
| 扫射式 sed（烟枪） | `~/.pi/agent/sessions/--home-na-AIPCAIPC-rrrrvvvvvveeeeehh--/2026-09-26T15-40-39-542Z_*.jsonl` rec 702 |
| 原厂 DTB 里两个 `reg = <0x10>` 节点 | 本机 `dtc -I dtb -O dts eic7700-pine64-starpro64.dtb` → `es8388-0@10`(i2c@50950000)、`mpq8785@10`(i2c@50960000) |
| 原厂 DTB md5（三份一致） | `8d139df31f829b13c738851bd3efbdaf` |
| power/status LED 是 gpio-leds | 原厂 DTB 反编译 `leds { compatible="gpio-leds"; power{default-on} status{heartbeat} }` |
| PMIC 写寄存器代码 | `eswin-nntools/kernel-rockos/drivers/regulator/mpq8785.c:1140,1167`（CMD 0x20/0x24；`set command:0x24 value:0xf2c0`） |
| 启动项 / rescue | 会话中的 `/boot/extlinux/extlinux.conf`（l0/l0r/l1/l2/l2r） |
| U-Boot 镜像与型号 | `eswin-nntools/investigation/2026-09-24-uboot-fdt/uboot-starpro64.bin`（`board=eic7700_evb`, `bootcmd=bootflow scan -lb`） |

## 附录 B：外部参考

- PINE64 Wiki StarPro64（供电 12 V/3–5 A、16 MB XSPI NOR、DIP 开关）：<https://wiki.pine64.org/wiki/STARPro64>
- NuttX StarPro64（串口 Pin 6/8/10、115200）：<https://nuttx.apache.org/docs/latest/platforms/risc-v/eic7700x/boards/starpro64/index.html>
- Lup Yuen 上手文（启动流程、eMMC 刷写、`es_burn`、过热警告）：<https://lupyuen.github.io/articles/starpro64>
- Post-market 镜像：<https://fast-mirror.isrc.ac.cn/rockos/images/generic/latest/>
