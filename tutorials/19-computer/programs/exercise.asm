; Your turn. Write a program that waits for one byte from the UART, sends it back as two
; hex digits, and halts. If the byte is 0x5A it should send the characters 5 and A.
;
; You need getc and putc from echo.asm, and these pieces:
;   - Four SHR instructions bring the high digit down. PUSH R0 keeps a copy first.
;   - ANDI R0, 0x0F keeps the low digit.
;   - The digit 0 is 0x30 and the letter A is 0x41, so a digit above 9 needs 7 more.
;
; "make sim" runs this program last, sends it 0x5A and prints what comes back. It does
; not check the answer, so read the line yourself. Until you write it, this only halts.

start:
        HALT
