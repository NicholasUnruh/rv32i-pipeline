// Bare-metal test environment for riscv-tests on a core with no CSRs or traps.
// Pass writes 1 to tohost; fail writes (test number << 1) | 1. Both then spin.
#ifndef RV32I_PIPELINE_RISCV_TEST_H
#define RV32I_PIPELINE_RISCV_TEST_H

#define RVTEST_RV32U .macro init; .endm
#define RVTEST_RV64U RVTEST_RV32U

#define TESTNUM gp

#define RVTEST_CODE_BEGIN \
  .section .text.init;    \
  .globl _start;          \
_start:                   \
  li TESTNUM, 0;

#define RVTEST_CODE_END unimp

#define RVTEST_PASS   \
  fence;              \
  li a0, 1;           \
  la t0, tohost;      \
  sw a0, 0(t0);       \
1: j 1b;

// A failure with TESTNUM 0 would look like a pass, so it spins until timeout.
#define RVTEST_FAIL      \
  fence;                 \
1: beqz TESTNUM, 1b;     \
  slli a0, TESTNUM, 1;   \
  ori a0, a0, 1;         \
  la t0, tohost;         \
  sw a0, 0(t0);          \
2: j 2b;

#define EXTRA_DATA

#define RVTEST_DATA_BEGIN                        \
  EXTRA_DATA                                     \
  .pushsection .tohost, "aw", @progbits;         \
  .align 4; .global tohost; tohost: .word 0;     \
  .popsection;                                   \
  .align 4; .global begin_signature; begin_signature:

#define RVTEST_DATA_END .align 4; .global end_signature; end_signature:

#endif
