# The boot ROM. Reset starts here, at 0x0010_0000, and a program may jump to
# 0x0010_0004, reboot, with a flash address in a0, to boot another image.
#
# It reads an image from SPI flash, copies it into RAM, checks its CRC-32, and
# jumps to it. The image starts at flash address 0 with a header of five
# little-endian words, then the payload:
#
#   +0   magic        0x544F4F42, "BOOT" in ASCII
#   +4   length       bytes of payload, at least 1
#   +8   load address where the payload goes in RAM
#   +12  entry point  where to jump once it is there
#   +16  CRC-32       of the payload bytes, as zlib.crc32 computes it
#   +20  the payload
#
# tools/mkflash.py writes images in this format.
#
# Everything is one flash read command, 0x03 with the image's address: the header, then
# the payload, in one stream. If the header is wrong, or the CRC does not match,
# it prints one line over the UART and stops with ebreak:
#
#   boot: bad magic      the first word is not "BOOT": no image, or a wrong one
#   boot: bad length     length is 0, or the payload would not fit in RAM
#   boot: bad CRC        the payload is not what was written
#
# There is no stack and no RAM of its own: every value lives in a register, and
# a subroutine that calls another saves ra in s11. The code only uses jumps and
# branches relative to pc, and la, so it runs at any address, although asm.py
# assembles it from 0.
#
# This file does not stand alone. make puts a line before it with SPI_DIV, the
# divider, and one of the getbyte_*.asm files after it, with the routine that
# reads one byte. That gives one ROM per divider and per way of reading.
#
# Tutorial 31 changed three things, marked "Tutorial 31" below: the image may
# start anywhere in the flash, at a0 from the entry at 0x0010_0004; the cache is
# invalidated before the jump, since the copy wrote code behind its back; and
# only the streaming getbyte is used. A program that jumps to reboot must turn
# its interrupts off and leave the DMA engine idle first: the copy overwrites its
# handler, and a STREAM read holds the bus for a whole byte.

        .equ   RAM_END, 0x00010000      # the first address past RAM
        .equ   UART, 0x10000000         # status at +0, data at +4
        .equ   TX_READY, 1              # bit 0 of the UART's status

        .equ   SPI, 0x10004000
        .equ   SPI_CTRL, 0x0            # divider, CPOL, CPHA
        .equ   SPI_TX, 0x4              # a byte to send. Bit 8: CS rises after it
        .equ   SPI_RX, 0x8              # the last byte received
        .equ   SPI_STATUS, 0xC
        .equ   SPI_STREAM, 0x10         # the next byte, stalling until it is in
        .equ   RX_FULL, 2               # STATUS bit 1
        .equ   BUSY, 4                  # STATUS bit 2: a byte waits, or CS is low
        .equ   LAST, 0x100

        .equ   CRC, 0x10005000
        .equ   CRC_CLEAR, 0x0
        .equ   CRC_DATA, 0x4
        .equ   CRC_RESULT, 0x8

        .equ   CACHECTL, 0x10007000     # Tutorial 31: +0 INVALIDATE

        .equ   MAGIC, 0x544F4F42
        .equ   READ, 0x03               # the flash's read command

# Tutorial 31: reset comes in here, with image address 0. A program that wants
# another image jumps to reboot, at 0x0010_0004, with its address in a0.
start:  li     a0, 0
reboot: mv     s9, a0                   # the image's flash address
        li     s0, SPI
        li     s1, CRC
        li     t0, SPI_DIV              # mode 0
        sw     t0, SPI_CTRL(s0)
        sw     zero, CRC_CLEAR(s1)      # a new message: the CRC slave keeps its
                                        # state across a jump back here, not only reset

# The read command, then the address in s9, most significant byte first.
        li     a0, READ
        call   send
        srli   a0, s9, 16               # Tutorial 31: the address from s9
        andi   a0, a0, 0xFF
        call   send
        srli   a0, s9, 8
        andi   a0, a0, 0xFF
        call   send
        andi   a0, s9, 0xFF
        call   send

# The header, five words.
        call   getword
        mv     s2, a0                   # magic
        call   getword
        mv     s3, a0                   # length
        call   getword
        mv     s4, a0                   # load address
        call   getword
        mv     s5, a0                   # entry point
        call   getword
        mv     s6, a0                   # CRC-32

        li     t0, MAGIC
        la     a0, bad_magic
        bne    s2, t0, fail_read
        la     a0, bad_length
        beqz   s3, fail_read
        li     t0, RAM_END
        bgeu   s4, t0, fail_read        # load address past RAM
        sub    t0, t0, s4               # room from there to the end of RAM
        bltu   t0, s3, fail_read

# The payload: each byte to RAM, and to the CRC slave.
        mv     s7, s4                   # where the next byte goes
        add    s8, s4, s3               # where the payload ends
copy:   call   getbyte
        sb     a0, 0(s7)
        sb     a0, CRC_DATA(s1)
        addi   s7, s7, 1
        bne    s7, s8, copy
        call   finish

        lw     t0, CRC_RESULT(s1)
        la     a0, bad_crc
        bne    t0, s6, fail
        li     t0, CACHECTL             # Tutorial 31: the cache may hold old
        sw     zero, 0(t0)              # words of the RAM just written
        jr     s5                       # boot

# Ends the read, then prints the message at a0 and stops.
fail_read:
        call   finish
fail:   call   puts
halt:   ebreak

# ----- Subroutines. Each uses only the registers it names. -----

# Sends the byte in a0 and waits for the byte that comes back at the same time,
# which it throws away. Uses t0.
send:   sw     a0, SPI_TX(s0)
swait:  lw     t0, SPI_STATUS(s0)
        andi   t0, t0, RX_FULL
        beqz   t0, swait
        lw     t0, SPI_RX(s0)
        ret

# Reads four bytes into a0, the first one lowest. Uses a1 and s11.
getword:
        mv     s11, ra
        call   getbyte
        mv     a1, a0
        call   getbyte
        slli   a0, a0, 8
        or     a1, a1, a0
        call   getbyte
        slli   a0, a0, 16
        or     a1, a1, a0
        call   getbyte
        slli   a0, a0, 24
        or     a0, a1, a0
        jr     s11

# Ends the read: one more byte, with last, so that CS rises after it. Waits
# until it has, then empties RX and clears overrun, so the next read starts
# clean. Uses t0.
finish: li     t0, LAST
        sw     t0, SPI_TX(s0)
fwait:  lw     t0, SPI_STATUS(s0)
        andi   t0, t0, BUSY
        bnez   t0, fwait
        lw     t0, SPI_RX(s0)
        sw     zero, SPI_STATUS(s0)
        ret

# Sends the zero-terminated string at a0, from hello.asm. Uses t0, t1 and t2,
# and leaves a0 at the zero.
puts:   li     t0, UART
pnext:  lbu    t2, 0(a0)
        beqz   t2, pdone
pwait:  lw     t1, 0(t0)
        andi   t1, t1, TX_READY
        beqz   t1, pwait
        sb     t2, 4(t0)
        addi   a0, a0, 1
        j      pnext
pdone:  ret

# The messages, little-endian, four bytes to a word.
bad_magic:  .word 0x746F6F62, 0x6162203A, 0x616D2064, 0x0A636967, 0x00000000  # "boot: bad magic\n"
bad_length: .word 0x746F6F62, 0x6162203A, 0x656C2064, 0x6874676E, 0x0000000A  # "boot: bad length\n"
bad_crc:    .word 0x746F6F62, 0x6162203A, 0x52432064, 0x00000A43              # "boot: bad CRC\n"
