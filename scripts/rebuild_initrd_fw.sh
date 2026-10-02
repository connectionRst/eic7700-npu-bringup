#!/bin/bash
# 重 pack initrd：加入 DSP/NPU 固件 + 新 eic7700_dsp.ko，用于测试
# "固件在 autoload 时刻即可用"能否让 DSP 在启动即绑上。
set -e
BAK=/home/debian/initrd.img-6.6.88-win2030.bak
WORK=/home/debian/ird_fwk
NEW=/home/debian/initrd-fwk.img
rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"
echo "[1/5] 解压备份 initrd"
zstd -dc "$BAK" | cpio -idm --no-absolute-filenames 2>/dev/null
echo "[2/5] 加固件到 usr/lib/firmware"
for f in eic7700_dsp_fw eic7700_die0_e31_fw eic7700_die1_e31_fw; do
  if [ -f /lib/firmware/$f ]; then cp -f /lib/firmware/$f usr/lib/firmware/ 2>/dev/null || cp -f /lib/firmware/$f usr/lib/modules/../firmware/ 2>/dev/null || true; fi
done
[ -d /lib/firmware/mcudfx ] && cp -r /lib/firmware/mcudfx usr/lib/firmware/ 2>/dev/null || true
# 保险：/lib 若未并到 usr，也补一份
[ -d /lib/firmware ] && [ ! -L /lib/firmware ] && for f in eic7700_dsp_fw eic7700_die0_e31_fw eic7700_die1_e31_fw; do [ -f /lib/firmware/$f ] && cp -f /lib/firmware/$f lib/firmware/ 2>/dev/null || true; done
echo "[3/5] 替换 eic7700_dsp.ko(新,vermagic 6.6.88-win2030+defer修复)"
cp -f /home/debian/eic7700_dsp_new.ko usr/lib/modules/6.6.88-win2030/kernel/drivers/soc/eswin/ai_driver/dsp/eic7700_dsp.ko
echo "[4/5] 打包(newc+zstd)"
find . | cpio -o -H newc 2>/dev/null | zstd -T0 > "$NEW"
echo "[5/5] 校验"
echo -n "  模块在: "; zstd -dc "$NEW" | cpio -t 2>/dev/null | grep -c "ai_driver/dsp/eic7700_dsp.ko"
echo -n "  dsp_fw在: "; zstd -dc "$NEW" | cpio -t 2>/dev/null | grep -c "eic7700_dsp_fw$"
echo "  新initrd大小: $(wc -c < "$NEW") bytes"
echo "完成: $NEW"
