#!/usr/bin/env python3
"""Merge eic7700.dtsi into starpro64.dts (simulating #include) and drop the
dt-bindings preprocessor lines that this environment's dtc cannot process,
replacing the one used clock constant with a literal. Emits merged.dts."""
import re, sys

dtsi = open('eic7700.dtsi').read()
# strip the dt-bindings #include lines and pin the one clock macro used
dtsi = re.sub(r'#include <dt-bindings/clock/eswin,eic7700-clock.h>\n',
              '', dtsi)
dtsi = re.sub(r'#include <dt-bindings/reset/eswin,eic7700-reset.h>\n',
              '', dtsi)
dtsi = dtsi.replace('EIC7700_CLK_GATE_HSP_CFG_CLK', '1')

board = open('starpro64.dts').read()
assert '#include "eic7700.dtsi"' in board, "board include not found"
merged = board.replace('#include "eic7700.dtsi"', dtsi)
open('merged.dts', 'w').write(merged)
print("wrote merged.dts (%d bytes)" % len(merged))
