# Copies a string one byte at a time, up to and including its zero, then counts it.

        la   a0, dst
        la   a1, src
copy:   lbu  t0, 0(a1)
        sb   t0, 0(a0)
        addi a0, a0, 1
        addi a1, a1, 1
        bnez t0, copy

        la   a0, dst            # strlen
        li   a2, 0
count:  add  t1, a0, a2
        lbu  t0, 0(t1)
        beqz t0, counted
        addi a2, a2, 1
        j    count
counted:
        li   t1, 13
        bne  a2, t1, fail
        la   a0, dst
        lw   t0, 0(a0)          # "Hell"
        li   t1, 0x6C6C6548
        bne  t0, t1, fail
        lw   t0, 12(a0)         # the exclamation mark, the zero, and two bytes not copied
        li   t1, 0xEEEE0021
        bne  t0, t1, fail
        ebreak

fail:   ecall

        .org 0x200
src:    .word 0x6C6C6548, 0x77202C6F, 0x646C726F, 0x00000021   # Hello, world!
        .org 0x300
dst:    .word 0xEEEEEEEE, 0xEEEEEEEE, 0xEEEEEEEE, 0xEEEEEEEE
