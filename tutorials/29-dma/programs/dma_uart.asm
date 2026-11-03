# The DMA engine prints a line through the UART while the CPU counts.
#
# The copy is one byte at a time (BYTES), from a string in RAM (SRC moves) to the
# UART's data register (DST_FIXED), waiting for the transmitter before each byte
# (PACE). The CPU loops, reading STATUS, until BUSY clears, then prints:
#
#   dma printed 40 bytes in C clocks
#   the cpu looped M times
#
# and stops with ebreak.

        .equ   UART, 0x10000000         # status at +0, data at +4
        .equ   UART_DATA, 0x10000004
        .equ   COUNTERS, 0x10002000
        .equ   DMA, 0x10005000          # SRC +0, DST +4, LEN +8, CTRL +C, STATUS +10
        .equ   GO, 29                   # START 1 + DST_FIXED 4 + BYTES 8 + PACE 16
        .equ   BUSY, 1
        .equ   TX_READY, 1
        .equ   LENGTH, 40

start:  li     sp, 0x10000
        li     s0, COUNTERS
        li     s1, DMA

        la     t0, message
        sw     t0, 0(s1)                # SRC
        li     t0, UART_DATA
        sw     t0, 4(s1)                # DST
        li     t0, LENGTH
        sw     t0, 8(s1)                # LEN
        li     t0, GO
        li     s3, 0                    # loops
        lw     s4, 0(s0)                # cycles, start
        sw     t0, 12(s1)               # CTRL: go
count:  addi   s3, s3, 1
        lw     t1, 16(s1)               # STATUS
        andi   t1, t1, BUSY
        bnez   t1, count
        lw     s5, 0(s0)                # cycles, end

        la     a0, text_printed
        call   puts
        li     a0, LENGTH
        call   print_dec
        la     a0, text_bytes_in
        call   puts
        sub    a0, s5, s4
        call   print_dec
        la     a0, text_clocks
        call   puts
        la     a0, text_looped
        call   puts
        mv     a0, s3
        call   print_dec
        la     a0, text_times
        call   puts
        ebreak

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

# "Sent by the DMA, while the CPU counted.\n", 40 bytes. The DMA engine needs no
# terminating zero: it stops after LEN bytes.
message:       .word 0x746E6553, 0x20796220, 0x20656874, 0x2C414D44, 0x69687720
               .word 0x7420656C, 0x43206568, 0x63205550, 0x746E756F, 0x0A2E6465
text_printed:  .word 0x20616D64, 0x6E697270, 0x20646574, 0x00000000         # "dma printed "
text_bytes_in: .word 0x74796220, 0x69207365, 0x0000206E                     # " bytes in "
text_clocks:   .word 0x6F6C6320, 0x0A736B63, 0x00000000                     # " clocks\n"
text_looped:   .word 0x20656874, 0x20757063, 0x706F6F6C, 0x00206465         # "the cpu looped "
text_times:    .word 0x6D697420, 0x000A7365                                 # " times\n"
digits:        .word 0, 0, 0
digits_end:    .word 0
