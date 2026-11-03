# Prints a line, then loads from 0x30000000, where nothing on the bus lives. The
# interconnect's default responder answers err, and the system must stop with
# trap cause 5, a load access fault, at the lw at "bad". If the load finishes
# anyway, the program prints "not trapped" and ends with ecall.

        .equ   UART, 0x10000000
        .equ   TX_READY, 1
        .equ   NOWHERE, 0x30000000

start:  la     a0, message
        call   puts
        li     t3, NOWHERE
bad:    lw     t4, 0(t3)                # 0x000E2E83: must trap here
        la     a0, oops
        call   puts
        ecall

# Sends the zero-terminated string at a0. Uses t0, t1 and t2.
puts:   li     t0, UART
next:   lbu    t2, 0(a0)
        beqz   t2, done
wait:   lw     t1, 0(t0)
        andi   t1, t1, TX_READY
        beqz   t1, wait
        sb     t2, 4(t0)
        addi   a0, a0, 1
        j      next
done:   ret

# "load from 0x30000000\n"
message: .word 0x64616F6C, 0x6F726620, 0x7830206D, 0x30303033, 0x30303030, 0x0000000A
# "not trapped\n"
oops:   .word  0x20746F6E, 0x70617274, 0x0A646570, 0x00000000
