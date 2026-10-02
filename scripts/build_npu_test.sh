#!/bin/bash
# Cross-compile the kernel (riscv64) with clang, used to validate the
# Eswin NPU driver port. Wrapper: clang --target=riscv64-linux-gnu.
set -euo pipefail
K=$KDIR
W=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$W/crossbin"

cat > "$W/crossbin/riscv64-linux-gnu-gcc" <<'EOF'
#!/bin/bash
exec clang --target=riscv64-linux-gnu "$@"
EOF
# binutils stand-ins (clang/llvm toolchain has no separate riscv binutils)
cat > "$W/crossbin/riscv64-linux-gnu-ld" <<'EOF'
#!/bin/bash
exec ld.lld "$@"
EOF
cat > "$W/crossbin/riscv64-linux-gnu-objcopy" <<'EOF'
#!/bin/bash
exec llvm-objcopy "$@"
EOF
cat > "$W/crossbin/riscv64-linux-gnu-ar" <<'EOF'
#!/bin/bash
exec llvm-ar "$@"
EOF
cat > "$W/crossbin/riscv64-linux-gnu-ranlib" <<'EOF'
#!/bin/bash
exec llvm-ar -s "$@"
EOF
cat > "$W/crossbin/riscv64-linux-gnu-nm" <<'EOF'
#!/bin/bash
exec llvm-nm "$@"
EOF
cat > "$W/crossbin/riscv64-linux-gnu-strip" <<'EOF'
#!/bin/bash
exec llvm-objcopy --strip-all "$@"
EOF
chmod +x "$W/crossbin/"*

export PATH="$W/crossbin:$PATH"
export CROSS_COMPILE=riscv64-linux-gnu-
cd "$K"

if [ ! -f .config ]; then
	make ARCH=riscv defconfig >/dev/null
fi

# Eswin NPU/MMZ stack options (see session-c-dtb-mmz.md)
scripts/config --file .config \
	--enable MEMORY \
	--enable ESWIN_MC \
	--enable ESWIN_RSV_MEMBLOCK \
	--enable ESWIN_CODACACHE_CONTROLLER \
	--enable ESWIN_BUDDY \
	--enable ESWIN_PROC \
	--enable ESWIN_RSVMEM_HEAP \
	--enable ESWIN_MMZ_VB \
	--enable ESWIN_DEV_DMA_BUF \
	--enable ESWIN_IOMMU_RSV \
	--enable ESWIN_DMA_MEMCP \
	--enable ESWIN_MALLOC_DMABUF \
	--enable MAILBOX \
	--enable ESWIN_MBOX \
	--enable ESWIN_DSP \
	--enable ESWIN_NPU

make ARCH=riscv olddefconfig >/dev/null
grep -E "CONFIG_(ESWIN|MBOX|MEMORY)=" .config

# build dtbs + prepare modules
make -j"$(nproc)" ARCH=riscv dtbs 2>&1 | tail -5
make -j"$(nproc)" ARCH=riscv modules_prepare 2>&1 | tail -3

# compile the new drivers as out-of-tree module builds
make ARCH=riscv M=drivers/mailbox \
	extramodules 2>&1 | tail -3 || true

for m in drivers/memory/eswin/codacache drivers/memory/eswin/es_buddy \
	 drivers/memory/eswin/es_proc drivers/memory/eswin/es_rsvmem_heap \
	 drivers/memory/eswin/es_mmz_vb drivers/memory/eswin/es_dev_buf \
	 drivers/memory/eswin/es_iommu_rsv drivers/memory/eswin/es_dma_memcp \
	 drivers/memory/eswin/es_malloc_dmabuf \
	 drivers/soc/eswin/ai_driver/npu drivers/soc/eswin/ai_driver/dsp; do
	echo "=== building $m"
	make ARCH=riscv M="$m" 2>&1 | grep -E "error|warning: implicit|Error" | head -20 || true
done
