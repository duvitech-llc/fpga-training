; Stores the Fibonacci numbers from 0x40 up, and stops at the last one that fits in
; 8 bits: 0, 1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233. The carry flag says when.

.equ TABLE, 0x40

start:
        LDI  R0, 0         ; R0 is this number
        LDI  R1, 1         ; R1 is the next one
        LDI  R2, TABLE     ; R2 points at where this one goes
loop:
        ST   R0, [R2]
        ADDI R2, 1
        MOV  R3, R1        ; R3 keeps the next number through the add
        ADD  R1, R0
        BCS  done          ; the sum did not fit
        MOV  R0, R3
        JMP  loop
done:
        ST   R3, [R2]      ; the last number that fitted, 233
        HALT
