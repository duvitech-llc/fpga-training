# Checks exactly when an interrupt is taken, and what it does to mstatus.
#
#   1. The timer is made due: mtimecmp = 0. MTIP shows in mip.
#   2. MIE on, but MTIE off in mie: no interrupt.
#   3. MTIE on, but MIE off: no interrupt.
#   4. Both on, with csrsi. The interrupt must be taken before the very next
#      instruction, "after1": mepc must be its address, and it must still run
#      once, after mret. MIE must be back on after mret, and MPIE set.
#   5. Both lines at once. The program prints ">", the testbench sends a byte, and
#      the timer is made due again. With both enabled, the external interrupt must
#      come first, then the timer, both with mepc at "after2".
#
# The handler logs mcause, mepc, and mstatus as it sees it: MIE off, MPIE on.
# It clears the source: a new mtimecmp for the timer, a read of the UART's data
# for the external line. At the end the log is compared with "expect", and the
# program prints "irq ok" or "irq FAIL", then stops with ebreak.

        .equ   UART, 0x10000000
        .equ   TX_READY, 1
        .equ   RX_WAITING, 2
        .equ   TIMER, 0x10003000        # +0 mtime, +8 mtimecmp, low word first
        .equ   MTIP, 0x80
        .equ   MEIP, 0x800
        .equ   LOG, 0x800

start:  la     t0, handler
        csrw   mtvec, t0
        li     s0, LOG
        li     s1, TIMER
        li     s2, UART
        li     s5, 0                    # how many times after1 and after2 ran

# 1. mtimecmp = 0, low word to all ones first, as the spec suggests.
        li     t0, -1
        sw     t0, 8(s1)
        sw     zero, 12(s1)
        sw     zero, 8(s1)
wait1:  csrr   t0, mip
        andi   t0, t0, MTIP
        beqz   t0, wait1

# 2. Pending, MIE on, but not enabled in mie.
        csrsi  mstatus, 8
        nop
        nop
        csrci  mstatus, 8

# 3. Enabled in mie, but MIE off.
        li     t0, MTIP
        csrs   mie, t0
        nop
        nop

# 4. Both. Taken before after1 runs.
        csrsi  mstatus, 8
after1: addi   s5, s5, 1
        csrr   t0, mstatus
        li     t1, 0x1888               # MPP 11, MPIE 1, MIE 1
        bne    t0, t1, fail
        csrci  mstatus, 8

# 5. Both lines. Wait for the testbench's byte with interrupts off.
        li     a0, 0x3E                 # ">"
        call   putc
wait2:  lw     t0, 0(s2)
        andi   t0, t0, RX_WAITING
        beqz   t0, wait2
        sw     zero, 12(s1)             # mtimecmp = 0 again: low half is all ones
        sw     zero, 8(s1)
wait3:  csrr   t0, mip
        andi   t0, t0, MTIP
        beqz   t0, wait3
        li     t0, MEIP
        csrs   mie, t0
        csrsi  mstatus, 8
after2: addi   s5, s5, 1
        csrci  mstatus, 8

        li     t0, 2
        bne    s5, t0, fail
# Compare the log with the table.
        la     s3, expect
        la     s4, expect_end
        li     s6, LOG
compare: lw    t0, 0(s3)
        lw     t1, 0(s6)
        bne    t0, t1, fail
        addi   s3, s3, 4
        addi   s6, s6, 4
        bne    s3, s4, compare
        bne    s6, s0, fail
        la     a0, ok
        call   puts
        ebreak

fail:   la     a0, bad
        call   puts
        ebreak

# mcause, mepc, mstatus in the handler: MPP 11, MPIE 1, MIE 0.
expect: .word  0x80000007, after1, 0x1880
        .word  0x8000000B, after2, 0x1880
        .word  0x80000007, after2, 0x1880
expect_end:

# The handler. It uses t3 to t6, and s0 to s2, which it does not change.
handler: csrr  t4, mcause
        csrr   t5, mepc
        csrr   t6, mstatus
        sw     t4, 0(s0)
        sw     t5, 4(s0)
        sw     t6, 8(s0)
        addi   s0, s0, 12
        li     t3, 0x8000000B
        beq    t4, t3, external
        li     t3, -1                   # the timer: mtimecmp to all ones, never due
        sw     t3, 8(s1)
        sw     t3, 12(s1)
        mret
external: lw   t3, 4(s2)                # take the byte: the UART lowers its line
        mret

# Sends the byte in a0. Uses t0 and t1.
putc:   li     t0, UART
pwait:  lw     t1, 0(t0)
        andi   t1, t1, TX_READY
        beqz   t1, pwait
        sb     a0, 4(t0)
        ret

# Sends the zero-terminated string at a0. Uses t0, t1, t2 and a0.
puts:   mv     t2, ra
        mv     a1, a0
pnext:  lbu    a0, 0(a1)
        beqz   a0, pdone
        call   putc
        addi   a1, a1, 1
        j      pnext
pdone:  mv     ra, t2
        ret

# "irq ok\n" and "irq FAIL\n"
ok:     .word  0x20717269, 0x000A6B6F
bad:    .word  0x20717269, 0x4C494146, 0x0000000A
