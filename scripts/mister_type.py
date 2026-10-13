#!/usr/bin/env python3
"""Type text on a MiSTer through a temporary virtual USB keyboard.

Runs ON the MiSTer (nothing is installed there):

    ssh root@MiSTer.local python3 - "PRINT 1+1" < scripts/mister_type.py

Characters are sent as a US keyboard would type them, so pick the matching
"Keyboard Layout" in the core's OSD.  "~" sends RETURN, "{dollar}" sends "$".
"""
import fcntl, os, struct, sys, time

EV_SYN, EV_KEY = 0, 1
UI_SET_EVBIT, UI_SET_KEYBIT, UI_DEV_CREATE, UI_DEV_DESTROY = 0x40045564, 0x40045565, 0x5501, 0x5502
KEY_LEFTSHIFT, KEY_ENTER = 42, 28

PLAIN = {"1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "6": 7, "7": 8, "8": 9, "9": 10, "0": 11, "-": 12, "=": 13,
         "q": 16, "w": 17, "e": 18, "r": 19, "t": 20, "y": 21, "u": 22, "i": 23, "o": 24, "p": 25, "[": 26,
         "]": 27, "a": 30, "s": 31, "d": 32, "f": 33, "g": 34, "h": 35, "j": 36, "k": 37, "l": 38, ";": 39,
         "'": 40, "z": 44, "x": 45, "c": 46, "v": 47, "b": 48, "n": 49, "m": 50, ",": 51, ".": 52, "/": 53,
         " ": 57}
SHIFTED = {"!": 2, "@": 3, "#": 4, "$": 5, "%": 6, "^": 7, "&": 8, "*": 9, "(": 10, ")": 11, "+": 13,
           ":": 39, '"': 40, "<": 51, ">": 52, "?": 53}


def main():
    text = " ".join(sys.argv[1:]).replace("{dollar}", "$")   # "$" is awkward to pass through ssh
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    for k in range(1, 128):
        fcntl.ioctl(fd, UI_SET_KEYBIT, k)
    os.write(fd, struct.pack("80sHHHHi", b"claude-type", 3, 0x1234, 0x5678, 1, 0) + bytes(4 * 64 * 4))
    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(2.0)           # let MiSTer hot-plug the device

    def ev(code, val):
        os.write(fd, struct.pack("llHHi", 0, 0, EV_KEY, code, val))
        os.write(fd, struct.pack("llHHi", 0, 0, EV_SYN, 0, 0))
        time.sleep(0.04)

    for ch in text:
        if ch == "~":
            ev(KEY_ENTER, 1); ev(KEY_ENTER, 0)
        elif ch.lower() in PLAIN:
            ev(PLAIN[ch.lower()], 1); ev(PLAIN[ch.lower()], 0)
        elif ch in SHIFTED:
            ev(KEY_LEFTSHIFT, 1); ev(SHIFTED[ch], 1); ev(SHIFTED[ch], 0); ev(KEY_LEFTSHIFT, 0)
    time.sleep(0.3)
    fcntl.ioctl(fd, UI_DEV_DESTROY)
    os.close(fd)


if __name__ == "__main__":
    main()
