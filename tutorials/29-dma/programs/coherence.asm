# Reading the destination before the copy is done gets old data.
#
# The DMA engine copies 256 bytes, 64 words, from a filled source to a
# destination that holds zeros. Straight after START the CPU:
#
#   - reads the last word of the destination, before the DMA engine has got there
#   - writes C0FFEE00 to the second-last word of the source, also not yet copied
#
# Then it waits for BUSY to clear, reads both words of the destination again, and
# prints:
#
#   before done: 00000000
#   after done:  XXXXXXXX                  the source's last word
#   written during the copy: c0ffee00      the copy took the CPU's new value
#
# Nothing in the hardware orders the CPU's accesses against the DMA engine's.
# Only the program can, by waiting for DONE.

        .equ   UART, 0x10000000
        .equ   DMA, 0x10005000          # SRC +0, DST +4, LEN +8, CTRL +C, STATUS +10
        .equ   START, 1
        .equ   BUSY, 1
        .equ   TX_READY, 1
        .equ   SRC_AREA, 0x4000
        .equ   DST_AREA, 0x6000
        .equ   WORDS, 64

start:  li     sp, 0x10000
        li     s1, DMA

        li     a0, SRC_AREA
        li     t0, 0x12345678
        li     t1, 0x9E3779B9
        li     t2, WORDS
fill:   sw     t0, 0(a0)
        add    t0, t0, t1
        addi   a0, a0, 4
        addi   t2, t2, -1
        bnez   t2, fill

        li     s2, SRC_AREA
        li     s3, DST_AREA
        sw     s2, 0(s1)
        sw     s3, 4(s1)
        li     t0, 256
        sw     t0, 8(s1)
        li     t0, START
        li     t3, 0xC0FFEE00
        sw     t0, 12(s1)               # go
        lw     s4, 252(s3)              # the destination's last word, too early
        sw     t3, 248(s2)              # the source's second-last word, changed

wait:   lw     t1, 16(s1)
        andi   t1, t1, BUSY
        bnez   t1, wait
        lw     s5, 252(s3)              # the last word again, after the copy
        lw     s6, 248(s3)              # the word the CPU changed in the source

        la     a0, text_before
        call   puts
        mv     a0, s4
        call   print_hex
        li     a0, 10
        call   putc
        la     a0, text_after
        call   puts
        mv     a0, s5
        call   print_hex
        li     a0, 10
        call   putc
        la     a0, text_during
        call   puts
        mv     a0, s6
        call   print_hex
        li     a0, 10
        call   putc
        ebreak

# Prints a0 as 8 hex digits. Uses t3 and putc.
print_hex:
        addi   sp, sp, -16
        sw     ra, 0(sp)
        sw     s8, 4(sp)
        sw     s9, 8(sp)
        mv     s8, a0
        li     s9, 8
ph_next:
        srli   a0, s8, 28
        slli   s8, s8, 4
        li     t3, 10
        blt    a0, t3, ph_digit
        addi   a0, a0, 39               # 'a' is 97, which is 48 + 39 + 10
ph_digit:
        addi   a0, a0, 48               # '0'
        call   putc
        addi   s9, s9, -1
        bnez   s9, ph_next
        lw     ra, 0(sp)
        lw     s8, 4(sp)
        lw     s9, 8(sp)
        addi   sp, sp, 16
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

text_before: .word 0x6F666562, 0x64206572, 0x3A656E6F, 0x00000020           # "before done: "
text_after:  .word 0x65746661, 0x6F642072, 0x203A656E, 0x00000020           # "after done:  "
text_during: .word 0x74697277, 0x206E6574, 0x69727564, 0x7420676E, 0x63206568, 0x3A79706F
             .word 0x00000020                                               # "written during the copy: "
