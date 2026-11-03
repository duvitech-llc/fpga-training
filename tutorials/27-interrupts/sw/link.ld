/* The linker script: where each part of a C program goes in the system's memory.
 *
 * The map is Tutorial 26's, in rtl/soc_map.vh. The only memory is the RAM, 64 KiB
 * from address 0, and the core starts at 0. So everything goes in RAM, in this
 * order:
 *
 *   0x0000  .text     crt0's _start first, then all the code
 *           .rodata   constants, such as string literals
 *           .data     variables with a starting value
 *           .sdata    small ones, reached through gp
 *           .bss      variables that start at 0, cleared by crt0. Not in the
 *                     binary: it holds nothing but zeros
 *           ...       free
 *   0xFFFF  the stack, growing down from __stack_top = 0x10000
 *
 * The devices are not in here. A program reaches them through pointers to fixed
 * addresses, in sw/soc.h.
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
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

    /* Notes for debuggers and the like, which the RAM does not need. */
    /DISCARD/ : { *(.comment) *(.note .note.*) *(.eh_frame .eh_frame_hdr) }
}
