#!/usr/bin/env python3
"""List the directory of a .D81 image, or extract a file.  usage: d81dir.py image.d81 [name out.prg]"""
import sys

def sec(d, t, s):
    o = ((t - 1) * 40 + s) * 256
    return d[o:o + 256]

def entries(d):
    t, s = 40, 3
    seen = set()
    while t and (t, s) not in seen:
        seen.add((t, s))
        b = sec(d, t, s)
        for i in range(8):
            e = b[i * 32:i * 32 + 32]
            if e[2]:
                name = bytes(c for c in e[5:21] if c != 0xA0)
                yield e[2], e[3], e[4], name, e[30] | e[31] << 8
        t, s = b[0], b[1]

def read_file(d, t, s):
    out = b""
    seen = set()
    while t and (t, s) not in seen:
        seen.add((t, s))
        b = sec(d, t, s)
        out += b[2:256] if b[0] else b[2:b[1] + 1]
        t, s = b[0], b[1]
    return out

if __name__ == "__main__":
    d = open(sys.argv[1], "rb").read()
    hdr = sec(d, 40, 0)
    print("disk:", bytes(c for c in hdr[4:20] if c != 0xA0).decode("latin-1"))
    TYPES = {0: "DEL", 1: "SEQ", 2: "PRG", 3: "USR", 4: "REL", 5: "CBM"}
    for ftype, t, s, name, blocks in entries(d):
        n = name.decode("latin-1")
        extra = ""
        if ftype & 7 == 2:
            data = read_file(d, t, s)
            extra = "load $%04X, %d bytes" % (data[0] | data[1] << 8, len(data))
        print("%4d  %-18s %s  %s" % (blocks, '"' + n + '"', TYPES.get(ftype & 7, "?"), extra))
        if len(sys.argv) > 3 and n == sys.argv[2]:
            open(sys.argv[3], "wb").write(read_file(d, t, s))
