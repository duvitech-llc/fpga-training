# Takes one exception of each kind, and checks what the handler saw.
#
# The handler writes four words for each trap to a log at LOG: mcause, mepc,
# mtval, and mstatus as the handler sees it. It then returns to the instruction
# after the one that trapped, by adding 4 to mepc. A fetch fault has no
# instruction to skip, since mepc is the bad address, so the handler returns to
# ra instead: the jump there was a jalr, which set ra.
#
# At the end the log is compared with the table at "expect", and the program
# prints "traps ok" or "traps FAIL". Then ebreak, cause 3, ends it: the
# testbenches stop at the first ebreak, so that cause is tested last.
#
# The words for the illegal instructions in the table come from
# "python3 tools/asm.py programs/traps.asm /dev/null --list".

        .equ   UART, 0x10000000
        .equ   TX_READY, 1
        .equ   NOWHERE, 0x30000000      # nobody's: the bus answers err
        .equ   AXIL_ID, 0x20000010      # AXI4-Lite ID: refuses writes
        .equ   LOG, 0x800

start:  la     t0, handler
        csrw   mtvec, t0
        li     s0, LOG

t_ill:  .word  0x00000000               # 2  illegal: not an instruction
t_ecall: ecall                          # 11 ecall
        li     a0, 0x102
t_lw:   lw     a1, 0(a0)                # 4  misaligned load
t_sh:   sh     a1, 1(zero)              # 6  misaligned store
t_jalr: jalr   zero, 0x102(zero)        # 0  misaligned jump: the jalr itself traps
        li     a0, NOWHERE
t_lf:   lw     a1, 0(a0)                # 5  load access fault
t_sf:   sb     a1, 3(a0)                # 7  store access fault
        li     a0, AXIL_ID
t_ro:   sw     a1, 0(a0)                # 7  store access fault: SLVERR from AXI4-Lite
        li     a0, NOWHERE
t_ff:   jalr   ra, 0(a0)                # the jalr retires. 1, at 0x30000000: fetch fault
t_cyc:  csrr   a1, cycle                # 2  a CSR this core does not have
t_hart: csrw   mhartid, a1              # 2  a write to a read-only CSR
        csrr   a1, mhartid              # reading it is fine: 0
        bnez   a1, fail

# Compare the log with the table, word by word, and check there was nothing more.
        la     s1, expect
        la     s3, expect_end
        li     s2, LOG
compare: lw    t0, 0(s1)
        lw     t1, 0(s2)
        bne    t0, t1, fail
        addi   s1, s1, 4
        addi   s2, s2, 4
        bne    s1, s3, compare
        bne    s2, s0, fail
        la     a0, ok
        call   puts
        ebreak                          # 3  the end

fail:   la     a0, bad
        call   puts
        ebreak

# mcause, mepc, mtval, mstatus. In mstatus, MPP (bits 12:11) is always 11, and
# MIE and MPIE are 0, since interrupts are off all through this program.
expect: .word  2,  t_ill,   0x00000000, 0x1800
        .word  11, t_ecall, 0,          0x1800
        .word  4,  t_lw,    0x102,      0x1800
        .word  6,  t_sh,    1,          0x1800
        .word  0,  t_jalr,  0x102,      0x1800
        .word  5,  t_lf,    0x30000000, 0x1800
        .word  7,  t_sf,    0x30000003, 0x1800
        .word  7,  t_ro,    0x20000010, 0x1800
        .word  1,  NOWHERE, NOWHERE,    0x1800
        .word  2,  t_cyc,   0xC00025F3, 0x1800      # csrr a1, cycle
        .word  2,  t_hart,  0xF1459073, 0x1800      # csrw mhartid, a1
expect_end:

# The handler. It uses t3 to t6 and s0, which nothing else here does.
handler: csrr  t4, mcause
        csrr   t5, mepc
        csrr   t6, mtval
        csrr   t3, mstatus
        sw     t4, 0(s0)
        sw     t5, 4(s0)
        sw     t6, 8(s0)
        sw     t3, 12(s0)
        addi   s0, s0, 16
        li     t3, 1
        beq    t4, t3, back
        addi   t5, t5, 4                # skip the instruction that trapped
        csrw   mepc, t5
        mret
back:   csrw   mepc, ra                 # a fetch fault: back to after the jump
        mret

# Sends the zero-terminated string at a0. Uses t0, t1 and t2.
puts:   li     t0, UART
next:   lbu    t2, 0(a0)
        beqz   t2, done
wait:   lw     t1, 0(t0)
        andi   t1, t1, TX_READY
        beqz   t1, wait
        sb     t2, 4(t0)
        addi   a0, a0, 1
        j      next
done:   ret

# "traps ok\n" and "traps FAIL\n"
ok:     .word  0x70617274, 0x6B6F2073, 0x0000000A
bad:    .word  0x70617274, 0x41462073, 0x000A4C49
