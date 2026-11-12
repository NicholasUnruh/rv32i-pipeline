# Step 6: data cache

## Design

`rtl/dcache.sv`: set-associative, write-back, write-allocate, LRU. This step used 1 KB (32 sets, 2 ways, 16-byte lines); sets, ways and line size are parameters of `core`, and step 8 chose 8 KB (64 sets, 2 ways, 64-byte lines) as the default from Embench.

- **Lookup**: as in the instruction cache, the tag and data arrays are block RAM read with EX's address, so MEM compares tags a clock later and a hit costs nothing.
- **Stores move from EX to MEM**: a store must know it hits before it writes. A store that hits writes on the edge where the next instruction reads the arrays, so if that next access is to the same word, the cache merges the store's bytes into the read data (a one-entry bypass).
- **Miss**: MEM raises `dstall` and every stage holds. The cache writes back a dirty victim, requests the line, writes its words as they arrive, reads the arrays again, and the access hits. With latency L and W words per line a miss stalls L + W + 3 cycles, plus W + 1 to write back a dirty victim.
- **Replacement**: each set keeps an LRU rank per way; the victim is the first invalid way, else the least recently used. This is the rule cache-sim uses, so the two can be compared access for access.
- **Memory port** (`docs/interface.md`): line reads work like the instruction side; writes are posted, one word per cycle.
- **I/O**: `tohost` moved to `0x4000_0000`. A write-back cache would keep the result store from reaching memory, so addresses below `0x8000_0000` bypass the cache as posted word writes.

## Bug found by the benchmark

The first version sent bubbles into WB during a miss. All 40 riscv-tests passed; the C benchmark never finished. The instruction frozen in EX had been forwarding a result from WB, and that result disappeared when WB emptied. Now WB holds too: it repeats its register write, which is harmless, and `retire` counts it once.

## Measured

`scripts/measure.py` under Verilator, results in `results/6-dcache/`. "Without" is the step-5 core, whose single-cycle data RAM acts as a perfect cache.

Benchmark CPI against memory latency:

| L | 1 | 2 | 5 | 10 | 20 |
|---|---|---|---|---|---|
| Without data cache | 1.073 | 1.077 | 1.087 | 1.105 | 1.141 |
| 1 KB, 2-way | 1.081 | 1.085 | 1.098 | 1.120 | 1.164 |

The benchmark touches less than 1 KB of data, so all 40 misses are cold and the cache costs 0.015 CPI at L = 10. Geometry at L = 10:

| Sets × ways × line | Size | Misses | Writebacks | CPI |
|---|---|---|---|---|
| 2 × 1 × 8 B | 16 B | 2,291 | 1,643 | 2.199 |
| 2 × 2 × 8 B | 32 B | 2,080 | 1,549 | 2.101 |
| 2 × 1 × 16 B | 32 B | 1,379 | 922 | 1.881 |
| 8 × 2 × 16 B | 256 B | 220 | 149 | 1.226 |
| 4 × 4 × 32 B | 512 B | 26 | 10 | 1.120 |
| 32 × 2 × 16 B | 1 KB | 40 | 0 | 1.120 |

The tiny caches exist to exercise writebacks: the benchmark's checksum and all 40 tests pass in every row, and at L = 1 too. riscv-tests: 810 data accesses, 98.1% hits, total CPI 4.127 (4.126 before).

## Limitations

- The C benchmark is too small to stress the cache; step 7 runs real workloads.
- No I/O loads, and at least 2 sets.
