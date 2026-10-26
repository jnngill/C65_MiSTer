; Hypervisor entry for the C65 core's MEGA65 hypervisor (see m65_hyp.sv).
;
; The core enters at $8000 + 4 * trap number with B = $BF (zero page at
; $BF00), SP = $BEFF (page mode), interrupts held and decimal mode off.  The
; program's registers are in the save area $D640-$D649; hyp_main() reads its
; arguments there and leaves the results there, and writing $D67F returns.

        .setcpu "4510"
        .export __STARTUP__ : absolute = 1
        .import _hyp_main
        .import __CSTACK_START__, __CSTACK_SIZE__
        .importzp c_sp
        .exportzp _far_ptr
        .export _far_put

        .segment "ZEROPAGE"
_far_ptr:   .res 4          ; 28-bit destination for far_put
src:        .res 2
cnt:        .res 2

        .segment "ENTRY"
        .repeat 64
        jmp common
        nop
        .endrep

        .segment "CODE"
common:
        cld
        ldz #0                  ; cc65's code assumes Z = 0 ((zp) is (zp),Z on the 4510)
        lda #<(__CSTACK_START__ + __CSTACK_SIZE__)
        sta c_sp
        lda #>(__CSTACK_START__ + __CSTACK_SIZE__)
        sta c_sp+1
        jsr _hyp_main
        sta $D67F               ; back to the program
hang:   bra hang

; void __fastcall__ far_put(unsigned int n): copy n bytes (up to 512) from the
; sector buffer at $DE00 to the 28-bit address in far_ptr.  far_ptr is left
; pointing past the last full page copied.
_far_put:
        sta cnt
        stx cnt+1
        lda #$00
        sta src
        lda #$DE
        sta src+1
@page:  lda cnt+1
        bne @full
        lda cnt
        beq @done
        tax                     ; last, partial page
        lda #0
        sta cnt
        bra @copy
@full:  dec cnt+1
        ldx #0                  ; 256 bytes
@copy:  ldy #0
@byte:  tya
        taz
        lda (src),y
        .byte $EA               ; EOM: the next (zp),Z uses a 32-bit pointer
        sta (_far_ptr),z
        iny
        dex
        bne @byte
        cpy #0
        bne @done               ; that was the partial page
        inc src+1
        inc _far_ptr+1
        bne @page
        inc _far_ptr+2
        bne @page
        inc _far_ptr+3
        bra @page
@done:  ldz #0
        rts
