// Startup for the C benchmark: zero .bss, set the stack at the top of memory, call main.
  .section .text.init
  .globl _start
_start:
  la t0, __bss_start
  la t1, __bss_end
1:
  bgeu t0, t1, 2f
  sw zero, 0(t0)
  addi t0, t0, 4
  j 1b
2:
  li sp, 0x8000ff00
  call main
3:
  j 3b

  .section .tohost, "aw", @progbits
  .globl tohost
tohost:
  .word 0
