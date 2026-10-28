# Make rtl/sid/sid_tables.sv acceptable to Verilator (simulation copy only):
# initialised wire arrays become localparams, "wire" function arguments inputs.
import re, sys
p = sys.argv[1]
s = open(p, newline='').read()
s = re.sub(r'(?m)^wire(\s+\[[^\]]+\]\s+\w+\s*\[[^\]]+\]\s*=)', r'localparam\1', s)
s = re.sub(r'(?<=[(,])\s*wire\b', ' input', s)
# static initialisers of the filter's block-local registers
s = re.sub(r'(reg signed \[\d+:0\] (vi|vd)) = 0;', r'\1;', s)
# wave outputs are declared as wires but written in an always block
s = re.sub(r'(?m)^wire(\s+\[7:0\]\s+(_st_out|p_t_out|ps__out|pst_out)\[)', r'reg\1', s)
open(p, 'w', newline='').write(s)
