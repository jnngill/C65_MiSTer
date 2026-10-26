; Hypervisor DOS test for the system simulation (sim/hyptest/build.sh).
; Run under BASIC 65 with MEGA65 extensions on and a FAT32 image as the SD
; card: LOAD"HYPTEST" and RUN.  Every call's A, X, Y and P go to a log at
; $7800 (4 bytes each), directory entries to $7000-$76FF; the simulation's
; ram.bin shows them.  Finishes with PASCAL65.D81 (in GAMES) attached.

        .setcpu "4510"
        .segment "LOADADDR"
        .word $2001
        .segment "STUB"
        .byte $0F, $20, $EA, $07, $FE, $02, $30, $3A, $9E, $38, $32, $31, $30, $00, $00, $00, $00

        .segment "CODE"
logp    = $FB           ; log pointer

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
        sta $7E00,x             ; the name must start a page
        beq en
        inx
        bra cp
nm:     .asciiz str
en:     ldy #$7E
        trap $2E
.endmacro

start:  sei
        lda #$70
        sta page
        lda #$00
        sta logp
        lda #$78
        sta logp+1

        trap $00                ; getversion
        jsr listdir             ; root directory into $7000...

        setname "A LONG FILE NAME.TXT"
        trap $34                ; findfile
        trap $18                ; openfile -> A = fd
        sta ffd
        tax
        trap $1A                ; readfile
        ; first 16 bytes of the sector buffer to the log
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
        lda logp
        clc
        adc #16
        sta logp
        ldz #0
        ldx ffd
        trap $20                ; closefile

        setname "GAMES"
        trap $34                ; findfile
        trap $0C                ; chdir
        jsr listdir

        setname "pascal65.d81"
        trap $40                ; d81attach0
        trap $3C                ; cdrootdir
        lda #$EE                ; end marker
        ldy #0
        sta (logp),y
        cli
        rts

; opendir, then readdir until it fails, entries to $7000, $7100, ...
listdir:
        trap $12                ; opendir -> A = fd
        sta fd
@next:  ldx fd
        ldy page
        trap $14                ; readdir
        bcc @done
        inc page
        lda page
        cmp #$77
        bne @next
@done:  ldx fd
        trap $16                ; closedir
        rts

fd:     .byte 0
ffd:    .byte 0
page:   .byte 0

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
