; Adds two 24-bit numbers, a byte at a time with ADC: 0xE2F0FF + 0x1E0F01. The carry
; has to cross all three bytes, so the answer is 0x01010000, with a fourth byte.
; Numbers are stored low byte first.

.equ A,   0x10             ; three bytes here
.equ B,   4                ; offset of the second number from A
.equ SUM, 8                ; offset of the answer from A

start:
        LDI  R2, A
        LDI  R0, 0xFF      ; A = 0xE2F0FF
        ST   R0, [R2+0]
        LDI  R0, 0xF0
        ST   R0, [R2+1]
        LDI  R0, 0xE2
        ST   R0, [R2+2]
        LDI  R0, 0x01      ; B = 0x1E0F01
        ST   R0, [R2+B]
        LDI  R0, 0x0F
        ST   R0, [R2+5]
        LDI  R0, 0x1E
        ST   R0, [R2+6]

; LD and ST leave the flags alone, so c survives from each add to the next.
; An ADDI to step a pointer here would destroy it, which is why this is not a loop.
        LD   R0, [R2+0]
        LD   R1, [R2+B]
        ADD  R0, R1        ; low byte: a plain ADD, with nothing to carry in
        ST   R0, [R2+SUM]
        LD   R0, [R2+1]
        LD   R1, [R2+5]
        ADC  R0, R1
        ST   R0, [R2+9]
        LD   R0, [R2+2]
        LD   R1, [R2+6]
        ADC  R0, R1
        ST   R0, [R2+10]
        LDI  R0, 0         ; LDI keeps the flags too
        ADC  R0, R0        ; R0 = c, the carry out of the top byte
        ST   R0, [R2+11]
        HALT
