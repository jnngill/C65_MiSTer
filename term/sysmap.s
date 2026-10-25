; Start-up and exit glue between cc65 and the C65 ROM.
;
; PRESTART comes first in MAIN, so the BASIC stub's BANK 0:SYS lands here,
; before cc65's own start-up code.  BANK 0 maps RAM over the whole 64K; this
; undoes that so the C65 KERNAL stays reachable: the MAP translation is
; cleared and the C65 ROM is switched in at $C000 and $E000 ($D030 bits 5
; and 7), with I/O at $D000.
;
; What the ROM keeps track of, and what happens to it:
;   $0100-$01FF  the stack: BASIC 10's SYS arrives through a chain of far
;                calls and leaves little of it free, so the program resets it
;                (S-BASIC 65's 16-bit stack is left alone).  The page also
;                holds the caller's MAP setting at $011C-$011F, which the KERNAL
;                puts back after its far calls (disk I/O)
;   $1000-$10FF  the function key definitions (16 lengths, then the text, as
;                on the C128): F1-F8 become the one-character strings 133-140
;                (the C64 codes) while the program runs, put back on exit
;   $1104 bit 0  BASIC 10's interrupt hook: the KERNAL IRQ calls $2006 (BASIC
;                ROM) when it is set, which with this map is the program
;
; _sysexit puts the key definitions back and restarts the machine (see
; below); it does not return.
        .setcpu "45GS02"
        .export _sysexit

        .segment "PRESTART"
        sei
        ; The program reaches bank 1 through 32-bit far pointers ([zp],Z), a
        ; MEGA65 (45GS02) feature: unlock MEGA65 I/O ($47, $53 to $D02F) and
        ; check that a far write to bank 1 reads back.  Without the core's
        ; MEGA65 Extensions option it does not: say so and go back to BASIC
        ; while nothing has been changed yet.
        lda $01                 ; first make I/O visible: BANK 0 maps RAM over
        sta save01              ; all of it under 911210 (the KERNAL's SYS
        lda #$00                ; trampoline puts the caller's map back from
        tax                     ; $011C-$011F when this returns)
        tay
        taz
        map
        eom
        lda #$37
        sta $01
        ldx #3
@fz:    lda $fb,x               ; borrow $FB-$FE as the far pointer
        sta fpsave,x
        dex
        bpl @fz
        lda #$47
        sta $d02f
        lda #$53
        sta $d02f
        lda #$f0                ; $1E7F0: a spare byte after the shadow colours
        sta $fb
        lda #$e7
        sta $fc
        lda #$01
        sta $fd
        lda #0
        sta $fe
        ldz #0
        lda #$5a
        sta [$fb],z
        lda [$fb],z
        cmp #$5a
        bne @nofar
        lda #$a5
        sta [$fb],z
        lda [$fb],z
        cmp #$a5
        bne @nofar
        jmp far_ok
@nofar: ldz #0
        jsr fprestore
        lda #$a5                ; the wrong key dropped the VIC-III mode: back
        sta $d02f
        lda #$96
        sta $d02f
        lda $d030               ; KERNAL visible for CHROUT
        pha
        ora #$a0
        sta $d030
        ldx #0
@msg:   lda nofarmsg,x
        beq @msgend
        jsr $ffd2
        inx
        bne @msg
@msgend:
        pla
        sta $d030
        lda save01
        sta $01
        cli
        rts                     ; back to BASIC: nothing else was touched

fprestore:
        ldx #3
@fr:    lda fpsave,x
        sta $fb,x
        dex
        bpl @fr
        rts

nofarmsg:
        .byte 13, "C65TERM NEEDS THE MEGA65 EXTENSIONS", 13
        .byte "OPTION SWITCHED ON IN THE OSD.", 13, 0

far_ok: ldz #0
        jsr fprestore
        tsy                     ; stack high byte: $01 = the 8-bit page 1 stack
        cpy #$01                ; (911210, nearly full after BASIC's SYS): the
        bne @keep               ; program takes all of it (it never returns
        ldx #$ff                ; to the SYS).  S-BASIC 65 runs a 16-bit stack
        txs                     ; high in bank 0, which is left alone
@keep:  lda $d030
        sta saved030
        lda $1104
        sta save1104
        lda $1104
        and #$fe
        sta $1104
        ldx #0                  ; function key definitions: save them all ...
@kl:    lda $1000,x
        sta savekeys,x
        inx
        bne @kl
        ldx #15                 ; ... then F1-F8 give the C64 key codes 133-140
@kz:    lda fklen,x
        sta $1000,x
        dex
        bpl @kz
        ldx #7
@kc:    lda fkcode,x
        sta $1010,x
        dex
        bpl @kc
        lda #$00
        tax
        tay
        taz
        map
        eom
        sta $011c
        sta $011d
        sta $011e
        sta $011f
        lda #$37
        sta $01
        lda $d030
        ora #$a0
        sta $d030
        cli
        ; falls through into STARTUP

        .code
; Leaving: the function keys and video settings go back, then the machine
; restarts through the ROM's reset vector.  Handing control back to BASIC's
; SYS in place would need BASIC's own memory map restored exactly, which the
; two ROMs set up differently; a restart is the dependable way back.
_sysexit:
        sei
        ldx #0
@kr:    lda savekeys,x
        sta $1000,x
        inx
        bne @kr
        lda save1104
        sta $1104
        ; the state a hardware reset leaves: 8-bit stack in page 1, base page
        ; 0, no MAP, $D030 = 0 and the CPU port as at power-on; then the
        ; reset vector of the ROM seen at $E000 ($2E000), as the CPU uses it
        cld
        see
        ldy #$01
        tys
        ldx #$ff
        txs
        lda #$00
        tab
        tax
        tay
        taz
        map
        eom
        sta $d030
        lda #$2f
        sta $00
        lda #$37
        sta $01
        jmp ($fffc)

        .data
fpsave:   .byte 0, 0, 0, 0
save01:   .byte 0
saved030: .byte 0
save1104: .byte 0
; the bigger save areas live in the text screen RAM, unused while the
; terminal runs (its serial ring buffer is $0800-$0BFF)
savekeys = $0e00
        .rodata
fklen:    .byte 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0
fkcode:   .byte 133, 137, 134, 138, 135, 139, 136, 140    ; F1 F2 F3 F4 F5 F6 F7 F8
