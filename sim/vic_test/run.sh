#!/usr/bin/env bash
# Build the video-chip-only test (rtl/vic3.sv against memory dumps of the system sim).
#   run.sh <dumpdir> <regs.txt> <frames> <out.ppm> [lb.bin]
set -e
cd "$(dirname "$0")"
OSS=${OSS:-/c/Users/jnngi/Downloads/oss-cad-suite}
export VERILATOR_ROOT=$OSS/share/verilator
VI=$VERILATOR_ROOT/include
if [ ! -f victest.exe ] || [ ../../rtl/vic3.sv -nt victest.exe ] || [ tb.cpp -nt victest.exe ]; then
	rm -rf obj; mkdir obj
	$OSS/bin/verilator_bin.exe --cc ../../rtl/vic3.sv ../../rtl/dpram.sv --top-module vic3 --public-flat-rw ${VDEFS} \
		--Mdir obj -O3 -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-UNUSED > obj/vl.log 2>&1 || { cat obj/vl.log; exit 1; }
	for f in obj/*.cpp $VI/verilated.cpp $VI/verilated_threads.cpp tb.cpp; do
		zig c++ -c -w -O2 -std=c++17 -I obj -I $VI -I $VI/vltstd $f -o obj/$(basename $f .cpp).o &
	done
	wait
	zig c++ obj/*.o -o victest.exe
fi
D=$(cd "$OLDPWD" && realpath "$1"); R=$(cd "$OLDPWD" && realpath "$2"); O=$(cd "$OLDPWD" && realpath -m "$4")
L=""; [ -n "$5" ] && L=$(cd "$OLDPWD" && realpath -m "$5")
./victest.exe "$D" "$R" "$3" "$O" $L
