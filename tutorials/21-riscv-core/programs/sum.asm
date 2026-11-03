# Adds 1 to 10 in a loop, stores the total and reads it back.
# Every program ends with ebreak if all its checks passed, and ecall if one failed.

        li   a0, 0              # the total
        li   a1, 10             # counts down to 0
loop:   add  a0, a0, a1
        addi a1, a1, -1
        bnez a1, loop

        la   t0, result
        sw   a0, 0(t0)
        lw   t1, 0(t0)
        li   t2, 55
        bne  t1, t2, fail
        ebreak

fail:   ecall

        .org 0x100
result: .word 0
