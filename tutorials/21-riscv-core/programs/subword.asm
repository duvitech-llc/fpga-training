# Bytes and halfwords: stores into each place in a word, then loads of each place,
# signed and unsigned. Memory is little-endian: byte 0 is bits 7 to 0.

        la   s0, data
        sw   zero, 0(s0)
        li   t0, 0x11
        sb   t0, 0(s0)
        li   t0, 0x22
        sb   t0, 1(s0)
        li   t0, 0x33
        sb   t0, 2(s0)
        li   t0, 0x7654F4       # only the low byte is stored
        sb   t0, 3(s0)
        lw   a0, 0(s0)
        li   t1, 0xF4332211
        bne  a0, t1, fail

        lb   a0, 0(s0)
        li   t1, 0x11
        bne  a0, t1, fail
        lb   a0, 1(s0)
        li   t1, 0x22
        bne  a0, t1, fail
        lb   a0, 2(s0)
        li   t1, 0x33
        bne  a0, t1, fail
        lb   a0, 3(s0)          # 0xF4 is negative, so it is sign-extended
        li   t1, 0xFFFFFFF4
        bne  a0, t1, fail
        lbu  a0, 0(s0)
        li   t1, 0x11
        bne  a0, t1, fail
        lbu  a0, 1(s0)
        li   t1, 0x22
        bne  a0, t1, fail
        lbu  a0, 2(s0)
        li   t1, 0x33
        bne  a0, t1, fail
        lbu  a0, 3(s0)
        li   t1, 0xF4
        bne  a0, t1, fail

        lh   a0, 0(s0)
        li   t1, 0x2211
        bne  a0, t1, fail
        lh   a0, 2(s0)
        li   t1, 0xFFFFF433
        bne  a0, t1, fail
        lhu  a0, 0(s0)
        li   t1, 0x2211
        bne  a0, t1, fail
        lhu  a0, 2(s0)
        li   t1, 0xF433
        bne  a0, t1, fail

        li   t0, 0x8899AABB
        sh   t0, 2(s0)
        lw   a0, 0(s0)
        li   t1, 0xAABB2211
        bne  a0, t1, fail
        sh   t0, 0(s0)
        lw   a0, 0(s0)
        li   t1, 0xAABBAABB
        bne  a0, t1, fail
        sb   zero, 1(s0)
        lw   a0, 0(s0)
        li   t1, 0xAABB00BB
        bne  a0, t1, fail
        lw   a0, 4(s0)          # the next word was never touched
        li   t1, 0x55555555
        bne  a0, t1, fail
        ebreak

fail:   ecall

        .org 0x200
data:   .word 0, 0x55555555
