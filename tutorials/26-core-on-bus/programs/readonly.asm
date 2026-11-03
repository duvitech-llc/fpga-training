# Prints a line, then writes to the ID register of the AXI4-Lite block. That
# register exists but refuses writes: axil_regs answers SLVERR, the bridge turns
# it into err, and the system must stop with trap cause 7, a store access fault,
# at the sw at "bad". If the store finishes anyway, the program prints
# "not trapped" and ends with ecall.

        .equ   UART, 0x10000000
        .equ   TX_READY, 1
        .equ   AXIL, 0x20000000         # ID at +0x10

start:  la     a0, message
        call   puts
        li     s2, AXIL
        li     t3, 0x12345678
bad:    sw     t3, 0x10(s2)             # 0x01C92823: must trap here
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

# "write to the ID register\n"
message: .word 0x74697277, 0x6F742065, 0x65687420, 0x20444920, 0x69676572, 0x72657473, 0x0000000A
# "not trapped\n"
oops:   .word  0x20746F6E, 0x70617274, 0x0A646570, 0x00000000
