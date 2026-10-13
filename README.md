# Commodore 65 for MiSTer

A from-scratch Commodore 65 core for the MiSTer (DE10-Nano). It boots the
original Commodore C65 ROMs to BASIC 10, with the internal 3.5" drive backed
by `.D81` images, and carries just enough MEGA65 hardware to run MEGA65-style
ROMs such as S-BASIC 65 (a completed BASIC).

> **You must supply your own system ROM. The core does not work without one.**
>
> No ROM is included in this repository or in its releases: C65 ROMs are
> copyrighted and cannot be distributed here. Without a ROM the core stays
> in reset and shows a blank screen. You need to obtain a 128K (131072 byte)
> C65 system ROM image yourself and place it on the SD card as
> `/media/fat/games/C65/boot.rom` - see [Installing](#installing).

## Status

| Part | State |
|------|-------|
| CSG 4510 CPU (65CE02 + MAP) | done, fuzz-tested against a reference model (`sim/cpu_fuzz`) |
| Memory map (128K RAM, 128K ROM, MAP, C64 banking, `$D030` ROM enables) | done |
| VIC-III: text 40/80 col + attributes, VIC-II bitmap modes, bitplanes (up to 8, 320 or 640 wide, 200 or 400 lines), palette, sprites, raster IRQ | done (line based, not cycle exact). 400-line modes are sent as two alternating fields for the scaler to weave; no true interlaced sync on analogue output. H1280 missing |
| F018 DMAgic (F018A and F018B lists; copy / fill / swap) | done |
| F011 floppy controller, internal drive, `.D81` read/write | done (sector level; no track format command) |
| CIA 6526 x2, keyboard incl. C65 extra keys, joysticks | done |
| 1351 mouse on either control port | done in simulation (movement); not yet confirmed on hardware |
| Dual SID | working (MiSTer C64/C128 SID); only a basic `SOUND` test so far |
| RAM expansion: banks 6-15 (`$60000-$FFFFF`) and 4 MB at `$400000-$7FFFFF` (DMA banks `$40-$7F`) | done; needs a MiSTer SDRAM module |
| UART, external 1565 drive, IEC devices | not implemented |
| MEGA65 subset for S-BASIC 65 | see below |

Verified with ROM **911210**:

- on hardware: boot, BASIC 10 program entry / `RUN`, reading and writing a
  D81 mounted from the OSD, 4 MB expansion RAM (detected at boot, `DMA`
  copy out and back)
- in simulation only: `LIST`, bitplane graphics (`SCREEN`, `PALETTE`,
  `LINE`, `BOX`, `CIRCLE`, `CHAR`), sprites, NTSC timing, `GO64`, and the
  Commodore C65 demo disk: auto-boot, the Deluxe Paint (640x200, 16
  colours), Workbench (640x400 interlaced) and REGINA (320x200, 256
  colours) pictures. That disk's `IFF DEMO` slideshow loads its pictures
  but then crashes; it appears to have been written for an earlier ROM

### MEGA65 subset

ROMs built for the MEGA65 (the 92xxxx series and derivatives such as
"S-BASIC 65") do not run on a real C65. The core switches the following on
when the ROM unlocks MEGA65 I/O (`$47`,`$53` written to `$D02F`); a stock
C65 ROM never does, so it sees a plain C65.

| Part | State |
|------|-------|
| 45GS02 `NEG NEG` 32-bit Q-register instructions | done, fuzz-tested |
| 45GS02 `[nn],Z` far pointers (28-bit addresses) | done, fuzz-tested |
| Chip RAM at `$40000-$5FFFF` (384K in total) | done |
| Character set RAM at `$FF7E000` | done |
| Multiplier / divider at `$D768-$D77F` | done |
| VIC-IV: 16-bit sprite pointers (`$D06C-$D06E`), bitplane bank (`$D07C`) | done |
| Other VIC-IV registers (full-colour mode, screen/char pointers, borders) | not implemented |
| Real-time clock (`$FFD7110`), read only, set from the MiSTer's clock | done |
| Hypervisor traps (`$D640`), SD card, attic RAM, 40 MHz | not implemented; traps are ignored |
| Enhanced DMA jobs (`$D705`) | not implemented |

Verified with S-BASIC 65 V250507:

- on hardware: boot, program entry / `RUN`, floating point, `SCREEN` + `BOX`
  graphics, reading and writing a D81 mounted from the OSD, the clock
  (`TI$` / `DT$` match the MiSTer's time)
- in simulation only: `LIST`, `SPRITE` / `MOVSPR`, the 8 / 16 MHz CPU speeds

Sound has been heard on hardware (the BASIC `SOUND` command); music with
`PLAY`, filters and stereo placement have not been judged.

Not yet checked on hardware at all: joysticks, the PAL/NTSC switch and the
UK / DE keyboard layouts.

## Installing

A ready-built core is in [`releases/`](releases) (MiSTer convention: the
newest dated `.rbf` is the one to use) and on the
[releases page](https://github.com/jnngill/C65_MiSTer/releases).

| File | Copy to (on the MiSTer SD card) |
|------|---------------------------------|
| `releases/C65_<date>.rbf` (or `output_files/C65.rbf` if you build it) | `/media/fat/_Computer/` |
| your C65 system ROM, renamed `boot.rom` | `/media/fat/games/C65/` |
| `blank.d81` (release, or `disks/blank.d81`) | `/media/fat/games/C65/` |

1. Create the folder `/media/fat/games/C65/`.
2. Copy the `.rbf` to `/media/fat/_Computer/`.
3. **Required:** copy a 128K C65 ROM image, which you must obtain yourself,
   to `/media/fat/games/C65/boot.rom`. ROMs are copyrighted and are not
   included; the core shows a blank screen until one is present. `boot.rom`
   is loaded when the core starts; other images in the folder (`.rom` /
   `.bin`) can be loaded from the OSD with *Load System ROM*.
4. Copy `blank.d81` to `/media/fat/games/C65/`.
5. Start **C65** from the Computer menu.
6. Press F12, choose *Mount Drive 8* and pick `blank.d81`. It is an empty,
   formatted 1581 disk; keep a spare copy, the core writes to the image.
   `scripts/mkd81.py` makes more, optionally with PRG files on them.

ROMs this core has been run with: **911210** (the last original Commodore
ROM; runs as a plain C65) and **S-BASIC 65 V250507** (a MEGA65-style ROM;
set *CPU Speed* to 16 MHz for it).

## Using it

*Reset* in the OSD restarts the machine; it is also the only way back from
`GO64`.

### OSD options

| Option | Choices | Notes |
|--------|---------|-------|
| Mount Drive 8 | a `.D81` file | the internal 3.5" drive |
| Load System ROM | a `.rom` / `.bin` file | replaces the ROM loaded from `boot.rom` and resets |
| Video Standard | PAL, NTSC | |
| Aspect Ratio, Scandoubler Fx, Stereo Mix | | standard MiSTer settings |
| Keyboard Layout | US, UK, DE, Positional | see below |
| CPU Speed | 3.5 MHz, 8 MHz, 16 MHz | 3.5 MHz is a real C65; MEGA65-style ROMs expect a much faster CPU, use 16 MHz |
| Expansion RAM | 4MB, Off | the C65 RAM expansion, kept in the MiSTer SDRAM module; without a module the machine reports no expansion |
| Mouse | Port 2, Port 1, Off | a Commodore 1351 on that control port. S-BASIC 65's `MOUSE ON` uses port 2; on the stock ROM name the port, e.g. `MOUSE ON,2` |
| DMA Revision | F018B, F018A | F018B for ROMs from mid 1991 on, F018A for older ones |
| Reset | | restarts the machine |

### Clock

MEGA65-style ROMs get the date and time from the MiSTer (`PRINT TI$` and
`PRINT DT$` in S-BASIC 65). The clock cannot be set from BASIC; it follows
the MiSTer's own clock, including its time zone setting. A stock C65 ROM has
no clock.

### Reporting problems

Please open an issue at
<https://github.com/jnngill/C65_MiSTer/issues> and include the ROM version,
the OSD settings, what you typed and, if you can, a screenshot.

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
