; Fills 8 bytes at 0x10, then copies them to 0x30 with LD and ST. One pointer is
; enough, because the address is rs + imm. There is no stack, so R3 is free.

.equ SRC,    0x10
.equ OFFSET, 0x20          ; the copy is this far above the original
.equ LEN,    8

start:
        LDI  R1, SRC
        LDI  R0, 7
        LDI  R2, LEN
fill:
        ST   R0, [R1]      ; 7, 38, 69, 100, 131, 162, 193, 224
        ADDI R0, 31
        ADDI R1, 1
        ADDI R2, -1
        BNE  fill

        LDI  R1, SRC
        LDI  R2, LEN
copy:
        LD   R0, [R1]
        ST   R0, [R1+OFFSET]
        ADDI R1, 1
        ADDI R2, -1
        BNE  copy

; rs + imm wraps at 8 bits: 0x20 + 0xF0 is 0x10.
        LDI  R2, 0x20
        LD   R3, [R2+0xF0]
        HALT
