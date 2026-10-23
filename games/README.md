# Test programs

## CATCH (`catch.prg`, on `disks/catch.d81`)

A small BASIC 10 game for the stock C65 ROM (911210). It exercises the
keyboard, a joystick, sound, the 80 column text screen and the disk drive.

1. Mount `catch.d81` (OSD, *Mount Drive 8*).
2. `DLOAD"CATCH"` then `RUN`.
3. Move the paddle with `Z` (left) and `X` (right), or a joystick in
   control port 2. Catch the falling stars; five misses ends the game.

Leave *CPU Speed* at 3.5 MHz - the game has no speed limiter and is too
fast to play at 8 or 16 MHz. `LIST` shows the program; it is short enough
to change and `DSAVE"@CATCH"` back to the disk.

It does not run under S-BASIC 65, which uses a different BASIC dialect.

## MODEMTEST (`modemtest.prg`, source `modemtest.bas`)

A tiny terminal for the stock C65 ROM (911210) that checks the serial port
against the MiSTer's emulated modem.

1. On the OSD's System page set *UART mode* to **Modem** and *Baud* to
   **9600** (the program opens the port with `CHR$(14)` = 9600 baud, 8N1).
   The stock KERNAL cannot make 38400 baud accurately; 9600 and 19200 are
   fine.
2. *Load Program* `modemtest.prg` (or put it on a disk) and `RUN`.
3. It sends `AT` and shows the reply: `AT` (the echo) and `OK`.
4. Then it is a terminal: what you type goes to the modem, what comes back
   is shown. `ATDT host:port` dials a telnet BBS; RUN/STOP quits.

The MiSTer modem sends PETSCII-style letters (bit 7 set); the program shows
both those and plain ASCII as normal letters on the upper case screen.
