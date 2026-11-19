; X raster compare IRQ test ($D050/51, $D019/$D01A bit 4, $D07A EXTIRQS).
; Run under ROM 911210 with MEGA65 extensions on: RUN.  Results as hex on
; the top text line ($0800):
;   0: lines with an X raster event while $D012 went 100 -> 200 (expect 64 = 100)
;   1: $D019 after one event, $D01A = 0            (expect 10: flag, no IRQ)
;   2: $D019 with $D01A = $10, EXTIRQS off        (expect 10)
;   3: $D019 with $D01A = $10, EXTIRQS on         (expect 90: IRQ)
;   4: $D01A read back                            (expect F0)
        .setcpu "4510"
        .segment "LOADADDR"
        .word $2001
        .segment "STUB"
        .byte $0F, $20, $EA, $07, $FE, $02, $30, $3A, $9E, $38, $32, $31, $30, $00, $00, $00, $00

        .segment "CODE"
out     = $FB
        sei
        lda #0
        tax
        tay
        taz
        map
        eom
        lda #$35
        sta $01
        lda #$47
        sta $D02F
        lda #$53
        sta $D02F
        lda #0
        sta $D01A
        lda #$80                ; EXTIRQS off, raster compare in VIC-II lines
        sta $D07A
        lda #<400
        sta $D050
        lda #>400
        sta $D051
        ldx #0
        stx out
        ; count X raster events while the raster runs from 100 to 200
w1:     lda $D012
        cmp #100
        bne w1
        lda #$1F
        sta $D019
cnt:    lda $D019
        and #$10
        beq nx
        inc out
        lda #$10
        sta $D019
nx:     lda $D012
        cmp #200
        bne cnt
        lda out
        jsr hex

        ; one event, no IRQ enabled
        lda #$1F
        sta $D019
w2:     lda $D019
        and #$10
        beq w2
        lda $D019
        jsr hex

        lda #$10
        sta $D01A
        lda $D019
        jsr hex

        lda #$C0
        sta $D07A
        lda $D019
        jsr hex
        lda $D01A
        jsr hex

        lda #$80
        sta $D07A
        lda #0
        sta $D01A
        lda #$1F
        sta $D019
done:   jmp done

hex:    pha
        lsr
        lsr
        lsr
        lsr
        jsr dig
        pla
        and #$0F
dig:    cmp #10
        bcc d1
        sbc #9                  ; A-F -> screen codes 1-6
        bra d2
d1:     ora #$30
d2:     sta $0800,x
        inx
        rts
