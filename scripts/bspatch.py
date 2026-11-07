# bspatch.py c-65-19910828.rom mega65_9204xx.bin 9204xx.bdf
#
# Builds a MEGA65 ROM (BASIC 65) from the C65 ROM 910828 and the .bdf file
# in the MEGA65 team's ROM patch package (a classic BSDIFF40 patch with bzip2;
# the package's .rdf is the format M65Connect uses).  No ROM is included
# in this project: you supply the 910828 ROM and the patch.
import bz2, sys


def offtin(b):
    y = int.from_bytes(b[:7] + bytes([b[7] & 0x7F]), 'little')
    return -y if b[7] & 0x80 else y


old = open(sys.argv[1], 'rb').read()
p = open(sys.argv[3], 'rb').read()
assert p[:8] == b'BSDIFF40', p[:8]
clen, dlen, nsize = offtin(p[8:16]), offtin(p[16:24]), offtin(p[24:32])
ctrl = bz2.decompress(p[32:32 + clen])
diff = bz2.decompress(p[32 + clen:32 + clen + dlen])
extra = bz2.decompress(p[32 + clen + dlen:])
new = bytearray(nsize)
op = np = ci = di = ei = 0
while np < nsize:
    x, y, z = (offtin(ctrl[ci + 8 * k:ci + 8 * k + 8]) for k in range(3))
    ci += 24
    for i in range(x):
        o = old[op + i] if 0 <= op + i < len(old) else 0
        new[np + i] = (diff[di + i] + o) & 0xFF
    di += x; np += x; op += x
    new[np:np + y] = extra[ei:ei + y]
    ei += y; np += y; op += z
open(sys.argv[2], 'wb').write(new)
print('wrote', len(new))
