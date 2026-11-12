/* 64 KB of memory at 0x80000000. tohost is an uncached I/O word at 0x40000000;
   NOLOAD keeps it out of the memory image. */
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text.init : { *(.text.init) }
  .text : { *(.text) }
  .rodata : { *(.rodata*) *(.srodata*) }
  .data : { *(.data*) *(.sdata*) }
  .bss : {
    . = ALIGN(4); __bss_start = .;
    *(.bss*) *(.sbss*)
    . = ALIGN(4); __bss_end = .;
  }
  .tohost 0x40000000 (NOLOAD) : { *(.tohost) }
}
