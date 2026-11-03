# The ALU at its edges. RISC-V has no flags and no overflow trap: sums wrap, and
# compares write 0 or 1 to a register.

        li   s0, 0x7FFFFFFF     # the largest signed number
        li   s1, 0x80000000     # the smallest
        li   s2, -1             # 0xFFFFFFFF

        addi t0, s0, 1          # wraps to the smallest
        bne  t0, s1, fail
        sub  t0, s1, s2         # -2**31 minus -1
        li   t1, 0x80000001
        bne  t0, t1, fail
        add  t0, s0, s0
        li   t1, 0xFFFFFFFE
        bne  t0, t1, fail
        sub  t0, zero, s1       # minus -2**31 wraps to itself
        bne  t0, s1, fail

        slt  t0, s1, s0         # signed: smallest < largest
        li   t1, 1
        bne  t0, t1, fail
        sltu t0, s1, s0         # unsigned: 0x80000000 > 0x7FFFFFFF
        bnez t0, fail
        slt  t0, s0, s0         # equal is not less
        bnez t0, fail
        slti t0, s1, 0
        beqz t0, fail
        slti t0, s0, -2048
        bnez t0, fail
        sltiu t0, s0, -1        # the immediate is sign-extended, then compared unsigned
        beqz t0, fail
        sltiu t0, s2, -1        # 0xFFFFFFFF is not below itself
        bnez t0, fail
        seqz t0, zero
        beqz t0, fail
        snez t0, s2
        beqz t0, fail
        neg  t0, s2
        li   t1, 1
        bne  t0, t1, fail

        li   a0, 0x0F0F00FF
        li   a1, 0x00FF0F0F
        xor  t0, a0, a1
        li   t1, 0x0FF00FF0
        bne  t0, t1, fail
        or   t0, a0, a1
        li   t1, 0x0FFF0FFF
        bne  t0, t1, fail
        and  t0, a0, a1
        li   t1, 0x000F000F
        bne  t0, t1, fail
        xori t0, a0, -1         # not
        li   t1, 0xF0F0FF00
        bne  t0, t1, fail
        ori  t0, zero, -2048    # immediates are sign-extended
        li   t1, 0xFFFFF800
        bne  t0, t1, fail
        andi t0, s2, 0x7FF
        li   t1, 0x7FF
        bne  t0, t1, fail
        andi t0, a0, -256
        li   t1, 0x0F0F0000
        bne  t0, t1, fail

        lui  t0, 0xFFFFF
        li   t1, 0xFFFFF000
        bne  t0, t1, fail
here:   auipc t0, 0             # its own address
        la   t1, here
        bne  t0, t1, fail
        auipc t0, 0x10          # 0x10000 on from its own address
        sub  t0, t0, t1
        li   t1, 0x10010        # it is four words after here
        bne  t0, t1, fail
        fence
        li   t0, 0x12345FFF     # lui and addi, with %hi rounded up
        lui  t1, %hi(0x12345FFF)
        addi t1, t1, %lo(0x12345FFF)
        bne  t0, t1, fail
        ebreak

fail:   ecall
