# Subroutines: a recursive sum with a stack, a call through a register, and a JALR
# whose rd is also its rs1.

        li   sp, 0x8000         # the stack grows down from here
        li   a0, 7
        call sum                # 7 + 6 + ... + 1
        li   t0, 28
        bne  a0, t0, fail

        la   t1, double         # a function pointer
        li   a0, 21
        jalr t1
        li   t0, 42
        bne  a0, t0, fail

        la   t2, after
        jalr t2, 0(t2)          # the target uses t2 before t2 gets the return address
back:   j    fail
after:  la   t3, back
        bne  t2, t3, fail

        li   t0, 0x8000         # every call put the stack back
        bne  sp, t0, fail
        ebreak

fail:   ecall

# a0 = a0 + (a0 - 1) + ... + 1
sum:    beqz a0, sum_done
        addi sp, sp, -8
        sw   ra, 4(sp)
        sw   a0, 0(sp)
        addi a0, a0, -1
        call sum
        lw   t0, 0(sp)
        add  a0, a0, t0
        lw   ra, 4(sp)
        addi sp, sp, 8
sum_done:
        ret

double: add  a0, a0, a0
        ret
