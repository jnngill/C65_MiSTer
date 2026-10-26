"""Build GO128.PRG and GO64.PRG (one-line BASIC programs) and go.d81 with both.

They ask the MiSTer to load its C128 / C64 core (C65 core with the core
switch helper; see the README): POKE 55037,67 ($D6FD) then 55038 ($D6FE) with
128 or 64.  BASIC, not machine code, so they run the same under every ROM.
"""
import os, subprocess, sys

here = os.path.dirname(os.path.abspath(__file__))


def basic_line(num, text):
    # tokenise just POKE ($97); the rest is plain PETSCII
    body = text.replace("POKE", "\x97").encode("latin-1")
    return num, body


def prg(lines):
    addr, out = 0x2001, bytearray([0x01, 0x20])
    for num, body in lines:
        nxt = addr + 4 + len(body) + 1
        out += bytes([nxt & 0xFF, nxt >> 8, num & 0xFF, num >> 8]) + body + b"\x00"
        addr = nxt
    return bytes(out + b"\x00\x00")


for name, val in (("go128", 128), ("go64", 64)):
    data = prg([basic_line(10, "POKE55037,67:POKE55038,%d" % val)])
    open(os.path.join(here, name + ".prg"), "wb").write(data)
print("ok")
