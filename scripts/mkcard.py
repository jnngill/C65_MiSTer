# mkcard.py out.img  -- a 64 MB MBR + FAT32 card (4 KB clusters) holding TEST.D64
# (one BASIC 65 program "HELLO": 10 PRINT "HELLO D64") and TEST.D71 (a copy
# of the same D64 contents on a 1571-sized image).
import struct, sys

SPT = [21] * 17 + [19] * 7 + [18] * 6 + [17] * 5


def d64_off(t, s):
    return (sum(SPT[:t - 1]) + s) * 256


def make_d64(nsides=1):
    tracks = 35 * nsides
    spt = SPT * nsides
    img = bytearray(sum(spt) * 256)
    # program at $2001: 10 PRINT "HELLO D64"
    body = bytes([0x0A, 0x00, 0x99, 0x20, 0x22]) + b'HELLO D64' + bytes([0x22, 0x00])
    nxt = 0x2001 + 2 + len(body)
    prg = bytes([0x01, 0x20]) + struct.pack('<H', nxt) + body + bytes([0, 0])
    o = d64_off(17, 0)
    img[o] = 0; img[o + 1] = len(prg) + 1
    img[o + 2:o + 2 + len(prg)] = prg
    # BAM at 18/0
    o = d64_off(18, 0)
    img[o:o + 4] = bytes([18, 1, 0x41, 0x80 if nsides == 2 else 0])
    for t in range(1, 36):
        n = SPT[t - 1]
        free = (1 << n) - 1
        if t == 17: free &= ~1
        if t == 18: free &= ~3
        cnt = bin(free).count('1')
        img[o + 4 * t:o + 4 * t + 4] = bytes([cnt, free & 255, (free >> 8) & 255, (free >> 16) & 255])
    img[o + 0x90:o + 0xA0] = b'D64 TEST'.ljust(16, b'\xa0')
    img[o + 0xA0:o + 0xAB] = b'\xa0\xa0' + b'64' + b'\xa0' + b'2A' + b'\xa0' * 4
    # directory at 18/1
    o = d64_off(18, 1)
    img[o:o + 2] = bytes([0, 0xFF])
    e = o + 2
    img[e] = 0x82; img[e + 1] = 17; img[e + 2] = 0
    img[e + 3:e + 19] = b'HELLO'.ljust(16, b'\xa0')
    img[e + 28:e + 30] = struct.pack('<H', 1)
    return bytes(img)


files = [('TEST    D64', make_d64(1)), ('TEST    D71', make_d64(2))]
assert len(files[0][1]) == 174848 and len(files[1][1]) == 349696

TOTAL = 64 * 1024 * 1024 // 512
PSTART = 2048
N = TOTAL - PSTART
SPC, RES, NF = 8, 32, 2
F = 1
while True:
    clusters = (N - RES - NF * F) // SPC
    need = ((clusters + 2) * 4 + 511) // 512
    if need <= F: break
    F = need
img = bytearray(TOTAL * 512)
# MBR
mbr = bytearray(512)
mbr[446:462] = bytes([0x00, 0, 0, 0, 0x0C, 0, 0, 0]) + struct.pack('<II', PSTART, N)
mbr[510:512] = b'\x55\xaa'
img[0:512] = mbr
# boot sector
bs = bytearray(512)
bs[0:3] = b'\xeb\x58\x90'; bs[3:11] = b'MSWIN4.1'
struct.pack_into('<HBHBHHBHHHII', bs, 11, 512, SPC, RES, NF, 0, 0, 0xF8, 0, 63, 255, PSTART, N)
struct.pack_into('<IHHIHH', bs, 36, F, 0, 0, 2, 1, 6)
bs[64] = 0x80; bs[66] = 0x29; struct.pack_into('<I', bs, 67, 0x12345678)
bs[71:82] = b'C65TEST    '; bs[82:90] = b'FAT32   '; bs[510:512] = b'\x55\xaa'
base = PSTART * 512
img[base:base + 512] = bs
img[base + 6 * 512:base + 7 * 512] = bs
fsi = bytearray(512)
struct.pack_into('<I', fsi, 0, 0x41615252); struct.pack_into('<II', fsi, 484, 0x61417272, 0xFFFFFFFF)
struct.pack_into('<I', fsi, 492, 0xFFFFFFFF); struct.pack_into('<I', fsi, 508, 0xAA550000)
img[base + 512:base + 1024] = fsi
# FAT and data
fat = [0x0FFFFFF8, 0x0FFFFFFF, 0x0FFFFFFF]   # cluster 2: root directory
data0 = base + (RES + NF * F) * 512
def clus(c): return data0 + (c - 2) * SPC * 512
root = bytearray(SPC * 512)
nextc = 3
for i, (name, content) in enumerate(files):
    n = (len(content) + SPC * 512 - 1) // (SPC * 512)
    first = nextc
    for k in range(n):
        fat.append(first + k + 1 if k < n - 1 else 0x0FFFFFFF)
    nextc += n
    img[clus(first):clus(first) + len(content)] = content
    e = 32 * i
    root[e:e + 11] = name.encode()
    root[e + 11] = 0x20
    struct.pack_into('<H', root, e + 20, first >> 16)
    struct.pack_into('<H', root, e + 26, first & 0xFFFF)
    struct.pack_into('<I', root, e + 28, len(content))
img[clus(2):clus(2) + len(root)] = root
fb = b''.join(struct.pack('<I', v) for v in fat)
for k in range(NF):
    o = base + (RES + k * F) * 512
    img[o:o + len(fb)] = fb
open(sys.argv[1], 'wb').write(img)
print('clusters', clusters, 'fat sectors', F)
