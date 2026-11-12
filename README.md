# RV32I Pipeline

A five-stage pipelined RISC-V (RV32I) core in SystemVerilog, verified against the official riscv-tests suite and built for a Cyclone V FPGA (DE1-SoC).

| Step | Design | Tests | Measured |
|---|---|---|---|
| 1 | [Single-cycle RV32I reference](docs/1-single-cycle.md) | 40/40 | CPI 1 |
| 2 | [Five stages: forwarding, load-use stall, branch flush](docs/2-pipeline.md) | 40/40 | CPI 1.115 (all tests) |
| 3 | Branch prediction (BTB, 2-bit counters) | — | — |
| 4 | Instruction cache | — | — |
| 5 | Block RAM, timing closure and a program on the board | — | — |

Each step must pass all 40 rv32ui tests (`fence_i` and `ma_data` excluded). Fmax comes from Quartus once memory is on-chip (step 5).

```sh
make toolchain   # xPack RISC-V GCC into ~/.local/opt
make tests       # build the riscv-tests programs
make sim         # run every test on rtl/core.sv
make check       # sim, Verilator lint, Yosys Cyclone V mapping
```

Core ports and the test protocol: [docs/interface.md](docs/interface.md).
