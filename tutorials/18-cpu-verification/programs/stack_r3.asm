; PUSH R3 and POP R3, the two cases where R3 moves while it is being used.
;
; PUSH R3 stores the value from before the decrement: 0xF0 lands at 0xEF.
; POP R3 keeps the loaded value: the load wins over the increment.

start:
        LDI  R3, 0xF0
        PUSH R3            ; memory at 0xEF is 0xF0, and R3 is 0xEF
        LD   R0, [R3]      ; R0 is 0xF0, the old R3
        MOV  R1, R3        ; R1 is 0xEF, the new R3
        LDI  R2, 0x55
        PUSH R2            ; memory at 0xEE is 0x55, and R3 is 0xEE
        POP  R3            ; R3 is 0x55. If the increment won, it would be 0xEF
        MOV  R2, R3
        HALT
