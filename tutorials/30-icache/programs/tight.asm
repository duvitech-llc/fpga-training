# A tight loop: three instructions, run 100 times, adding 100 down to 1.
#
# Every program here uses only jumps and branches relative to pc, so the same
# words run from RAM at 0 and from the flash at 0x4000_0000. Ends with ebreak if
# the sum is right, and with ecall if not.

start:  li     a0, 0
        li     t0, 100
loop:   add    a0, a0, t0
        addi   t0, t0, -1
        bnez   t0, loop
        li     t1, 5050
        bne    a0, t1, fail
        ebreak
fail:   ecall
