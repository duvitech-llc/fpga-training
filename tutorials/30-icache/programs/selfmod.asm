# Code that writes code: why the cache needs an invalidate.
#
# The program copies a routine into RAM at RUN and calls it, then copies a
# different routine to the same place and calls it twice: once straight away,
# and once after writing the cache's INVALIDATE register. Routine A returns 1,
# routine B returns 2. The three answers go to GPIO, one byte each:
#
#   gpio_out = first | second << 8 | third << 16
#
#   with no cache:      0x020201, every call runs what RAM holds
#   with the cache:     0x020101, the second call runs A again, from the cache
#
# The store that copies B changes RAM, but the cache does not look at stores,
# and still holds A's words from the first call. Only the invalidate makes it
# fetch from RAM again. Ends with ebreak, or with ecall if the first or the
# third answer is wrong, since those must be right with any cache.
#
# RUN is chosen so that its cache lines are not used by this program's own
# code, for every cache size measured here, so A stays in the cache between
# the first and second calls.

        .equ   GPIO, 0x10001000
        .equ   INVALIDATE, 0x10007000
        .equ   RUN, 0x80C0

start:  li     s0, GPIO
        li     s1, RUN
        la     a0, routine_a
        call   copy
        jalr   s1                       # 1: runs A
        mv     s2, a0
        la     a0, routine_b
        call   copy
        jalr   s1                       # 2: B is in RAM, but is it what runs?
        mv     s3, a0
        li     t0, INVALIDATE
        sw     zero, 0(t0)              # the cache forgets everything
        jalr   s1                       # 3: runs B
        mv     s4, a0
        slli   t0, s3, 8
        slli   t1, s4, 16
        or     t0, t0, s2
        or     t0, t0, t1
        sw     t0, 0(s0)
        li     t0, 1
        bne    s2, t0, fail
        li     t0, 2
        bne    s4, t0, fail
        ebreak
fail:   ecall

# Copies the two words at a0 to RUN. Uses t0 only.
copy:   lw     t0, 0(a0)
        sw     t0, 0(s1)
        lw     t0, 4(a0)
        sw     t0, 4(s1)
        ret

routine_a:
        li     a0, 1
        ret
routine_b:
        li     a0, 2
        ret
