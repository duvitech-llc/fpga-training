; Not a useful program: a stress test for the receive path. It reads the data register
; as fast as it can with no polling, so a read keeps landing near the edge where a new
; byte arrives. The Python test checks what comes back.

.equ UART_STATUS, 0xF0
.equ UART_DATA,   0xF1

start:
        LDI  R2, 0
loop:
        LD   R0, [R2+UART_DATA]
        LD   R1, [R2+UART_STATUS]
        JMP  loop
