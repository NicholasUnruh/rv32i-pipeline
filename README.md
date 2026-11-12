# RV32I Pipeline

A five-stage pipelined RISC-V (RV32I) core in SystemVerilog, verified against the official riscv-tests suite and built for a Cyclone V FPGA (DE1-SoC).

| Step | Design | Tests | Measured |
|---|---|---|---|
| 1 | [Single-cycle RV32I reference](docs/1-single-cycle.md) | 40/40 | CPI 1 |
| 2 | [Five stages: forwarding, load-use stall, branch flush](docs/2-pipeline.md) | 40/40 | CPI 1.115 (all tests) |
| 3 | [Branch prediction (BTB, 2-bit counters)](docs/3-branch-prediction.md) | 40/40 | C benchmark CPI 1.303 → 1.049 |
| 4 | [Instruction cache, 10-cycle memory](docs/4-icache.md) | 40/40 | Benchmark hit rate 99.6%, CPI 1.102 |
| 5 | [Block RAM and timing closure on the DE1-SoC](docs/5-de1-soc.md) | 40/40 | Fmax 67.6 MHz, 1,822 ALMs; not yet run on the board |

Each step must pass all 40 rv32ui tests (`fence_i` and `ma_data` excluded).

```sh
make toolchain   # xPack RISC-V GCC into ~/.local/opt
make tests       # build the riscv-tests programs
make sim         # run every test; cycles and CPI per test
make check       # sim, bench, Verilator lint, Yosys Cyclone V mapping
make build       # Quartus compile for the DE1-SoC; fails on missed timing
```

Core ports and the test protocol: [docs/interface.md](docs/interface.md).
