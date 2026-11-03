# All six branches, taken and not taken, and the pseudo-branches. -1 and 1 show that
# signed and unsigned compares disagree: -1 < 1, but 0xFFFFFFFF > 1.

        li   a0, -1
        li   a1, 1

        beq  a1, a1, b1
        j    fail
b1:     beq  a0, a1, fail
        bne  a0, a1, b2
        j    fail
b2:     bne  a1, a1, fail
        blt  a0, a1, b3         # signed
        j    fail
b3:     blt  a1, a0, fail
        blt  a1, a1, fail       # equal is not less
        bge  a1, a0, b4
        j    fail
b4:     bge  a0, a1, fail
        bge  a1, a1, b5         # equal is greater or equal
        j    fail
b5:     bltu a1, a0, b6         # unsigned
        j    fail
b6:     bltu a0, a1, fail
        bgeu a0, a1, b7
        j    fail
b7:     bgeu a1, a0, fail

        bgt  a1, a0, p1
        j    fail
p1:     ble  a0, a1, p2
        j    fail
p2:     bgtu a0, a1, p3
        j    fail
p3:     bleu a1, a0, p4
        j    fail
p4:     beqz zero, p5
        j    fail
p5:     bnez a1, p6
        j    fail
p6:     blez a0, p7
        j    fail
p7:     bgez zero, p8
        j    fail
p8:     bltz a0, p9
        j    fail
p9:     bgtz a1, p10
        j    fail
p10:    bgtz a0, fail

        li   t0, 3              # a loop, so a branch goes backwards
back:   addi t0, t0, -1
        bnez t0, back
        ebreak

fail:   ecall
