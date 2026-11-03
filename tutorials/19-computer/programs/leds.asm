; Counts from 1 up to 255 and on to 0 on the LEDs, then halts. The count lives only in
; the LED register: each step reads it back, adds one and writes it again.

.equ STACK_TOP, 0xF0
.equ LED,       0xF2
.equ DELAY,     8

start:
        LDI  R3, STACK_TOP
        LDI  R2, 0
loop:
        LD   R0, [R2+LED]
        ADDI R0, 1
        ST   R0, [R2+LED]
        CALL wait
        CMPI R0, 0
        BNE  loop
        HALT

; Burns time. A real board would need a far larger DELAY for an eye to see it.
wait:
        LDI  R1, DELAY
wait_loop:
        ADDI R1, -1
        BNE  wait_loop
        RET
