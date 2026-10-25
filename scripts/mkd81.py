#!/usr/bin/env python3
"""Create a formatted 1581 disk image (.D81), optionally containing PRG files.

usage: mkd81.py out.d81 [-n "DISK NAME"] [-i ID] [-s file.seq NAME ...] [file.prg ...]
"""
import sys, os

TRACKS, SECTORS = 80, 40


def petscii(s, n):
    b = s.upper().encode("ascii", "replace")[:n]
    return b + b"\xA0" * (n - len(b))


class D81:
    def __init__(self, name="C65 DISK", did="65"):
        self.d = bytearray(TRACKS * SECTORS * 256)
        self.free = {t: [True] * SECTORS for t in range(1, TRACKS + 1)}
        self.did = did.encode("ascii")[:2].ljust(2, b"\xA0")
        self.name = name
        self.dir = []
        for s in range(4):
            self.free[40][s] = False

    def off(self, t, s):
        return ((t - 1) * SECTORS + s) * 256

    def alloc(self):
        for t in list(range(1, 40)) + list(range(41, TRACKS + 1)):
            for s in range(SECTORS):
                if self.free[t][s]:
                    self.free[t][s] = False
                    return t, s
        raise RuntimeError("disk full")

    def add_prg(self, fname, data, ftype=0x82):
        blocks = [data[i:i + 254] for i in range(0, len(data), 254)] or [b""]
        locs = [self.alloc() for _ in blocks]
        for i, (blk, (t, s)) in enumerate(zip(blocks, locs)):
            o = self.off(t, s)
            if i + 1 < len(blocks):
                self.d[o], self.d[o + 1] = locs[i + 1]
            else:
                self.d[o], self.d[o + 1] = 0, len(blk) + 1
            self.d[o + 2:o + 2 + len(blk)] = blk
        self.dir.append((fname, locs[0], len(blocks), ftype))

    def image(self):
        d = self.d
        # header
        o = self.off(40, 0)
        d[o:o + 4] = bytes([40, 3, 0x44, 0])
        d[o + 4:o + 20] = petscii(self.name, 16)
        d[o + 20:o + 22] = b"\xA0\xA0"
        d[o + 22:o + 24] = self.did
        d[o + 24:o + 29] = b"\xA0\x33\x44\xA0\xA0"
        # BAM
        for n, (first, link) in enumerate(((1, (40, 2)), (41, (0, 255)))):
            o = self.off(40, 1 + n)
            d[o:o + 8] = bytes([link[0], link[1], 0x44, 0xBB]) + self.did + bytes([0xC0, 0])
            for i in range(40):
                t = first + i
                e = o + 16 + i * 6
                d[e] = sum(self.free[t])
                for byte in range(5):
                    d[e + 1 + byte] = sum(1 << bit for bit in range(8) if self.free[t][byte * 8 + bit])
        # directory (sectors 3.. on track 40, 8 entries each)
        nsec = max(1, (len(self.dir) + 7) // 8)
        for n in range(nsec):
            s = 3 + n
            self.free[40][s] = False
            o = self.off(40, s)
            d[o:o + 2] = bytes([40, s + 1]) if n + 1 < nsec else bytes([0, 255])
            for i, (fname, (t, sec), nblk, ftype) in enumerate(self.dir[n * 8:n * 8 + 8]):
                e = o + i * 32
                d[e + 2] = ftype
                d[e + 3], d[e + 4] = t, sec
                d[e + 5:e + 21] = petscii(fname, 16)
                d[e + 30], d[e + 31] = nblk & 255, nblk >> 8
        if nsec > 1:   # BAM changed after allocating extra directory sectors
            return self.image_bam_only()
        return bytes(d)

    def image_bam_only(self):
        self.dir_done = True
        d = self.d
        for n, first in enumerate((1, 41)):
            o = self.off(40, 1 + n)
            for i in range(40):
                t = first + i
                e = o + 16 + i * 6
                d[e] = sum(self.free[t])
                for byte in range(5):
                    d[e + 1 + byte] = sum(1 << bit for bit in range(8) if self.free[t][byte * 8 + bit])
        return bytes(d)


def main(argv):
    out, name, did, files, seqs = None, "C65 DISK", "65", [], []
    i = 1
    while i < len(argv):
        if argv[i] == "-n":
            name = argv[i + 1]; i += 2
        elif argv[i] == "-i":
            did = argv[i + 1]; i += 2
        elif argv[i] == "-s":
            seqs.append((argv[i + 1], argv[i + 2])); i += 3
        elif out is None:
            out = argv[i]; i += 1
        else:
            files.append(argv[i]); i += 1
    if not out:
        print(__doc__); return 2
    img = D81(name, did)
    for f in files:
        img.add_prg(os.path.splitext(os.path.basename(f))[0], open(f, "rb").read())
    for f, n in seqs:
        img.add_prg(n, open(f, "rb").read(), 0x81)
    open(out, "wb").write(img.image())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
