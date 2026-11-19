#!/usr/bin/env bash
# Build rxirq.prg (VIC-IV X raster interrupt test) with cc65.
set -e
cd "$(dirname "$0")"
CC65=${CC65:-/c/Users/jnngi/Tools/cc65/bin}
$CC65/ca65.exe rxirq.s -o rxirq.o
$CC65/ld65.exe -C link.cfg rxirq.o -o rxirq.prg
rm -f rxirq.o
