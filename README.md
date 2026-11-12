# RV32I Pipeline

A five-stage pipelined RISC-V (RV32I) core in SystemVerilog, verified against the official riscv-tests suite and closed for timing on a Cyclone V FPGA (DE1-SoC).

| Step | Design | Tests | Measured |
|---|---|---|---|
| 1 | [Single-cycle RV32I reference](docs/1-single-cycle.md) | 40/40 | CPI 1 |
| 2 | [Five stages: forwarding, load-use stall, branch flush](docs/2-pipeline.md) | 40/40 | CPI 1.115 (all tests) |
| 3 | [Branch prediction (BTB, 2-bit counters)](docs/3-branch-prediction.md) | 40/40 | C benchmark CPI 1.303 → 1.049 |
| 4 | [Instruction cache, 10-cycle memory](docs/4-icache.md) | 40/40 | Benchmark hit rate 99.6%, CPI 1.102 |
| 5 | [Block RAM and timing closure on the DE1-SoC](docs/5-de1-soc.md) | 40/40 | Fmax 67.61 MHz, 1,822 ALMs |
| 6 | [Data cache: set-associative, write-back, LRU](docs/6-dcache.md) | 40/40 | Benchmark CPI 1.105 → 1.120 at 10-cycle memory |
| 7 | [Data cache checked against cache-sim, access by access](docs/7-crosscheck.md) | 40/40 | 0 of 52,528 events differ over 7 geometries |

![CPI stack per step](docs/img/cpi-stack.png)

*Where the cycles go: every cycle that retired nothing, by cause, rerun per step (`scripts/cpi_stack.py`).*

## Why it matters

Each step adds one microarchitectural mechanism and measures what it buys: CPI from simulated cycle counts, Fmax from Quartus timing analysis. Flush cost, prediction accuracy, miss penalty and critical path are measured, not estimated.

## Quick start

Requires Icarus Verilog, Verilator 5, Yosys and, for the FPGA build, Quartus Prime Lite with Cyclone V support.

```sh
git clone --recursive https://github.com/NicholasUnruh/rv32i-pipeline
cd rv32i-pipeline
make toolchain   # xPack RISC-V GCC into ~/.local/opt
make check       # all riscv-tests, C benchmark, Verilator lint, Yosys Cyclone V mapping
make build       # Quartus compile for the DE1-SoC; fails on missed timing
make program     # load the bitstream over USB-Blaster
```

## Repository layout

| Path | Contents |
|---|---|
| `rtl/` | Core, decoder, ALU, register file, BTB, instruction and data caches |
| `tb/` | Testbench with memory model and CPI counters; probe for traces |
| `fpga/` | DE1-SoC top, dual-port block RAM, seven-segment driver |
| `quartus/` | Project, pin assignments, timing constraints |
| `tests/env/` | Bare-metal environment for riscv-tests (no CSRs or traps) |
| `tests/bench/` | C benchmark for CPI comparisons |
| `scripts/` | Hex conversion, Verilator measurement runner, Quartus gate, figures in `docs/img/` |
| `results/` | Measured CSVs behind the step notes |
| `third_party/riscv-tests/` | Official test suite (unmodified submodule) |
| `docs/` | One design note per step, core interface; `docs/journal/` records the process |

## Results and verification

- Every step passes all 40 rv32ui tests (`fence_i` and `ma_data` excluded: no Zifencei, no misaligned access).
- Each step's design, hazards and measurements are in its note, linked from the table above.
- Core ports and test protocol: [docs/interface.md](docs/interface.md).
- Quartus build (step 5 core): all corners meet timing at 50 MHz (setup +5.209 ns, hold +0.126 ns); the board top passes the benchmark in simulation in 37,914 cycles (CPI 1.073).

## Limitations

- The bitstream meets timing but has not yet run on the board.
- RV32I only: no CSRs, traps, `ecall`/`ebreak`, `fence.i` or misaligned access.
- The instruction cache is not coherent with stores.

## Related projects

- [cache-sim](https://github.com/NicholasUnruh/cache-sim): trace-driven cache simulator; step 7 checks this core's data cache against it access by access.
- [cuda-gemm](https://github.com/NicholasUnruh/cuda-gemm): GEMM in CUDA from a naive kernel to tensor cores.
- [openroad-chip-lab](https://github.com/NicholasUnruh/openroad-chip-lab) and [bf16-fpga](https://github.com/NicholasUnruh/bf16-fpga): a BF16 training tile from RTL to layout, then on the same DE1-SoC.
- Portfolio: https://genwealth.world

## License

MIT. See [LICENSE](LICENSE).
