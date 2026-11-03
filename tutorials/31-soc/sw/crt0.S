# The start of every C program: what runs between reset and main.
#
# The core starts at address 0 with every register 0 and no stack. C needs a
# stack, a global pointer, and every variable without an initial value set to 0.
# This file does those, calls main, and ends the program with ebreak. The
# testbenches stop at that ebreak, and read main's return value in a0.
#
# There is no copy of .data here. The whole program, .data included, is loaded
# into RAM by $readmemh before reset, at the addresses where it runs. A program
# kept in flash would have to copy .data into RAM first: Tutorial 28 does that.

        .section .text.start, "ax"
        .global _start
_start:
        # The global pointer. The linker may turn an access near __global_pointer$
        # into one instruction relative to gp. That must not happen to this la,
        # which sets gp itself, hence norelax.
        .option push
        .option norelax
        la      gp, __global_pointer$
        .option pop

        # The stack grows down from the top of RAM. The ABI wants it 16-byte aligned.
        la      sp, __stack_top

        # Until main sets its own, every trap goes to _trap_default.
        la      t0, _trap_default
        csrw    mtvec, t0

        # Clear .bss, a word at a time. The linker script aligns both ends to 4.
        la      t0, __bss_start
        la      t1, __bss_end
1:      bgeu    t0, t1, 2f
        sw      zero, 0(t0)
        addi    t0, t0, 4
        j       1b
2:
        call    main

        # main returned. a0 holds its return value: 0 means the program passed.
        .global _exit
_exit:
        ebreak
        j       _exit

# A trap nobody expected: an exception in a program without a handler, say. a0
# gets mcause and a1 mepc, for the testbench to print, then ebreak stops it. That
# ebreak is not the one at _exit, so the testbench can tell the two apart.
        .balign 4
        .global _trap_default
_trap_default:
        csrr    a0, mcause
        csrr    a1, mepc
        ebreak
        j       _trap_default
