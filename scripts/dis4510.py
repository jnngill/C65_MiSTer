#!/usr/bin/env python3
"""Tiny 4510 disassembler.  usage: dis4510.py <rom.bin> <file-offset-hex> <cpu-addr-hex> [count]"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sim", "ref"))
from tables4510 import INS, MODE

FMT = {"IMPL": (0, ""), "IMM": (1, "#$%02X"), "IMM16": (2, "#$%04X"), "ZP": (1, "$%02X"), "ZPX": (1, "$%02X,X"),
       "ZPY": (1, "$%02X,Y"), "ABS": (2, "$%04X"), "ABSX": (2, "$%04X,X"), "ABSY": (2, "$%04X,Y"),
       "INDX": (1, "($%02X,X)"), "INDY": (1, "($%02X),Y"), "INDZ": (1, "($%02X),Z"), "INDSPY": (1, "($%02X,SP),Y"),
       "REL": (1, None), "REL16": (2, None), "ZPREL": (2, None), "IND16": (2, "($%04X)"), "IND16X": (2, "($%04X,X)")}

def dis(d, off, addr, count):
    for _ in range(count):
        op = d[off]; ins, mode = INS[op], MODE[op]
        n, fmt = FMT[mode]
        b = d[off:off + 1 + n]
        v = int.from_bytes(b[1:], "little") if n else 0
        if mode == "REL":
            arg = "$%04X" % ((addr + 2 + (v - 256 if v & 0x80 else v)) & 0xFFFF)
        elif mode == "REL16":
            arg = "$%04X" % ((addr + 2 + (v - 65536 if v & 0x8000 else v)) & 0xFFFF)
        elif mode == "ZPREL":
            r = b[2]
            arg = "$%02X,$%04X" % (b[1], (addr + 3 + (r - 256 if r & 0x80 else r)) & 0xFFFF)
        else:
            arg = (fmt % v) if n else ""
        if ins in ("RMB", "SMB", "BBR", "BBS"):
            ins += str((op >> 4) & 7)
        print("%04X  %-9s %s %s" % (addr, b.hex(" "), ins, arg))
        off += 1 + n; addr += 1 + n

if __name__ == "__main__":
    d = open(sys.argv[1], "rb").read()
    dis(d, int(sys.argv[2], 16), int(sys.argv[3], 16), int(sys.argv[4]) if len(sys.argv) > 4 else 24)
