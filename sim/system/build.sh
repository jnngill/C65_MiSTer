#!/usr/bin/env bash
# Build the whole-system Verilator model (sim/system/build/tb.exe).
set -e
cd "$(dirname "$0")"
OSS=${OSS:-/c/Users/jnngi/Downloads/oss-cad-suite}
export VERILATOR_ROOT=$OSS/share/verilator
VI=$VERILATOR_ROOT/include
R=../../rtl
B=build; mkdir -p $B
$OSS/bin/verilator_bin.exe --cc --top-module c65_core -DC65_NO_SID \
	-I$R -I$R/cpu \
	$R/c65_core.sv $R/cpu/cpu4510.sv $R/vic3.sv $R/dma_f018.sv $R/f011.sv $R/c65_keyboard.sv $R/dpram.sv $R/mos6526_8520.v \
	--Mdir $B/obj -O3 --x-assign fast --x-initial fast -Wno-fatal \
	-Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-UNUSED -Wno-PINCONNECTEMPTY -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
	>$B/verilator.log 2>&1 || { cat $B/verilator.log; exit 1; }
grep -E -A3 '%(Warning|Error)' $B/verilator.log | head -${VLINES:-40} || true
# compile each generated file once (cached by timestamp)
objs=""
for src in $B/obj/*.cpp $VI/verilated.cpp $VI/verilated_threads.cpp tb.cpp; do
	o=$B/$(basename $src .cpp).o
	if [ ! -f $o ] || [ $src -nt $o ] || { [ $src = tb.cpp ] && [ $B/obj/Vc65_core.h -nt $o ]; }; then
		rm -f $o
		zig c++ -c -w -O2 -std=c++17 -I $B/obj -I $VI -I $VI/vltstd $src -o $o &
	fi
	objs="$objs $o"
done
wait
for o in $objs; do [ -f $o ] || { echo "compile failed: $o"; exit 1; }; done
zig c++ -O2 $objs -o $B/tb.exe
echo "built $B/tb.exe"
