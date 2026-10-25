; C65TERM low-level routines: bitplane text screen, DMA, serial port.
;
; The terminal screen is a 4-bitplane (16 colour) picture, so every cell has
; its own foreground and background colour:
;   80 columns: 640x200 (H640), 40 columns: 320x200
;   plane 0 $08000, plane 2 $0C000 (bank 0; even planes must be in bank 0)
;   plane 1 $14000, plane 3 $18000 (bank 1; $10000-$11FFF is the DOS's RAM)
; Planes are laid out like a VIC-II bitmap: 8 bytes per character cell, so
; one cell is 8 consecutive bytes in each plane at (row * cols + col) * 8.
;
; Bank 1 also holds the fonts ($1C000: 256 glyphs x 8 bytes per font, three
; fonts) and the screen shadow (glyphs at $1D800, colours at $1E000).
;
; The serial port receives into a 1K ring at $0800 (the unused text screen)
; from its interrupt; the KERNAL's IRQ keeps running after it.

        .setcpu "45GS02"

        .export _g_col, _g_row, _g_ch, _g_fg, _g_bg, _g_font, _g_cols
        .export _hw_draw, _hw_scroll, _hw_clear_rows, _hw_video_on, _hw_video_off
        .export _hw_set_palette, _hw_shadow_put, _hw_shadow_get, _g_attr
        .export _far_get, _far_put, _g_far
        .export _ser_init, _ser_off, _ser_get, _ser_put, _ser_avail, _ser_baud
        .export _hw_fill_far, _hw_copy_far
        .export _g_top, _g_bot, _g_dir, _g_lines, _setbnk0

PLANE0  = $08000
PLANE1  = $14000
PLANE2  = $0C000
PLANE3  = $18000
FONTS   = $1C000
SHADOWC = $1D800        ; 80 x 25 glyphs
SHADOWA = $1E000        ; 80 x 25 colour bytes
RING    = $0800

        .zeropage
fp:     .res 4          ; far pointer for [fp],z
gp:     .res 4          ; far pointer to the glyph

        .bss
_g_col:   .res 1        ; cell to draw
_g_row:   .res 1
_g_ch:    .res 1        ; glyph number
_g_fg:    .res 1        ; colours 0-15
_g_bg:    .res 1
_g_attr:  .res 1        ; bit 0 underline (drawn as the last glyph row)
_g_font:  .res 1        ; 0, 1, 2: which font in bank 1
_g_cols:  .res 1        ; 40 or 80
_g_top:   .res 1        ; scroll region (rows, inclusive)
_g_bot:   .res 1
_g_dir:   .res 1        ; 0 up, 1 down
_g_lines: .res 1
_g_far:   .res 4        ; far address argument
glyph:    .res 8
offs:     .res 2        ; cell offset in bytes
rxhead:   .res 2        ; written by the interrupt
rxtail:   .res 2
oldirq:   .res 2
saved031: .res 1
saved032: .res 1
saved020: .res 1
saved021: .res 1
saved030: .res 1
saved07c: .res 1
dmalist:  .res 12

        .code

; offs = (g_row * g_cols + g_col) * 8
calc_offs:
        lda _g_row
        ldx _g_cols
        cpx #80
        beq @w80
        ; *40 = *32 + *8
        sta offs
        lda #0
        sta offs+1
        jsr shl3                ; row*8
        lda offs
        pha
        lda offs+1
        pha
        jsr shl2                ; row*32
        pla
        tay
        pla
        clc
        adc offs
        sta offs
        tya
        adc offs+1
        sta offs+1
        jmp @addc
@w80:   sta offs
        lda #0
        sta offs+1
        jsr shl4                ; row*16
        lda offs
        pha
        lda offs+1
        pha
        jsr shl2                ; row*64
        pla
        tay
        pla
        clc
        adc offs
        sta offs
        tya
        adc offs+1
        sta offs+1
@addc:  lda _g_col
        clc
        adc offs
        sta offs
        bcc :+
        inc offs+1
:       jmp shl3
shl4:   asl offs
        rol offs+1
shl3:   asl offs
        rol offs+1
shl2:   asl offs
        rol offs+1
        asl offs
        rol offs+1
        rts

; fp = plane base (A = plane 0-3) + offs
plane_ptr:
        asl
        asl
        tax
        lda offs
        clc
        adc pbase,x
        sta fp
        lda offs+1
        adc pbase+1,x
        sta fp+1
        lda pbase+2,x
        adc #0
        sta fp+2
        lda #0
        sta fp+3
        rts
pbase:  .dword PLANE0, PLANE1, PLANE2, PLANE3

; Draw one cell: glyph g_ch of font g_font in colours g_fg on g_bg.
_hw_draw:
        jsr calc_offs
        ; glyph address: FONTS + font*2048 + ch*8
        lda _g_ch
        sta gp
        lda #0
        sta gp+1
        ldx #3
:       asl gp
        rol gp+1
        dex
        bne :-
        lda _g_font
        asl
        asl
        asl
        clc
        adc gp+1
        adc #>FONTS
        sta gp+1
        lda #^FONTS
        adc #0
        sta gp+2
        lda #0
        sta gp+3
        ldz #7
:       lda [gp],z
        tay
        tza
        tax
        tya
        sta glyph,x
        dez
        bpl :-
        lda _g_attr
        lsr
        bcc :+
        lda #$ff
        sta glyph+7
:       ; four planes
        lda #0
@pl:    pha
        jsr plane_ptr
        pla
        pha
        tax
        lda bitmask,x
        sta tmpmask
        ldz #0
        ldx #0
@by:    lda glyph,x
        tay
        lda #0
        sta tmpb
        lda _g_fg
        and tmpmask
        beq :+
        tya
        sta tmpb
:       lda _g_bg
        and tmpmask
        beq :+
        tya
        eor #$ff
        ora tmpb
        sta tmpb
:       lda tmpb
        sta [fp],z
        inz
        inx
        cpx #8
        bne @by
        pla
        clc
        adc #1
        cmp #4
        bne @pl
        ldz #0
        rts
bitmask: .byte 1, 2, 4, 8

        .bss
tmpmask: .res 1
tmpb:    .res 1
        .code

; DMA helpers.  The list is F018B: cmd, count(2), src(3), dst(3), subcmd,
; modulo(2).  Started through $D700 (works with and without MEGA65 mode).
run_dma:
        ; Long jobs are split into 512 byte pieces: the CPU (and so the
        ; serial interrupt) is stopped while the DMA runs, and the serial
        ; port holds one byte, so at 9600 baud one job must not take longer
        ; than about a millisecond.
        lda #0
        sta dmalist+9
        sta dmalist+10
        sta dmalist+11
        lda dmalist+1
        sta dmarest
        lda dmalist+2
        sta dmarest+1
@piece: lda dmarest+1
        cmp #2
        bcc @last               ; < 512 left
        lda #0
        sta dmalist+1
        lda #2
        sta dmalist+2
        jsr dma_go
        ; advance: destination always, source for copies; down for
        ; decrementing jobs (command bits 4 / 5)
        lda dmalist
        and #3
        cmp #3
        beq @dst                ; fill: the source is the fill byte
        lda dmalist
        and #$10
        bne @sdn
        inc dmalist+4
        inc dmalist+4
        bne @dst
        inc dmalist+5
        jmp @dst
@sdn:   lda dmalist+4
        sec
        sbc #2
        sta dmalist+4
        bcs @dst
        dec dmalist+5
@dst:   lda dmalist
        and #$20
        bne @ddn
        inc dmalist+7
        inc dmalist+7
        bne @next
        inc dmalist+8
        jmp @next
@ddn:   lda dmalist+7
        sec
        sbc #2
        sta dmalist+7
        bcs @next
        dec dmalist+8
@next:  lda dmarest+1
        sec
        sbc #2
        sta dmarest+1
        ora dmarest
        bne @piece
        rts
@last:  lda dmarest
        ora dmarest+1
        beq @done
        lda dmarest
        sta dmalist+1
        lda dmarest+1
        sta dmalist+2
        jmp dma_go
@done:  rts

dma_go:
        lda #0
        sta $d702
        lda #>dmalist
        sta $d701
        lda #<dmalist
        sta $d700               ; starts the job; the CPU waits until it is done
        rts

        .bss
dmarest: .res 2
        .code

; The screen is six "layers" scrolled and cleared the same way: the four
; bitplanes (cols*8 bytes per row) and the shadow's glyph and colour arrays
; (80 bytes per row).  For layer curplane: rbase = start, stride = bytes per
; row, fillb = the byte a cleared row holds.
layer_setup:
        lda curplane
        cmp #4
        bcs @shadow
        asl
        asl
        tax
        lda pbase,x
        sta rbase
        lda pbase+1,x
        sta rbase+1
        lda pbase+2,x
        sta rbase+2
        lda _g_cols
        sta stride
        lda #0
        sta stride+1
        ldx #3
:       asl stride
        rol stride+1
        dex
        bne :-
        ldy curplane
        lda bitmask,y
        and _g_bg
        beq :+
        lda #$ff
:       sta fillb
        rts
@shadow:
        ldx #<SHADOWC
        ldy #>SHADOWC
        lda #' '
        sta fillb
        lda curplane
        cmp #4
        beq :+
        ldx #<SHADOWA
        ldy #>SHADOWA
        lda _g_bg
        asl
        asl
        asl
        asl
        ora _g_fg
        sta fillb
:       stx rbase
        sty rbase+1
        lda #^SHADOWC
        sta rbase+2
        lda #80
        sta stride
        lda #0
        sta stride+1
        rts

; result = A * stride (A < 64)
mul_stride:
        asl
        asl
        sta mtmp                ; bit 5 of the row now in bit 7
        lda #0
        sta result
        sta result+1
        ldx #6
@m:     asl result
        rol result+1
        asl mtmp
        bcc :+
        lda result
        clc
        adc stride
        sta result
        lda result+1
        adc stride+1
        sta result+1
:       dex
        bne @m
        rts

; addr3 = rbase + A16 (in result)
add_base:
        lda rbase
        clc
        adc result
        sta addr3
        lda rbase+1
        adc result+1
        sta addr3+1
        lda rbase+2
        adc #0
        sta addr3+2
        rts

; fill count bytes at addr3 with fillb
fill_at:
        lda #3
        sta dmalist
        lda fillb
        sta dmalist+3
        lda #0
        sta dmalist+4
        sta dmalist+5
        lda addr3
        sta dmalist+6
        lda addr3+1
        sta dmalist+7
        lda addr3+2
        sta dmalist+8
        lda cnt
        sta dmalist+1
        lda cnt+1
        sta dmalist+2
        jmp run_dma

; Scroll rows g_top..g_bot (inclusive) by g_lines rows, up (g_dir = 0) or
; down (1); the rows that come free are cleared to colour g_bg (and the
; shadow to spaces in g_fg on g_bg).
_hw_scroll:
        lda #0
@lay:   sta curplane
        jsr layer_setup
        lda _g_lines
        jsr mul_stride
        lda result
        sta shift
        lda result+1
        sta shift+1
        lda _g_bot
        sec
        sbc _g_top
        clc
        adc #1
        sec
        sbc _g_lines            ; rows that move
        beq @nomove
        bcs :+
@nomove:
        jmp @fill
:       jsr mul_stride
        lda result
        sta cnt
        lda result+1
        sta cnt+1
        lda _g_dir
        bne @down
        ; up: from (top+lines) to top, ascending
        lda _g_top
        clc
        adc _g_lines
        jsr mul_stride
        jsr add_base
        lda addr3
        sta dmalist+3
        lda addr3+1
        sta dmalist+4
        lda addr3+2
        sta dmalist+5
        lda _g_top
        jsr mul_stride
        jsr add_base
        lda #0
        jmp @go
@down:  ; down: from the end of the moving block backwards
        lda _g_bot
        sec
        sbc _g_lines
        clc
        adc #1
        jsr mul_stride          ; end of the moving block (exclusive)
        jsr add_base
        jsr dec_addr3
        lda addr3
        sta dmalist+3
        lda addr3+1
        sta dmalist+4
        lda addr3+2
        sta dmalist+5
        lda _g_bot
        clc
        adc #1
        jsr mul_stride
        jsr add_base
        jsr dec_addr3
        lda #$30                ; copy, both addresses decrementing
@go:    sta dmalist
        lda addr3
        sta dmalist+6
        lda addr3+1
        sta dmalist+7
        lda addr3+2
        sta dmalist+8
        lda cnt
        sta dmalist+1
        lda cnt+1
        sta dmalist+2
        jsr run_dma
@fill:  ; the freed rows: up -> the last lines rows, down -> the first
        lda shift
        sta cnt
        lda shift+1
        sta cnt+1
        lda _g_dir
        bne @ftop
        lda _g_bot
        sec
        sbc _g_lines
        clc
        adc #1
        jmp @fset
@ftop:  lda _g_top
@fset:  jsr mul_stride
        jsr add_base
        jsr fill_at
        lda curplane
        clc
        adc #1
        cmp #6
        beq :+
        jmp @lay
:       rts

dec_addr3:
        lda addr3
        bne :+
        lda addr3+1
        bne @h
        dec addr3+2
@h:     dec addr3+1
:       dec addr3
        rts

; Clear g_lines rows from g_top: colour g_bg, shadow spaces in g_fg on g_bg.
_hw_clear_rows:
        lda #0
@lay:   sta curplane
        jsr layer_setup
        lda _g_lines
        jsr mul_stride
        lda result
        sta cnt
        lda result+1
        sta cnt+1
        lda _g_top
        jsr mul_stride
        jsr add_base
        jsr fill_at
        lda curplane
        clc
        adc #1
        cmp #6
        bne @lay
        rts

        .bss
curplane: .res 1
stride:   .res 2
rbase:    .res 3
fillb:    .res 1
mtmp:     .res 1
result:   .res 2
addr3:    .res 3
shift:    .res 2
cnt:      .res 2
        .code

; Bitplane mode on: g_cols = 40 or 80.  The previous video registers are
; kept for hw_video_off.
_hw_video_on:
        lda $d031
        sta saved031
        lda $d032
        sta saved032
        lda $d020
        sta saved020
        lda $d021
        sta saved021
        lda $d030
        sta saved030
        lda $d07c
        sta saved07c
        and #$f8                ; VIC-IV bitplane bank (MEGA65 ROMs set it): 0
        sta $d07c
        lda #0
        sta $d020
        sta $d021
        sta $d03b               ; no plane inverted
        sta $d03c
        sta $d03d
        lda #$0f
        sta $d032               ; planes 0-3
        ; plane addresses: bits 3:1 = 8K block (320 wide), 3:2 = 16K block
        ; (640 wide); the same values work for both here
        lda #$08                ; plane 0 $08000
        sta $d033
        lda #$04                ; plane 1 $14000 (bank 1, odd plane)
        sta $d034
        lda #$0c                ; plane 2 $0C000
        sta $d035
        lda #$08                ; plane 3 $18000
        sta $d036
        lda _g_cols
        cmp #80
        bne @w40
        lda saved031
        and #$40                ; keep FAST
        ora #$90                ; H640 + bitplanes
        sta $d031
        jmp @pal
@w40:   lda saved031
        and #$40
        ora #$10
        sta $d031
@pal:   lda $d030
        ora #$04                ; palette RAM
        sta $d030
        rts

_hw_video_off:
        lda saved032
        sta $d032
        lda saved031
        sta $d031
        lda saved020
        sta $d020
        lda saved021
        sta $d021
        lda saved030
        sta $d030
        lda saved07c
        sta $d07c
        rts

; palette entries 0-15 from the 48 bytes at A/X (r0 g0 b0 r1 ...), 4 bits each
_hw_set_palette:
        sta gp
        stx gp+1
        ldx #0
        ldy #0
:       lda (gp),y
        sta $d100,x
        iny
        lda (gp),y
        sta $d200,x
        iny
        lda (gp),y
        sta $d300,x
        iny
        inx
        cpx #16
        bne :-
        rts

; shadow cell (g_row, g_col): glyph at SHADOWC + row*80 + col, colours
; (fg | bg << 4) at SHADOWA + the same offset
shadow_ptr:
        lda _g_row
        sta offs
        lda #0
        sta offs+1
        jsr shl4                ; *16
        lda offs
        pha
        lda offs+1
        pha
        jsr shl2                ; *64
        pla
        tay
        pla
        clc
        adc offs
        sta offs
        tya
        adc offs+1
        sta offs+1              ; row*80
        lda _g_col
        clc
        adc offs
        sta offs
        bcc :+
        inc offs+1
:       lda offs
        clc
        adc #<SHADOWC
        sta fp
        sta gp
        lda offs+1
        adc #>SHADOWC
        sta fp+1
        clc
        adc #>(SHADOWA-SHADOWC)
        sta gp+1
        lda #^SHADOWC
        sta fp+2
        sta gp+2
        lda #0
        sta fp+3
        sta gp+3
        rts

; store g_ch and the colour byte A at (g_row, g_col)
_hw_shadow_put:
        pha
        jsr shadow_ptr
        ldz #0
        lda _g_ch
        sta [fp],z
        pla
        sta [gp],z
        rts

; g_ch = glyph at (g_row, g_col); returns its colour byte
_hw_shadow_get:
        jsr shadow_ptr
        ldz #0
        lda [fp],z
        sta _g_ch
        lda [gp],z
        ldx #0
        rts

; byte at flat address g_far
_far_get:
        ldx #3
:       lda _g_far,x
        sta fp,x
        dex
        bpl :-
        ldz #0
        lda [fp],z
        ldx #0
        rts

; store A at flat address g_far
_far_put:
        pha
        ldx #3
:       lda _g_far,x
        sta fp,x
        dex
        bpl :-
        pla
        ldz #0
        sta [fp],z
        rts

; fill: count A/X bytes at flat g_far with g_ch
_hw_fill_far:
        sta dmalist+1
        stx dmalist+2
        lda #3
        sta dmalist
        lda _g_ch
        sta dmalist+3
        lda #0
        sta dmalist+4
        sta dmalist+5
        lda _g_far
        sta dmalist+6
        lda _g_far+1
        sta dmalist+7
        lda _g_far+2
        sta dmalist+8
        jmp run_dma

; copy A/X bytes from flat address in tmpsrc (set via g_far first) ...
; here: from g_far to the 3-byte address g_far+... kept simple: src = g_far,
; dst = copydst
        .export _g_copydst
        .bss
_g_copydst: .res 4
        .code
_hw_copy_far:
        sta dmalist+1
        stx dmalist+2
        lda #0
        sta dmalist
        lda _g_far
        sta dmalist+3
        lda _g_far+1
        sta dmalist+4
        lda _g_far+2
        sta dmalist+5
        lda _g_copydst
        sta dmalist+6
        lda _g_copydst+1
        sta dmalist+7
        lda _g_copydst+2
        sta dmalist+8
        jmp run_dma

; KERNAL SETBNK: file names and data in bank 0 (the C65 KERNAL reads the
; name given to SETNAM from the bank set here)
_setbnk0:
        lda #0
        ldx #0
        jmp $ff6b

; ---------------------------------------------------------------- serial port
; ser_baud(divisor): $D603/$D604; baud = 7.09 MHz / 16 / (divisor + 1)
_ser_baud:
        sta $d603
        stx $d604
        rts

_ser_init:
        sei
        lda #0
        sta rxhead
        sta rxhead+1
        sta rxtail
        sta rxtail+1
        lda #$c0                ; send and receive on, 8 data bits, no parity
        sta $d602
        sta $d601               ; clear the status flags
        lda $d600
        lda $0314
        sta oldirq
        lda $0315
        sta oldirq+1
        lda #<serirq
        sta $0314
        lda #>serirq
        sta $0315
        lda #$40                ; interrupt on a received byte
        sta $d605
        cli
        rts

_ser_off:
        sei
        lda #0
        sta $d605
        lda oldirq
        sta $0314
        lda oldirq+1
        sta $0315
        cli
        rts

; KERNAL IRQ hook: take every waiting byte, then carry on with the KERNAL.
serirq:
        lda $d601
        lsr
        bcc @done
        lda $d600
        ldx rxhead+1
        beq @lo
        cpx #1
        beq @p1
        cpx #2
        beq @p2
        ldx rxhead
        sta RING+$300,x
        jmp @adv
@lo:    ldx rxhead
        sta RING,x
        jmp @adv
@p1:    ldx rxhead
        sta RING+$100,x
        jmp @adv
@p2:    ldx rxhead
        sta RING+$200,x
@adv:   inc rxhead
        bne serirq
        lda rxhead+1
        clc
        adc #1
        and #3
        sta rxhead+1
        jmp serirq
@done:  jmp (oldirq)

; bytes waiting (0-1023)
_ser_avail:
        sei
        lda rxhead
        sec
        sbc rxtail
        tay
        lda rxhead+1
        sbc rxtail+1
        and #3
        tax
        tya
        cli
        rts

; next byte, or -1 ($FFFF) when the ring is empty
_ser_get:
        sei
        lda rxtail
        cmp rxhead
        bne @have
        lda rxtail+1
        cmp rxhead+1
        bne @have
        cli
        lda #$ff
        tax
        rts
@have:  cli
        lda rxtail
        sta fp
        lda rxtail+1
        clc
        adc #>RING
        sta fp+1
        ldy #0
        lda (fp),y
        pha
        inc rxtail
        bne :+
        lda rxtail+1
        clc
        adc #1
        and #3
        sta rxtail+1
:       pla
        ldx #0
        rts

; send A (waits until the sender can take it)
_ser_put:
        tay
:       lda $d601
        and #$40
        beq :-
        sty $d600
        rts
