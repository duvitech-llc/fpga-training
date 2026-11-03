# A payload that prints a line, then stores to the boot ROM. The ROM answers a
# write with err, so the store is a store access fault, trap cause 7, and the
# second line never prints.

        .equ   UART, 0x10000000
        .equ   TX_READY, 1
        .equ   ROM, 0x00100000

start:  la     a0, message
        call   puts
        li     t3, ROM
bad:    sw     zero, 0(t3)              # the first word of the boot ROM
        la     a0, missed
        call   puts
        ebreak

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

message: .word 0x74697277, 0x6F742065, 0x65687420, 0x6F6F6220, 0x4F522074, 0x00000A4D  # "write to the boot ROM\n"
missed:  .word 0x20746F6E, 0x70617274, 0x0A646570, 0x00000000                          # "not trapped\n"
