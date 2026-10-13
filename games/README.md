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
