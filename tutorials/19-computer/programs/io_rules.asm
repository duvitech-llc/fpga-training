; Tests every rule in the I/O map with real instructions, and stores what it sees at
; 0x10 and up for the testbench to check. LED is the handshake: the testbench watches
; it, and sends the next thing on the serial line when it changes.

.equ STACK_TOP,    0xF0
.equ UART_STATUS,  0xF0
.equ UART_DATA,    0xF1
.equ LED,          0xF2
.equ FIRST_UNUSED, 0xF3
.equ TX_READY,     1
.equ RX_WAITING,   2
.equ RX_ERROR,     4

start:
        LDI  R3, STACK_TOP
        LDI  R2, 0

        ; After reset the transmitter is ready, and nothing else is set.
        LD   R0, [R2+UART_STATUS]
        ST   R0, [R2+0x10]              ; 01

        ; Two writes with no poll between them. The second byte is lost.
        LDI  R0, 0x41
        ST   R0, [R2+UART_DATA]
        LDI  R0, 0x42
        ST   R0, [R2+UART_DATA]
        LD   R0, [R2+UART_STATUS]
        ST   R0, [R2+0x11]              ; 00, the transmitter is busy
        CALL tx_wait

        ; The LED register reads back.
        LDI  R0, 0x5A
        ST   R0, [R2+LED]
        LD   R1, [R2+LED]
        ST   R1, [R2+0x12]              ; 5A

        ; 0xF3 to 0xFF ignore writes and read as 0. R1 wraps to 0 after 0xFF.
        LDI  R1, FIRST_UNUSED
unused_loop:
        LDI  R0, 0xEE
        ST   R0, [R1]
        LD   R0, [R1]
        CMPI R0, 0
        BNE  fail
        ADDI R1, 1
        BNE  unused_loop
        LDI  R0, 1
        ST   R0, [R2+0x13]              ; 01

        ; Step 1: the testbench sends 0xC3.
        LDI  R0, 1
        ST   R0, [R2+LED]
        LDI  R1, RX_WAITING
        CALL status_wait

        ; This LDI puts R0 + 0xF1 on the address wires with R0 at 0, so the bus sees
        ; address 0xF1 with re low. That must not take the byte.
        LDI  R0, 0
        LDI  R1, UART_DATA
        LD   R0, [R2+UART_STATUS]
        ST   R0, [R2+0x14]              ; 03

        LD   R0, [R2+UART_DATA]
        ST   R0, [R2+0x15]              ; C3
        LD   R0, [R2+UART_STATUS]
        ST   R0, [R2+0x16]              ; 01, reading cleared rx waiting
        LD   R0, [R2+UART_DATA]
        ST   R0, [R2+0x17]              ; C3, an old byte can be read again

        ; Step 2: the testbench sends a frame with a bad stop bit.
        LDI  R0, 2
        ST   R0, [R2+LED]
        LDI  R1, RX_ERROR
        CALL status_wait
        LD   R0, [R2+UART_STATUS]
        ST   R0, [R2+0x18]              ; 05, and no byte is waiting

        ; A read of status and writes elsewhere leave the error alone.
        LDI  R0, 3
        ST   R0, [R2+LED]               ; this is also step 3 for the testbench
        ST   R0, [R2+0x40]
        LDI  R1, FIRST_UNUSED
        ST   R0, [R1]
        LD   R0, [R2+UART_STATUS]
        ST   R0, [R2+0x19]              ; 05

        ; Any value written to status clears it.
        ST   R2, [R2+UART_STATUS]
        LD   R0, [R2+UART_STATUS]
        ST   R0, [R2+0x1A]              ; 01

        ; Step 3: the testbench sends 0x11, 0x22, then a bad frame to say they have
        ; arrived. No read came between the bytes, so the newer one is kept.
        LDI  R1, RX_ERROR
        CALL status_wait
        LD   R0, [R2+UART_DATA]
        ST   R0, [R2+0x1B]              ; 22
        ST   R2, [R2+UART_STATUS]

        ; The stack instructions reach the bus too: this PUSH transmits a byte, because
        ; it stores at R3 - 1, which is 0xF1.
        CALL tx_wait
        LDI  R0, 0x43
        LDI  R3, LED
        PUSH R0
        LDI  R3, STACK_TOP
        CALL tx_wait

        LDI  R0, 0xAA
        ST   R0, [R2+0x1C]              ; AA, the program reached the end
        HALT

fail:
        LDI  R0, 0xEE
        ST   R0, [R2+0x1C]
        HALT

; Waits until a status bit in R1 is set, and keeps R0.
status_wait:
        PUSH R0
status_loop:
        LD   R0, [R2+UART_STATUS]
        AND  R0, R1
        BEQ  status_loop
        POP  R0
        RET

; Waits until the transmitter is ready. Changes R1.
tx_wait:
        LDI  R1, TX_READY
        CALL status_wait
        RET
