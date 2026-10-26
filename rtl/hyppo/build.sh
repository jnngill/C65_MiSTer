#!/usr/bin/env bash
# Build the hypervisor program (needs cc65, https://cc65.github.io; set CC65
# to its folder) into hyppo.hex, which rtl/hyp_ram.sv loads at configuration.
set -e
cd "$(dirname "$0")"
CC65=${CC65:-/c/Users/jnngi/Tools/cc65}
"$CC65/bin/cl65" -t none -C link.cfg -O -Or -Os -o hyppo.bin crt0.s hyppo.c
python -I - <<'PY'
d = open('hyppo.bin', 'rb').read()
assert len(d) <= 16384, len(d)
d = d + bytes(16384 - len(d))
open('hyppo.hex', 'w', newline='\n').write(''.join('%02x\n' % b for b in d))
PY
rm -f *.o hyppo.bin
