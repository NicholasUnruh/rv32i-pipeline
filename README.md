# RV32I Pipeline

A five-stage pipelined RISC-V (RV32I) core in SystemVerilog, verified against the official riscv-tests suite and built for a Cyclone V FPGA (DE1-SoC).

| Step | Design | Status |
|---|---|---|
| 1 | Single-cycle RV32I reference | — |
| 2 | Five stages: forwarding, load-use stall, branch flush | — |
| 3 | Branch prediction (BTB, 2-bit counters) | — |
| 4 | Instruction cache | — |
| 5 | Block RAM, timing closure and a program on the board | — |

Each step must pass all 40 rv32ui tests (`fence_i` and `ma_data` excluded) and report CPI and Fmax.

```sh
make toolchain   # xPack RISC-V GCC into ~/.local/opt
make tests       # build the riscv-tests programs
make sim         # run every test on rtl/core.sv
make lint synth  # Verilator lint, Yosys Cyclone V mapping
```

Core ports and the test protocol: [docs/interface.md](docs/interface.md).
