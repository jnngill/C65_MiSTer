; Hypervisor DOS write test (sim/hyptest): run like hyptest.prg, with the
; test image sim/out/sd/sd.img as the SD card.  Log at $7800 (A X Y P per
; call), the read-back sector's first 16 bytes after the "readfile" record.
;   mkfile NEWFILE.TXT (1000 bytes), write two sectors ("W" x 512, "X" x 512),
;   read the first sector back, delete "A LONG FILE NAME.TXT", check it is
;   gone, chdir GAMES, attach "pascal65" (no extension) on drive 0, and
;   catch.d81 is not there, so attach "pascal65.d81" on drive 1 again (a
;   double attach error), then cdroot.

        .setcpu "4510"
        .segment "LOADADDR"
        .word $2001
        .segment "STUB"
        .byte $0F, $20, $EA, $07, $FE, $02, $30, $3A, $9E, $38, $32, $31, $30, $00, $00, $00, $00

        .segment "CODE"
logp    = $FB

.macro  trap fn
        lda #fn
        sta $D640
        nop
        jsr log
.endmacro

.macro  setname str
        .local nm, cp, en
        ldx #0
cp:     lda nm,x
        sta $7E00,x
        beq en
        inx
        bra cp
nm:     .asciiz str
en:     ldy #$7E
        trap $2E
.endmacro

; fill the SD sector buffer ($FFD6E00) with A
.macro  fillbuf
        .local lp, lp2
        sta fillv
        lda #$00
        sta $F0
        lda #$6E
        sta $F1
        lda #$FD
        sta $F2
        lda #$0F
        sta $F3
        ldz #0
lp:     lda fillv
        .byte $EA
        sta ($F0),z
        inz
        bne lp
        inc $F1
        ldz #0
lp2:    lda fillv
        .byte $EA
        sta ($F0),z
        inz
        bne lp2
        ldz #0
.endmacro

start:  sei
        lda #$00
        sta logp
        lda #$78
        sta logp+1

        setname "NEWFILE.TXT"
        ldx #<1000
        ldy #>1000
        ldz #0
        trap $1E                ; mkfile
        ldz #0
        trap $34                ; findfile
        trap $18                ; openfile
        sta ffd
        lda #'W'
        fillbuf
        ldx ffd
        trap $1C                ; writefile
        lda #'X'
        fillbuf
        ldx ffd
        trap $1C                ; writefile
        ldx ffd
        trap $20                ; closefile

        setname "newfile.txt"
        trap $34
        trap $18
        sta ffd
        lda #0
        fillbuf
        ldx ffd
        trap $1A                ; readfile
        jsr dumpbuf
        ldx ffd
        trap $20

        setname "A LONG FILE NAME.TXT"
        trap $34
        trap $26                ; rmfile
        trap $34                ; findfile: now not found ($88)

        setname "GAMES"
        trap $34
        trap $0C                ; chdir
        setname "pascal65"
        trap $40                ; d81attach0 (finds PASCAL65.D81)
        setname "pascal65.d81"
        trap $46                ; d81attach1: the same image, double attach ($8F)
        trap $3C                ; cdrootdir
        lda #$EE
        ldy #0
        sta (logp),y
        cli
        rts

; first 16 bytes of the sector buffer to the log
dumpbuf:
        lda #$00
        sta $F0
        lda #$6E
        sta $F1
        lda #$FD
        sta $F2
        lda #$0F
        sta $F3
        ldz #0
        ldy #0
:       .byte $EA
        lda ($F0),z
        sta (logp),y
        iny
        inz
        cpz #16
        bne :-
        ldz #0
        lda logp
        clc
        adc #16
        sta logp
        rts

ffd:    .byte 0
fillv:  .byte 0

; append A X Y P to the log (all registers and flags kept)
log:    php
        sta la
        stx lx
        sty ly
        pla
        sta lp
        pha
        ldy #0
        lda la
        sta (logp),y
        iny
        lda lx
        sta (logp),y
        iny
        lda ly
        sta (logp),y
        iny
        lda lp
        sta (logp),y
        lda logp
        clc
        adc #4
        sta logp
        ldy ly
        ldx lx
        lda la
        plp
        rts

la:     .byte 0
lx:     .byte 0
ly:     .byte 0
lp:     .byte 0
