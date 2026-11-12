/* 64 KB of memory at 0x80000000; tohost is the last 16 bytes' first word. */
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
  . = 0x8000FFF0;
  .tohost : { *(.tohost) }
}
