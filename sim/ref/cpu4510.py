"""Instruction-level reference model of the CSG 4510 (65CE02 + MAP).

Used to fuzz the RTL core (sim/cpu_fuzz): both run the same random memory
image and their per-instruction register traces must match.  Not cycle
accurate; semantics follow Xemu / MEGA65 gs4510.
"""
from tables4510 import INS, MODE

FN, FV, FE, FB, FD, FI, FZ, FC = 0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01

BRANCH = {"BPL": (FN, 0), "BMI": (FN, 1), "BVC": (FV, 0), "BVS": (FV, 1),
          "BCC": (FC, 0), "BCS": (FC, 1), "BNE": (FZ, 0), "BEQ": (FZ, 1)}


def s8(v):
    return v - 256 if v & 0x80 else v


def s16(v):
    return v - 65536 if v & 0x8000 else v


class CPU4510:
    def __init__(self, read, write):
        self.rd_phys, self.wr_phys = read, write
        self.a = self.x = self.y = self.z = self.b = 0
        self.sp = 0x01FF
        self.p = FE | FI
        self.pc = 0
        self.map_lo = self.map_hi = 0
        self.map_en = 0
        self.inhibit = False

    # ---- memory -------------------------------------------------------
    def phys(self, addr):
        addr &= 0xFFFF
        blk = addr >> 13
        if (self.map_en >> blk) & 1:
            off = self.map_lo if blk < 4 else self.map_hi
            return (addr + (off << 8)) & 0xFFFFF
        return addr

    def rd(self, addr):
        return self.rd_phys(self.phys(addr), addr & 0xFFFF)

    def wr(self, addr, v):
        self.wr_phys(self.phys(addr), addr & 0xFFFF, v & 0xFF)

    def fetch(self):
        v = self.rd(self.pc)
        self.pc = (self.pc + 1) & 0xFFFF
        return v

    def push(self, v):
        self.wr(self.sp, v)
        if self.p & FE:
            self.sp = (self.sp & 0xFF00) | ((self.sp - 1) & 0xFF)
        else:
            self.sp = (self.sp - 1) & 0xFFFF

    def pull(self):
        if self.p & FE:
            self.sp = (self.sp & 0xFF00) | ((self.sp + 1) & 0xFF)
        else:
            self.sp = (self.sp + 1) & 0xFFFF
        return self.rd(self.sp)

    def reset(self):
        self.__init__(self.rd_phys, self.wr_phys)
        self.pc = self.rd(0xFFFC) | (self.rd(0xFFFD) << 8)

    # ---- flags / alu --------------------------------------------------
    def nz(self, v):
        v &= 0xFF
        self.p = (self.p & ~(FN | FZ)) | (v & 0x80) | (0 if v else FZ)
        return v

    def setf(self, f, c):
        self.p = (self.p | f) if c else (self.p & ~f)

    def adc(self, m):
        a, c = self.a, self.p & 1
        if self.p & FD:
            lo = (a & 15) + (m & 15) + c
            if lo > 9:
                lo += 6
            hi = (a >> 4) + (m >> 4) + (1 if lo > 15 else 0)
            self.setf(FV, ~(a ^ m) & (a ^ (hi << 4)) & 0x80)
            if hi > 9:
                hi += 6
            self.setf(FC, hi > 15)
            self.a = self.nz(((hi << 4) | (lo & 15)) & 0xFF)
        else:
            r = a + m + c
            self.setf(FV, ~(a ^ m) & (a ^ r) & 0x80)
            self.setf(FC, r > 0xFF)
            self.a = self.nz(r)

    def sbc(self, m):
        a, c = self.a, self.p & 1
        r = a - m - (1 - c)
        self.setf(FV, (a ^ m) & (a ^ r) & 0x80)
        self.setf(FC, r >= 0)
        if self.p & FD:
            lo = (a & 15) - (m & 15) - (1 - c)
            if r < 0:
                r -= 0x60
            if lo < 0:
                r -= 6
        self.a = self.nz(r)

    def cmp(self, reg, m):
        r = reg - m
        self.setf(FC, r >= 0)
        self.nz(r)

    def rmw(self, ins, op, m):
        c = self.p & 1
        if ins == "ASL":
            self.setf(FC, m & 0x80); return self.nz(m << 1)
        if ins == "ROL":
            self.setf(FC, m & 0x80); return self.nz((m << 1) | c)
        if ins == "LSR":
            self.setf(FC, m & 1); return self.nz(m >> 1)
        if ins == "ROR":
            self.setf(FC, m & 1); return self.nz((m >> 1) | (c << 7))
        if ins == "ASR":
            self.setf(FC, m & 1); return self.nz((m >> 1) | (m & 0x80))
        if ins == "INC":
            return self.nz(m + 1)
        if ins == "DEC":
            return self.nz(m - 1)
        if ins == "TSB":
            self.setf(FZ, (m & self.a) == 0); return m | self.a
        if ins == "TRB":
            self.setf(FZ, (m & self.a) == 0); return m & ~self.a & 0xFF
        if ins == "RMB":
            return m & ~(1 << ((op >> 4) & 7)) & 0xFF
        if ins == "SMB":
            return m | (1 << ((op >> 4) & 7))
        raise ValueError(ins)

    # ---- interrupts ---------------------------------------------------
    def interrupt(self, vector, brk=False):
        self.push(self.pc >> 8)
        self.push(self.pc & 0xFF)
        self.push((self.p & ~FB) | (FB if brk else 0))
        self.p = (self.p | FI) & ~FD
        self.pc = self.rd(vector) | (self.rd(vector + 1) << 8)

    # ---- one instruction ----------------------------------------------
    def step(self):
        op = self.fetch()
        ins, mode = INS[op], MODE[op]
        zp = lambda v: (self.b << 8) | (v & 0xFF)
        ea = None
        imm = None

        if mode == "IMM":
            imm = self.fetch()
        elif mode == "IMM16":
            imm = self.fetch(); imm |= self.fetch() << 8
        elif mode == "ZP":
            ea = zp(self.fetch())
        elif mode == "ZPX":
            ea = zp(self.fetch() + self.x)
        elif mode == "ZPY":
            ea = zp(self.fetch() + self.y)
        elif mode in ("ABS", "ABSX", "ABSY", "IND16", "IND16X"):
            if ins in ("JSR",):
                lo = self.fetch(); hi = self.rd(self.pc)   # PC left on last byte
            else:
                lo = self.fetch(); hi = self.fetch()
            ea = lo | (hi << 8)
            if mode in ("ABSX", "IND16X"):
                ea = (ea + self.x) & 0xFFFF
            elif mode == "ABSY":
                ea = (ea + self.y) & 0xFFFF
            if mode in ("IND16", "IND16X"):
                ea = self.rd(ea) | (self.rd(ea + 1) << 8)
        elif mode in ("INDX", "INDY", "INDZ"):
            n = self.fetch()
            if mode == "INDX":
                n += self.x
            ea = self.rd(zp(n)) | (self.rd(zp(n + 1)) << 8)
            if mode == "INDY":
                ea = (ea + self.y) & 0xFFFF
            elif mode == "INDZ":
                ea = (ea + self.z) & 0xFFFF
        elif mode == "INDSPY":
            ptr = self.sp + self.fetch()
            ea = self.rd(ptr) | (self.rd(ptr + 1) << 8)
            ea = (ea + self.y) & 0xFFFF
        elif mode == "REL":
            imm = self.fetch()
            ea = (self.pc + s8(imm)) & 0xFFFF
        elif mode == "REL16":
            lo = self.fetch(); hi = self.rd(self.pc)       # PC on 2nd operand byte
            ea = (self.pc + s16(lo | (hi << 8))) & 0xFFFF
        elif mode == "ZPREL":
            ea = zp(self.fetch())

        operand = lambda: imm if mode == "IMM" else self.rd(ea)

        if ins in ("ORA", "AND", "EOR"):
            m = operand()
            self.a = self.nz({"ORA": self.a | m, "AND": self.a & m, "EOR": self.a ^ m}[ins])
        elif ins == "ADC":
            self.adc(operand())
        elif ins == "SBC":
            self.sbc(operand())
        elif ins == "CMP":
            self.cmp(self.a, operand())
        elif ins == "CPX":
            self.cmp(self.x, operand())
        elif ins == "CPY":
            self.cmp(self.y, operand())
        elif ins == "CPZ":
            self.cmp(self.z, operand())
        elif ins == "LDA":
            self.a = self.nz(operand())
        elif ins == "LDX":
            self.x = self.nz(operand())
        elif ins == "LDY":
            self.y = self.nz(operand())
        elif ins == "LDZ":
            self.z = self.nz(operand())
        elif ins == "BIT":
            m = operand()
            self.setf(FZ, (m & self.a) == 0)
            if mode != "IMM":
                self.p = (self.p & 0x3F) | (m & 0xC0)
        elif ins == "STA":
            self.wr(ea, self.a)
        elif ins == "STX":
            self.wr(ea, self.x)
        elif ins == "STY":
            self.wr(ea, self.y)
        elif ins == "STZ":
            self.wr(ea, self.z)
        elif ins in ("ASL", "ROL", "LSR", "ROR", "ASR", "INC", "DEC") and mode == "IMPL":
            self.a = self.rmw(ins, op, self.a)
        elif ins in ("ASL", "ROL", "LSR", "ROR", "ASR", "INC", "DEC", "TSB", "TRB", "RMB", "SMB"):
            self.wr(ea, self.rmw(ins, op, self.rd(ea)))
        elif ins in ("INW", "DEW", "ASW", "ROW"):
            w = self.rd(ea) | (self.rd(ea + 1) << 8)
            if ins == "INW":
                w = (w + 1) & 0xFFFF
            elif ins == "DEW":
                w = (w - 1) & 0xFFFF
            else:
                cin = (self.p & 1) if ins == "ROW" else 0
                self.setf(FC, w & 0x8000)
                w = ((w << 1) | cin) & 0xFFFF
            self.setf(FN, w & 0x8000)
            self.setf(FZ, w == 0)
            self.wr(ea, w & 0xFF)
            self.wr(ea + 1, w >> 8)
        elif ins == "PHW":
            w = imm if mode == "IMM16" else (self.rd(ea) | (self.rd(ea + 1) << 8))
            self.push(w & 0xFF)
            self.push(w >> 8)
        elif ins in BRANCH or ins == "BRA":
            taken = True
            if ins != "BRA":
                f, want = BRANCH[ins]
                taken = bool(self.p & f) == bool(want)
            if taken:
                self.pc = ea
            elif mode == "REL16":
                self.pc = (self.pc + 1) & 0xFFFF
        elif ins == "BSR":
            self.push(self.pc >> 8)
            self.push(self.pc & 0xFF)
            self.pc = ea
        elif ins in ("BBR", "BBS"):
            m = self.rd(ea)
            rel = self.fetch()
            bit = (m >> ((op >> 4) & 7)) & 1
            if bit == (1 if ins == "BBS" else 0):
                self.pc = (self.pc + s8(rel)) & 0xFFFF
        elif ins == "JMP":
            self.pc = ea
        elif ins == "JSR":
            self.push(self.pc >> 8)
            self.push(self.pc & 0xFF)
            self.pc = ea
        elif ins == "RTS":
            lo = self.pull(); hi = self.pull()
            self.pc = ((lo | (hi << 8)) + 1) & 0xFFFF
            if mode == "IMM":
                if self.p & FE:
                    self.sp = (self.sp & 0xFF00) | ((self.sp + imm) & 0xFF)
                else:
                    self.sp = (self.sp + imm) & 0xFFFF
        elif ins == "RTI":
            v = self.pull()
            self.p = (self.p & (FE | FB)) | (v & ~(FE | FB) & 0xFF)
            lo = self.pull(); hi = self.pull()
            self.pc = lo | (hi << 8)
        elif ins == "BRK":
            self.pc = (self.pc + 1) & 0xFFFF
            self.interrupt(0xFFFE, brk=True)
        elif ins == "PHA":
            self.push(self.a)
        elif ins == "PHX":
            self.push(self.x)
        elif ins == "PHY":
            self.push(self.y)
        elif ins == "PHZ":
            self.push(self.z)
        elif ins == "PHP":
            self.push(self.p | FB)
        elif ins == "PLA":
            self.a = self.nz(self.pull())
        elif ins == "PLX":
            self.x = self.nz(self.pull())
        elif ins == "PLY":
            self.y = self.nz(self.pull())
        elif ins == "PLZ":
            self.z = self.nz(self.pull())
        elif ins == "PLP":
            v = self.pull()
            self.p = (self.p & (FE | FB)) | (v & ~(FE | FB) & 0xFF)
        elif ins == "NEG":
            self.a = self.nz(-self.a)
        elif ins == "INX":
            self.x = self.nz(self.x + 1)
        elif ins == "INY":
            self.y = self.nz(self.y + 1)
        elif ins == "INZ":
            self.z = self.nz(self.z + 1)
        elif ins == "DEX":
            self.x = self.nz(self.x - 1)
        elif ins == "DEY":
            self.y = self.nz(self.y - 1)
        elif ins == "DEZ":
            self.z = self.nz(self.z - 1)
        elif ins == "TAX":
            self.x = self.nz(self.a)
        elif ins == "TAY":
            self.y = self.nz(self.a)
        elif ins == "TAZ":
            self.z = self.nz(self.a)
        elif ins == "TXA":
            self.a = self.nz(self.x)
        elif ins == "TYA":
            self.a = self.nz(self.y)
        elif ins == "TZA":
            self.a = self.nz(self.z)
        elif ins == "TBA":
            self.a = self.nz(self.b)
        elif ins == "TAB":
            self.b = self.a
        elif ins == "TSX":
            self.x = self.nz(self.sp & 0xFF)
        elif ins == "TSY":
            self.y = self.nz(self.sp >> 8)
        elif ins == "TXS":
            self.sp = (self.sp & 0xFF00) | self.x
        elif ins == "TYS":
            self.sp = (self.sp & 0x00FF) | (self.y << 8)
        elif ins == "CLC":
            self.p &= ~FC
        elif ins == "SEC":
            self.p |= FC
        elif ins == "CLI":
            self.p &= ~FI
        elif ins == "SEI":
            self.p |= FI
        elif ins == "CLD":
            self.p &= ~FD
        elif ins == "SED":
            self.p |= FD
        elif ins == "CLV":
            self.p &= ~FV
        elif ins == "CLE":
            self.p &= ~FE
        elif ins == "SEE":
            self.p |= FE
        elif ins == "MAP":
            self.map_lo = self.a | ((self.x & 15) << 8)
            self.map_hi = self.y | ((self.z & 15) << 8)
            self.map_en = (self.x >> 4) | (self.z & 0xF0)
            self.inhibit = True
        elif ins == "EOM":
            self.inhibit = False
        else:
            raise ValueError("unhandled %s %02X" % (ins, op))
        self.p &= 0xFF
