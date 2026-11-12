# Backlog

## In flight
## Queued
- [ ] de1_soc_run - Program the DE1-SoC (`make build program`) and confirm LEDR[0] and the HEX cycle count (37,914 = 0x0941A in simulation); held: no board connected on 2026-11-11 (repo: rv32i-pipeline) (queued 2026-11-11)
## Done
- [x] de1_soc - Step 5: synchronous block RAM and Quartus timing closure (67.6 MHz) for the DE1-SoC (repo: rv32i-pipeline) (done 2026-11-11)
- [x] icache - Step 4: direct-mapped instruction cache in front of multi-cycle memory; hit rate and CPI (repo: rv32i-pipeline) (done 2026-11-11)
- [x] branch_predict - Step 3: BTB and 2-bit counters; CPI before and after on a small C benchmark (repo: rv32i-pipeline) (done 2026-11-11)
- [x] pipeline5 - Step 2: IF/ID/EX/MEM/WB with forwarding, load-use stall and branch flush; report cycles and CPI per test (repo: rv32i-pipeline) (done 2026-11-11)
- [x] single_cycle - Step 1: single-cycle RV32I in rtl/core.sv passing all 40 rv32ui tests; add sim, lint and synth to `make check` (repo: rv32i-pipeline) (done 2026-11-11)
- [x] scaffold - riscv-tests submodule, bare-metal test env, testbench, toolchain and gate (repo: rv32i-pipeline) (done 2026-11-11)
  Harness checked with a throwaway core outside the repo: 40/40 pass, an injected sub bug fails test 3, an idle core times out.
