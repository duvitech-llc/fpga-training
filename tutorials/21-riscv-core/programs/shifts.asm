# Shifts by 0, 1 and 31, and by registers whose upper bits must be ignored.

        li   a0, 0x80000001
        slli t0, a0, 1
        li   t1, 0x00000002
        bne  t0, t1, fail
        srli t0, a0, 1
        li   t1, 0x40000000
        bne  t0, t1, fail
        srai t0, a0, 1          # the sign comes in at the top
        li   t1, 0xC0000000
        bne  t0, t1, fail
        slli t0, a0, 0
        bne  t0, a0, fail
        srai t0, a0, 31
        li   t1, -1
        bne  t0, t1, fail
        srli t0, a0, 31
        li   t1, 1
        bne  t0, t1, fail
        slli t0, a0, 31
        li   t1, 0x80000000
        bne  t0, t1, fail
        li   a2, 0x40000000
        srai t0, a2, 30         # a positive number shifts in zeros
        li   t1, 1
        bne  t0, t1, fail

        li   a1, 33             # only the low 5 bits count: 33 is 1
        sll  t0, a0, a1
        li   t1, 2
        bne  t0, t1, fail
        li   a1, -1             # 31
        srl  t0, a0, a1
        li   t1, 1
        bne  t0, t1, fail
        sra  t0, a0, a1
        li   t1, -1
        bne  t0, t1, fail
        li   a1, 32             # 0
        sra  t0, a0, a1
        bne  t0, a0, fail
        srl  t0, a0, zero
        bne  t0, a0, fail
        ebreak

fail:   ecall
