# Measures its own clocks per instruction with the counters peripheral, for six
# loops of N iterations, and prints one line for each through the UART:
#
#   alu     C clocks, I instructions, CPI x.yy
#
# Each loop is three instructions: one under test, then addi and bnez. Only the
# first differs: an addi, a load or store to RAM, a load from the GPIO register,
# and a load or store to the AXI4-Lite block.
#
# The counters are read at the clock edge that accepts each read. cycles is read
# first and instret second, at the start and at the end, so both windows hold the
# same number of instructions: the 3 N of the loop and three more, two counter
# reads and the li. So the CPI is a little higher than the loop's alone.
#
# There is no divide instruction in RV32I, so divu below divides one bit at a
# time. Ends with ebreak.

        .equ   UART, 0x10000000
        .equ   GPIO, 0x10001000
        .equ   COUNTERS, 0x10002000     # cycles at +0, instret at +4
        .equ   AXIL, 0x20000000
        .equ   TX_READY, 1
        .equ   N, 100

start:  li     sp, 0x10000              # the stack grows down from the top of RAM
        li     s0, COUNTERS

        # ALU instructions only
        la     a0, name_alu
        call   puts
        lw     s2, 0(s0)                # cycles, start
        lw     s3, 4(s0)                # instret, start
        li     t2, N
loop1:  addi   t1, t1, 1
        addi   t2, t2, -1
        bnez   t2, loop1
        lw     s4, 0(s0)                # cycles, end
        lw     s5, 4(s0)                # instret, end
        call   report

        # Loads from RAM
        la     a0, name_ram_r
        call   puts
        la     s1, data
        lw     s2, 0(s0)
        lw     s3, 4(s0)
        li     t2, N
loop2:  lw     t1, 0(s1)
        addi   t2, t2, -1
        bnez   t2, loop2
        lw     s4, 0(s0)
        lw     s5, 4(s0)
        call   report

        # Stores to RAM
        la     a0, name_ram_w
        call   puts
        la     s1, data
        lw     s2, 0(s0)
        lw     s3, 4(s0)
        li     t2, N
loop3:  sw     t2, 0(s1)
        addi   t2, t2, -1
        bnez   t2, loop3
        lw     s4, 0(s0)
        lw     s5, 4(s0)
        call   report

        # Loads from the GPIO register
        la     a0, name_gpio_r
        call   puts
        li     s1, GPIO
        lw     s2, 0(s0)
        lw     s3, 4(s0)
        li     t2, N
loop4:  lw     t1, 0(s1)
        addi   t2, t2, -1
        bnez   t2, loop4
        lw     s4, 0(s0)
        lw     s5, 4(s0)
        call   report

        # Loads from the AXI4-Lite block, through the bridge
        la     a0, name_axi_r
        call   puts
        li     s1, AXIL
        lw     s2, 0(s0)
        lw     s3, 4(s0)
        li     t2, N
loop5:  lw     t1, 0(s1)
        addi   t2, t2, -1
        bnez   t2, loop5
        lw     s4, 0(s0)
        lw     s5, 4(s0)
        call   report

        # Stores to the AXI4-Lite block
        la     a0, name_axi_w
        call   puts
        li     s1, AXIL
        lw     s2, 0(s0)
        lw     s3, 4(s0)
        li     t2, N
loop6:  sw     t2, 0(s1)
        addi   t2, t2, -1
        bnez   t2, loop6
        lw     s4, 0(s0)
        lw     s5, 4(s0)
        call   report

        ebreak

# Prints " C clocks, I instructions, CPI x.yy" and a newline, where C is s4 - s2
# and I is s5 - s3. CPI is 100 * C / I, rounded down, with a point put in.
report: addi   sp, sp, -16
        sw     ra, 0(sp)
        sw     s6, 4(sp)
        sw     s7, 8(sp)
        sub    s6, s4, s2               # clocks
        sub    s7, s5, s3               # instructions
        mv     a0, s6
        call   print_dec
        la     a0, text_clocks
        call   puts
        mv     a0, s7
        call   print_dec
        la     a0, text_cpi
        call   puts
        slli   t0, s6, 6                # 100 * C is 64 C + 32 C + 4 C
        slli   t1, s6, 5
        add    t0, t0, t1
        slli   t1, s6, 2
        add    a0, t0, t1
        mv     a1, s7
        call   divu                     # a0 = 100 * C / I
        li     a1, 100
        call   divu                     # a0 = the whole part, a1 = hundredths
        mv     s6, a1
        call   print_dec
        li     a0, 46                   # '.'
        call   putc
        mv     a0, s6
        li     a1, 10
        call   divu                     # a0 = tenths, a1 = hundredths
        mv     s7, a1
        addi   a0, a0, 48               # '0'
        call   putc
        addi   a0, s7, 48
        call   putc
        li     a0, 10                   # newline
        call   putc
        lw     ra, 0(sp)
        lw     s6, 4(sp)
        lw     s7, 8(sp)
        addi   sp, sp, 16
        ret

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
# Restoring division, one bit per pass. Uses t0 to t3.
divu:   li     t0, 0                    # quotient
        li     t1, 0                    # remainder
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

name_alu:    .word 0x20756C61, 0x00202020       # "alu    "
name_ram_r:  .word 0x206D6172, 0x00202072       # "ram r  "
name_ram_w:  .word 0x206D6172, 0x00202077       # "ram w  "
name_gpio_r: .word 0x6F697067, 0x00207220       # "gpio r "
name_axi_r:  .word 0x20697861, 0x00202072       # "axi r  "
name_axi_w:  .word 0x20697861, 0x00202077       # "axi w  "
text_clocks: .word 0x6F6C6320, 0x2C736B63, 0x00000020                       # " clocks, "
text_cpi:    .word 0x736E6920, 0x63757274, 0x6E6F6974, 0x43202C73, 0x00204950 # " instructions, CPI "
data:        .word 0
digits:      .word 0, 0, 0
digits_end:  .word 0
