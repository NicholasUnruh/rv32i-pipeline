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

**Fmax rose by 20%.** Step 5's critical path ran from the forwarding compare through the address adder into the data RAM's byte enables. Step 6 moved stores to MEM, so byte enables now come from a register and that path is gone. The new critical path, 12.0 ns, starts at the MEM-stage address register: the valid-bit mux over 64 sets, the way-hit compare, the cache's `stall`, and the BTB's update enable (`!dstall`) into its counters. Cutting it would mean registering the BTB update a cycle later.

The board still runs from the 50 MHz oscillator; there is no PLL.

## Simulation of the board top

The board top, simulated in Icarus with its RAM, passes the C benchmark in 38,113 cycles (CPI 1.079), against 37,914 with step 5's core.

`make check` maps the core with Yosys 0.33: 2,946 ALUTs, 1,160 flip-flops, 38 M10K. Its ABC pass hits an internal assertion (`giaMfs.c:386`), and the run still completes. Yosys 0.70 maps it without the assertion: 2,986 ALUTs, the same flip-flops and M10K. The gate stays on 0.33.

## Limitations

The bitstream meets timing but has not run on the board.
