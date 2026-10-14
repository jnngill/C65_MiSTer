#!/bin/bash
# C65 PRG disk: packs every .prg file in /media/fat/games/C65/PRG, and the
# files inside every .d64 image there, into the disk image
# /media/fat/games/C65/prg.d81, so the C65 core can DIR and DLOAD them (in C64
# mode too).  Copy this file to /media/fat/Scripts and run it from the MiSTer
# Scripts menu after adding or removing programs.
#
# Only files are copied: software that reads a 1541 disk directly (fast
# loaders, copy protection, most demos) needs a real 1541 and will not work.
#
# prg.d81 is rebuilt from the folder each time: anything saved onto that
# disk from the C65 is replaced (the previous image is kept as prg.d81.bak).

C65=${C65_DIR:-/media/fat/games/C65}
PRG_DIR="$C65/PRG"
OUT="$C65/prg.d81"

if [ ! -d "$PRG_DIR" ]; then
	mkdir -p "$PRG_DIR"
	echo "Created $PRG_DIR"
	echo "Copy your .prg and .d64 files there and run this script again."
	exit 0
fi

[ -f "$OUT" ] && cp "$OUT" "$OUT.bak"

python3 - "$PRG_DIR" "$OUT" <<'PY'
import os, sys

TRACKS, SECTORS = 80, 40
prg_dir, out = sys.argv[1], sys.argv[2]
TYPES = {1: "seq", 2: "prg", 3: "usr"}


def pad(name, n=16):
    return name[:n] + b"\xA0" * (n - len(name[:n]))


def show(name):
    return name.decode("latin-1").lower()


# ---------------------------------------------------------------- D81 image
d = bytearray(TRACKS * SECTORS * 256)
free = {t: [True] * SECTORS for t in range(1, TRACKS + 1)}
for s in range(40):                      # track 40: header, BAM and directory
    free[40][s] = False


def off(t, s):
    return ((t - 1) * SECTORS + s) * 256


def alloc():
    for t in list(range(39, 0, -1)) + list(range(41, TRACKS + 1)):
        for s in range(SECTORS):
            if free[t][s]:
                free[t][s] = False
                return t, s
    return None


def n_free():
    return sum(sum(free[t]) for t in free if t != 40)


entries, names = [], set()


def add_file(name, ftype, data, label):
    """name: PETSCII bytes; ftype: 1 SEQ, 2 PRG, 3 USR"""
    blocks = [data[i:i + 254] for i in range(0, len(data), 254)] or [b""]
    if len(entries) >= 296:
        print("  skipped (directory full): " + label); return
    if len(blocks) > n_free():
        print("  skipped (disk full):      " + label); return
    name = name[:16]
    base, k = name, 1
    while name in names:                 # two files with the same name
        k += 1; tag = b"~%d" % k
        name = base[:16 - len(tag)] + tag
    names.add(name)
    locs = [alloc() for _ in blocks]
    for i, (blk, (t, s)) in enumerate(zip(blocks, locs)):
        o = off(t, s)
        if i + 1 < len(blocks):
            d[o], d[o + 1] = locs[i + 1]
        else:
            d[o], d[o + 1] = 0, len(blk) + 1
        d[o + 2:o + 2 + len(blk)] = blk
    entries.append((name, ftype, locs[0], len(blocks)))
    print("%6d  %-16s %s" % (len(blocks), show(name), TYPES[ftype]))


# ---------------------------------------------------------------- D64 reader
def d64_offset(t, s):
    o = 0
    for tt in range(1, t):
        o += 21 if tt <= 17 else 19 if tt <= 24 else 18 if tt <= 30 else 17
    return (o + s) * 256


def d64_files(img):
    """yield (name, type, data) for the SEQ / PRG / USR files of a D64 image"""
    ntracks = 40 if len(img) >= 196608 else 35
    def sector(t, s):
        if not 1 <= t <= ntracks: return None
        o = d64_offset(t, s)
        return img[o:o + 256] if o + 256 <= len(img) else None
    t, s, seen = 18, 1, set()
    while t and (t, s) not in seen:
        seen.add((t, s))
        sec = sector(t, s)
        if sec is None: break
        for e in range(0, 256, 32):
            typ = sec[e + 2]
            if not (typ & 0x80) or (typ & 7) not in TYPES:
                continue                 # deleted, unclosed, DEL or REL
            name = bytes(sec[e + 5:e + 21]).rstrip(b"\xA0")
            data, ft, fs, chain = bytearray(), sec[e + 3], sec[e + 4], set()
            while ft and (ft, fs) not in chain:
                chain.add((ft, fs))
                blk = sector(ft, fs)
                if blk is None: break
                if blk[0] == 0:
                    data += blk[2:max(2, blk[1] + 1)]
                    break
                data += blk[2:]
                ft, fs = blk[0], blk[1]
            yield name, typ & 7, bytes(data)
        t, s = sec[0], sec[1]


# ---------------------------------------------------------------- collect files
listing = sorted(f for f in os.listdir(prg_dir) if os.path.isfile(os.path.join(prg_dir, f)))
prgs = [f for f in listing if f.lower().endswith(".prg")]
d64s = [f for f in listing if f.lower().endswith(".d64")]
if prgs:
    print("PRG files:")
for f in prgs:
    name = os.path.splitext(f)[0].upper().encode("ascii", "replace")
    add_file(name, 2, open(os.path.join(prg_dir, f), "rb").read(), f)
for f in d64s:
    print(f + ":")
    try:
        for name, ftype, data in d64_files(open(os.path.join(prg_dir, f), "rb").read()):
            add_file(name, ftype, data, f + ": " + show(name))
    except Exception as e:
        print("  could not read this image (%s)" % e)

did = b"65"
# header (40/0)
o = off(40, 0)
d[o:o + 4] = bytes([40, 3, 0x44, 0])
d[o + 4:o + 20] = pad(b"PRG DISK")
d[o + 20:o + 22] = b"\xA0\xA0"
d[o + 22:o + 24] = did
d[o + 24:o + 29] = b"\xA0\x33\x44\xA0\xA0"
# directory: track 40 from sector 3, 8 entries per sector
nsec = max(1, (len(entries) + 7) // 8)
for n in range(40):
    free[40][n] = n >= 3 + nsec
for n in range(nsec):
    s = 3 + n
    o = off(40, s)
    d[o:o + 2] = bytes([40, s + 1]) if n + 1 < nsec else bytes([0, 255])
    for i, (name, ftype, (t, sec), nblk) in enumerate(entries[n * 8:n * 8 + 8]):
        e = o + i * 32
        d[e + 2] = 0x80 | ftype
        d[e + 3], d[e + 4] = t, sec
        d[e + 5:e + 21] = pad(name)
        d[e + 30], d[e + 31] = nblk & 255, nblk >> 8
# BAM (40/1 tracks 1-40, 40/2 tracks 41-80)
for n, (first, link) in enumerate(((1, (40, 2)), (41, (0, 255)))):
    o = off(40, 1 + n)
    d[o:o + 8] = bytes([link[0], link[1], 0x44, 0xBB]) + did + bytes([0xC0, 0])
    for i in range(40):
        t = first + i
        e = o + 16 + i * 6
        d[e] = sum(free[t])
        for byte in range(5):
            d[e + 1 + byte] = sum(1 << bit for bit in range(8) if free[t][byte * 8 + bit])

open(out, "wb").write(bytes(d))
print()
print("%d files, %d blocks free -> %s" % (len(entries), n_free(), out))
PY

echo
echo "Mount prg.d81 from the C65 OSD (F12, Mount Drive 8)."
echo "If it is already mounted, mount it again to see the changes."
