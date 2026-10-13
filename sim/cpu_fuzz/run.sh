#!/usr/bin/env bash
# Fuzz cpu4510.sv against the Python reference model.
# usage: run.sh [seeds=20] [instructions=200000]
set -e
cd "$(dirname "$0")"
OSS=${OSS:-/c/Users/jnngi/Downloads/oss-cad-suite}
export VERILATOR_ROOT=$OSS/share/verilator
VI=$VERILATOR_ROOT/include
B=build; mkdir -p $B
$OSS/bin/verilator_bin.exe --cc ../../rtl/cpu/cpu4510.sv -I../../rtl/cpu --Mdir $B/obj -O2 -Wno-fatal >$B/verilator.log 2>&1 || { cat $B/verilator.log; exit 1; }
grep -E '%(Warning|Error)' $B/verilator.log | sort | uniq -c | head -20 || true
zig c++ -O2 -std=c++17 -I $B/obj -I $VI -I $VI/vltstd tb.cpp $B/obj/*.cpp $VI/verilated.cpp $VI/verilated_threads.cpp -o $B/tb.exe
fail=0
for seed in $(seq 1 ${1:-20}); do
	python -I ref_trace.py $seed ${2:-200000} $B/mem.bin $B/ref.txt
	$B/tb.exe $B/mem.bin $B/rtl.txt ${2:-200000}
	if cmp -s $B/ref.txt $B/rtl.txt; then echo "seed $seed: PASS"; else
		echo "seed $seed: FAIL"; fail=1
		python -I - $B <<'PY'
import sys
b=sys.argv[1]
r=open(b+'/ref.txt').read().split('\n'); t=open(b+'/rtl.txt').read().split('\n')
m=open(b+'/mem.bin','rb').read()
for i,(x,y) in enumerate(zip(r,t)):
    if x!=y:
        print(' first diff at instruction',i)
        for j in range(max(0,i-2),i+1): print('  ref',r[j],'| rtl',t[j])
        pc=int(r[i-1][:4],16); print('  prev opcode bytes (unmapped view): %s'%m[pc:pc+3].hex())
        break
PY
		break
	fi
done
exit $fail
