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
that depend on exact 40 MHz timing may not run (the core tops out at about 30 MHz equivalent).
MEGA65 network programs do work, through the MiSTer's network cable (see
[Networking](#networking-mega65-ethernet)). For C64 games the MiSTer
C64 core is the better choice than `GO64`, and `GO64` can load it (see
[GO64 / GO128: the MiSTer C64 and C128 cores](#go64--go128-the-mister-c64-and-c128-cores)).

## Status

| Part | State |
|------|-------|
| CSG 4510 CPU (65CE02 + MAP) | done, fuzz-tested against a reference model (`sim/cpu_fuzz`) |
| Memory map (128K RAM, 128K ROM, MAP, C64 banking, `$D030` ROM enables) | done |
| VIC-III: text 40/80 col + attributes, VIC-II bitmap modes, bitplanes (up to 8, 320 or 640 wide, 200 or 400 lines), palette, sprites, raster IRQ | done (line based, not cycle exact). 400-line modes are sent as two alternating fields for the scaler to weave; no true interlaced sync on analogue output |
| VIC-III DAT (display address translator): `$D040-$D047` read and write the byte of bitplane 0-7 at the position in `$D03C` / `$D03D`, in the plane's address (`$D033-$D03A`) and bank (`$D07C`), as on the C65 and MEGA65 | done, confirmed on hardware (Intro Disk #1 "2 BITPLANE CUBE") |
| VIC-III 1280 pixel bitplane modes (`$D031` H1280) | done, confirmed on hardware over HDMI: 160 cells across, up to 6 bitplanes (the fetch has time for no more). The core then sends pixels at twice the normal rate; they do not fit the analogue scandoubler's line buffer (use HDMI, or analogue output without the scandoubler). The 911210 ROM's `SCREEN` command does not set these modes up (that part of BASIC 10 was never finished), so they are reached by programming the registers |
| F018 DMAgic (F018B, F018A and the original 9-byte lists; copy / fill / swap) | done |
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
  black screen with ROM 911210 (see below)
- with **Expansion RAM** off it shows the Workbench and Deluxe Paint
  pictures, which work

To run the pictures by hand, press Win+Esc (RUN/STOP) during the `LOADING`
lines, then `DLOAD"FB DEMO"`, `DLOAD"DP DEMO"` or `DLOAD"REGINA DEMO"` and
`RUN`. The disk needs a stock C65 ROM; its programs do not run under
S-BASIC 65.

#### Fred Bowen's slideshow demo disks (1991)

`DemosAutoboot` and `c65Disk2` on zimmers.net hold "c65 demo #2c" (910417,
F. Bowen), which asks for ROM 910417 and the original F018 DMA chip. Its
slideshow builds five chained DMA lists at `$0400`, 9 bytes each (command,
count, source, destination, no modulo), and `DEMO.9.BIN` starts them at
`$D700`. Read as 11- or 12-byte lists they go wrong, so the screen stays
black. It runs on hardware with:

- **DMA Revision** set to *F018 (9-byte lists)*,
- **Expansion RAM** on,
- a ROM of the same time loaded as the system ROM. ROM 910429 (a C64DX
  ROM, on zimmers.net as `910429.bin`) passes the demo's own ROM check.
  Later ROMs, 911210 included, need F018B for their own DMA.

The disk then auto-boots into the IFF slideshow, followed by the Workbench,
Deluxe Paint and REGINA pictures and the BASIC graphics demos. `Demos910610`
and `c65Disk3` hold "demo #2d" (910624), which asks for ROM 910620. It also
uses 9-byte lists although it names the F018A, so the early chips probably
read only 9 bytes per list; the core's F018A keeps the MEGA65's 11-byte
format. Under ROM 910429 it loads its pictures, then stops with `?SYNTAX
ERROR` at `FILTER1,...`: that ROM's `FILTER` has no SID-number argument yet.
ROM 910626 (`910626.bin` on zimmers.net) passes its ROM check but has a
start-up bug of its own when expansion RAM is present: the sizing loop at
`$FE1D` pushes eight bytes and the restore loop at `$FE3A` (`SBC #$08` /
`BVS`) pops one, so the next `RTS` lands in the monitor (`BREAK` at
`$38032`). With **Expansion RAM** off it skips that loop and boots, and
`RUN"AUTOBOOT*"` then runs demo #2d's Workbench, Deluxe Paint and REGINA
pictures and the graphics demos on hardware. The IFF slideshow needs
expansion RAM, so it is skipped there.

#### The C65 disks from zimmers.net

All 129 programs on the 23 disk images in
[zimmers.net's C65 archive](https://www.zimmers.net/anonftp/pub/cbm/c65/)
were run in simulation (BASIC 10 911210 and BASIC 65 920423). Most of
the failures come from the software, not the core:

- **ROM version**: many of these disks were written for 1990-91
  development ROMs.
  - The IFF slideshows (`DEMO`, `OLD DEMO`, `PIC256` on `IFFDemoReel1` and
    `c65Disk6`) run `SYS 12288` while `BANK 128` is selected. With ROM
    911210 that address is ROM, so the call lands in a ROM DMA routine that
    clears low memory.
  - Selecting bank 0 instead gets the IFF loader running, but it then calls
    `$CF9C`, an entry point only the older ROMs had.
  - `c65Disk2` and `c65Disk3` stop with their own `ROM MISMATCH` message
    (see [Fred Bowen's slideshow demo disks](#fred-bowens-slideshow-demo-disks-1991)).
  - `IFF SS` and `IFF DEMO.8E` on `c65Disk1` / `Demos900907` were written
    for a prototype with the DMA controller at `$DF00`; no released ROM or
    chip matches them.
  - `IFF DEMO` on `c65Disk1` loads its twelve pictures into banks 4-15
    correctly, then goes black. Its routine at `$1880` copies a picture
    with `MAP`, then ends with `MAP` 0, `EOM`, `CLI`, `RTS`. With ROM
    911210 the system map lives in `MAP` (the KERNAL at `$E000` included),
    so the pending interrupt taken after `CLI` reads its vector from the
    RAM the routine just filled with picture data. `JSRFAR` would restore
    the map one step later. The disk asks for ROM 910107, which set up
    memory differently (ROM 910111, the closest available, loads the
    pictures but also goes black). Workaround: `DLOAD"IFF DEMO"`, add the
    line `105 BANK0:POKE6531,234:BANK128:POKE53270,200` and `RUN`. The
    first part turns that `CLI` into a `NOP`; `POKE53270,200` clears
    XSCROLL, which ROM 911210 leaves at 1 for its 80 column screen (in a
    320 pixel bitplane mode that moves the picture one pixel right and
    shows the background colour in the first column). The slideshow then
    runs on hardware (Expansion RAM on).
  - The `IFFDemoReel1` / `c65Disk6` loader `IFF.BIN6E` calls a BASIC jump
    table at `$CF9C`-`$CFB1` that none of ROMs 910111, 910429 and 911210
    has; it needs an earlier (1990) ROM.
- **InfoDisk1** (1993 programs from the Highlander BBS): the raster bar,
  terminal and fade programs run. `BONZI BMAP` and `BMD SLIDER 65` switch
  on bitplane modes without setting the plane addresses, so they show
  whatever memory the defaults point at. `BOUNCEBARZ2.BAS` is damaged on
  the disk image (`?SYNTAX ERROR IN 35748`).
- **Bitplane bank with ROM 920423**: the 1990 demos (`Demos900907`,
  `c65Disk1`) show a grey screen under BASIC 65. ROM 920423 sets `$D07C` to
  2 at start-up, so bitplanes are fetched from `$40000` instead of banks 0
  and 1. A real MEGA65 does the same. Under ROM 911210, `DEMO ALL` shows the
  Workbench, Deluxe Paint and REGINA pictures correctly.
- **Expected stops**:
  - Programs that wait at their own prompt.
  - C128 programs that drop into the monitor.
  - Files missing from the images (`IFF.BIN6E`, `D3.5`, `KINGTUT`,
    `PIC.DIR`, where a program looks for them on a disk that lacks them).
  - BASIC 10 programs that use commands BASIC 65 changed (`?SCREEN NOT
    OPEN`, `?RESERVED NAME`, `?UNDEFINED STATEMENT`).
  - The DOS test disk's `A` / `USER` files, which `LOAD` reports as
    `?PROGRAM MANGLED`. These are probably not BASIC programs.

No core bug turned up in this pass.

All 129 programs were then run on hardware (core C65_20261109c, BASIC 65
920423), and each ends the way it does in simulation: the same prompts,
monitor stops and missing-file errors, and the same grey screens for the
1990 demos. With ROM 911210 loaded instead, `DEMO ALL` on `Demos900907`
loads the Workbench, Deluxe Paint and REGINA pictures and shows them
correctly on hardware.

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
| VIC-IV full-colour character mode: 16-bit characters, `$D054` CHR16 / FCLRLO / FCLRHI, screen pointer `$D060-$D063`, row step `$D058/59`, colour offset `$D064/65` (S-BASIC `FCM` commands) | done. 32K of colour RAM (`$FF80000-$FF87FFF`) as on the MEGA65 (the C65 has 2K), so 80 column and larger full-colour screens work (confirmed on hardware from the CPU / DMA side, the video side in simulation). S-BASIC's own `FCM ON` is always 40x25 |
| VIC-IV raster rewrite buffer: each 16-bit text line is drawn into a line buffer, CHRCOUNT cells per row (`$D05E`, `$D063`), GOTOX cells (colour byte 0 bit 4) with transparency and the vertical glyph offset | done, confirmed on hardware (Space Commander). A GOTOX with colour byte 0 bit 3 set uses colour byte 1 as a mask of the 8 glyph rows (confirmed on hardware) |
| VIC-IV hot registers (`$D05D` bit 7) and the character set pointer (`$D068-$D06A`) | done. As on the VIC-IV, a VIC-II / VIC-III register touched while HOTREG is off is applied when HOTREG is set again (writing `$D05D` with it clear forgets it), the recalculation keeps bits 16-19 of the character set pointer (MEGA65 GEOS keeps its 640x400 bitmap at `$40000` this way) and `$D018` sets the pointer's bits 11-13 directly |
| VIC-IV bitmaps: VIC-II bitmap mode uses the text row machinery as on the VIC-IV, i.e. the bitmap comes from the character set pointer (16K aligned in H640, else 8K), cards are `row * LINESTEP + column`, `CHRCOUNT` cards a row, `CHRYSCL` / V400 / `DISPROWS` rows, colours from the screen pointer and colour RAM pointer. The hot registers give the VIC-II layout | done, tested in simulation (MEGA65 GEOS's 80x50 bitmap) |
| V400 text: 80x50 and 40x50 screens (`$D031` bit 3 in text modes) | done, confirmed on hardware with the MEGA65 Open ROMs. As on the VIC-IV, the text rows follow V400 only when it is set with hot registers on (`$D05D` bit 7); Space Commander sets V400 with them off and keeps 25 rows. S-BASIC 65 itself has no 50-line mode |
| VIC-IV sprites: 16-colour (`$D06B`) with 16 palette entries per sprite, 64 pixels wide (`$D057`), programmable height (`$D055/56`) (S-BASIC `FCSPRITE` commands) | done; wide and tall sprites confirmed on hardware |
| VIC-IV display geometry: border positions (`$D048-$D04B`, side border width `$D05C/5D`), text / bitmap position (`$D04C-$D04F`), text rows (`$D07B` DISPROWS), glyph row height (`$D05B` CHRYSCL), every-other-row rendering (`$D051` DBLRR), characters per row (`$D05E`) also in 8-bit text modes | done, in the MEGA65's physical pixels (800 across, two rows per raster line); the hot registers set them from the VIC-II / VIC-III ones as the MEGA65 does. Bitplanes keep the C65's fixed window. Tested in simulation; Space Commander, Little Mega People, Pascal65 and BASIC 65 look unchanged on hardware |
| VIC-IV palette banks (`$D070`: CPU-mapped, text / bitmap, sprite and alternate banks) and `$D053` BOLDISALT; BOLD + REVERSE selects the alternate palette as on the MEGA65 | done, tested in simulation |
| VIC-IV 8-bit palette: each entry keeps the whole byte and reads back as written; the MEGA65's nibble order (the colour's low four bits in the high nibble) gives 8 bits per gun. Without the MEGA65 extensions a plain C65 4-bit palette | done, tested in simulation |
| VIC-IV 16-bit text cells: nibble-colour (NCM) glyphs (colour byte 0 bit 3: 16 pixels of 4 bits), glyph width trimming (screen byte 1 bits 7-5), horizontal / vertical flips (colour byte 0 bits 6 / 7), the full 8-bit foreground colour from colour byte 1 when ATTR is off, REVERSE in full-colour / NCM cells (empty pixels show the foreground) | done, tested in simulation |
| VIC-IV alpha compositor (`$D054` bit 7): alpha-mask glyphs (colour byte 0 bit 5: the pixel values are the opacity of the foreground colour over the screen colour) and alpha sprites (`$D074` / `$D075`) | done, tested in simulation |
| VIC-IV horizontal text scaling (`$D05A` CHRXSCL, 120ths of a pixel per physical pixel) | done for 16-bit text (the raster rewrite buffer); ignored in 8-bit text and bitmap modes. Tested in simulation |
| VIC-IV sprite extensions: H640 sprites (`$D054` bit 4, X bit 9 in `$D05F`), V400 sprites (`$D076`, Y bits 8-9 in `$D077` / `$D078`), horizontal tiling (`$D04D` / `$D04F` bits 7-4), sprite bitplanes (`$D049` / `$D04B` bits 7-4) | done, tested in simulation. A V400 sprite shows every other row on a 200 line screen (each field shows its own rows) |
| Sprite pointer list address (`$D06C-$D06E`): used for all sprites, as on the MEGA65; writing `$D018`, `$D031` or the VIC bank resets it to the screen + `$3F8` (`$7F8` in 80 column and 400 line modes) while the hot registers are on. BASIC 65 keeps its 80 column sprite pointers at `$0FF8` this way | done, tested in simulation (Intro Disk #1 COMBAT) |
| VIC-IV physical raster: position (`$D052` / `$D053`, `$D050` / `$D051` for X), raster compare in physical rasters (`$D079` / `$D07A`, FNRSTCMP), PAL / NTSC readable at `$D06F` bit 7 | done |
| Other VIC-IV registers (16-colour bitplanes `$D071`, sprite Y adjust `$D072`, raster height / alpha delay `$D073`, X raster compare `$D050/51`, PALEMU / SMTH video filters, the `$D06F` video mode bits) | stored and read back, no effect |
| Real-time clock (`$FFD7110`), read only, set from the MiSTer's clock | done |
| Speed switch (65 / 64 written to address 0; S-BASIC `FAST` / `SLOW`) | done: "40 MHz" selects the core's top speed (about 30 MHz equivalent, see *CPU top speed*) |
| MEGA65 speed bits: with the MEGA65 extensions on, `$D031` FAST together with `$D054` VFAST is full speed and FAST alone is the C65's 3.5 MHz, as on a MEGA65 (BASIC 65 sets both; programs that clear VFAST to time things at 3.5 MHz, such as the Intro Disk #1 "2 BITPLANE CUBE", get 3.5 MHz) | done |
| Hypervisor mode (`$D640-$D67F` traps and register save area, 16K hypervisor RAM at `$8000-$BFFF`) running the core's own hypervisor DOS (`rtl/hyppo`, see *MEGA65 SD card* below) | done. Only the DOS trap (`$D640`) is implemented; the others fail with "not implemented" |
| ROM write protection (`$D67D` bit 2 ROMPROT, on after a reset; DOS call `$70` toggles it, as on the MEGA65): while it is off, `MAP`ped CPU writes reach `$20000-$3FFFF` | done, tested in simulation |
| SD card controller (`$D680-$D684`, sector buffer at `$FFD6E00` and mapped at `$DE00`), backed by a FAT32 image in *Mount SD Card / Data File (MEGA65)* | done |
| Hypervisor DOS calls: version, drives, setname, findfile / findfirst / findnext (`*` and `?`, long file names), opendir / readdir / closedir, chdir / cdrootdir, openfile / readfile / closefile / closeall, loadfile (and into attic RAM), mkfile / writefile / rmfile, geterrorcode, disk image attach (D81, D64, D71, D65) / detach / write enable (drives 0 and 1) | done in simulation (every call), the FAT32 result checked with Linux `fsck.vfat`; `MOUNT`, `DIR`, `LOAD`, Space Commander's 2.7 MB data file and writing files (mkfile, writefile, rmfile; checked with `fsck.vfat`) confirmed on hardware. As in the MEGA65's own DOS, mkfile makes a file of a fixed size (8.3 name) and writefile fills it, files do not grow; there are no folder creation or rename calls |
| F011 disk images on the SD card (`$D68B-$D693`): drive 0 / 1 reads and writes an attached `.D81`, `.D64`, `.D71` or `.D65` straight from the card (`MOUNT "GAME.D64"`); the image type is flagged in `$D68A` / `$D68B` as on the MEGA65, and the ROM's DOS does the 1541 / 1571 layout | D81 confirmed on hardware (drive 0). D64 and D71 tested in simulation with BASIC 65 920422 (`MOUNT`, `DIR`, `DLOAD`, `RUN`). S-BASIC 65's DOS only knows the D81 layout: a D64 mounts but `DIR` gives `74,DRIVE NOT READY` |
| A disk mounted in the OSD reads as a disk image in `$D68B` (image, present, write enabled unless read-only), as an attached image does on a MEGA65; programs that also drive a real floppy (which numbers its sides the other way) check this bit. The hypervisor sees the flags as they are | done, confirmed on hardware (the MEGA65 BBS Client loads its MEGANET module this way) |
| F011 sector buffer mapped flat at `$FFD6C00-$FFD6DFF` (the BASIC 65 DOS reads and writes sectors there) | done, confirmed on hardware with BASIC 65 920422 (`DIR`, `SAVE`, `LOAD`) |
| Writable `$20000-$3FFFF` (far pointer and DMA writes, as on the MEGA65 where this is RAM; `MAP`ped writes once ROMPROT is off) | done. A copy of the ROM is kept in the SDRAM module and put back at the next reset, so S-BASIC returns without reloading the core |
| Keyboard: matrix peek (`$D613` / `$D614`), modifier keys (`$D611`), cursor left / up (`$D60F`), and the typing queue: oldest key as ASCII (`$D610`) and PETSCII (`$D619`), its modifiers (`$D60A`), 8 keys with repeat | done, confirmed on hardware (the Open ROMs read `$D611` for SHIFT; BASIC 65 920422 types through `$D619`) |
| Four SIDs: with the MEGA65 extensions on, `$D440` (left) and `$D460` (right) are two more SIDs, sharing the waveform tables and filter with the first two (without the extensions they mirror `$D400` / `$D420`, as on a C65). The MEGA65 itself puts `$D400` / `$D420` on one side and `$D440` / `$D460` on the other; here `$D400` / `$D420` keep the C65's right / left, so the extra pair is split the other way | done, tested in simulation (each chip matches the original two-chip SID sample for sample) |
| Audio DMA (`$D711-$D75F`): four channels, 16 / 8 / 4 bit samples, looping, volume and panning, mixed with the SIDs | done, confirmed on hardware (Space Commander's music and sound effects, Little Mega People's samples). A sample can be started from the current address (`$D72A-$D72C`) as well as the base address. Samples come from the first 16 MB as on the MEGA65 (its 24-bit sample addresses cannot reach attic RAM). Audio DMA interrupts (`$D713`, offsets `$D714-$D717`: one interrupt per arming as the address nears the top) and sine mode (`$D72x` bit 4) tested in simulation |
| CPU top speed | about 30 MHz equivalent (1.25x-1.5x the previous 24 MHz, depending on the program): the CPU tells the memory its next address a clock ahead (the opcode after a data access, zero page and absolute operands, branch targets, pointers, stack pulls, return addresses), learning where each 4K block of its address space lands from its own reads, so almost every read of chip RAM, ROM and the extra chip RAM takes one clock (31.5 MHz); a wrong guess only costs the clock it would have taken anyway. Measured in simulation on Intro Disk #1 TUTTER: 2.75 clocks per instruction, was 3.48. The MEGA65's own CPU spends an extra cycle on most 2 and 3 byte instructions, so for ordinary code this is close to a 40.5 MHz MEGA65 (an estimate, not a measurement). A faster clock is not possible: the CPU and memory paths are too long |
| MEGA65 Ethernet (`$D6E0-$D6EF`, RX / TX buffers at `$FFDE800`): four RX buffers with the MEGA65's rotation, free count and interrupts, TX, MAC address, MAC / broadcast / multicast filter, an emulated PHY for the MIIM registers. The buffers are in DDR3, passed to and from the MiSTer's `eth0` by the [MiSTer NetBridge](https://github.com/jnngill/MiSTer_NetBridge) helper (see [Networking](#networking-mega65-ethernet)) | done, confirmed on hardware: DHCP, the MEGA65 BBS Client (telnet BBSes), SSH, SFTP (upload and download), IRC and NTP from the MEGA65 `net-tools.d81` |
| Frame counter (`$D7FA`, counts video frames; MEGA65 programs time their waits with it) | done |
| Read-modify-write instructions on `$D019` write the old value back before the new one, as on the MEGA65 (and the 6502), so `ASL $D019` / `INC $D019` acknowledge VIC interrupts | done, tested in simulation (Intro Disk #1 LUNAR TAXI 2 and SCORE OR DIE hung in an endless raster interrupt) |
| F011: side 0 sectors 11-20 read the second half of the track, as on the MEGA65 (fast loaders that ignore the side register) | done, tested in simulation (Intro Disk #1 DUAL SID COMPO loads its pictures) |
| MEGA65 direct POT registers (`$D620-$D627`): the paddle lines of both ports read without CIA1 PA6 / PA7, `$FF` when nothing is connected (the 1351 mouse's position on its port). BASIC 65's `JOY()` reads the second / third fire buttons there | done, tested in simulation (`JOY()` returned 768 with nothing pressed before) |
| Attic RAM: 8 MB at `$8000000`, through far pointers and DMA | done, confirmed on hardware (S-BASIC `EDMA` fill and copy back); kept in the SDRAM module, so it needs one (it does not depend on the *Expansion RAM* option) |
| Enhanced DMA jobs (`$D705`): megabyte options, list format, transparency (`$06`/`$07`, `$86`), source / destination step rates in 1/256 steps (`$82`-`$85`) (S-BASIC `EDMA`) | done, confirmed on hardware (copy, fill, transparency, source and destination step rates). Other options (line drawing, spiral mode) are ignored |
| Inline DMA jobs (`$D707`): the enhanced job list follows the `STA $D707` instruction and the CPU carries on after it | done, confirmed on hardware (Little Mega People). The list is read from bank 0 at the CPU's address, so the code must not be in a `MAP`ped block |

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
characters for the same keys) and the 3.5 / 8 / 16 MHz (now Max) OSD speeds with the
stock ROM's `FAST`.

Also confirmed on hardware by hand: real US and UK keyboards (symbols, graphics
characters, colour keys, cursor and editing keys, RUN/STOP and RESTORE, key
repeat), joysticks in both ports, the SID filter and stereo placement.

## Tested

A summary of the software run on the core. **Hardware** means it was run
on a real MiSTer. **Simulation** means it was run in the Verilator test
bench (`sim/system`) with the same RTL. The details are in the sections
linked in the table.

| Software | ROM | Where | Result |
|----------|-----|-------|--------|
| BASIC 10: typing, `RUN`, `LIST`, D81 read / write, `HEADER` | 911210 | hardware | works |
| BASIC 10 graphics (`SCREEN`, `PALETTE`, `LINE`, `BOX`, `CIRCLE`, `CHAR`), sprites | 911210 | simulation | works |
| 1280-pixel bitplane modes (programmed directly) | 911210 | hardware (HDMI) | works |
| Commodore C65 demo disk: Workbench (640x400), Deluxe Paint, REGINA | 911210 | hardware / simulation | works ([details](#the-commodore-c65-demo-disk)) |
| `IFF DEMO` slideshow (`c65Disk1`, with Expansion RAM) | 911210 | hardware | black screen as shipped; runs with a one-line patch ([details](#the-c65-disks-from-zimmersnet)) |
| zimmers.net C65 disks (23 images, 129 programs) | 911210, 920423 | simulation and hardware | no core bugs found; failures are ROM-version dependencies ([details](#the-c65-disks-from-zimmersnet)) |
| RS-232: KERNAL device 2, C65TERM with Synchronet and Particles BBS | 911210 | hardware | works (the KERNAL is accurate up to 19200 baud) |
| 4 MB expansion RAM, `DMA` copy | 911210 | hardware | works |
| `.D64` / `.G64` on the emulated 1541 (unit 10), in C65 and C64 mode | 911210 | hardware | directory, load, save |
| `GO64` (the C65's own C64 mode, not cycle exact) | 911210 | hardware | works for BASIC and simple programs ([details](#go64--go128-the-mister-c64-and-c128-cores)) |
| S-BASIC 65 commands (graphics, sprites, sound, `MOUSE`, `BACKUP`) | S-BASIC 65 V250507 | hardware / simulation | works, except relative files (an S-BASIC DOS bug) ([details](#mega65-extensions)) |
| Space Commander 1.3 | S-BASIC 65, BASIC 65 920422 | hardware | works ([details](#mega65-programs)) |
| Titan Fall, Little Mega People, MEGA-Python 0.8.0, Pascal65, `sample.d81` | BASIC 65 920422 | hardware | works |
| Xanadu demo (Syntax Party 2022) | BASIC 65 920423 | hardware | BASIC 65 edition works; the ASM edition needs an earlier MEGA65 ROM |
| MEGA65 Intro Disks 1-4 (every program) | BASIC 65 920423 | simulation; on hardware every program on all four disks | almost all work ([details](#mega65-intro-disks-1-4)) |
| MEGA65 `net-tools.d81`: BBS Client 1.4, SSH, SFTP, IRC, NTP | BASIC 65 920423 | hardware | works with the NetBridge helper ([details](#networking-mega65-ethernet)) |
| Keyboards (US, UK, DE, positional layouts), joysticks, 1351 mouse, PAL / NTSC, SID stereo and filter | all | hardware | works |
| Wolfgang Lorenz 6510 test suite 2.15 (in `GO64` mode) | 911210 | hardware | every documented-instruction test passes ([details](#lorenz-6510-test-suite)) |

Every Intro Disk program fixed during testing has now been confirmed on
hardware.

### Lorenz 6510 test suite

Run on the MiSTer in C64 mode (`GO64`, ROM 911210) with core C65_20261109b.
The suite expects an NMOS 6510, so it shows which parts of the C65 behave
like a C64 and which are 4510 differences that a real C65 shares.

- **Pass:** every load / store / logic / shift / ADC / SBC / compare / BIT /
  flag / branch / BRK / RTI / JSR / RTS / JMP test, `branchwrap`, `mmufetch`,
  `mmu`, `loadth`, `imr`, `cntdef`.  Testing found and fixed two CPU bugs:
  decimal-mode ADC/SBC flags (they followed the 65C02, not the 6502) and BRK /
  interrupts clearing the D flag.
- **Expected to fail on a real C65:**
  - `jmpi`: the 4510 doesn't have the 6502's `JMP ($xxFF)` page-wrap bug.
  - `nop*` to `sbcb(eb)`, `trap1`-`trap17`: these use the undocumented 6502
    opcodes, which the 4510 runs as 65CE02 instructions (e.g. `$1A` is
    `INC A`).
  - `cputiming`, `irq`, `nmi` and the cycle-exact CIA tests (`cia1tb123`,
    `cia*pb6/7`, `cia1tab`, `cnto2`, `icr01`, `flipos`, `oneshot`,
    `cia1ta`...`cia2tb`): even at 1 MHz the 4510 drops the 6502's dead
    cycles, so code timed for a 6510 is off by a cycle or more.
- **Unverifiable:** `cpuport` (with $00 = 0, $01 reads $FF; the test
  expects $DF from the C64's cassette motor line, which the C65 doesn't
  have).

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
| `c65_sd_image.sh` (optional, builds the MEGA65 SD card image; release, or `scripts/mister/`) | `/media/fat/Scripts/` |
| `c65_core_switch.sh` (optional, lets `GO64` / `GO128` load the MiSTer C64 / C128 cores; release, or `scripts/mister/`) | `/media/fat/Scripts/`, then run it once |
| `go.d81` (optional, `GO128` and `GO64` programs; release, or `disks/`) | `/media/fat/games/C65/` |
| [MiSTer NetBridge](https://github.com/jnngill/MiSTer_NetBridge) (optional, MEGA65 networking) | see [Networking](#networking-mega65-ethernet) |

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
ROM; runs as a plain C65), **S-BASIC 65 V250507** (a MEGA65-style ROM) and
**BASIC 65 V920422 / V920423** (the MEGA65's own ROM). See
[Tested](#tested) for what has been run with each.

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

With *MEGA65 Extensions* on, MEGA65 programs run with the MEGA65's own ROM
(BASIC 65, 920422 or 920423) and some also with S-BASIC 65. Most MEGA65
software is written for BASIC 65: S-BASIC 65 is a separate BASIC built from an
older MEGA65 ROM (920300) and stores some commands under other token numbers,
so a BASIC 65 program can stop with `?SYNTAX ERROR` under it (for example
`SLEEP`). Use BASIC 65 unless a program asks for S-BASIC 65.

Tested on hardware:

- **Space Commander** (v1.3): mount `space-commander.d81` in *Mount Drive 8*
  and `SPACE.SCP` with *Mount SD Card / Data File (MEGA65)* (or put both
  on the SD card image and `MOUNT"SPACE-COMMANDER"`: confirmed on hardware,
  the game streams SPACE.SCP from the card), then
  `LOAD"SPACE COMMANDER"` and `BANK 0:SYS 8205` (S-BASIC's `RUN` / `SYS`
  run in a bank where `$2000` is ROM, so the game's `SYS 8205` stub needs
  the `BANK 0`; typing `BANK 0` first and then `RUN` does not work, the
  game stays on a blank screen). The data file streams into attic RAM in
  about 30 seconds; title screen, gameplay, music and sound effects are
  correct. With BASIC 65 920422 as the ROM, `RUN"SPACE COMMANDER"` loads and
  starts it.
- **Titan Fall**: `LOAD"TITANFALL"` and `RUN`.
- **Little Mega People** (with BASIC 65 920422): mount `littlemegapeople.d81`,
  `LOAD"LITTLEMEGAPEOPLE"` and `RUN`. It loads its graphics and sounds from
  the disk ("MOVING IN..."); the guestbook, the house, gameplay, SID sound
  and the sampled voices and effects are correct.
- **MEGA-Python** 0.8.0 (a Python 3.15 subset, with BASIC 65 920422):
  `RUN"MEGA-PYTHON"`. With the disk in *Mount Drive 8* when the core
  starts, it boots by itself. It does not start under S-BASIC 65.
- **`sample.d81`** (plays music held in attic RAM): works with both S-BASIC 65
  and BASIC 65 920422.
- **Xanadu demo** (Syntax Party 2022, with BASIC 65 920423; the disk
  boots by itself): the BASIC 65 edition runs. The 45GS02 ASM edition hangs
  at "LOADING" with BASIC 65 920422 / 920423: it switches BASIC out by
  clearing bit 0 of the CPU port `$01`, which worked with the earlier MEGA65
  ROMs (they leave `$01` at `$FF`), but these ROMs set `$01` to `$85`, so the
  I/O area disappears with it. A MEGA65 decodes `$01` the same way, so this
  is the ROM, not the core; use an earlier MEGA65 ROM for that edition.
- **Pascal65** (with BASIC 65 920422): `DLOAD"PASCAL65"` and `RUN` (after a
  plain `LOAD` it cannot load its ASM.LIB and stops at a BRK); compiling
  and running the BUBBLES demo works. Its messages are mixed case, so if
  capitals show as graphics characters press SHIFT + C= (MEGA) to switch to
  the lower-case set. A program that loops forever (BUBBLES does) can only
  be left with the OSD's Reset: RUN/STOP + RESTORE drops into the monitor,
  which keeps breaking again.

#### MEGA65 Intro Disks 1-4

Every program on the four MEGA65 Intro Disks (`INTRO1.D81`-`INTRO4.D81`
from the Intro Disk package's `sdcard-files`) was run in simulation with
BASIC 65 920423. Put the package's `sdcard-files` on the SD card image: the
menus `MOUNT` their own disk image, and several programs read data files
from the card. Almost everything starts and looks right. Notes:

- **Need files on the SD card**: MEGAPPLE (Bad Apple) streams `BAFRAMES.BIN`
  and `BAMUSIC.BIN`; MEGAMOD, MEGAJPG and WAVPLAY look for `.MOD`, `.JPG`
  and `.WAV` files; GO64 needs `C64.D81`. Without them they show an empty
  file chooser or stall at their loading bar.
- **GEOS65**: its AUTOBOOT attaches `GEOSX.D81`, which is not in the
  package, and flashes the border when it is missing (on any machine).
- **MEGAMAZE**: its unpacker assumes `$01` = `$37`, but the 920423 KERNAL
  leaves `$85`, so it overwrites itself (as the Xanadu ASM edition does; the
  package was tested with ROM 920413).
- **TUTTER and MEGADOTS** must be started from the Intro Disk #1 menu, or
  after `POKE 1,135` (in bank 128, before any program has run `BANK 0`).
  The menu does that POKE in line 20, and their unpacker relies on it: it
  INCs `$01` to switch the I/O area to RAM, which works from `$87` but not
  from the `$85` the 920423 KERNAL leaves. Typed in straight after a boot,
  they unpack into the I/O chips and crash. That can also issue F011 sector
  writes and damage the mounted disk image, as it did once while testing,
  so use a copy of the disk to try it.
- **MEGAPPLE** plays its video in magenta and black: the program writes
  colour 11 to colour RAM and loads magenta into palette 0 entry 11, and
  the core follows the MEGA65 VHDL's palette banking, so this appears to be
  what the program asks for.
- Fixed while testing: the IFFL-loader demos (MEGAJGLR, MEGAPOLY, MEGATORN)
  and the Intro Disk #4 menu, which read the directory themselves and DMA
  the sector out of `$FFD6C00` (the F011 now always fills its buffer from
  offset 0); LUNAR TAXI 2 and SCORE OR DIE (`$D019` read-modify-write);
  DUAL SID COMPO (F011 sectors 11-20 of side 0); GEOS's bitmap screen.
- Fixed: the Intro Disk #4 menu's proportional text, which was missing
  letters, needed the MAP instruction's MB (megabyte) registers.
- Fixed: the Intro Disk #4 menu's bottom line ("press RETURN to
  CONTINUE") showed rows of junk. The menu moves TEXTYPOS (`$D04E`) further
  down part-way through the frame; on the VIC-IV the text then pauses and
  resumes with the same text row, and the core had restarted at row 0.
  Confirmed on hardware.
- Fixed (core C65_20261110b, confirmed on hardware): two white blocks at
  the left of the Intro Disk #4 menu. The menu parks its 64 pixel sprites
  past the right edge, and on the VIC-IV their rows now end there instead
  of coming out at the left edge of the next line. Also fixed: a cut-off
  copy of the bottom line just above it. The core draws text rows two
  raster lines ahead, so the lines already drawn when the menu moves
  TEXTYPOS down now show the background, as on the VIC-IV.
- Halved (core C65_20261111a, confirmed on hardware): the dotted line
  under the menu's logo. The menu switches the screen pointer in the
  middle of a text row, and because the core draws two raster lines ahead
  (the VIC-IV draws one), the old screen's next row showed for four
  physical lines. A write to a text-placement register in VIC-IV mode now
  restarts the line being drawn ahead with the new values, so only the
  two lines already drawn show it. Still different from a MEGA65: those
  two lines, and two pixel rows at the bottom edge of the grey panel
  (cause not found; it isn't this latency). Twelve RRB and raster demos
  are pixel-identical in the simulator before and after the change.
- TUTTER looks and runs correctly on hardware at the top CPU speed
  (about 30 MHz equivalent); it had shown streaks before the per-line
  text position fix and the faster CPU.
- On hardware: DUAL SID COMPO's menu and music are correct, LUNAR TAXI 2
  shows its title and landscape, SCORE OR DIE plays (it is started with
  fire on joystick 2), and RASTER65's bars and scroller run. Its bars end
  above the bottom of the screen by design: the raster loop changes the
  colours on 224 lines, from line 25 to where the bottom border starts, and
  how much of that is lit depends on where its scrolling colour table is.
- Every program on Intro Disks 2-4 (111 programs) was also run on
  hardware with core C65_20261109c, and every program on Intro Disk 1
  (56) with C65_20261110a; each starts and shows what it shows in
  simulation (or gets further: GO64 reaches C64 BASIC and LUNAR TAXI 2 its
  title screen). The ones that return to READY
  do so by design: DAYS and ZEYNEP are BASIC `PLAY` tunes, AUDIODMADEMO
  keeps playing in the background, and NERDTEST waits at its menu.

The MEGA65's own ROM (**BASIC 65**, e.g. V920422, built from the C65 ROM
910828 with the patch the MEGA65 team publishes) boots, shows the clock and
takes typing. Its DOS reads and writes `.D81` disks (`DIR`, `LOAD`, `SAVE`,
confirmed on hardware) through the MEGA65's flat view of the floppy
controller's sector buffer at `$FFD6C00`.

MEGA65 network programs run with the NetBridge helper installed (see
[Networking](#networking-mega65-ethernet)). Tested on hardware with BASIC 65
920423: the **MEGA65 BBS Client** 1.4 (`RUN"BBS"`: DHCP, then telnet BBSes),
**SSH**, **SFTP** (upload and download work; listing a directory is slow),
**IRC** and **NTP** from the MEGA65
`net-tools.d81` disk.

### GO64 / GO128: the MiSTer C64 and C128 cores

`GO64` normally switches the C65 into its own C64 mode, which is not cycle
exact. It can load the MiSTer C64 core instead, and the C128 core can be
loaded the same way. A core cannot load another core by itself, so this needs
a small helper on the MiSTer:

1. Copy `c65_core_switch.sh` to `/media/fat/Scripts` and run it once from the
   Scripts menu. It copies itself to `/media/fat/linux`, adds one line to
   `/media/fat/linux/user-startup.sh` so it starts at every boot, and starts.
   (`c65_core_switch.sh remove`, from a terminal, takes it out again.)
   The helper has to be waiting in the background while the C65 core runs,
   and the Scripts menu only runs a script when you pick it, so it starts
   from `user-startup.sh`, the MiSTer's own hook for running things at boot.
   It runs from its copy in `/media/fat/linux`, so tidying up the Scripts
   folder cannot break the boot; running it from the Scripts menu again
   updates that copy and restarts it.
2. In the C65 core's OSD set **GO64** to **Load C64 core** (and *Save
   settings*).

Then `GO64` (and holding C= at power on, which also starts C64 mode) loads the
newest `C64_*.rbf` in `_Computer`. For the C128 core, `RUN"GO128"` from
`go.d81` (or type `POKE55037,67:POKE55038,128`); `RUN"GO64"` loads the C64
core whatever the OSD option says. The other core starts fresh, with its own
settings and its own folder (`games/C64`, `games/C128`): nothing is carried
over from the C65, as with `GO64` itself. To choose a particular core, put
`C64_CORE=/media/fat/_Computer/...rbf` (or `C128_CORE=`) into
`/media/fat/linux/c65_core_switch.conf`.

How it works: the C65 core writes "C65GO" and the target into DDR memory at
`0x3FFFF800` (the C64 cold start is recognised by the CPU running `$FCE2` of
the C64 KERNAL; programs ask by writing `$43` to `$D6FD` and then `$40` or
`$80` to `$D6FE`); the helper, which only looks while the C65 core is
running, clears it and sends `load_core` to the MiSTer.

### MEGA65 SD card

MEGA65 programs reach the SD card through the hypervisor's DOS. Here the card
is an image file: a FAT32 file system, either a whole card with a partition
table (a real MEGA65 card's layout: the FAT32 partition is used, the system
partition skipped) or a bare FAT32 image. To make one on the MiSTer:

1. Put the files and folders for the card in `/media/fat/games/C65/SD`.
2. Copy `c65_sd_image.sh` (in the release, or `scripts/mister/`) to
   `/media/fat/Scripts` and run it from the Scripts menu. It writes
   `/media/fat/games/C65/mega65sd.img` (the previous one is kept as
   `mega65sd.img.bak`).
3. In the core (BASIC 65 or S-BASIC 65 with *MEGA65 Extensions* on): F12,
   *Mount SD Card / Data File (MEGA65)*, `mega65sd.img`.

Then programs find their files on the card, and BASIC 65 can put a `.D81`
from it in drive 8: `MOUNT"NAME.D81"` (or `MOUNT"NAME"`: a name without a
dot also finds `NAME.D81`), followed by `DIR`, `DLOAD` and so on. The image
must be in one piece on the card, which it always is in a freshly made image.
An attached disk stays in the drive through a reset; mounting a disk in the
OSD (or another SD card image) replaces it.

Programs, and BASIC 65 saving to an attached `.D81`, write into the image,
not into the files in the `SD` folder: running the script again replaces
those changes, so copy anything you want to keep out of the image first (on
the MiSTer: `mount -o loop` it, as the script does).

### Networking (MEGA65 Ethernet)

MEGA65 network programs (the BBS client, SSH, IRC, FTP, Gopher ... on the
MEGA65 `net-tools.d81` disk) work on this core and reach your network and the
internet. It takes a one-time setup on the MiSTer.

**Why there is a setup step.** On the DE10-Nano the network port is wired to
the board's ARM processor (the MiSTer's Linux side), not to the FPGA where the
core runs. So the core cannot reach the network by itself: a small helper
program on the MiSTer, [MiSTer NetBridge](https://github.com/jnngill/MiSTer_NetBridge), passes the C65's
network traffic to and from the network port. The same helper serves other
cores with network hardware (the z486's NE2000, for example). Once turned on
it starts by itself at every boot, so you do this only once.

**You need:**

- The MiSTer connected to your network **with a cable**. Wi-Fi does not work
  for this (a Wi-Fi access point drops traffic from a second machine behind
  the MiSTer).
- *MEGA65 Extensions* set to *On* in the OSD, and a MEGA65 ROM
  (BASIC 65, e.g. 920423) as the system ROM.

**Setup (once):**

1. Install NetBridge. Either add these two lines to the bottom of
   `/media/fat/downloader.ini` and run update_all (or `downloader`), which
   also keeps it up to date:

       [mister_netbridge]
       db_url = https://raw.githubusercontent.com/jnngill/MiSTer_NetBridge/main/db.json

   or copy the files by hand as its README describes.
2. On the MiSTer, open the Scripts menu (F12, then *Scripts*) and run
   `netbridge`. It says *NetBridge is now ON.*

That is all: it is now running, and it starts again at every boot. (It adds
one line to `/media/fat/linux/user-startup.sh`; anything already in that file
is left as it is.) Nothing needs setting up on your router or in the MiSTer's
network settings. If you used this core's earlier helper, `c65_net`, turning
NetBridge on stops it and takes its line out of `user-startup.sh`.

**Using it:** start the C65 core, mount the program's disk and run it, e.g.
`RUN"BBS"` from `net-tools.d81`. The program gets an address from your
router by DHCP the same way a real MEGA65 does; your router lists it as a new
device with the MAC address `02:47:53:65:65:65` (the MEGA65's). In the network
programs, **Esc** is ESC (what BBSes ask for, e.g. in a "press ESC" check)
and **Win+Esc** is RUN/STOP (the BBS client's way back to its menu).

**If it does not work:**

- The program stays at "starting the network" or finds no address: run
  `/media/fat/Scripts/netbridge.sh status` in a terminal on the MiSTer (over
  ssh, for example). It says whether the bridge is on and running and whether
  the cable has a link; `/tmp/netbridge.log` says when a core attached.
- The MiSTer is on Wi-Fi: this needs the cable.
- Your MiSTer uses a wired port other than `eth0`: put `NET_IF=eth1` (the
  port's name) into `/media/fat/Scripts/.config/netbridge/netbridge.conf` and
  run `netbridge` from the Scripts menu twice (off, then on).

**Good to know:**

- The C65 is a separate machine on your network with its own address. Other
  computers on your network and the internet can reach it, but the MiSTer's
  own Linux cannot (traffic the MiSTer sends out of its network port does
  not come back in to it).
- The helper does nothing while another core is loaded: it serves the shared
  memory only while the C65's Ethernet controller keeps signalling that it is
  there. While it runs, the MiSTer's network port also listens for the C65's
  traffic (promiscuous mode); the MiSTer's own networking is not affected.
- To turn it off, run `netbridge` from the Scripts menu again.

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
| Mount SD Card / Data File (MEGA65) | an `.IMG` (FAT32 card image), or a single `.SCP`, `.BIN` or `.DAT` file | the MEGA65's SD card (see *MEGA65 SD card*); a single file answers to every name, for programs that only open one (e.g. Space Commander's `SPACE.SCP`) |
| Load System ROM | a `.rom` / `.bin` file | replaces the ROM loaded from `boot.rom` and resets |
| Load Program | a `.prg` file | copies the program into memory, see [Loading .PRG and .D64 files](#loading-prg-and-d64-files) |
| Load 1541 ROM | a `.rom` / `.bin` file | the 1541's DOS ROM, if it is not in `boot1.rom` |
| Video Standard | PAL, NTSC | |
| Aspect Ratio, Stereo Mix | | standard MiSTer settings |
| Scandoubler Fx | None, CRT 25%, CRT 50%, CRT 75% | scanlines for analogue output with the scandoubler. The HQ2x filter is not included: it took about 58 of the FPGA's memory blocks, which now hold the 32K colour RAM and the G64 track buffer |
| Keyboard Layout | US, UK, DE, Positional | see below |
| CPU Speed | 3.5 MHz, 8 MHz, Max (~30 MHz) | speed of the C65 FAST mode with *MEGA65 Extensions* off; 3.5 MHz is a real C65. With the extensions on the MEGA65's own speed bits decide, as on a MEGA65: FAST alone is 3.5 MHz, full speed comes from `$D054` VFAST or `POKE 0,65` (BASIC 65 and S-BASIC 65 ask for it themselves; S-BASIC's `SLOW` / `FAST` change it) |
| Expansion RAM | 4MB, Off | the C65 RAM expansion, kept in the MiSTer SDRAM module; without a module the machine reports no expansion |
| Mouse | Port 2, Port 1, Off | a Commodore 1351 on that control port. S-BASIC 65's `MOUSE ON` uses port 2; on the stock ROM name the port, e.g. `MOUSE ON,2` |
| Swap Joysticks | No, Yes | No: the first MiSTer controller is control port 2 and the second is port 1 (as in the C64 core). Yes: the other way round, for games that read port 1 (such as Break-A-Tile on the MEGA65 Intro Disk #1) |
| DMA Revision | F018B, F018A, F018 (9-byte lists) | F018B for ROMs from mid 1991 on, F018A for older ones. F018 (9-byte lists): chained DMA lists follow each other every 9 bytes (no modulo bytes), as Commodore's spring 1991 demo disks expect; use it only with a ROM of that time (such as 910429), since later ROMs need F018B |
| MEGA65 Extensions | Off, On | Off: a plain C65. On: the MEGA65 subset that S-BASIC 65 needs (see [MEGA65 extensions](#mega65-extensions)). Changing it restarts the machine |
| GO64 | C64 mode, Load C64 core | Load C64 core: `GO64` loads the MiSTer C64 core (needs the `c65_core_switch.sh` helper, see [GO64 / GO128](#go64--go128-the-mister-c64-and-c128-cores)) |
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
| Esc | ESC |
| Win+Esc | RUN/STOP (C= is not pressed) |
| F11 | RESTORE |
| F1 F3 F5 F7 / F2 F4 F6 F8 | F1 F3 F5 F7 / shifted |
| F9, F10, F12 | F9, F11, F13 |
| End | ESC (as Esc) |
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

The MEGA65 hypervisor program (`rtl/hyppo`, C and assembler for cc65) is
built into the FPGA from `rtl/hyppo/hyppo.hex`. After changing it, run
`bash rtl/hyppo/build.sh` (needs cc65) before compiling.

## Simulation

Needs Verilator (the OSS CAD Suite build works) and `zig c++` as the C++
compiler; paths are set at the top of the scripts.

    bash sim/cpu_fuzz/run.sh            # CPU vs. reference model, random code
    bash sim/cpu_fuzz/run.sh 20 200000 gs   # same with the 45GS02 prefixes
    bash sim/system/build.sh            # whole machine
    sim/system/build/tb.exe roms/911210.bin sim/out 150
    sim/system/build/tb.exe roms/911210.bin sim/out 560 \
        -keys sim/system/keys_disk.txt -d81 blank.d81

`-eth frames.txt` adds DDR3 and a stand-in for the NetBridge helper: it gives the core
the frames in the file (one per line, in hex), writes the core's frames to
`eth_tx.txt` in the output folder, and answers ARP requests.

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
    rtl/m65_eth.sv        MEGA65 Ethernet controller (buffers in DDR3)
    scripts/mister/       helpers that run on the MiSTer
    rtl/sdram.v           SDRAM controller (expansion RAM), from the MiSTer C64 core
    rtl/c65_keyboard.sv   generated by scripts/gen_keyboard.py
    rtl/mos6526_8520.v, rtl/sid/, rtl/pll*, sys/   from MiSTer C64/C128 cores

## License

This core is GPL-3.0-or-later, see [LICENSE](LICENSE). That covers everything
written for this project, including the hypervisor DOS (`rtl/hyppo`), the
terminal (`term/`), the scripts and the simulation test benches.

Files taken from other projects keep their authors' copyright and licence
headers, and are used under those licences:

| Files | From | Authors | Licence |
|---|---|---|---|
| `sys/` | the MiSTer framework ([Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer)) | Alexey Melnikov (Sorgelig), Till Harbaum and others, see each file | GPL (version per file header) |
| `rtl/sid/sid_filter.sv`, `rtl/sid/sid_dac.sv` | the MiSTer C64 core, based on reDIP-SID | Alexey Melnikov, Dag Lem | CERN-OHL-S-2.0 |
| the rest of `rtl/sid/` | the MiSTer C64 core | Alexey Melnikov and the MiSTer C64 core contributors | no licence header in the files; used as distributed with the MiSTer C64 core. Changed here: four chips (`QUAD`) |
| `rtl/mos6526_8520.v` | the MiSTer C64 / C128 cores | Rayne, slingshot, Sorgelig, Erik Scheffers | no licence header in the file; used as distributed with the MiSTer C64 core |
| `rtl/iec_drive/` (1541) | the MiSTer C64 core | Sorgelig, Dar, Mark McDougall, Gideon Zweijtzer | GPL (`c1541_track.sv`), GPL-3.0 (`iecdrv_via6522.vhd`); the others have no licence header and are used as distributed with the MiSTer C64 core |
| `rtl/t65/` (the 1541's 6502) | T65 | Daniel Wallner, Mike Johnson, Wolfgang Scherr and others | BSD-style, see the file headers |
| `rtl/c1351.v` | the MiSTer C64 core | Sorgelig | GPL-2.0-or-later |
| `rtl/sdram.v` | MiSTer cores | Till Harbaum | GPL-3.0-or-later |
| `rtl/pll*` | generated by Quartus (Altera PLL megafunction) | | |
| `rtl/cpu/cpu4510_tables.svh`, `sim/ref/tables4510.py` (the 4510 opcode map) | generated from `gs4510.vhdl` of [MEGA65/mega65-core](https://github.com/MEGA65/mega65-core) | the MEGA65 team (Paul Gardner-Stephen and others) | LGPL-3.0-or-later |

### MEGA65 reference

The MEGA65 features (VIC-IV, four SIDs, audio DMA, the SD card controller,
the hypervisor and its DOS, the F011 disk images, the math unit, enhanced
DMA, Ethernet) are this project's own code. They were written from the MEGA65's
open-source FPGA design, [MEGA65/mega65-core](https://github.com/MEGA65/mega65-core)
(VHDL under LGPL-3.0-or-later): `viciv.vhdl`, `sprite.vhdl`, `bitplane(s).vhdl`,
`multisid.vhdl`, `audio_mixer.vhdl`, `gs4510.vhdl`, `sdcardio.vhdl`,
`ethernet.vhdl` and `iomapper.vhdl` were the reference for register layouts and behaviour, and
the hypervisor DOS uses the function numbers, register conventions, error
codes and directory entry layout of `src/hyppo/dos.asm`. Apart from the
generated opcode map above, no MEGA65 source code is included.

### ROMs and software

No ROMs are included or distributed: the C65 and MEGA65 system ROMs (including
S-BASIC 65 and BASIC 65) and the 1541 DOS ROM are copyrighted, and you supply
your own. MEGA65 programs mentioned here (Space Commander, Little Mega People
and others) belong to their authors and are not included. The disk images in
`disks/`, `games/` and `term/` contain only programs written for this
project.

## Credits

CIA, SID, the 1541, the mouse, PLL and the `sys/` framework come from the
MiSTer C64 / C128 cores and the MiSTer framework (Alexey Melnikov and the
MiSTer contributors). The MEGA65 features follow the MEGA65 project's
mega65-core, and the 4510 opcode table is derived from its `gs4510.vhdl`.
