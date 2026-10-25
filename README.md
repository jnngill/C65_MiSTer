# Commodore 65 for MiSTer

A from-scratch Commodore 65 core for the MiSTer (DE10-Nano). It recreates
the original C65 (4510 CPU, VIC-III, F018 DMA, F011 floppy controller, two
SIDs) and boots the original Commodore ROMs to BASIC 10, with the internal
3.5" drive backed by `.D81` images.

By default it is a plain C65. An OSD option, **MEGA65 Extensions**, adds the
small part of the MEGA65 hardware needed by S-BASIC 65, a MEGA65-style ROM
with a completed BASIC 10 (see [MEGA65 extensions](#mega65-extensions)).
It does not turn the core into a MEGA65.

> **You must supply your own system ROM. The core does not work without one.**
>
> No ROM is included in this repository or in its releases: C65 ROMs are
> copyrighted and cannot be distributed here. Without a ROM the core stays
> in reset and shows a blank screen. You need to obtain a 128K (131072 byte)
> C65 system ROM image yourself and place it on the SD card as
> `/media/fat/games/C65/boot.rom` - see [Installing](#installing).

**Test builds, testers wanted.** Releases are test builds: please try your
ROMs, software, keyboards and controllers and report what works and what
doesn't (see [Feedback and problems](#feedback-and-problems)). This is not a
MEGA65, even with the MEGA65 Extensions option on: MEGA65 games and demos
that use the SD card, digital audio or 40 MHz will not run, and
for C64 games the MiSTer C64 core is the better choice than `GO64`.

## Status

| Part | State |
|------|-------|
| CSG 4510 CPU (65CE02 + MAP) | done, fuzz-tested against a reference model (`sim/cpu_fuzz`) |
| Memory map (128K RAM, 128K ROM, MAP, C64 banking, `$D030` ROM enables) | done |
| VIC-III: text 40/80 col + attributes, VIC-II bitmap modes, bitplanes (up to 8, 320 or 640 wide, 200 or 400 lines), palette, sprites, raster IRQ | done (line based, not cycle exact). 400-line modes are sent as two alternating fields for the scaler to weave; no true interlaced sync on analogue output |
| VIC-III 1280 pixel bitplane modes (`$D031` H1280) | done, confirmed on hardware over HDMI: 160 cells across, up to 6 bitplanes (the fetch has time for no more). The core then sends pixels at twice the normal rate; they do not fit the analogue scandoubler's line buffer (use HDMI, or analogue output without the scandoubler). The 911210 ROM's `SCREEN` command does not set these modes up (that part of BASIC 10 was never finished), so they are reached by programming the registers |
| F018 DMAgic (F018A and F018B lists; copy / fill / swap) | done |
| F011 floppy controller, internal drive, `.D81` read/write | done (sector level). The write-track command blanks the track, which is what `HEADER` with an ID needs to format a disk |
| External 1565 drive (second `.D81`, OSD *Mount Drive 9*) | done: both ROMs report it at start-up and use it as unit 9 (`DIR U9`, `DLOAD"X",U9`, S-BASIC `BACKUP U8 TO U9`). `D1` is not supported by either ROM |
| Serial port (UART at `$D600`), RS-232 through the MiSTer's UART modes | done, sending and receiving confirmed on hardware: 5-8 data bits, parity, 300-38400 baud. The stock ROM's KERNAL drives it as device 2 (`OPEN 2,2,0,CHR$(14)`); S-BASIC 65 has no RS-232 driver |
| CIA 6526 x2, keyboard incl. C65 extra keys, joysticks | done; keyboard and joysticks confirmed on hardware |
| 1351 mouse on either control port | done; pointer movement and left button confirmed on hardware |
| Dual SID | done (MiSTer C64/C128 SID): `SOUND`, `PLAY`, the filter and stereo placement (`$D400` SID right, `$D420` SID left) confirmed on hardware |
| RAM expansion: banks 6-15 (`$60000-$FFFFF`) and 4 MB at `$400000-$7FFFFF` (DMA banks `$40-$7F`) | done; needs a MiSTer SDRAM module |
| IEC serial bus with an emulated 1541 (unit 10, `.D64` and `.G64` images) | done, confirmed on hardware with the stock ROM, in C64 mode and with S-BASIC 65: directory, load, save. Needs a 1541 DOS ROM (`boot1.rom`) and the SDRAM module, where the drive's ROM is kept. Built from the MiSTer C64 / C128 cores' 1541 (no parallel cable). G64 images (bit-exact tracks, used by copy-protected disks) are converted by the MiSTer as for the C64 core (confirmed on hardware: directory, save, load); copy protection that depends on exact C64 timing still fails. Printers and other IEC devices are not emulated |
| MEGA65 extensions for S-BASIC 65 (OSD option, off by default) | see below |

Verified with ROM **911210**:

- on hardware: boot, BASIC 10 program entry / `RUN`, reading and writing a
  D81 mounted from the OSD, 4 MB expansion RAM (detected at boot, `DMA`
  copy out and back), the 640x400 interlaced Workbench picture from the
  Commodore C65 demo disk (`FB DEMO`), mouse pointer movement, formatting a
  disk with `HEADER` (simulation)
- in simulation only: `LIST`, bitplane graphics (`SCREEN`, `PALETTE`,
  `LINE`, `BOX`, `CIRCLE`, `CHAR`), sprites, NTSC timing, `GO64`, and from
  the demo disk the Deluxe Paint (640x200, 16 colours) and REGINA
  (320x200, 256 colours) pictures

#### The Commodore C65 demo disk

The disk auto-boots. Its boot program says it requires the C65.9.910107 ROM
and an early F018 DMA chip, and what it does depends on expansion RAM:

- with **Expansion RAM** on it loads an IFF slideshow, which then leaves a
  black screen with ROM 911210 (it uses that early DMA list format)
- with **Expansion RAM** off it shows the Workbench and Deluxe Paint
  pictures, which work

To run the pictures by hand, press Esc (RUN/STOP) during the `LOADING`
lines, then `DLOAD"FB DEMO"`, `DLOAD"DP DEMO"` or `DLOAD"REGINA DEMO"` and
`RUN`. The disk needs a stock C65 ROM; its programs do not run under
S-BASIC 65.

### MEGA65 extensions

ROMs built for the MEGA65 (the 92xxxx series and derivatives such as
"S-BASIC 65") do not run on a real C65, and they do not run on this core
with the OSD option **MEGA65 Extensions** at its default, *Off*: the
machine is then a plain C65 and the MEGA65 unlock (`$47`,`$53` written to
`$D02F`) is treated as a wrong key, as on a real C65. S-BASIC 65 stops at a
blue screen.

With the option *On*, the core switches the following on when the ROM
unlocks MEGA65 I/O. A stock C65 ROM never does that, so it still sees a
plain C65 either way. The extra chip RAM at `$40000-$5FFFF` is present in
both settings (C65 software does not use it).

| Part | State |
|------|-------|
| 45GS02 `NEG NEG` 32-bit Q-register instructions | done, fuzz-tested |
| 45GS02 `[nn],Z` far pointers (28-bit addresses) | done, fuzz-tested |
| Chip RAM at `$40000-$5FFFF` (384K in total) | done |
| Character set RAM at `$FF7E000` | done |
| Multiplier / divider at `$D768-$D77F` | done |
| VIC-IV: 16-bit sprite pointers (`$D06C-$D06E`), bitplane bank (`$D07C`) | done |
| VIC-IV full-colour character mode: 16-bit characters, `$D054` CHR16 / FCLRLO / FCLRHI, screen pointer `$D060-$D063`, row step `$D058/59`, colour offset `$D064/65` (S-BASIC `FCM` commands) | done. 32K of colour RAM (`$FF80000-$FF87FFF`) as on the MEGA65 (the C65 has 2K), so 80 column and larger full-colour screens work (confirmed on hardware from the CPU / DMA side, the video side in simulation). S-BASIC's own `FCM ON` is always 40x25. Per-character flips untested; alpha and nibble-colour (NCM) characters missing |
| VIC-IV raster rewrite buffer: each 16-bit text line is drawn into a line buffer, CHRCOUNT cells per row (`$D05E`, `$D063`), GOTOX cells (colour byte 0 bit 4) with transparency and the vertical glyph offset | done, confirmed on hardware (Space Commander). GOTOX row mask, pixel trimming and alpha are ignored |
| VIC-IV hot registers (`$D05D` bit 7) and the character set pointer (`$D068-$D06A`) | done |
| V400 text: 80x50 and 40x50 screens (`$D031` bit 3 in text modes) | done, confirmed on hardware with the MEGA65 Open ROMs. S-BASIC 65 itself has no 50-line mode |
| VIC-IV sprites: 16-colour (`$D06B`) with 16 palette entries per sprite, 64 pixels wide (`$D057`), programmable height (`$D055/56`) (S-BASIC `FCSPRITE` commands) | done; wide and tall sprites untested |
| Other VIC-IV registers (borders, scaling, text position, palette banks, sprite alpha / tiling) | stored and read back, no effect on the picture |
| Real-time clock (`$FFD7110`), read only, set from the MiSTer's clock | done |
| Speed switch (65 / 64 written to address 0; S-BASIC `FAST` / `SLOW`) | done: "40 MHz" selects the core's top speed, 16 MHz |
| Hypervisor DOS traps (`$D640`): getversion, setname, findfile, openfile, readfile (512 bytes at a time into the SD sector buffer at `$FFD6E00`), closefile, chdir / cdrootdir | done for one file: the one mounted with *Mount Data File (MEGA65)* (any name finds it). Other traps fail with "not implemented"; there is no SD card file system |
| Writable `$20000-$3FFFF` (far pointer and DMA writes, as on the MEGA65 where this is RAM) | done. A copy of the ROM is kept in the SDRAM module and put back at the next reset, so S-BASIC returns without reloading the core |
| Keyboard matrix peek (`$D613` / `$D614`), cursor left / up (`$D60F`) | done. The ASCII key queue (`$D610`) is not implemented |
| Audio DMA (`$D711-$D75F`): four channels, 16 / 8 / 4 bit samples, looping, volume and panning, mixed with the SIDs | done, confirmed on hardware (Space Commander's music and sound effects). Samples come from chip RAM only; no audio DMA interrupts or sine mode |
| SD card, Ethernet, a true 40 MHz | not implemented. The CPU's top speed is 16 MHz |
| Attic RAM: 8 MB at `$8000000`, through far pointers and DMA | done, confirmed on hardware (S-BASIC `EDMA` fill and copy back); kept in the SDRAM module, so it needs one (it does not depend on the *Expansion RAM* option) |
| Enhanced DMA jobs (`$D705`): megabyte options, list format, transparency (`$06`/`$07`, `$86`), source / destination step rates in 1/256 steps (`$82`-`$85`) (S-BASIC `EDMA`) | done, confirmed on hardware (copy, fill, transparency, source and destination step rates). Other options (line drawing, spiral mode) are ignored |

Verified with S-BASIC 65 V250507:

- on hardware: boot, program entry / `RUN`, floating point, `SCREEN` + `BOX`
  graphics, reading and writing a D81 mounted from the OSD, the clock
  (`TI$` / `DT$` match the MiSTer's time), full-colour mode (`FCM ON`,
  `FCM CLS`, `FCM TEXT`), full-colour sprites (`FCSPRITE` with
  transparency, priority and x/y expansion, `FCSPRDEF`, `FCSPRFRAME`,
  `FCSPRCOPY`, `FCSPRFLIP` both ways, `FCSPRCOLOR`, `PALETTE COPY`:
  pixel-identical to simulation)
- also on hardware (checked against the simulator): number and string
  functions (`BIN$`, `HEX$`, `DEC`, `BYTE`, `ADD` / `SUB` / `SHL` / `SHR`,
  `MADD` / `MSUB`, `PEEK@`, `MOD`), procedures (`PROC`, `DEFPROC`, `LOCAL`,
  `ENDPROC`, `RPROC`, `RLEVEL`), `EVERY` / `AFTER`, the inline assembler and
  `CALL`, `TEXT` / `RTEXT` / `PUTSCR` / `GETSCR` / `INK` / `PAPER` /
  `BORDER`, sprites (`SPRDEF`, `SPRCOPY`, `SPRFLIP`, `SPRCOLOR`,
  `SPRSAVE` / `SPRLOAD`, `SPRITE`, `SPRFRAME`, `MOVSPR`, multicolour),
  `FCALC`, `INFO`, `VIC4`, `SYNC`, `PAUSE`, `PALETTE SAVE` / `LOAD`,
  `FAST` / `SLOW`, `EDMA`, `HEADER`, `SAVEIFF` / `LOADIFF`, `MOUSE` /
  `RMOUSE` with the button, `MONITOR`, `HELP`, and `VOL`, `TEMPO`,
  `ENVELOPE`, `FILTER`, `PLAY`, `SOUND` (a `PLAY` scale sounds correct)
- in simulation only: `LIST`, `MAN`, `MODE 40` / `80`, graphics (`DRAW`,
  `BOX` outline and solid, `FILL`, `CUT` / `PASTE`, `GCOPY`, `VIEWPORT`,
  `PIXEL`, `RPEN`), disk commands (`SAVE` / `VERIFY`, `RENAME`, `COPY`,
  `CONCAT`, `ERASE`, `COLLECT`, `DCLEAR`, `TYPE`, `MERGE`, sequential files
  with `DOPEN` / `APPEND` / `PRINT#` / `INPUT#`, `BSAVE` / `BLOAD` /
  `BVERIFY`), `WINDOW` / `RWINDOW`, `CURSOR` / `RCURSOR`, `HIGHLIGHT`,
  `RENUMBER`, `TRAP` / `RESUME` / `ERR$`, `JOY`, `RSPEED` / `RSPPOS` /
  `RSPRITE` / `RSPCOLOR`, `COLLISION`, `FONT`, `CHARDEF`, `KEY`, `SET DEF`,
  `MEM`, `RREG`, `FCSPRSAVE` / `FCSPRLOAD` round trip

Known not to work under S-BASIC 65:

- `MOUNT` (needs the MEGA65 hypervisor's SD card access); use the OSD.
- Relative files (`DOPEN` with `L`, `RECORD`) do not work: records are not
  stored, `DCLOSE` can report `71,BAM CORRUPTED`, and the directory entry
  can get a nonsense block count. Traced in simulation, this is a bug in
  S-BASIC's DOS rather than in the core: the DOS starts using a second data
  buffer for the file without ever recording which track that buffer holds,
  then looks up the BAM entry for "track 0". It uses no hardware the core
  lacks, and the stock 911210 ROM's DOS handles relative files correctly on
  this core.
- `CHDIR` was not tried (it needs a partitioned disk). `BACKUP U8 TO U9`
  (and the other way round) works with a second image in *Mount Drive 9*.
- RS-232 (`OPEN` on device 2): S-BASIC 65's KERNAL has no driver for it
  (`?DEV NOT PRESENT`); it works with the stock ROM.

Sound has been heard on hardware: `SOUND`, a `PLAY` scale, a filter sweep,
and each SID on its own side of the stereo mix.

Also checked on hardware: the PAL / NTSC switch (312 and 263 line frames),
all four keyboard layouts (US, UK, DE, Positional give the expected
characters for the same keys) and the 3.5 / 8 / 16 MHz OSD speeds with the
stock ROM's `FAST`.

Also confirmed on hardware by hand: real US and UK keyboards (symbols, graphics
characters, colour keys, cursor and editing keys, RUN/STOP and RESTORE, key
repeat), joysticks in both ports, the SID filter and stereo placement.

## Installing

A ready-built core is in [`releases/`](releases) (MiSTer convention: the
newest dated `.rbf` is the one to use) and on the
[releases page](https://github.com/jnngill/C65_MiSTer/releases).

| File | Copy to (on the MiSTer SD card) |
|------|---------------------------------|
| `releases/C65_<date>.rbf` (or `output_files/C65.rbf` if you build it) | `/media/fat/_Computer/` |
| your C65 system ROM, renamed `boot.rom` | `/media/fat/games/C65/` |
| `blank.d81` (release, or `disks/blank.d81`) | `/media/fat/games/C65/` |
| `c65_prg_disk.sh` (optional, for `.prg` / `.d64` files; release, or `scripts/mister/`) | `/media/fat/Scripts/` |

1. Create the folder `/media/fat/games/C65/`.
2. Copy the `.rbf` to `/media/fat/_Computer/`.
3. **Required:** copy a 128K C65 ROM image, which you must obtain yourself,
   to `/media/fat/games/C65/boot.rom`. ROMs are copyrighted and are not
   included; the core shows a blank screen until one is present. `boot.rom`
   is loaded when the core starts; other images in the folder (`.rom` /
   `.bin`) can be loaded from the OSD with *Load System ROM*.
4. Copy `blank.d81` to `/media/fat/games/C65/`.
   *Optional, for `.D64` images:* copy a 16K Commodore 1541 DOS ROM (for
   example 325302-01 + 901229-05, as shipped with VICE as `dos1541`) to
   `/media/fat/games/C65/boot1.rom`. Like the C65 ROM it is copyrighted and
   not included. The emulated 1541 keeps it in the SDRAM module, so it needs
   one.
5. Start **C65** from the Computer menu.
6. Press F12, choose *Mount Drive 8* and pick `blank.d81`. It is an empty,
   formatted 1581 disk; keep a spare copy, the core writes to the image.
   `scripts/mkd81.py` makes more, optionally with PRG files on them; see
   [Loading .PRG and .D64 files](#loading-prg-and-d64-files).

ROMs this core has been run with: **911210** (the last original Commodore
ROM; runs as a plain C65) and **S-BASIC 65 V250507** (a MEGA65-style ROM).

**Using S-BASIC 65 or another MEGA65-style ROM?** Set **MEGA65 Extensions**
to *On* in the OSD, then choose *Save settings* (on the OSD's System page) so
it stays on; with the default *Off* the ROM stops at a blue screen.

## Using it

*Reset* in the OSD restarts the machine; it is also the only way back from
`GO64`.

### Loading .PRG and .D64 files

**One program:** choose *Load Program* in the OSD and pick a `.prg` file.
It is copied straight into memory at its load address while the machine is
held, then `RUN` (or `LIST`) it. C65 BASIC programs (load address `$2001`)
and C64 BASIC programs after `GO64` (`$0801`) get BASIC's end-of-program
pointer set, so `RUN`, `LIST` and `SAVE` work; anything else is machine code,
started with `SYS` and its address.

**A `.d64` image:** mount it with *Mount Drive 10 (1541)* and use it as unit
10: `DIR U10`, `DLOAD"NAME",U10`, `DSAVE"NAME",U10` (S-BASIC 65:
`DIR U10`, `LOAD "NAME",U10`); in C64 mode `LOAD"$",10`, `LOAD"NAME",10`.
This needs a 1541 ROM, see [Installing](#installing). Fast loaders and copy
protection mostly fail, because C64 mode is not cycle exact.

**A whole folder of programs:** the `c65_prg_disk.sh` script builds a `.d81`
disk for the internal drive from a folder of `.prg` and `.d64` files:

1. Copy `c65_prg_disk.sh` to `/media/fat/Scripts/`.
2. Run **c65_prg_disk** from the MiSTer *Scripts* menu once. It creates the
   folder `/media/fat/games/C65/PRG/`.
3. Copy your `.prg` and `.d64` files into that folder (over the network, or with the SD
   card in a PC).
4. Run **c65_prg_disk** again. It packs every `.prg` in the folder, and
   every file (PRG, SEQ, USR) inside every `.d64`, into
   `/media/fat/games/C65/prg.d81` and lists what it added.
5. In the C65 core, mount `prg.d81` from the OSD, then `DIR` and
   `DLOAD"NAME"` (or `LOAD "NAME"` in S-BASIC 65) and `RUN`. In C64 mode
   (`GO64`) use `LOAD"$",8` / `LIST` and `LOAD"NAME",8` or `LOAD"NAME",8,1`.

Run the script again whenever you add or remove programs, then mount
`prg.d81` again. The disk is rebuilt from the folder each time, so files
saved onto `prg.d81` from the C65 are replaced; the previous image is kept as
`prg.d81.bak`. Names longer than 16 characters are shortened, and files
with the same name get a `~2`, `~3` ... suffix. On a PC,
`scripts/mkd81.py` does the same job for `.prg` files.

Only the files are copied from a `.d64`. Software that reads the 1541 disk
directly (fast loaders, copy protection, most demos and multi-load games)
needs a real 1541 and will not work; use the MiSTer C64 core for those.
Relative (REL) files on a `.d64` are skipped.

### MEGA65 programs

With *MEGA65 Extensions* on and S-BASIC 65 as the ROM, some MEGA65 games run.
Tested on hardware:

- **Space Commander** (v1.3): mount `space-commander.d81` in *Mount Drive 8*
  and `SPACE.SCP` with *Mount Data File (MEGA65)*, then
  `LOAD"SPACE COMMANDER"` and `BANK 0:SYS 8205` (S-BASIC's `RUN` / `SYS`
  run in a bank where `$2000` is ROM, so the game's `SYS 8205` stub needs
  the `BANK 0`). The data file streams into attic RAM in about 30 seconds;
  title screen and gameplay are correct.
- **Titan Fall**: `LOAD"TITANFALL"` and `RUN`.

The MEGA65 network programs (BBS, IRC, SSH ...) need the MEGA65 Ethernet
controller, which the core does not have.

### C65TERM: a telnet BBS terminal

`c65term.d81` (in the release, source in `term/`) holds C65TERM, a terminal
for telnet BBSes through the MiSTer's emulated modem. It runs under the stock
911210 ROM and S-BASIC 65 and needs the OSD option **MEGA65 Extensions** on
(it uses the 45GS02's 32-bit pointers; without them it says so and stops):
mount the disk, `LOAD"C65TERM"` (or `DLOAD`) and `RUN`.

- Set the MiSTer's *UART mode* to the modem and its baud rate to 9600 (the
  default; **B** in C65TERM switches both sides to 2400 / 9600 / 19200).
- Emulations: **ANSI-BBS** (80x25, CP437 font, 16 colours with a background
  per character), **VT100** and **PETSCII** (40x25, C64 colours and fonts).
  The screen is a 16 colour bitplane picture; the fonts are built at start-up
  from the ROM's character sets.
- A dialling directory (up to 8 sites, saved as `C65TERM.CFG`), quick dial
  (`host:port`) and a direct line to the modem for AT commands.
- Telnet negotiation (terminal type, window size, binary) when the server
  asks for it; raw TCP BBSes (such as C64 BBSes behind a WiFi modem) are
  detected and left untouched.
- File transfers to the disk in drive 8: **ZMODEM** (downloads start by
  themselves) and **XMODEM** (checksum, CRC, 1K), both ways. Downloads are
  saved as SEQ files; a full disk or other drive error is shown and the
  transfer cancelled.
- In a session **F1** opens a menu: hang up, download, upload, change the
  emulation. While C65TERM runs, F1-F8 send the C64 codes 133-140. **X** on
  the main menu quits by restarting the machine (a program in BASIC memory is
  lost; the disk is not touched).

Tested on hardware with Synchronet (ANSI, a 720 KB ZMODEM download, a disk
full stop) and Particles BBS (PETSCII, XMODEM). Not yet tried on hardware:
uploads and VT100. Building it needs [cc65](https://cc65.github.io)
(`term/build.sh`).

### OSD options

| Option | Choices | Notes |
|--------|---------|-------|
| Mount Drive 8 | a `.D81` file | the internal 3.5" drive |
| Mount Drive 9 (1565) | a `.D81` file | the external 1565 drive, unit 9. It can be mounted at any time; the start-up message only reports it if it was mounted before the machine started |
| Mount Drive 10 (1541) | a `.D64` or `.G64` file | the emulated 1541 on the IEC bus, unit 10 (needs a 1541 ROM and the SDRAM module) |
| Mount Data File (MEGA65) | a `.SCP`, `.BIN` or `.DAT` file | the file that MEGA65 programs open through the hypervisor (e.g. Space Commander's `SPACE.SCP`); read only |
| Load System ROM | a `.rom` / `.bin` file | replaces the ROM loaded from `boot.rom` and resets |
| Load Program | a `.prg` file | copies the program into memory, see [Loading .PRG and .D64 files](#loading-prg-and-d64-files) |
| Load 1541 ROM | a `.rom` / `.bin` file | the 1541's DOS ROM, if it is not in `boot1.rom` |
| Video Standard | PAL, NTSC | |
| Aspect Ratio, Stereo Mix | | standard MiSTer settings |
| Scandoubler Fx | None, CRT 25%, CRT 50%, CRT 75% | scanlines for analogue output with the scandoubler. The HQ2x filter is not included: it took about 58 of the FPGA's memory blocks, which now hold the 32K colour RAM and the G64 track buffer |
| Keyboard Layout | US, UK, DE, Positional | see below |
| CPU Speed | 3.5 MHz, 8 MHz, 16 MHz | speed of the C65 FAST mode; 3.5 MHz is a real C65. MEGA65-style ROMs switch to 16 MHz by themselves when they ask for full speed (S-BASIC 65 does at start; `SLOW` / `FAST` change it) |
| Expansion RAM | 4MB, Off | the C65 RAM expansion, kept in the MiSTer SDRAM module; without a module the machine reports no expansion |
| Mouse | Port 2, Port 1, Off | a Commodore 1351 on that control port. S-BASIC 65's `MOUSE ON` uses port 2; on the stock ROM name the port, e.g. `MOUSE ON,2` |
| DMA Revision | F018B, F018A | F018B for ROMs from mid 1991 on, F018A for older ones |
| MEGA65 Extensions | Off, On | Off: a plain C65. On: the MEGA65 subset that S-BASIC 65 needs (see [MEGA65 extensions](#mega65-extensions)). Changing it restarts the machine |
| Reset | | restarts the machine |

### Serial port

The C65's serial port (UART) is connected to the MiSTer's UART. Pick a
*UART mode* on the OSD's System page (for example *Modem* for telnet BBSes,
*MIDI*, or *Console*) and set its *Baud* to the rate the C65 program uses.

With the stock 911210 ROM, BASIC opens it as device 2; the first character
of the name sets the speed and format as on a C64, e.g.

    OPEN 2,2,0,CHR$(14)+CHR$(0)    : REM 9600 baud, 8 data bits, no parity
    PRINT#2,"ATZ"                  : GET#2,A$ ... : CLOSE 2

`CHR$(6)` is 300 baud, `CHR$(8)` 1200, `CHR$(10)` 2400, `CHR$(12)` 4800,
`CHR$(14)` 9600, `CHR$(15)` 19200. S-BASIC 65 has no RS-232 driver.

### Clock

MEGA65-style ROMs get the date and time from the MiSTer (`PRINT TI$` and
`PRINT DT$` in S-BASIC 65). The clock cannot be set from BASIC; it follows
the MiSTer's own clock, including its time zone setting. A stock C65 ROM has
no clock.

### Feedback and problems

Please open an issue at
<https://github.com/jnngill/C65_MiSTer/issues> and include the ROM version,
the OSD settings, what you typed and, if you can, a screenshot.

Especially useful:

- other ROM versions and how far they get
- C65 / MEGA65 BASIC software on `.D81` images that works or doesn't
- keyboard and controller setups
- anything that looks or sounds different from a real C65 or MEGA65

Many BASIC 10 commands on the 911210 ROM answer `UNIMPLEMENTED COMMAND`:
that ROM was never finished by Commodore, it is not a fault of the core.

### Keyboard

With the US, UK and DE layouts the character on the host key cap is what
the C65 gets. "Positional" maps keys by their place on a C64/C65 keyboard.

| Host key | C65 key |
|----------|---------|
| Esc | RUN/STOP |
| F11 | RESTORE |
| F1 F3 F5 F7 / F2 F4 F6 F8 | F1 F3 F5 F7 / shifted |
| F9, F10, F12 | F9, F11, F13 |
| End | ESC |
| Tab, Alt, Win | TAB, ALT, C= |
| PgUp | HELP |
| PgDn | up arrow |
| Insert | pound |
| Home | HOME / CLR |
| Scroll Lock | NO SCROLL |
| Caps Lock | CAPS LOCK |

## Building

Quartus 17.0 (Lite is enough):

    quartus_sh --flow compile C65

## Simulation

Needs Verilator (the OSS CAD Suite build works) and `zig c++` as the C++
compiler; paths are set at the top of the scripts.

    bash sim/cpu_fuzz/run.sh            # CPU vs. reference model, random code
    bash sim/cpu_fuzz/run.sh 20 200000 gs   # same with the 45GS02 prefixes
    bash sim/system/build.sh            # whole machine
    sim/system/build/tb.exe roms/911210.bin sim/out 150
    sim/system/build/tb.exe roms/911210.bin sim/out 560 \
        -keys sim/system/keys_disk.txt -d81 blank.d81

The testbench prints the text screen and writes `final.ppm`
(`scripts/ppm2png.py` converts it). `scripts/dis4510.py` is a small 4510
disassembler for poking at ROMs.

## Layout

    C65.sv                MiSTer top level (OSD, ROM load, video/audio out)
    rtl/c65_core.sv       the machine: bus cycle, address decode, I/O
    rtl/cpu/cpu4510.sv    CPU
    rtl/vic3.sv           video
    rtl/dma_f018.sv       DMA
    rtl/f011.sv           floppy controller
    rtl/m65_math.sv       MEGA65 multiplier / divider
    rtl/m65_rtc.sv        MEGA65 real-time clock registers
    rtl/sdram.v           SDRAM controller (expansion RAM), from the MiSTer C64 core
    rtl/c65_keyboard.sv   generated by scripts/gen_keyboard.py
    rtl/mos6526_8520.v, rtl/sid/, rtl/pll*, sys/   from MiSTer C64/C128 cores

## License

GPL-3.0-or-later, see [LICENSE](LICENSE). Files taken from other projects
keep their own headers (`sys/`, `rtl/sid/`, `rtl/mos6526_8520.v`, `rtl/pll*`).

## Credits

CIA, SID, PLL and the `sys/` framework come from the MiSTer C64 / C128
cores. The 4510 opcode table is derived from the MEGA65 project's
`gs4510.vhdl`.
