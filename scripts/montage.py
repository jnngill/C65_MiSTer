#!/usr/bin/env python3
"""montage.py out.png scale cols label1=img1.png label2=img2.png ...

Tiles 8-bit RGB PNGs (as written by ppm2png.py) into one image, each scaled
down by an integer factor.  No dependencies."""
import struct, sys, zlib


def read_png(path):
    d = open(path, 'rb').read()
    pos, w, h, idat = 8, 0, 0, b''
    while pos < len(d):
        n, t = struct.unpack('>I4s', d[pos:pos + 8])
        c = d[pos + 8:pos + 8 + n]
        if t == b'IHDR':
            w, h = struct.unpack('>II', c[:8])
        elif t == b'IDAT':
            idat += c
        pos += 12 + n
    raw = zlib.decompress(idat)
    stride = w * 3
    rows, prev, p = [], bytearray(stride), 0
    for _ in range(h):
        f = raw[p]; line = bytearray(raw[p + 1:p + 1 + stride]); p += 1 + stride
        for i in range(stride):
            a = line[i - 3] if i >= 3 else 0
            b = prev[i]
            c = prev[i - 3] if i >= 3 else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + ((a + b) >> 1)) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        rows.append(line); prev = line
    return w, h, rows


def write_png(path, w, h, rows):
    raw = b''.join(b'\x00' + bytes(r) for r in rows)
    def chunk(t, c):
        return struct.pack('>I', len(c)) + t + c + struct.pack('>I', zlib.crc32(t + c) & 0xffffffff)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
                chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))


def main():
    out, sc, cols = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    tiles = []
    for a in sys.argv[4:]:
        try:
            w, h, rows = read_png(a)
        except Exception:
            continue
        tiles.append((w // sc, h // sc, [bytes(b for x in range(w // sc) for b in r[x * sc * 3:x * sc * 3 + 3]) for r in rows[::sc][:h // sc]]))
    if not tiles:
        return
    tw = max(t[0] for t in tiles) + 4; th = max(t[1] for t in tiles) + 4
    nrow = (len(tiles) + cols - 1) // cols
    W, H = tw * cols, th * nrow
    canvas = [bytearray(b'\x40' * (W * 3)) for _ in range(H)]
    for i, (w, h, rows) in enumerate(tiles):
        ox, oy = (i % cols) * tw, (i // cols) * th
        for y in range(h):
            canvas[oy + y][ox * 3:(ox + w) * 3] = rows[y]
    write_png(out, W, H, canvas)


if __name__ == '__main__':
    main()
