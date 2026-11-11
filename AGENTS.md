# RV32I Pipeline

- Goal: a portfolio project for CPU-architecture internships. The owner writes the RTL; agents review, explain, debug and extend the harness. Ask before writing core RTL.
- `rtl/core.sv` is the core; `docs/interface.md` is its contract with `tb/tb.sv`. Change both together.
- `third_party/riscv-tests` is an unmodified submodule. Test glue lives in `tests/env/` (no CSRs or traps: pass and fail write `tohost`).
- Run `make check` before committing. Once `rtl/core.sv` exists, `check` must also run `sim lint synth`.
- A step is done only when `make sim` passes every test. CPI and Fmax come from measurement (`build/sim.log`, Quartus timing), never estimates.
- Keep the README at or below 200 words and each `docs/` file at or below 500.
