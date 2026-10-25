#!/usr/bin/env python3
"""Press OSD / navigation keys on a MiSTer through a temporary virtual USB keyboard.

Runs ON the MiSTer (nothing is installed there):

    ssh root@MiSTer.local python3 - F12 DOWN DOWN ENTER F12 < scripts/mister_osd.py

Key names: F1-F8 F12 DOWN UP LEFT RIGHT ENTER ESC.  In the OSD, Enter changes an
option; separator lines are skipped and the cursor starts at the top.
"""
import fcntl, os, struct, sys, time

UI_SET_EVBIT, UI_SET_KEYBIT, UI_DEV_CREATE, UI_DEV_DESTROY = 0x40045564, 0x40045565, 0x5501, 0x5502
KEYS = {"F1": 59, "F2": 60, "F3": 61, "F4": 62, "F5": 63, "F6": 64, "F7": 65, "F8": 66, "F12": 88, "DOWN": 108, "UP": 103, "LEFT": 105, "RIGHT": 106, "ENTER": 28, "ESC": 1}


def main():
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, 1)
    for k in range(1, 128):
        fcntl.ioctl(fd, UI_SET_KEYBIT, k)
    os.write(fd, struct.pack("80sHHHHi", b"claude-osd", 3, 0x1234, 0x567a, 1, 0) + bytes(4 * 64 * 4))
    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(2.0)           # let MiSTer hot-plug the device

    def ev(code, val):
        os.write(fd, struct.pack("llHHi", 0, 0, 1, code, val))
        os.write(fd, struct.pack("llHHi", 0, 0, 0, 0, 0))
        time.sleep(0.08)

    for name in sys.argv[1:]:
        ev(KEYS[name], 1); ev(KEYS[name], 0)
        time.sleep(0.4)
    time.sleep(0.5)
    fcntl.ioctl(fd, UI_DEV_DESTROY)
    os.close(fd)


if __name__ == "__main__":
    main()
