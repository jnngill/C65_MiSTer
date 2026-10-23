#!/usr/bin/env python3
"""Turn a simulator key script (sim/system/keys_*.txt) into text for mister_hw.sh type.

usage: keys2type.py keys_file.txt  ->  prints the lines joined with "~" (RETURN),
       without the frame numbers, the trailing \\r markers and any "run" line.
"""
import re, sys

out = []
for line in open(sys.argv[1]):
    line = re.sub(r'^\d+ ', '', line.rstrip('\n'))
    if line.endswith(chr(92) + 'r'):          # the two characters \ r
        line = line[:-2]
    if line.strip() == 'run':
        continue
    out.append(line.replace('$', '{dollar}'))
sys.stdout.write('~'.join(out) + '~')
