// Startup for Embench: zero .bss, set the stack at the top of memory, call main,
// then report its result to tohost: main returns 0 when the output verified,
// which becomes 1 (pass); anything else becomes 3 (fail in test 1).
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
  li sp, 0x80010000
  call main
  snez a0, a0
  slli a0, a0, 1
  ori a0, a0, 1
  la t0, tohost
  sw a0, 0(t0)
3:
  j 3b

  .section .tohost, "aw", @progbits
  .globl tohost
tohost:
  .word 0
