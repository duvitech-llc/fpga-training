# Prints "Hello, world!" and a newline through the UART, then stops with ebreak.
#
# The text is packed four bytes to a word, so lbu reads it from every byte lane.
# There are no character literals in this assembler, so the words are written in hex.

        .equ   UART, 0x10000000         # status at +0, data at +4
        .equ   TX_READY, 1              # bit 0 of status

start:  la     a0, message
        call   puts
        ebreak

# Sends the zero-terminated string at a0. Waits for the transmitter before each
# byte, because a byte written while it is busy is lost. Uses t0, t1 and t2.
puts:   li     t0, UART
next:   lbu    t2, 0(a0)
        beqz   t2, done
wait:   lw     t1, 0(t0)                # status
        andi   t1, t1, TX_READY
        beqz   t1, wait
        sb     t2, 4(t0)                # data: a byte store, wstrb 0001
        addi   a0, a0, 1
        j      next
done:   ret

# "Hello, world!\n", little-endian: 'H' is the low byte of the first word.
message: .word 0x6C6C6548, 0x77202C6F, 0x646C726F, 0x00000A21
