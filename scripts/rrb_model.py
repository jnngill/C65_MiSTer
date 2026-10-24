#!/usr/bin/env python3
"""Reference model of the VIC-IV CHR16 / RRB text renderer, for checking rtl/vic3.sv.

usage: rrb_model.py <dumpdir> <scrnptr-hex> <linestep> <chrcount> <out.ppm> [--rom rom.bin] [--attic-copy]

Reads the sim's memory dumps (ram.bin = $00000-$1FFFF, ram2.bin = $40000-$5FFFF,
cram2.bin = colour RAM $0800-$7FFF, rom.bin = $20000-$3FFFF) and draws the
200 text lines the way the renderer should (H320, FCLRHI, colptr 0, palette
indices shown as grey levels unless a palette dump is given).
"""
import sys


def load(path, n):
    try:
        d = open(path, 'rb').read()
    except OSError:
        d = b''
    return d + bytes(n - len(d))


def main():
    a = sys.argv[1:]
    dd, scr, step, count, out = a[0], int(a[1], 16), int(a[2]), int(a[3]), a[4]
    ram = load(dd + '/ram.bin', 0x20000)
    ram2 = load(dd + '/ram2.bin', 0x20000)
    cram2 = load(dd + '/cram2.bin', 0x8000)
    rom = load(dd + '/rom.bin', 0x20000)
    mem = bytearray(ram + rom + ram2 + bytes(0x20000))
    # colour RAM: first 2K at $1F800, the rest in cram2 (offset - $800)
    col = bytearray(ram[0x1F800:0x20000] + cram2[0:0x7800])

    w = 320
    img = []
    for y in range(200):
        row, rc = y >> 3, y & 7
        buf = [None] * 1024
        x, yoff, trans = 0, 0, False
        for c in range(count):
            so = scr + row * step + c * 2
            lo, hi = mem[so], mem[so + 1]
            co = row * step + c * 2
            c0, c1 = col[co], col[co + 1]
            if c0 & 0x10:
                x = ((hi & 3) << 8) | lo
                yoff = hi >> 5
                trans = bool(c0 & 0x80)
                continue
            if x >= w:
                x += 8
                continue
            ch = ((hi & 0x1F) << 8) | lo
            r = (7 - rc) if c0 & 0x80 else rc
            for k in range(8):
                kk = (7 - k) if c0 & 0x40 else k
                addr = (ch * 64 + r * 8 + kk - yoff * 8) & 0x7FFFF
                px = 0 if 0x1F800 <= addr < 0x20000 else mem[addr]   # the VIC-IV sees plain RAM there
                on = px != 0
                if on or not trans:
                    if x + k < 1024:
                        buf[x + k] = ((c1 & 15) if px == 0xFF else px) if on else None
            x += 8
        img.append(buf[:w])
    with open(out, 'wb') as f:
        f.write(b'P6\n%d %d\n255\n' % (w, 200))
        for line in img:
            for p in line:
                v = 0 if p is None else p
                f.write(bytes([v, v, v]))
    print('wrote', out)


if __name__ == '__main__':
    main()
