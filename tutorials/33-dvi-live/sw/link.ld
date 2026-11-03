/* The linker script: where each part of a C program goes in the system's memory.
 *
 * Tutorial 27's script, with a second memory: the flash, read in place through
 * the XIP slave. The map is in rtl/soc_map.vh. Three memories matter to a
 * program here:
 *
 *   BOOT   0x0010_0000, 1 KiB. The boot ROM, in assembly, rom/boot.asm. Not
 *          linked here: it is the same for every program.
 *   RAM    0x0000_0000, 64 KiB. Where the boot ROM copies the program, and where
 *          it runs. Everything goes here except .xip:
 *
 *            0x0000  .text     crt0's _start first, then all the code
 *                    .rodata   constants, such as string literals
 *                    .data     variables with a starting value
 *                    .sdata    small ones, reached through gp
 *                    .bss      variables that start at 0, cleared by crt0
 *                    ...       free
 *            0xFFFF  the stack, growing down from __stack_top = 0x10000
 *
 *   FLASH  0x4000_8000, 16 KiB: flash addresses 0x8000 to 0xBFFF, read in place.
 *          Only .xip goes here: functions marked XIP in sw/soc.h. They run from
 *          the flash, through the instruction cache. The boot ROM does not copy
 *          them, and the CRC in the boot image does not cover them.
 *
 * Why no .data copy. A program that runs from flash keeps its .data in flash,
 * and its startup code must copy .data into RAM before main. Here the boot ROM
 * has already copied the whole RAM image, .data included, to the addresses where
 * it runs. So crt0 stays Tutorial 27's, and .data is linked with its load
 * address equal to its run address. Only code goes in .xip, never variables.
 *
 * The Makefile splits the ELF in two: build/X.ram.bin, everything but .xip, for
 * the boot image, and build/X.xip.bin, .xip alone, written at flash 0x8000.
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    RAM   (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
    FLASH (rx)  : ORIGIN = 0x40008000, LENGTH = 16K
}

SECTIONS
{
    .text : {
        KEEP(*(.text.start))        /* _start must be at address 0 */
        *(.text .text.*)
    } > RAM

    .rodata : ALIGN(4) {
        *(.rodata .rodata.* .srodata .srodata.*)
    } > RAM

    .data : ALIGN(4) {
        *(.data .data.*)
    } > RAM

    /* gp points 0x800 past the start of the small data, so that one 12-bit signed
       offset from gp reaches 4 KiB of it. */
    .sdata : ALIGN(4) {
        __global_pointer$ = . + 0x800;
        *(.sdata .sdata.*)
    } > RAM

    .bss (NOLOAD) : ALIGN(4) {
        __bss_start = .;
        *(.sbss .sbss.* .bss .bss.* COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM

    __stack_top = ORIGIN(RAM) + LENGTH(RAM);

    /* Tutorial 31: code that runs from the flash. */
    .xip : ALIGN(4) {
        __xip_start = .;
        *(.xip.text .xip.text.*)
        . = ALIGN(4);
        __xip_end = .;
    } > FLASH

    /* Notes for debuggers and the like, which the RAM does not need. */
    /DISCARD/ : { *(.comment) *(.note .note.*) *(.eh_frame .eh_frame_hdr) }
}
