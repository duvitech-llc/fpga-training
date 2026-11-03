# x0 always reads 0. Writes to it are thrown away, but a load into it still reads.

        addi zero, zero, 5
        bnez zero, fail
        li   t0, 0x1234
        add  zero, t0, t0
        bnez zero, fail
        lui  zero, 0x12345
        bnez zero, fail
        auipc zero, 1
        bnez zero, fail

        la   s0, data
        lw   zero, 0(s0)        # the load happens, and its value goes nowhere
        bnez zero, fail
        sw   zero, 4(s0)        # stores 0
        lw   t1, 4(s0)
        bnez t1, fail
        jal  zero, next         # this is j
        j    fail
next:   mv   t2, zero
        bnez t2, fail
        add  t2, zero, zero
        bnez t2, fail
        ebreak

fail:   ecall

        .org 0x100
data:   .word 0x55555555, 0xFFFFFFFF
