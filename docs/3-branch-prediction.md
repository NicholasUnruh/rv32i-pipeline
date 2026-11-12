# Step 3: branch prediction

## Design

`rtl/btb.sv` is a 64-entry direct-mapped branch target buffer indexed by `pc[7:2]` with a 24-bit tag, a 32-bit target and a 2-bit saturating counter per entry.

- IF looks up its PC. A tag hit with counter 2 or 3 fetches the stored target next; otherwise PC+4. The guess (direction and target) travels with the instruction to EX.
- EX resolves every instruction and redirects if the direction differs, or if it is taken to a different target. Any instruction is checked, so a stale entry can never send fetch astray. The redirect still costs 2 cycles; a correct prediction costs none.
- EX updates the entry of each branch and jump: a hit steps the counter toward the outcome and stores the target when taken. A taken miss allocates at weakly not-taken (1), so a branch is predicted taken only after its second taken run. `jalr` returns predict the last target seen.

The allocation policy was measured both ways. Allocating at weakly taken (2) gives the same benchmark CPI (1.048) but costs the riscv-tests an extra misprediction on each two-trip bypass loop (CPI 1.115 to 1.173).

## Benchmark

`tests/bench/bench.c` (`make bench`): insertion sort of 96 values, 64 binary searches, popcount loops and recursive `fib(14)`, built with `-O2` and checked against the host's result.

| | Step 2 (predict not taken) | Step 3 (BTB) |
|---|---|---|
| Cycles | 46,012 | 37,050 |
| Instructions | 35,324 | 35,324 |
| CPI | 1.303 | 1.049 |
| Branches and jumps | 9,113 | 9,113 |
| Redirects | 5,295 | 814 |
| Prediction accuracy | 58.1% | 91.1% |

The riscv-tests total stays at CPI 1.115: almost every branch there runs once or twice.

Yosys: 1,389 ALUTs, 266 carry cells, 502 flip-flops and 230 MLAB cells (the BTB arrays).
