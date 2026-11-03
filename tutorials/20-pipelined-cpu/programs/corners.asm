; Directed coverage. Each ADDI leaves one of the nine combinations of flags that can
; exist, and then come the ALU operations no other program uses, and addresses that wrap.

        LDI  R3, 0xF0

        ; {z, c, n, v}
        LDI  R0, 1
        ADDI R0, 1          ; 0000: 1 + 1
        LDI  R0, 0x80
        ADDI R0, 1          ; 0010: negative
        LDI  R0, 0x7F
        ADDI R0, 1          ; 0011: 127 + 1 overflows
        LDI  R0, 0xFF
        ADDI R0, 2          ; 0100: carry
        LDI  R0, 0x80
        ADDI R0, 0xFF       ; 0101: -128 - 1 overflows, with carry
        LDI  R0, 0xFF
        ADDI R0, 0xFF       ; 0110: -1 - 1, with carry
        LDI  R0, 0
        ADDI R0, 0          ; 1000: zero
        LDI  R0, 0xFF
        ADDI R0, 1          ; 1100: zero, with carry
        LDI  R0, 0x80
        ADDI R0, 0x80       ; 1101: -128 - 128 overflows to zero

        ; Each ALU operation, from a known carry.
        LDI  R0, 0xA5
        LDI  R1, 0x3C
        CMP  R0, R1         ; c = 1, since 0xA5 >= 0x3C
        ADC  R0, R1
        SBC  R0, R1
        SUB  R0, R1
        AND  R0, R1
        OR   R0, R1
        XOR  R0, R1
        NOT  R0
        SHL  R0
        SHR  R0
        ASR  R0
        ROL  R0
        ROR  R0
        MOV  R2, R0
        ANDI R2, 0x0F
        CMPI R2, 3

        ; rs + imm wraps at 8 bits, and JR goes to a register.
        LDI  R1, 0x90
        ST   R2, [R1+0x80]  ; address 0x10
        LD   R0, [R1+0x80]
        LDI  R2, done
        JR   R2
        NOP

done:   CALL leaf
        HALT

leaf:   PUSH R0
        POP  R1
        RET
