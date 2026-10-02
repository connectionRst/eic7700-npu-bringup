#!/bin/bash
# Iterate compilation of all ported Eswin modules; prints per-dir errors.
set -uo pipefail
cd $KDIR
export PATH="$WORKSPACE/eswin-nntools/crossbin:$PATH"
export CC=riscv64-linux-gnu-gcc CROSS_COMPILE=riscv64-linux-gnu-

DIRS="drivers/mailbox drivers/memory/eswin/codacache drivers/memory/eswin/es_buddy \
drivers/memory/eswin/es_proc drivers/memory/eswin/es_rsvmem_heap \
drivers/memory/eswin/es_mmz_vb drivers/memory/eswin/es_dev_buf \
drivers/memory/eswin/es_iommu_rsv drivers/memory/eswin/es_dma_memcp \
drivers/memory/eswin/es_malloc_dmabuf drivers/soc/eswin"

for d in $DIRS; do
	out=$(make -j8 ARCH=riscv M=$d 2>&1)
	if [ $? -eq 0 ]; then
		echo "BUILD-OK  $d"
	else
		echo "BUILD-FAIL $d"
		echo "$out" | grep -E "error:" | head -15
	fi
done
