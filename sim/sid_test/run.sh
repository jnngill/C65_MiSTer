#!/usr/bin/env bash
# SID test: the two-chip SID must match the committed one sample for sample,
# and in the four-chip build chips 0 / 1 must match it too.
set -e
cd "$(dirname "$0")"
OSS=${OSS:-/c/Users/jnngi/Downloads/oss-cad-suite}
export VERILATOR_ROOT=$OSS/share/verilator
VI=$VERILATOR_ROOT/include
R=../../rtl/sid
build() {   # name, source dir, extra verilator args, extra c++ defines
	local d=build_$1; rm -rf $d; mkdir -p $d
	$OSS/bin/verilator_bin.exe --cc -sv --top-module sid_top $3 $2/sid_top.sv $2/sid_voice.sv $2/sid_tables.sv \
		$2/sid_filter.sv $2/sid_envelope.sv $2/sid_dac.sv --Mdir $d -O2 -Wno-fatal -Wno-WIDTH \
		-Wno-CASEINCOMPLETE -Wno-UNUSED -Wno-PINCONNECTEMPTY -Wno-DECLFILENAME > $d/vl.log 2>&1 || { cat $d/vl.log; exit 1; }
	for f in $d/*.cpp $VI/verilated.cpp $VI/verilated_threads.cpp tb.cpp; do
		zig c++ -c -w -O2 -std=c++17 $4 -I $d -I $VI -I $VI/vltstd $f -o $d/$(basename $f .cpp).o &
	done
	wait
	zig c++ $d/*.o -o $d/tb.exe
}
# Verilator does not take the tables' initialised wire arrays: use localparams
fix() { for f in $1/*.sv; do python -I fixtables.py $f; done; }
OLD=build_src_old; NEW=build_src_new; rm -rf $OLD $NEW; mkdir -p $OLD $NEW
for f in sid_top sid_voice sid_tables sid_filter sid_envelope sid_dac; do
	git show HEAD:rtl/sid/$f.sv > $OLD/$f.sv; cp $R/$f.sv $NEW/
done
fix $OLD; fix $NEW
build old $OLD "" -DOLD &
build dual $NEW "" "" &
build quad $NEW "-GQUAD=1" "" &
wait
build_old/tb.exe out_old.txt
build_dual/tb.exe out_dual.txt
build_quad/tb.exe out_quad.txt 4
build_old/tb.exe out_swap.txt s
cmp out_old.txt out_dual.txt && echo "two-chip build: identical to the committed SID"
python -I - <<'PY'
o = [l.split() for l in open('out_old.txt') if not l.startswith('chip')]
q = [l.split() for l in open('out_quad.txt') if not l.startswith('chip')]
same = all(a[:2] == b[:2] for a, b in zip(o, q))
print('four-chip build, chips 0/1 identical to the committed SID:', same)
w = [l.split() for l in open('out_swap.txt') if not l.startswith('chip')]
print('four-chip build, chips 2/3 identical to the committed SID playing their settings:', all(a[:2] == b[2:4] for a, b in zip(w, q)))
for c in (2, 3):
    v = [int(r[c]) for r in q]
    print('chip', c, 'min', min(v), 'max', max(v), 'distinct values', len(set(v)))
print(open('out_quad.txt').read().split('\n')[-5:])
PY
