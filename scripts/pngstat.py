#!/usr/bin/env python3
"""Print the most common pixel colours of a PNG (8-bit RGB/RGBA, non-interlaced).  usage: pngstat.py file.png"""
import sys, zlib, struct, collections

def load(path):
    d = open(path, "rb").read()
    o = 8; idat = b""; w = h = bpp = 0
    while o < len(d):
        n, t = struct.unpack(">I4s", d[o:o + 8])
        c = d[o + 8:o + 8 + n]; o += 12 + n
        if t == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", c[:10])
            bpp = {2: 3, 6: 4, 0: 1}[ctype]
        elif t == b"IDAT":
            idat += c
    raw = zlib.decompress(idat)
    stride = w * bpp
    rows = []; prev = bytearray(stride); p = 0
    for _ in range(h):
        f = raw[p]; line = bytearray(raw[p + 1:p + 1 + stride]); p += 1 + stride
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c2 = prev[i - bpp] if i >= bpp else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + ((a + b) >> 1)) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c2), abs(a - c2), abs(a + b - 2 * c2)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c2)
                line[i] = (line[i] + pr) & 255
        rows.append(line); prev = line
    return w, h, bpp, rows

if __name__ == "__main__":
    w, h, bpp, rows = load(sys.argv[1])
    c = collections.Counter(tuple(r[i:i + 3]) for r in rows for i in range(0, len(r), bpp))
    print(w, h, c.most_common(8))
