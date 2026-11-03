# Byte and halfword stores and loads on three kinds of target: a word of RAM, the
# GPIO register on Wishbone, and reg0 of the AXI4-Lite block behind the bridge.
# Each store has a different mem_wstrb, and the same bits must arrive as sel on
# Wishbone and as wstrb on AXI4-Lite. Then the AXI4-Lite ID register is read a
# byte at a time and printed, which should give "AXIL".
#
# Ends with ebreak if every check passes, and with ecall at the first that fails.
# Afterwards the RAM word and reg0 hold 66778899, and gpio_out holds 667788A5.

        .equ   UART, 0x10000000         # status at +0, data at +4
        .equ   GPIO, 0x10001000         # gpio_out
        .equ   AXIL, 0x20000000         # reg0 at +0x00, ID at +0x10
        .equ   TX_READY, 1

start:  la     a0, data
        call   lanes
        li     a0, GPIO
        call   lanes
        li     a0, AXIL
        call   lanes

        li     t0, GPIO
        li     t1, 0xA5
        sb     t1, 0(t0)                # only the LEDs' byte: gpio_out is 667788A5

        # ID is 4158494C. Its top byte is 'A', so print from byte 3 down to byte 0.
        li     s0, AXIL+0x13
        li     s1, 4
id:     lbu    a0, 0(s0)
        call   putc
        addi   s0, s0, -1
        addi   s1, s1, -1
        bnez   s1, id
        li     a0, 10                   # newline
        call   putc
        ebreak

fail:   ecall

# Builds one word at a0 from bytes and halfwords, and checks it with every load.
# Uses t0, t1 and t2.
lanes:  sw     zero, 0(a0)              # wstrb 1111
        li     t0, 0x11
        sb     t0, 0(a0)                # wstrb 0001
        li     t0, 0x22
        sb     t0, 1(a0)                # wstrb 0010
        li     t0, 0x33
        sb     t0, 2(a0)                # wstrb 0100
        li     t0, 0xF4
        sb     t0, 3(a0)                # wstrb 1000

        lw     t1, 0(a0)
        li     t2, 0xF4332211
        bne    t1, t2, fail
        lb     t1, 3(a0)                # F4 is negative
        li     t2, 0xFFFFFFF4
        bne    t1, t2, fail
        lbu    t1, 3(a0)
        li     t2, 0xF4
        bne    t1, t2, fail
        lbu    t1, 1(a0)
        li     t2, 0x22
        bne    t1, t2, fail
        lb     t1, 2(a0)
        li     t2, 0x33
        bne    t1, t2, fail
        lh     t1, 2(a0)
        li     t2, 0xFFFFF433
        bne    t1, t2, fail
        lhu    t1, 2(a0)
        li     t2, 0xF433
        bne    t1, t2, fail
        lhu    t1, 0(a0)
        li     t2, 0x2211
        bne    t1, t2, fail

        li     t0, 0x8899
        sh     t0, 0(a0)                # wstrb 0011
        lh     t1, 0(a0)                # 8899 is negative as a halfword
        li     t2, 0xFFFF8899
        bne    t1, t2, fail
        li     t0, 0x6677
        sh     t0, 2(a0)                # wstrb 1100
        lw     t1, 0(a0)
        li     t2, 0x66778899
        bne    t1, t2, fail
        ret

# Sends the byte in a0, once the transmitter is ready. Uses t0 and t1.
putc:   li     t0, UART
wait:   lw     t1, 0(t0)
        andi   t1, t1, TX_READY
        beqz   t1, wait
        sb     a0, 4(t0)
        ret

data:   .word  0
