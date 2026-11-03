; Fetching assumes that nothing jumps, so the two words after any jump are fetched
; anyway. None of them may do anything, and these are as bad as words can be: a store
; and HALT. The right answer is 0 at 0x40 and 0x77 at 0x41. The assembler refuses illegal
; words, so tb_cpu.v writes some over the wrong-path HALTs and runs this again.
;
; The NOPs keep data hazards out of this program, so that it shows one thing only.

.equ OUT, 0x40

        LDI  R3, 0xF0
        LDI  R1, OUT
        LDI  R0, 0x11
        NOP
        NOP
        NOP
        CMPI R0, 0x11
        NOP
        NOP
        NOP
        BEQ  over1          ; taken
        ST   R0, [R1+0]     ; wrong path
        HALT                ; wrong path
over1:
        JMP  over2
        ST   R0, [R1+0]     ; wrong path
        HALT                ; wrong path
over2:
        LDI  R2, over3
        NOP
        NOP
        NOP
        JR   R2
        LD   R0, [R1+0]     ; wrong path
        HALT                ; wrong path
over3:
        CALL routine
        LDI  R2, 0x77
        NOP
        NOP
        NOP
        ST   R2, [R1+1]
        HALT
routine:
        NOP
        NOP
        NOP
        RET
        ST   R0, [R1+0]     ; wrong path
        HALT                ; wrong path
        POP  R0             ; never fetched: while RET is in EX, fetching holds at HALT
