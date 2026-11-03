; Takes every branch condition both ways, after signed and unsigned compares, and
; then runs JMP, JR and NOP. A wrong turn reaches fail, with the group in R0.
;
; A branch that must be taken jumps over a JMP fail. One that must not be taken
; goes straight to fail if it is. LDI does not touch the flags, so one compare
; serves a whole group of branches.
;
; Pass: 0xAA at 0x80, and 0 at 0x81. Fail: 0xEE at 0x80, and the group at 0x81.

.equ RESULT, 0x80

start:

; Group 1: 5 - 5. z=1 c=1 n=0 v=0. Equal, so all twelve can be tested at once.
        LDI  R0, 1
        LDI  R1, 5
        CMPI R1, 5
        BEQ  ok1
        JMP  fail
ok1:    BNE  fail
        BCS  ok2
        JMP  fail
ok2:    BCC  fail
        BPL  ok3
        JMP  fail
ok3:    BMI  fail
        BVC  ok4
        JMP  fail
ok4:    BVS  fail
        BGE  ok5
        JMP  fail
ok5:    BLT  fail
        BHS  ok6
        JMP  fail
ok6:    BLO  fail

; Group 2: 0xFF - 1, with CMP this time. z=0 c=1 n=1 v=0. As unsigned numbers
; 255 >= 1, but as signed numbers -1 < 1, so BLT and BLO disagree.
        LDI  R0, 2
        LDI  R1, 0xFF
        LDI  R2, 1
        CMP  R1, R2
        BNE  ok7
        JMP  fail
ok7:    BEQ  fail
        BMI  ok8
        JMP  fail
ok8:    BPL  fail
        BLT  ok9
        JMP  fail
ok9:    BGE  fail
        BHS  ok10
        JMP  fail
ok10:   BLO  fail

; Group 3: 1 - 0xFF. z=0 c=0 n=0 v=0. The other way round: 1 < 255, but 1 > -1.
        LDI  R0, 3
        LDI  R1, 1
        CMPI R1, 0xFF
        BCC  ok11
        JMP  fail
ok11:   BCS  fail
        BLO  ok12
        JMP  fail
ok12:   BHS  fail
        BGE  ok13
        JMP  fail
ok13:   BLT  fail

; Group 4: -128 - 1 overflows to +127. z=0 c=1 n=0 v=1. n alone gives the wrong
; answer here, and BLT must still see that -128 < 1.
        LDI  R0, 4
        LDI  R1, 0x80
        CMPI R1, 1
        BVS  ok14
        JMP  fail
ok14:   BVC  fail
        BLT  ok15
        JMP  fail
ok15:   BGE  fail

; Group 5: 127 - (-1) overflows to -128. z=0 c=0 n=1 v=1. BGE must see 127 >= -1.
        LDI  R0, 5
        LDI  R1, 0x7F
        CMPI R1, 0xFF
        BGE  ok16
        JMP  fail
ok16:   BLT  fail
        BLO  ok17
        JMP  fail
ok17:   BHS  fail

; The rest of the control flow.
        LDI  R0, 6
        JMP  over
        JMP  fail
over:   LDI  R1, there
        JR   R1
        JMP  fail
there:  NOP

        LDI  R0, 0
        LDI  R1, 0xAA
        LDI  R2, RESULT
        ST   R1, [R2]
        ST   R0, [R2+1]
        HALT

fail:
        LDI  R1, 0xEE
        LDI  R2, RESULT
        ST   R1, [R2]
        ST   R0, [R2+1]
        HALT
