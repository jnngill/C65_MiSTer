#!/usr/bin/env python3
"""Move a temporary virtual USB mouse on a MiSTer (for testing a core's mouse input).

Runs ON the MiSTer (nothing is installed there):

    ssh root@MiSTer.local python3 - 4 2 40 < scripts/mister_mouse.py

Arguments: dx dy steps [click].  Sends `steps` relative moves of (dx, dy);
positive dy is down.  With a fourth argument the left button is clicked at
the end.
"""
import fcntl, os, struct, sys, time

EV_SYN, EV_KEY, EV_REL = 0, 1, 2
REL_X, REL_Y = 0, 1
BTN_LEFT, BTN_RIGHT = 0x110, 0x111
UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_RELBIT, UI_DEV_CREATE, UI_DEV_DESTROY = \
    0x40045564, 0x40045565, 0x40045566, 0x5501, 0x5502


def main():
    dx, dy, steps = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_REL)
    fcntl.ioctl(fd, UI_SET_KEYBIT, BTN_LEFT)
    fcntl.ioctl(fd, UI_SET_KEYBIT, BTN_RIGHT)
    fcntl.ioctl(fd, UI_SET_RELBIT, REL_X)
    fcntl.ioctl(fd, UI_SET_RELBIT, REL_Y)
    os.write(fd, struct.pack("80sHHHHi", b"claude-mouse", 3, 0x1234, 0x5679, 1, 0) + bytes(4 * 64 * 4))
    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(2.0)           # let MiSTer hot-plug the device

    def ev(t, code, val):
        os.write(fd, struct.pack("llHHi", 0, 0, t, code, val))

    for _ in range(steps):
        ev(EV_REL, REL_X, dx); ev(EV_REL, REL_Y, dy); ev(EV_SYN, 0, 0)
        time.sleep(0.02)
    if len(sys.argv) > 4:
        ev(EV_KEY, BTN_LEFT, 1); ev(EV_SYN, 0, 0); time.sleep(0.2)
        ev(EV_KEY, BTN_LEFT, 0); ev(EV_SYN, 0, 0)
    time.sleep(0.3)
    fcntl.ioctl(fd, UI_DEV_DESTROY)
    os.close(fd)


if __name__ == "__main__":
    main()
