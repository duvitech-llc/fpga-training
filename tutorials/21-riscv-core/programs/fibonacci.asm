# The first 30 Fibonacci numbers, as a table of words.

        la   s0, table
        li   a0, 0              # fib(n)
        li   a1, 1              # fib(n + 1)
        li   s1, 30             # how many to store
loop:   sw   a0, 0(s0)
        add  a2, a0, a1
        mv   a0, a1
        mv   a1, a2
        addi s0, s0, 4
        addi s1, s1, -1
        bnez s1, loop

        lw   t0, -4(s0)         # the last one stored is fib(29)
        li   t1, 514229
        bne  t0, t1, fail
        la   t2, table
        lw   t0, 40(t2)         # fib(10)
        li   t1, 55
        bne  t0, t1, fail
        ebreak

fail:   ecall

        .org 0x200
table:  .word 0
