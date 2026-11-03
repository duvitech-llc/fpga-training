# What the CPU sees while the DMA engine runs: three loops, each timed three ways.
#
# The loops are Tutorial 26's cpi.asm loops, 100 iterations of three instructions:
#
#   alu    addi, addi, bnez         no data access, but every fetch is on the bus
#   ram    lw from RAM, addi, bnez
#   gpio   lw from GPIO, addi, bnez a load that never touches RAM
#
# and the DMA engine is doing one of three things meanwhile:
#
#   idle   nothing
#   copy   a 4 KiB word copy from RAM to RAM, as fast as it can
#   uart   printing a line through the UART, paced by the transmitter
#
# Each run reads cycles and the DMA engine's LEN before and after the loop, so it
# knows its own clocks and the bytes the DMA engine moved in the same window. The
# DMA engine must still be busy at the end of the loop, or the window would not
# be shared all the way: STATUS is read to check. The results are kept in RAM and
# printed at the end, since the UART is in use during the uart runs:
#
#   alu  idle 913 clocks, dma moved 0 bytes
#   alu  copy C clocks, dma moved B bytes, dma busy
#   ...
#
# Ends with ebreak.

        .equ   UART, 0x10000000
        .equ   UART_DATA, 0x10000004
        .equ   GPIO, 0x10001000
        .equ   COUNTERS, 0x10002000
        .equ   DMA, 0x10005000          # SRC +0, DST +4, LEN +8, CTRL +C, STATUS +10
        .equ   START, 1
        .equ   UART_GO, 29              # START + DST_FIXED 4 + BYTES 8 + PACE 16
        .equ   BUSY, 1
        .equ   TX_READY, 1
        .equ   N, 100
        .equ   COPY_SRC, 0x8000
        .equ   COPY_DST, 0x9000
        .equ   COPY_LEN, 4096
        .equ   LINE_LEN, 23

start:  li     sp, 0x10000
        li     s0, COUNTERS
        li     s1, DMA
        la     s10, results             # 9 results of 3 words: clocks, bytes, STATUS
        li     s11, 0                   # condition: 0 idle, 1 copy, 2 uart

conds:  mv     a0, s11
        call   dma_go
        call   run_alu
        call   dma_wait
        mv     a0, s11
        call   dma_go
        call   run_ram
        call   dma_wait
        mv     a0, s11
        call   dma_go
        call   run_gpio
        call   dma_wait
        addi   s11, s11, 1
        li     t0, 3
        bne    s11, t0, conds

        # Print the nine results.
        la     s10, results
        li     s11, 0                   # which result, 0 to 8
        li     s7, 0                    # condition of this result
        li     s6, 0                    # loop of this result
show:   la     a0, names_loop
        slli   t0, s6, 3                # each name is 8 bytes
        add    a0, a0, t0
        call   puts
        la     a0, names_cond
        slli   t0, s7, 3
        add    a0, a0, t0
        call   puts
        lw     a0, 0(s10)
        call   print_dec
        la     a0, text_clocks
        call   puts
        la     a0, text_moved
        call   puts
        lw     a0, 4(s10)
        call   print_dec
        la     a0, text_bytes
        call   puts
        lw     t0, 8(s10)
        andi   t0, t0, BUSY
        beqz   t0, show_nl
        la     a0, text_busy
        call   puts
        j      show_next
show_nl:
        li     a0, 10
        call   putc
show_next:
        addi   s10, s10, 12
        addi   s6, s6, 1
        li     t0, 3
        bne    s6, t0, show_same
        li     s6, 0
        addi   s7, s7, 1
show_same:
        addi   s11, s11, 1
        li     t0, 9
        bne    s11, t0, show
        ebreak

# Starts the DMA engine for condition a0: 0 nothing, 1 the copy, 2 the UART line.
dma_go: beqz   a0, go_done
        li     t0, 1
        bne    a0, t0, go_uart
        li     t0, COPY_SRC
        sw     t0, 0(s1)
        li     t0, COPY_DST
        sw     t0, 4(s1)
        li     t0, COPY_LEN
        sw     t0, 8(s1)
        li     t0, START
        sw     t0, 12(s1)
        ret
go_uart:
        la     t0, line
        sw     t0, 0(s1)
        li     t0, UART_DATA
        sw     t0, 4(s1)
        li     t0, LINE_LEN
        sw     t0, 8(s1)
        li     t0, UART_GO
        sw     t0, 12(s1)
go_done:
        ret

# Waits until BUSY clears.
dma_wait:
        lw     t1, 16(s1)
        andi   t1, t1, BUSY
        bnez   t1, dma_wait
        ret

# The three loops. Each reads cycles and LEN before and after, then STATUS, and
# stores clocks, bytes moved and STATUS at s10, which moves on by 12.
run_alu:
        lw     s2, 0(s0)                # cycles
        lw     s3, 8(s1)                # LEN
        li     t2, N
loop_alu:
        addi   t1, t1, 1
        addi   t2, t2, -1
        bnez   t2, loop_alu
        j      record

run_ram:
        la     s9, data
        lw     s2, 0(s0)
        lw     s3, 8(s1)
        li     t2, N
loop_ram:
        lw     t1, 0(s9)
        addi   t2, t2, -1
        bnez   t2, loop_ram
        j      record

run_gpio:
        li     s9, GPIO
        lw     s2, 0(s0)
        lw     s3, 8(s1)
        li     t2, N
loop_gpio:
        lw     t1, 0(s9)
        addi   t2, t2, -1
        bnez   t2, loop_gpio
        j      record

record: lw     s4, 0(s0)                # cycles
        lw     s5, 8(s1)                # LEN
        lw     t0, 16(s1)               # STATUS
        sub    t1, s4, s2
        sw     t1, 0(s10)
        sub    t1, s3, s5
        sw     t1, 4(s10)
        sw     t0, 8(s10)
        addi   s10, s10, 12
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

# Each name is 8 bytes, zero-terminated, so the n-th is at 8 n.
names_loop:  .word 0x20756C61, 0x00000020       # "alu  "
             .word 0x206D6172, 0x00000020       # "ram  "
             .word 0x6F697067, 0x00000020       # "gpio "
names_cond:  .word 0x656C6469, 0x00000020       # "idle "
             .word 0x79706F63, 0x00000020       # "copy "
             .word 0x74726175, 0x00000020       # "uart "
text_clocks: .word 0x6F6C6320, 0x2C736B63, 0x00000020                       # " clocks, "
text_moved:  .word 0x20616D64, 0x65766F6D, 0x00002064                       # "dma moved "
text_bytes:  .word 0x74796220, 0x00007365                                   # " bytes"
text_busy:   .word 0x6D64202C, 0x75622061, 0x000A7973                       # ", dma busy\n"
# "[the DMA printed this]\n", 23 bytes, for the uart runs.
line:        .word 0x6568745B, 0x414D4420, 0x69727020, 0x6465746E, 0x69687420, 0x000A5D73
data:        .word 0
results:     .word 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
             .word 0, 0, 0, 0, 0, 0, 0, 0, 0
digits:      .word 0, 0, 0
digits_end:  .word 0
