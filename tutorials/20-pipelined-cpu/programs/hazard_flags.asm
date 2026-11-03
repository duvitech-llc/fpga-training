; Flags are written in WB, like a register, and branches and ADC read them in EX.
; The right answer is 0x01 at 0x40, 0x00 at 0x41, and 0xAA at 0x42.

.equ OUT, 0x40

        LDI  R2, OUT
        LDI  R0, 0xFF
        LDI  R1, 1
        ADD  R0, R1         ; 0 with a carry out
        LDI  R3, 0          ; leaves the flags alone
        ADC  R3, R3         ; 2 places after the ADD: forward from WB. R3 = 1
        ST   R3, [R2+0]
        ST   R0, [R2+1]
        LDI  R0, 0xFF
        ADD  R0, R1
        ADC  R0, R0         ; right after the ADD: forward from MEM. 0 + 0 + 1 = 1
        CMPI R0, 1          ; sets z
        BNE  fail           ; right after the CMPI: forward from MEM
        CMPI R0, 2          ; clears z
        NOP
        BEQ  fail           ; 2 places after: forward from WB
        LDI  R0, 0xAA
        ST   R0, [R2+2]
        HALT
fail:
        LDI  R0, 0xEE
        ST   R0, [R2+2]
        HALT
