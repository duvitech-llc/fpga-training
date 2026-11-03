# A payload that boots twice. It counts its runs in the GPIO register, which
# reset clears and the boot ROM never touches, prints "Hello again!", and on its
# first run jumps back to the boot ROM, as a program does to restart without a
# reset. The second boot finds the CRC slave still holding the first boot's
# CRC, unless the boot ROM clears it. On its second run it stops with ebreak.

        .equ   UART, 0x10000000
        .equ   TX_READY, 1
        .equ   GPIO, 0x10001000
        .equ   ROM, 0x00100000

start:  li     t0, GPIO
        lw     t1, 0(t0)
        addi   t1, t1, 1
        sw     t1, 0(t0)                # one more run
        la     a0, message
        call   puts
        li     t0, GPIO
        lw     t1, 0(t0)
        li     t2, 2
        bgeu   t1, t2, stop
wait_tx: li    t0, UART                 # let the last byte go before the reboot
        lw     t1, 0(t0)
        andi   t1, t1, TX_READY
        beqz   t1, wait_tx
        li     t0, ROM
        jr     t0                       # boot again
stop:   ebreak

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

message: .word 0x6C6C6548, 0x6761206F, 0x216E6961, 0x0000000A   # "Hello again!\n"
