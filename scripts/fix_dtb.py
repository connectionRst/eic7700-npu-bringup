#!/usr/bin/env python3
import subprocess, sys, re

DTB_PATH = '/boot/dtbs/linux-image-6.6.88-win2030/eswin/eic7700-pine64-starpro64.dtb'
OUT_DTS = '/home/debian/vendor-modified.dts'
OUT_DTB = '/home/debian/vendor-fixed.dtb'

# Decode vendor DTB to DTS
r = subprocess.run(['sudo', 'dtc', '-I', 'dtb', '-O', 'dts', DTB_PATH],
    capture_output=True, text=True)
if r.returncode != 0:
    print("Failed to decode DTB:", r.stderr)
    sys.exit(1)
content = r.stdout

# Insert regulator-fixed node AFTER the model line (after all top-level properties)
node = '\tnpu_svcc_fixed: regulator-npu-svcc {\n'
node += '\t\tcompatible = "regulator-fixed";\n'
node += '\t\tregulator-name = "npu-svcc";\n'
node += '\t\tregulator-min-microvolt = <900000>;\n'
node += '\t\tregulator-max-microvolt = <900000>;\n'
node += '\t\tregulator-always-on;\n'
node += '\t\tregulator-boot-on;\n'
node += '\t};'

# Find the model line and insert after it
content = content.replace(
    '\tmodel = "Pine64 StarPro64";\n',
    '\tmodel = "Pine64 StarPro64";\n' + node + '\n',
    1
)

# Replace npu-supply phandles
content = content.replace('npu-supply = <0x20>;', 'npu-supply = <&npu_svcc_fixed>;')

# Write DTS
with open(OUT_DTS, 'w') as f:
    f.write(content)
print(f"Wrote {OUT_DTS}")

# Compile
r = subprocess.run(['dtc', '-I', 'dts', '-O', 'dtb', '-o', OUT_DTB, OUT_DTS],
    capture_output=True, text=True)
if r.returncode != 0:
    print("Failed to compile:", r.stderr)
    sys.exit(1)
print(f"Compiled {OUT_DTB}")

# Deploy
r = subprocess.run(['sudo', 'cp', OUT_DTB, DTB_PATH], capture_output=True, text=True)
if r.returncode != 0:
    print("Failed to deploy:", r.stderr)
    sys.exit(1)
print("Deployed to", DTB_PATH)

# Verify
r = subprocess.run(['sudo', 'dtc', '-I', 'dtb', '-O', 'dts', DTB_PATH],
    capture_output=True, text=True)
for line in r.stdout.split('\n'):
    if 'npu-supply' in line or 'npu_svcc_fixed' in line:
        print(line.strip())
