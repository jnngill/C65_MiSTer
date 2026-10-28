#!/usr/bin/env bash
# Audio DMA unit test: interrupts and sine mode of rtl/m65_audio.sv.
set -e
cd "$(dirname "$0")"
OSS=${OSS:-/c/Users/jnngi/Downloads/oss-cad-suite}
export VERILATOR_ROOT=$OSS/share/verilator
VI=$VERILATOR_ROOT/include
B=build; rm -rf $B; mkdir -p $B
$OSS/bin/verilator_bin.exe --cc --top-module m65_audio ../../rtl/m65_audio.sv --Mdir $B -O2 -Wno-fatal -Wno-WIDTH > $B/vl.log 2>&1 || { cat $B/vl.log; exit 1; }
for f in $B/*.cpp $VI/verilated.cpp $VI/verilated_threads.cpp tb.cpp; do
	zig c++ -c -w -O2 -std=c++17 -I $B -I $VI -I $VI/vltstd $f -o $B/$(basename $f .cpp).o &
done
wait
zig c++ $B/*.o -o $B/tb.exe
$B/tb.exe
