; Prints "hello" through the UART, then halts. There are no character literals, so
; each letter is its ASCII code under a name.

.equ STACK_TOP,   0xF0
.equ UART_STATUS, 0xF0
.equ UART_DATA,   0xF1
.equ TX_READY,    1

.equ CHAR_h, 0x68
.equ CHAR_e, 0x65
.equ CHAR_l, 0x6C
.equ CHAR_o, 0x6F

start:
        LDI  R3, STACK_TOP
        LDI  R2, 0         ; R2 stays 0, so [R2+UART_DATA] reads like an absolute address
        LDI  R0, CHAR_h
        CALL putc
        LDI  R0, CHAR_e
        CALL putc
        LDI  R0, CHAR_l
        CALL putc
        LDI  R0, CHAR_l
        CALL putc
        LDI  R0, CHAR_o
        CALL putc
        HALT               ; the UART finishes the last frame by itself

; Sends the byte in R0. Waits for the transmitter first, because a byte written
; while it is busy is lost. Every register comes back unchanged.
putc:
        PUSH R1
putc_wait:
        LD   R1, [R2+UART_STATUS]
        ANDI R1, TX_READY
        BEQ  putc_wait
        ST   R0, [R2+UART_DATA]
        POP  R1
        RET
