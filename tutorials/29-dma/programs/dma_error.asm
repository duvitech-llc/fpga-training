# What the CPU sees when the DMA engine's copy goes wrong.
#
# Three copies that fail, each followed by a line with STATUS, SRC, DST and LEN:
#
#   write error   from RAM to 0x30000000, where nothing is. The read works, the
#                 write gets err from the interconnect.
#   read error    from 0x30000000 to RAM. The read gets err.
#   misaligned    a word copy from an odd address. START refuses it at once,
#                 and nothing goes on the bus.
#
# None of these stops the CPU: the err went to the DMA engine, not to the core.
# Then the CPU loads from 0x30000000 itself, and that is an access fault, as in
# Tutorial 26: the system stops with trap cause 5.

        .equ   UART, 0x10000000
        .equ   DMA, 0x10005000          # SRC +0, DST +4, LEN +8, CTRL +C, STATUS +10
        .equ   START, 1
        .equ   BUSY, 1
        .equ   TX_READY, 1
        .equ   NOWHERE, 0x30000000

start:  li     sp, 0x10000
        li     s1, DMA

        # A write to nowhere.
        li     a0, 0x4000
        li     a1, NOWHERE
        call   copy16
        call   wait
        la     a0, text_write
        call   report

        # A read from nowhere.
        li     a0, NOWHERE
        li     a1, 0x6000
        call   copy16
        call   wait
        la     a0, text_read
        call   report

        # A misaligned word copy. STATUS is read straight after START, without
        # waiting, and ERROR is already set.
        li     a0, 0x4002
        li     a1, 0x6000
        call   copy16
        la     a0, text_misaligned
        call   report

        la     a0, text_cpu
        call   puts
        li     t0, NOWHERE
        lw     t1, 0(t0)                # access fault: the system stops here
        ebreak                          # never reached

# Starts a word copy of 16 bytes from a0 to a1.
copy16: sw     a0, 0(s1)
        sw     a1, 4(s1)
        li     t0, 16
        sw     t0, 8(s1)
        li     t0, START
        sw     t0, 12(s1)
        ret

# Waits until BUSY clears.
wait:   lw     t1, 16(s1)
        andi   t1, t1, BUSY
        bnez   t1, wait
        ret

# Prints the label at a0, then "XXXXXXXX src XXXXXXXX dst XXXXXXXX len XXXXXXXX".
report: addi   sp, sp, -16
        sw     ra, 0(sp)
        call   puts
        lw     a0, 16(s1)
        call   print_hex
        la     a0, text_src
        call   puts
        lw     a0, 0(s1)
        call   print_hex
        la     a0, text_dst
        call   puts
        lw     a0, 4(s1)
        call   print_hex
        la     a0, text_len
        call   puts
        lw     a0, 8(s1)
        call   print_hex
        li     a0, 10
        call   putc
        lw     ra, 0(sp)
        addi   sp, sp, 16
        ret

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

text_write:      .word 0x74697277, 0x72652065, 0x3A726F72, 0x74732020, 0x73757461, 0x00000020
                 # "write error:  status "
text_read:       .word 0x64616572, 0x72726520, 0x203A726F, 0x74732020, 0x73757461, 0x00000020
                 # "read error:   status "
text_misaligned: .word 0x6173696D, 0x6E67696C, 0x203A6465, 0x74732020, 0x73757461, 0x00000020
                 # "misaligned:   status "
text_src:        .word 0x63727320, 0x00000020                               # " src "
text_dst:        .word 0x74736420, 0x00000020                               # " dst "
text_len:        .word 0x6E656C20, 0x00000020                               # " len "
text_cpu:        .word 0x20776F6E, 0x20656874, 0x20757063, 0x64616F6C, 0x72662073
                 .word 0x33206D6F, 0x30303030, 0x0A303030, 0x00000000
                 # "now the cpu loads from 30000000\n"
