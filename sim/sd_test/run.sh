#!/usr/bin/env bash
# Build and run the line doubler test for sys/scandoubler.v (pass -v for timing).
set -e
cd "$(dirname "$0")"
OSS=${OSS:-/c/Users/jnngi/Downloads/oss-cad-suite}
export VERILATOR_ROOT=$OSS/share/verilator
VI=$VERILATOR_ROOT/include
rm -rf obj; mkdir obj
$OSS/bin/verilator_bin.exe --cc ../../sys/scandoubler.v --top-module scandoubler --public \
	-GLENGTH=1056 -GHALF_DEPTH=1 --Mdir obj -Wno-fatal -Wno-WIDTH > obj/vl.log 2>&1 || { cat obj/vl.log; exit 1; }
for f in obj/*.cpp $VI/verilated.cpp $VI/verilated_threads.cpp tb.cpp; do
	zig c++ -c -w -O1 -std=c++17 -I obj -I $VI -I $VI/vltstd $f -o obj/$(basename $f .cpp).o &
done
wait
zig c++ obj/*.o -o sdtest.exe
./sdtest.exe "$@"
