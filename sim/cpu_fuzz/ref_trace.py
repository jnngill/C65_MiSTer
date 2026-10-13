"""Write a random 1MB image and the reference trace for it."""
import sys, os, random
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ref"))
import cpu4510

seed, n, img, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]
random.seed(seed)
mem = bytearray(random.randbytes(1 << 20))
open(img, "wb").write(mem)
c = cpu4510.CPU4510(lambda p, a: mem[p], lambda p, a, v: mem.__setitem__(p, v))
c.reset()
with open(out, "w", newline="\n") as f:
    for _ in range(n):
        f.write("%04X %02X %02X %02X %02X %02X %04X %02X\n" % (c.pc, c.a, c.x, c.y, c.z, c.b, c.sp, c.p))
        c.step()
