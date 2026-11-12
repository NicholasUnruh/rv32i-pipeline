# Taking the data-cache stall off the critical path

## Question

Step 9's critical path ran from the MEM-stage address through the data cache's hit logic and `stall` into the BTB's counter enables. If the BTB applies its update a cycle later, how much Fmax does that buy, and what does the late update cost in cycles?

## Concept

**Retiming by adding a stage.** A path that crosses several blocks in one cycle can be cut by registering a signal partway along it. The logic after the new register then has a whole cycle of its own. The price is that its effect arrives a cycle later.

**Why a late update is safe here.** The BTB only predicts. EX checks every prediction against the real outcome, so a stale entry can cost a misprediction but never a wrong result. Delaying the update changes only lookups in the one cycle before it lands.

## What I tried

- Registered the BTB's update inputs (valid, PC, hit, outcome, target) in `rtl/btb.sv` and applied them from the register.
- Ran the 40 tests, the C benchmark and the 14 Embench programs, and repeated the cache-sim crosscheck.
- Compiled in Quartus under the same constraints as step 9 and asked for the worst setup paths.
- Fmax fell, so compiled both cores again at fitter seeds 1 to 4 with `scripts/fmax_seeds.py` to separate the design from placement.

## Output

Quartus, default seed:

```
Logic utilization (in ALMs) : 2,449 / 32,070 ( 8 % )
Total registers : 2469
Total RAM Blocks : 142 / 397 ( 36 % )
; 75.14 MHz ; 75.14 MHz       ; CLOCK_50   ;      ;
```

The worst setup paths (slack, from, to):

```
; 6.691 ; core:cpu|ex_mem.result[31]    ; ram:memory|...|ram_block1a47~porta_address_reg3
; 6.721 ; core:cpu|ex_mem.mem_write     ; ram:memory|...|ram_block1a47~porta_address_reg3
; 7.052 ; core:cpu|dcache:dc|state.IDLE ; ram:memory|...|ram_block1a47~porta_address_reg3
; 7.181 ; core:cpu|mem_wb.rd[0]         ; core:cpu|id_ex.rs2_val[19]
```

None of the 20 worst paths touches the BTB.

`fmax_seeds.py 1 2 3 4` on the step-9 core, then on the registered update (the RAM instance name shortened):

```
seed,alms,registers,m10k,fmax_mhz,setup_slack_ns,worst_from,worst_to
1,2437,2366,142,81.47,7.725,core:cpu|ex_mem.result[10],core:cpu|btb:predictor|counters[44][1]
2,2441,2358,142,75.05,6.676,core:cpu|ex_mem.reg_write~DUPLICATE,core:cpu|btb:predictor|counters[27][0]
3,2432,2395,142,74.57,6.589,core:cpu|id_ex.rs2[2],core:cpu|ex_mem.result[0]
4,2432,2378,142,71.94,6.099,core:cpu|mem_wb.rd[4],core:cpu|id_ex.rs1_val[17]

seed,alms,registers,m10k,fmax_mhz,setup_slack_ns,worst_from,worst_to
1,2449,2469,142,75.14,6.691,core:cpu|ex_mem.result[31],ram:memory|...|ram_block1a47~porta_address_reg3
2,2459,2489,142,72.21,6.151,core:cpu|mem_wb.rd[2]~DUPLICATE,core:cpu|id_ex.rs2_val[8]
3,2449,2485,142,72.9,6.282,core:cpu|ex_mem.reg_write,core:cpu|ex_mem.result[0]
4,2449,2461,142,73.77,6.444,core:cpu|ex_mem.rd[4],core:cpu|dcache:dc|bypass
```

C benchmark: 39,300 → 39,306 cycles. The 40 tests and 14 Embench programs: the same cycles. Crosscheck: 0 differences.

## Result

- The BTB path is gone: the counters were the worst endpoint at two of four seeds before and at none after.
- Finding: Fmax didn't rise. The mean over four seeds went from 75.76 to 73.51 MHz, inside the 9.5 MHz spread of step 9's own seeds. Paths through forwarding, the EX result and the D-cache bypass are just as long, so cutting one exposes the next.
- The 81.47 MHz reported in step 9 was seed 1, the best of the four. A single compile can't measure a timing change this small.
- The late update costs 6 cycles on the C benchmark and none elsewhere, plus about 100 registers.

## Next

Report Fmax as a spread over seeds from now on. Raising it further would mean pipelining the forwarding and branch-resolve paths together, which costs CPI; at 50 MHz on the board there is no need. The I-cache, 73.6% of Embench's lost cycles, is the next step.
