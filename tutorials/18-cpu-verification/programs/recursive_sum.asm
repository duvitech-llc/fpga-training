; Works out 6 + 5 + 4 + 3 + 2 + 1 by recursion, and stores 21 at 0x80. Each call
; leaves a return address and the caller's R0 on the stack.

.equ STACK_TOP, 0xF0
.equ RESULT,    0x80
.equ N,         6

start:
        LDI  R3, STACK_TOP
        LDI  R0, N
        CALL sum
        LDI  R2, RESULT
        ST   R1, [R2]
        HALT

; R1 = R0 + (R0 - 1) + ... + 1. R0 comes back unchanged.
sum:
        CMPI R0, 0
        BNE  recurse
        LDI  R1, 0         ; sum(0) is 0, and the recursion stops here
        RET
recurse:
        PUSH R0            ; the call below needs R0 for itself
        ADDI R0, -1
        CALL sum
        POP  R0
        ADD  R1, R0
        RET
