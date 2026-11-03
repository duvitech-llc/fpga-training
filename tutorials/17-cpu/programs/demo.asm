; Works out 2 * (5 + 4 + 3 + 2 + 1) with a loop, a subroutine and the stack, and
; stores the answer, 30, in data memory at 0x80.

.equ STACK_TOP, 0xF0       ; the first push lands at 0xEF
.equ RESULT,    0x80
.equ COUNT,     5

start:
        LDI  R3, STACK_TOP ; set the stack pointer before any CALL or PUSH
        LDI  R0, COUNT     ; R0 counts down to 0
        LDI  R1, 0         ; R1 is the running total
        LDI  R2, RESULT    ; R2 points at where the answer goes
loop:
        CALL add_double    ; R1 = R1 + 2 * R0
        ADDI R0, -1        ; sets z when R0 reaches 0
        BNE  loop
        ST   R1, [R2]
        HALT

; Adds 2 * R0 to R1. It needs a working register, so it saves R2 on the stack
; and restores it. The ST above only works if R2 comes back unchanged.
add_double:
        PUSH R2
        MOV  R2, R0
        SHL  R2
        ADD  R1, R2
        POP  R2
        RET
