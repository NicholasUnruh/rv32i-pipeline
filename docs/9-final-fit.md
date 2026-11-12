# Step 9: the final core on the DE1-SoC

The step-8 core (8 KB, 2-way, 64 B-line data cache) compiled with `make build` (Quartus Prime 25.1 Lite, Cyclone V 5CSEMA5F31C6). The board's data port refills 64 B lines through `fpga/line_fill.sv`.

## Quartus had never compiled the data cache

Steps 6 to 8 were checked with Verilator, Icarus and Yosys. Quartus, the first time it saw `rtl/dcache.sv`, rejected the per-way generate loop: Quartus Standard parses only the SystemVerilog-2005 form, with a separately declared `genvar` and explicit `generate ... endgenerate`. A minimal one-module project reproduced it. The loop was rewritten in that form, with no change to behaviour: the 40 tests, the C benchmark and the cache-sim crosscheck give the same counts as before.

## Measured

| | Step 5 core | Final core |
|---|---|---|
| ALMs | 1,822 (6%) | 2,437 (8%) |
| Registers | 1,826 | 2,366 |
| M10K blocks | 132 | 142 |
| Fmax, slow 85 °C | 67.61 MHz | 81.47 MHz |
| Setup slack at 50 MHz | +5.209 ns | +7.725 ns |
| Worst hold slack | +0.126 ns | +0.135 ns |

All four corners meet timing. The ten extra M10K blocks are the data cache: each way holds 1,024 words of 32 bits (four blocks), plus one tag block per way.

**Fmax rose by 20%.** Step 5's critical path ran from the forwarding compare through the address adder into the data RAM's byte enables. Step 6 moved stores to MEM, so byte enables now come from a register and that path is gone. The new critical path, 12.0 ns, starts at the MEM-stage address register: the valid-bit mux over 64 sets, the way-hit compare, the cache's `stall`, and the BTB's update enable (`!dstall`) into its counters. This is one compile at the default seed; the section below repeats it at four.

The board still runs from the 50 MHz oscillator; there is no PLL.

## Registering the BTB update

`rtl/btb.sv` now applies its update one cycle after EX resolves the branch, so `stall` ends at a flip-flop. `scripts/fmax_seeds.py` compiled both cores at fitter seeds 1 to 4 (1 is the default):

| Fmax, slow 85 °C | Seed 1 | 2 | 3 | 4 | Mean |
|---|---|---|---|---|---|
| Update in EX | 81.47 | 75.05 | 74.57 | 71.94 | 75.76 MHz |
| Registered update | 75.14 | 72.21 | 72.90 | 73.77 | 73.51 MHz |

ALMs rise by about 15 and registers by about 100; M10K stays at 142.

**Finding: it buys no Fmax.** The BTB counters were the worst endpoint at two seeds before and at none after. What is left are paths of the same length: MEM/WB's destination register into the ID/EX operands, EX into `ex_mem.result`, the MEM stage into the D-cache bypass and, at seed 1 (12.8 ns of data delay), the MEM address through the I/O decode into the board RAM. Step 9's 81.47 MHz was a lucky placement; its four seeds span 9.5 MHz. Raising Fmax means shortening all of these paths.

The late update costs the C benchmark 6 cycles (39,300 → 39,306): a lookup in the cycle before an update lands sees the old entry. The 40 tests and the 14 Embench programs take the same cycles, and the cache-sim crosscheck still finds 0 differences.

## Simulation of the board top

The board top, simulated in Icarus with its RAM, passes the C benchmark in 38,113 cycles (CPI 1.079), against 37,914 with step 5's core, and in 38,119 with the registered BTB update.

`make check` maps the core with Yosys 0.33: 2,946 ALUTs, 1,160 flip-flops, 38 M10K. Its ABC pass hits an internal assertion (`giaMfs.c:386`), and the run still completes. Yosys 0.70 maps it without the assertion: 2,986 ALUTs, the same flip-flops and M10K. The gate stays on 0.33. With the registered BTB update, 0.33 gives 2,972 ALUTs and 1,225 flip-flops.

## Limitations

The bitstream meets timing but has not run on the board.
