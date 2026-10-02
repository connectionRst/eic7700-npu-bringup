#!/bin/bash
# Sparse clone of eswincomputing/linux-stable @ da228da (vendor EIC7X kernel)
# to fetch the NPU/LLC/DSP/mailbox/memory driver sources for porting.
set -euo pipefail

SHA=da228da68a382684b01f6c0717effafcec2bee76
DIR=$(dirname "$0")/vendor-kernel
REPO=https://github.com/eswincomputing/linux-stable

if [ -d "$DIR/.git" ]; then
	echo "clone exists, fetching"
	git -C "$DIR" fetch origin "$SHA" || true
else
	git clone --filter=blob:none --no-checkout "$REPO" "$DIR"
fi
git -C "$DIR" checkout -q "$SHA" || git -C "$DIR" checkout -q FETCH_HEAD

git -C "$DIR" sparse-checkout set --no-cone \
	'drivers/soc/eswin/**' \
	'drivers/memory/eswin/**' \
	'drivers/mailbox/**' \
	'include/dt-bindings/**' \
	'include/linux/es*.h' \
	'include/uapi/linux/es*.h' \
	'arch/riscv/boot/dts/eswin/**' \
	'drivers/soc/Kconfig' \
	'drivers/soc/Makefile' \
	'drivers/memory/Kconfig' \
	'drivers/memory/Makefile' \
	'drivers/mailbox/Kconfig' \
	'drivers/mailbox/Makefile'

echo done
find "$DIR" -type f | wc -l
