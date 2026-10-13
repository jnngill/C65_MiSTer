#!/usr/bin/env python3
"""Convert a binary PPM (P6) to PNG without external libraries.  usage: ppm2png.py in.ppm out.png"""
import sys, zlib, struct

def main(src, dst):
    d = open(src, "rb").read()
    parts = d.split(b"\n", 3)
    w, h = map(int, parts[1].split())
    pix = parts[3]
    raw = b"".join(b"\x00" + pix[y * w * 3:(y + 1) * w * 3] for y in range(h))
    def chunk(t, c):
        return struct.pack(">I", len(c)) + t + c + struct.pack(">I", zlib.crc32(t + c) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
    open(dst, "wb").write(png)

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
