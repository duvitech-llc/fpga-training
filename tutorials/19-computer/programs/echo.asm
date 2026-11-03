; Reads bytes from the UART forever, and sends each one back with a to z changed to
; upper case. Every other byte passes through unchanged.

.equ STACK_TOP,   0xF0
.equ UART_STATUS, 0xF0
.equ UART_DATA,   0xF1
.equ TX_READY,    1
.equ RX_WAITING,  2

.equ CHAR_a,      0x61
.equ AFTER_z,     0x7B     ; the code after z
.equ TO_UPPER,    -32      ; a is 0x61 and A is 0x41

start:
        LDI  R3, STACK_TOP
        LDI  R2, 0         ; R2 stays 0, so [R2+UART_DATA] reads like an absolute address
loop:
        CALL getc
        CALL upper
        CALL putc
        JMP  loop

; Waits for a received byte, and returns it in R0.
getc:
        PUSH R1
getc_wait:
        LD   R1, [R2+UART_STATUS]
        ANDI R1, RX_WAITING
        BEQ  getc_wait
        LD   R0, [R2+UART_DATA]
        POP  R1
        RET

; Upper-cases R0. After CMPI the carry means "no borrow", so BLO is "R0 was lower".
upper:
        CMPI R0, CHAR_a
        BLO  upper_done
        CMPI R0, AFTER_z
        BHS  upper_done
        ADDI R0, TO_UPPER
upper_done:
        RET

; Sends the byte in R0. Waits for the transmitter first.
putc:
        PUSH R1
putc_wait:
        LD   R1, [R2+UART_STATUS]
        ANDI R1, TX_READY
        BEQ  putc_wait
        ST   R0, [R2+UART_DATA]
        POP  R1
        RET
