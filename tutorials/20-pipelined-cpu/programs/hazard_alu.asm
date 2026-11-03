; Each ADD needs a result that the instruction 1, 2 or 3 places before it has not
; finished writing. The right answers are 3, 13, 23, 33 at 0x40 to 0x43.

.equ OUT, 0x40

        LDI  R2, OUT
        LDI  R0, 1
        ADDI R0, 2          ; R0 comes from 1 place back: forward from MEM
        LDI  R1, 10
        NOP
        ADD  R1, R0         ; R1 comes from 2 places back: forward from WB
        ST   R0, [R2+0]
        ST   R1, [R2+1]
        LDI  R1, 20
        NOP
        NOP
        ADD  R1, R0         ; R1 comes from 3 places back: taken in ID
        ST   R1, [R2+2]
        LDI  R0, 30
        LDI  R1, 3
        ADD  R0, R1         ; rs needs 1 place back, and rd needs 2
        ST   R0, [R2+3]
        HALT
