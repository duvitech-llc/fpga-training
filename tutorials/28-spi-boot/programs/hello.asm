# The payload: prints "Hello from flash!" and a newline through the UART, then
# stops with ebreak. This is Tutorial 26's hello.asm with a new message. The boot
# ROM copies it from flash into RAM at 0x1000 and jumps there.
#
# la reaches the message relative to pc, and every jump is relative, so the code
# runs wherever it is loaded, although asm.py assembles it from 0.

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

# "Hello from flash!\n", little-endian: 'H' is the low byte of the first word.
message: .word 0x6C6C6548, 0x7266206F, 0x66206D6F, 0x6873616C, 0x00000A21
