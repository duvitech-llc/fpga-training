; Stack instructions read and write R3 without naming it, so they have the same hazards
; as any other instruction. The right answers are 0x12, 0x34, 0x12, 0xEE, 0xF0 at 0x40
; to 0x44, and R3 back at 0xF0.

.equ OUT, 0x40

        LDI  R3, 0xF0       ; the PUSH needs this at once
        LDI  R1, OUT
        LDI  R0, 0x12
        PUSH R0
        LDI  R0, 0x34
        PUSH R0             ; R3 from the last PUSH, 2 places back
        POP  R2             ; R3 from 1 place back. R2 = 0x34
        POP  R0             ; again. R0 = 0x12
        ST   R0, [R1+0]
        ST   R2, [R1+1]
        CALL routine
        ST   R2, [R1+2]     ; R2 from just before the RET
        MOV  R0, R3         ; R3 from the RET
        ST   R0, [R1+4]     ; 0xF0
        LDI  R3, 0xF0
        LDI  R2, 0xEE
        PUSH R2
        LD   R3, [R3+0]     ; a load into R3, so the PUSH below waits for it
        PUSH R3             ; stores 0xEE at 0xED
        LD   R0, [R3+0]     ; R3 = 0xED
        ST   R0, [R1+3]
        LDI  R3, 0xF0
        HALT
routine:
        PUSH R0
        POP  R2
        RET
