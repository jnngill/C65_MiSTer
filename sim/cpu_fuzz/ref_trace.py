"""Write a random 1MB image and the reference trace for it."""
import sys, os, random
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ref"))
import cpu4510

seed, n, img, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]
gs = len(sys.argv) > 5 and sys.argv[5] == "gs"
random.seed(seed)
mem = bytearray(random.randbytes(1 << 20))
if gs:
    # random code almost never contains the prefixes, so plant them densely
    for _ in range(60000):
        o = random.randrange(len(mem) - 8)
        k = random.random()
        if k < 0.45:
            mem[o:o + 2] = b"\x42\x42"
        elif k < 0.7:
            mem[o:o + 3] = b"\x42\x42\xea"
        elif k < 0.9:
            mem[o:o + 2] = bytes([0xEA, random.choice([0x12, 0x32, 0x52, 0x72, 0x92, 0xB2, 0xD2, 0xF2])])
        else:
            mem[o:o + 3] = b"\x42\x42\x42"
open(img, "wb").write(mem)
c = cpu4510.CPU4510(lambda p, a: mem[p], lambda p, a, v: mem.__setitem__(p, v), gs,
                    lambda a: mem[a & 0xFFFFF], lambda a, v: mem.__setitem__(a & 0xFFFFF, v))
c.reset()
with open(out, "w", newline="\n") as f:
    lcg = 12345
    cov = (set(), {}, {}) if os.environ.get("COV") else None
    for i in range(n):
        if (i & 63) == 63 and (c.pc & 0x1FFF) < 0x1FFD:
            lcg = (lcg * 1103515245 + 12345) & 0x7FFFFFFF
            tgt = (lcg >> 8) & 0xFFFF
            o = c.phys(c.pc)
            mem[o], mem[o + 1], mem[o + 2] = 0x4C, tgt & 255, tgt >> 8
        if cov is not None:
            op = c.rd(c.pc)
            cov[0].add(c.pc)
            if c.negc == 2:
                cov[1][cpu4510.INS[op] + "/" + cpu4510.MODE[op]] = cov[1].get(cpu4510.INS[op] + "/" + cpu4510.MODE[op], 0) + 1
            if c.far and cpu4510.MODE[op] == "INDZ":
                cov[2][cpu4510.INS[op]] = cov[2].get(cpu4510.INS[op], 0) + 1
        f.write("%04X %02X %02X %02X %02X %02X %04X %02X\n" % (c.pc, c.a, c.x, c.y, c.z, c.b, c.sp, c.p))
        c.step()
if cov is not None:
    print("unique PCs %d, Q-prefixed %d (%d kinds), far %s" % (len(cov[0]), sum(cov[1].values()), len(cov[1]), cov[2]))
    print(" ".join(sorted(cov[1])))
