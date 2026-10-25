#!/usr/bin/env bash
# Build C65TERM (needs cc65, https://cc65.github.io; set CC65 to its folder).
set -e
cd "$(dirname "$0")"
CC65=${CC65:-/c/Users/jnngi/Tools/cc65}
"$CC65/bin/cl65" -t c65 ${CFLAGS} -C link.cfg -O -Or -Os -Cl -m c65term.map -o c65term.prg \
	ui.c emu.c screen.c serial.c xfer.c font.c hw.s sysmap.s
ls -l c65term.prg
