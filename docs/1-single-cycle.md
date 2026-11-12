# Step 1: single-cycle core

Every instruction fetches, decodes, executes, accesses memory and writes back in one clock, so CPI is 1 by construction. It is the reference the pipeline is checked against.

## Design

| File | Role |
|---|---|
| `rtl/decoder.sv` | Opcode to control signals and the sign-extended immediate; anything outside RV32I raises `illegal` and does nothing |
| `rtl/alu.sv` | Ten operations selected by `{funct7[5], funct3}`, so R-type bits pass straight through |
| `rtl/regfile.sv` | 31 registers, two combinational reads, one clocked write; x0 reads zero |
| `rtl/core.sv` | PC, operand muxes, branch compare, jump target, load and store alignment |

- ALU input a is rs1, the PC (`auipc`) or zero (`lui`); input b is rs2 or the immediate.
- `jal` and branches add the immediate to the PC; `jalr` adds it to rs1 and clears bit 0. Jumps write PC+4.
- Stores replicate the byte or halfword onto every lane and let `dmem_wstrb` pick the lanes. Loads select the byte or halfword with `dmem_addr[1:0]` and sign- or zero-extend it.
- `fence` is a no-op: one hart, and memory is not cached.
- In simulation an assertion stops on any illegal instruction the core executes.

## Hazards

None: nothing overlaps.

## Measured

- `make sim`: 40/40 rv32ui tests pass.
- Yosys Cyclone V mapping: 743 ALUTs, 225 carry cells and 32 flip-flops (the PC); the register file maps to 64 MLAB cells.
- Fmax is not meaningful yet: the critical path runs through the combinational test memory outside the core. It is measured in step 5, with memory in block RAM.
