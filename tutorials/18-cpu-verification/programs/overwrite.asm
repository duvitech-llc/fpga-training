; A program that hides mistakes from any check made only at the end. LDI must leave
; the flags alone, and so must LD and ST. The ADDI at the end sets all four flags, so
; whatever happened to them before that leaves no trace in the final state.

        LDI  R0, 5
        CMPI R0, 5          ; equal: z and c are set
        LDI  R1, 0x80       ; the flags must not change here
        LDI  R2, 0x40
        ST   R1, [R2+0]     ; or here
        LD   R0, [R2+0]     ; or here
        LDI  R1, 3
        ADDI R1, 4          ; sets all four flags, and hides what came before
        HALT
