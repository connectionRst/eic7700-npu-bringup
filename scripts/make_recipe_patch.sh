#!/bin/bash
# Build the recipe patch(es) for the Eswin NPU port.
# Base state = pmb master + recipe patches 0019-0031 (for the dtsi).
set -euo pipefail
S=$WORKSPACE/eswin-nntools/.patch-staging
K=$KDIR
OUT=$S/patches
mkdir -p "$OUT"

# staged repo with base files
R=$S/repo3
if [ ! -d "$R/.git" ]; then
	mkdir -p "$R"
	cd "$R"
	git init -q
fi
cd "$R"
git checkout -q . 2>/dev/null || true

# 1. dtsi base = post-0031 reconstruction
mkdir -p arch/riscv/boot/dts/eswin
cp $S/eic7700.dtsi.post0031 arch/riscv/boot/dts/eswin/eic7700.dtsi

# 2. other modified files: base from pmb master
for f in arch/riscv/boot/dts/eswin/Makefile \
	 drivers/mailbox/Kconfig drivers/mailbox/Makefile \
	 drivers/memory/Kconfig drivers/memory/Makefile \
	 drivers/soc/Kconfig drivers/soc/Makefile \
	 drivers/iommu/Makefile; do
	mkdir -p "$(dirname $f)"
	git -C "$K" show "master:$f" > "$f"
done

# commit base
git add -A >/dev/null
git -c user.email=dev@local -c user.name=dev commit -qm base || true

# 3. overlay my versions (tracked status only; build artifacts are gitignored)
while IFS= read -r line; do
	f=$line
	case "$f" in
		arch/riscv/boot/dts/eswin/eic7700.dtsi|arch/riscv/boot/dts/eswin/Makefile|arch/riscv/boot/dts/eswin/eic7700-sbc-a1.dts)
			mkdir -p "$(dirname $f)"; cp "$K/$f" "$f" ;;
		drivers/mailbox/Kconfig|drivers/mailbox/Makefile|drivers/mailbox/eswin-mailbox.c)
			mkdir -p "$(dirname $f)"; cp "$K/$f" "$f" ;;
		drivers/iommu/Makefile|drivers/iommu/eswin/*)
			mkdir -p "$(dirname $f)"; cp "$K/$f" "$f" ;;
		drivers/memory/Kconfig|drivers/memory/Makefile)
			mkdir -p "$(dirname $f)"; cp "$K/$f" "$f" ;;
		drivers/memory/eswin/*)
			mkdir -p "$(dirname $f)"; cp "$K/$f" "$f" ;;
		drivers/soc/Kconfig|drivers/soc/Makefile)
			mkdir -p "$(dirname $f)"; cp "$K/$f" "$f" ;;
		drivers/soc/eswin/*)
			mkdir -p "$(dirname $f)"; cp "$K/$f" "$f" ;;
		include/dt-bindings/interconnect/eswin,win2030.h|include/dt-bindings/mailbox/eswin-mailbox.h|include/dt-bindings/memory/eswin-win2030-sid.h)
			mkdir -p "$(dirname $f)"; cp "$K/$f" "$f" ;;
		include/linux/mailbox/eswin-mailbox.h)
			mkdir -p "$(dirname $f)"; cp "$K/$f" "$f" ;;
		include/linux/*|include/uapi/linux/*)
			case "$f" in
				include/linux/es_iommu_rsv.h|include/linux/es_proc.h|include/linux/eswin_cpuid_hartid_convert.h|include/linux/eswin_npu.h|include/linux/eswin_rsvmem_common.h|include/linux/eswin-win2030-sid-cfg.h|include/linux/win2030_noc.h|include/linux/dmabuf-heap-import-helper.h|include/uapi/linux/es_vb_user.h|include/uapi/linux/mmz_vb.h|include/uapi/linux/dma_memcp.h|include/uapi/linux/malloc_dmabuf.h)
					mkdir -p "$(dirname $f)"; cp "$K/$f" "$f" ;;
			esac ;;
	esac
done < <( { git -C "$K" ls-files --others --exclude-standard; \
	git -C "$K" diff --name-only; } )

git add -A >/dev/null
git -c user.email=dev@local -c user.name=dev commit -qm mine
git format-patch -q --start-number 100 HEAD~1 -o "$OUT"
ls "$OUT"
