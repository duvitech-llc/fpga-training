; A load's data does not exist until WB, so the instruction right after it has to wait.
; That is true when the loaded value is an address, too. The right answers are 8 at 0x41,
; 7 at 0x42, 0x40 at 0x43 and 8 at 0x44.

.equ DATA, 0x40

        LDI  R1, DATA
        LDI  R0, 7
        ST   R0, [R1+0]
        LDI  R0, 0
        LD   R2, [R1+0]     ; R2 = 7
        ADDI R2, 1          ; uses R2 at once: one stall
        ST   R2, [R1+1]
        LD   R0, [R1+0]
        NOP
        ST   R0, [R1+2]     ; one instruction later: no stall, forwarded from WB
        ST   R1, [R1+3]     ; a pointer, 0x40, at 0x43
        LD   R2, [R1+3]     ; R2 = 0x40
        LD   R0, [R2+1]     ; uses R2 at once, as an address: one stall. R0 = 8
        NOP
        ST   R0, [R1+4]
        HALT
