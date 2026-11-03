# Copies 1 KiB twice, once with the CPU and once with the DMA engine, and times
# both with the counters peripheral. Prints:
#
#   cpu copy: 1024 bytes in C clocks
#   dma copy: 1024 bytes in C clocks
#   copies match
#
# Then stops with ebreak. The source is filled with a pattern first. While the
# DMA engine copies, the CPU polls its STATUS register, so both masters are on
# the bus at once and the DMA time includes that sharing.

        .equ   UART, 0x10000000
        .equ   COUNTERS, 0x10002000     # cycles at +0
        .equ   DMA, 0x10005000          # SRC +0, DST +4, LEN +8, CTRL +C, STATUS +10
        .equ   START, 1
        .equ   BUSY, 1
        .equ   TX_READY, 1
        .equ   SRC_AREA, 0x4000
        .equ   CPU_AREA, 0x5000
        .equ   DMA_AREA, 0x6000
        .equ   WORDS, 256
        .equ   BYTES, 1024              # 4 times WORDS
        .equ   BYTE_AREA, 0x7000
        .equ   BYTES_MODE, 8            # CTRL bit 3

start:  li     sp, 0x10000
        li     s0, COUNTERS
        li     s1, DMA

        # The source: 256 words of a pattern that never repeats a word.
        li     a0, SRC_AREA
        li     t0, 0x12345678
        li     t1, 0x9E3779B9
        li     t2, WORDS
fill:   sw     t0, 0(a0)
        add    t0, t0, t1
        addi   a0, a0, 4
        addi   t2, t2, -1
        bnez   t2, fill

        # The CPU copies, one word per pass: a load, a store, and four more.
        li     a0, SRC_AREA
        li     a1, CPU_AREA
        li     t2, WORDS
        lw     s2, 0(s0)                # cycles, start
copy:   lw     t0, 0(a0)
        sw     t0, 0(a1)
        addi   a0, a0, 4
        addi   a1, a1, 4
        addi   t2, t2, -1
        bnez   t2, copy
        lw     s3, 0(s0)                # cycles, end

        # The DMA engine copies, and the CPU polls STATUS until BUSY clears.
        li     t0, SRC_AREA
        sw     t0, 0(s1)                # SRC
        li     t0, DMA_AREA
        sw     t0, 4(s1)                # DST
        li     t0, BYTES
        sw     t0, 8(s1)                # LEN, in bytes
        li     t0, START                # whole words, both addresses moving
        lw     s4, 0(s0)                # cycles, start
        sw     t0, 12(s1)               # CTRL: go
poll:   lw     t1, 16(s1)               # STATUS
        andi   t1, t1, BUSY
        bnez   t1, poll
        lw     s5, 0(s0)                # cycles, end

        # Report.
        la     a0, text_cpu
        call   puts
        sub    s6, s3, s2
        call   report
        la     a0, text_dma
        call   puts
        sub    s6, s5, s4
        call   report

        # Check both copies, word by word.
        li     a0, SRC_AREA
        li     a1, CPU_AREA
        li     a2, DMA_AREA
        li     t2, WORDS
check:  lw     t0, 0(a0)
        lw     t1, 0(a1)
        bne    t0, t1, differ
        lw     t1, 0(a2)
        bne    t0, t1, differ
        addi   a0, a0, 4
        addi   a1, a1, 4
        addi   a2, a2, 4
        addi   t2, t2, -1
        bnez   t2, check
        la     a0, text_match
        call   puts

        # A byte copy: 13 bytes, from an odd address to another, with BYTES set.
        li     t0, SRC_AREA + 1
        sw     t0, 0(s1)
        li     t0, BYTE_AREA + 3
        sw     t0, 4(s1)
        li     t0, 13
        sw     t0, 8(s1)
        li     t0, START + BYTES_MODE
        sw     t0, 12(s1)
bpoll:  lw     t1, 16(s1)
        andi   t1, t1, BUSY
        bnez   t1, bpoll
        la     a0, text_bytes
        call   puts
        li     a0, SRC_AREA + 1
        li     a1, BYTE_AREA + 3
        li     t2, 13
