#!/bin/bash
# Runs ~35s after multi-user target: deferred DSP probes should have resolved
# once rootfs(+firmware) are up. Writes results to /home/debian/npu_boot_check.out.
exec > /home/debian/npu_boot_check.out 2>&1
echo "=== npu_boot_check $(date) ==="
echo "uptime: $(cut -d' ' -f1 /proc/uptime)s"
sleep 25
echo
echo "=== DSP cores bound? ==="
for c in 0 1 2 3; do
  d=$(ls -d /sys/devices/platform/52280400.dsp_subsys:es_dsp@$c/driver 2>/dev/null)
  echo "es_dsp@$c -> $([ -n "$d" ] && echo BOUND || echo NOT-BOUND)"
done
echo
echo "=== NPU bound? ==="
ls -d /sys/devices/platform/51c00000.eswin-npu/driver >/dev/null 2>&1 && echo "npu BOUND" || echo "npu NOT-BOUND"
echo
echo "=== firmware ENOENT count since boot ==="
sudo dmesg | grep -c "Direct firmware load for eic7700_dsp_fw failed"
echo
echo "=== recent DSP/NPU probe log ==="
sudo dmesg | grep -iE "es_dsp@[0-9]:|eswin-npu|Direct firmware|probe successful|deferring" | tail -15
echo
echo "=== modules ==="
lsmod | grep -iE "npu|dsp|llc|mmz"
echo
echo "=== mmz_vb device ==="
ls -la /dev/mmz_vb 2>&1
