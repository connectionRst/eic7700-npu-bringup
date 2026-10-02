#!/bin/bash
# restore-boot-files.sh — StarPro64 (EIC7700) 事故后回滚脚本
# 依据: eswin-nntools/BOARD-DAMAGE-REPORT.md 第 5 节 L3。
# 用法（板子上）:
#   bash ~/restore-boot-files.sh check      # 只看不写
#   sudo bash ~/restore-boot-files.sh apply # 实际回滚
# 注意: 若默认启动项 l2 已起不来，先在 U-Boot 菜单选 l0 (RockOS 7.2，自带未动过的 DTB) 进系统。
set -u
KVER=6.6.88-win2030
DTB_DIR="/boot/dtbs/linux-image-${KVER}/eswin"
DTB="${DTB_DIR}/eic7700-pine64-starpro64.dtb"
INITRD="/boot/initrd.img-${KVER}"
NPU_KO="/lib/modules/${KVER}/kernel/drivers/soc/eswin/ai_driver/npu/eic7700_npu.ko"
GOOD_MD5="8d139df31f829b13c738851bd3efbdaf"
MODE="${1:-check}"
md5_of() { [ -f "$1" ] && md5sum "$1" 2>/dev/null | awk '{print $1}' || echo MISSING; }
size_of() { [ -f "$1" ] && stat -c '%s bytes  %y' "$1" 2>/dev/null || echo MISSING; }
echo "=== StarPro64 启动文件状态 ($MODE) ==="
echo "[1] DTB  $DTB"; echo "    现状: $(size_of "$DTB")"; echo "    md5 : $(md5_of "$DTB")  (原厂应为 $GOOD_MD5)"
echo "    备份: ${DTB}.bak -> $(md5_of "${DTB}.bak")"
echo "[2] initrd  $INITRD -> $(size_of "$INITRD")"
echo "[3] NPU 模块  $NPU_KO -> $(size_of "$NPU_KO")  .bak -> $(size_of "${NPU_KO}.bak")"
[ "$MODE" != "apply" ] && { echo "（check 模式，未修改。回滚请用: sudo bash $0 apply）"; exit 0; }
[ "$(id -u)" != "0" ] && { echo "ERROR: apply 模式需要 root"; exit 1; }
if [ -f "${DTB}.bak" ]; then cp -f "${DTB}.bak" "$DTB"; echo "OK 已还原 DTB (.bak)"
elif [ -f "${DTB}.orig2" ]; then cp -f "${DTB}.orig2" "$DTB"; echo "OK 已还原 DTB (.orig2)"
else echo "WARN 板上无备份；请 scp 本机原厂副本后覆盖"; fi
[ "$(md5_of "$DTB")" = "$GOOD_MD5" ] && echo "OK DTB md5 校验通过" || echo "WARN DTB md5 与原厂不符，请人工确认"
for c in "/home/debian/initrd.img-${KVER}.bak" "/home/debian/initrd.img-${KVER}.orig2" "/home/debian/initrd.img-${KVER}.without-fw.bak"; do
  [ -f "$c" ] && { cp -f "$c" "$INITRD"; echo "OK 已还原 initrd: $c"; break; }
done
[ -f "${NPU_KO}.bak" ] && { cp -f "${NPU_KO}.bak" "$NPU_KO"; command -v depmod >/dev/null && depmod -a "$KVER"; echo "OK 已还原 NPU 模块 + depmod"; } || echo "WARN 无 NPU 模块备份"
echo "完成。确认 md5 后再 reboot。"