bcheck: lbu    t0, 0(a0)
        lbu    t1, 0(a1)
        bne    t0, t1, differ
        addi   a0, a0, 1
        addi   a1, a1, 1
        addi   t2, t2, -1
        bnez   t2, bcheck
        lbu    t1, 0(a1)                # the byte after the copy is untouched
        bnez   t1, differ
        lbu    t1, -14(a1)              # and so is the byte before it
        bnez   t1, differ
        la     a0, text_ok
        call   puts
        ebreak
differ: la     a0, text_differ
        call   puts
        ecall                           # a different stop, so the testbench sees it

# Prints "1024 bytes in C clocks" and a newline, with C in s6.
report: addi   sp, sp, -16
        sw     ra, 0(sp)
        li     a0, BYTES
        call   print_dec
        la     a0, text_bytes_in
        call   puts
        mv     a0, s6
        call   print_dec
        la     a0, text_clocks
        call   puts
        lw     ra, 0(sp)
        addi   sp, sp, 16
        ret

# ----- The same routines as cpi.asm in Tutorial 26 -----

# Prints a0 as an unsigned decimal number. Builds the digits backwards in digits.
print_dec:
        addi   sp, sp, -16
        sw     ra, 0(sp)
        sw     s8, 4(sp)
        sw     s9, 8(sp)
        la     s8, digits_end
        mv     s9, s8
pd_div: li     a1, 10
        call   divu
        addi   a1, a1, 48
        addi   s8, s8, -1
        sb     a1, 0(s8)
        bnez   a0, pd_div
pd_out: lbu    a0, 0(s8)
        call   putc
        addi   s8, s8, 1
        bne    s8, s9, pd_out
        lw     ra, 0(sp)
        lw     s8, 4(sp)
        lw     s9, 8(sp)
        addi   sp, sp, 16
        ret

# Unsigned division: a0 / a1. Returns the quotient in a0 and the remainder in a1.
divu:   li     t0, 0
        li     t1, 0
        li     t2, 32
dv_bit: slli   t1, t1, 1
        srli   t3, a0, 31
        or     t1, t1, t3
        slli   a0, a0, 1
        slli   t0, t0, 1
        bltu   t1, a1, dv_skip
        sub    t1, t1, a1
        ori    t0, t0, 1
dv_skip:
        addi   t2, t2, -1
        bnez   t2, dv_bit
        mv     a0, t0
        mv     a1, t1
        ret

# Sends the zero-terminated string at a0. Uses t0, t1 and t2.
puts:   li     t0, UART
ps_next:
        lbu    t2, 0(a0)
        beqz   t2, ps_done
ps_wait:
        lw     t1, 0(t0)
        andi   t1, t1, TX_READY
        beqz   t1, ps_wait
        sb     t2, 4(t0)
        addi   a0, a0, 1
        j      ps_next
ps_done:
        ret

# Sends the byte in a0. Uses t0 and t1.
putc:   li     t0, UART
pc_wait:
        lw     t1, 0(t0)
        andi   t1, t1, TX_READY
        beqz   t1, pc_wait
        sb     a0, 4(t0)
        ret

text_cpu:      .word 0x20757063, 0x79706F63, 0x0000203A                     # "cpu copy: "
text_dma:      .word 0x20616D64, 0x79706F63, 0x0000203A                     # "dma copy: "
text_bytes_in: .word 0x74796220, 0x69207365, 0x0000206E                     # " bytes in "
text_clocks:   .word 0x6F6C6320, 0x0A736B63, 0x00000000                     # " clocks\n"
text_match:    .word 0x69706F63, 0x6D207365, 0x68637461, 0x0000000A         # "copies match\n"
text_differ:   .word 0x49504F43, 0x44205345, 0x45464649, 0x00000A52         # "COPIES DIFFER\n"
text_bytes:    .word 0x65747962, 0x706F6320, 0x31203A79, 0x79622033, 0x20736574, 0x6D6F7266
               .word 0x30303020, 0x30303430, 0x6F742031, 0x30303020, 0x30303730, 0x00202C33
               # "byte copy: 13 bytes from 00004001 to 00007003, "
text_ok:       .word 0x6374616D, 0x00000A68                                 # "match\n"
digits:        .word 0, 0, 0
digits_end:    .word 0
