/* Memory map for the architecture tests: everything in one RAM from address 0,
   where the core starts. The code comes first, so the entry point is at 0. */
OUTPUT_ARCH("riscv")
ENTRY(rvtest_entry_point)

SECTIONS
{
    . = 0x0;
    .text.init : { *(.text.init) }
    .text      : { *(.text) }
    . = ALIGN(16);
    .data      : { *(.data) }
    .bss       : { *(.bss) }
}
