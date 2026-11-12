# Step 7: data cache checked against cache-sim

## Method

[cache-sim](https://github.com/NicholasUnruh/cache-sim) is a separate C++ model of the same cache rules. The two should agree on every access; a disagreement is a bug in one of them.

- `+dtrace=<file>`: every cached data access in program order, in cache-sim's trace format (`R <hex>` or `W <hex>`).
- `+devents=<file>`: what the RTL did with each access, in the format of `cachesim --events`: set, tag, hit or miss, the evicted tag (`*` if dirty and written back), and each way's tag afterwards.
- `scripts/crosscheck.py` replays each trace through `cachesim` with the RTL's geometry, compares the access, miss and writeback counts, and diffs the two event files line by line. `make crosscheck CACHESIM=<path>` runs it on the C benchmark and all 40 tests at eight geometries.

Events also check way placement and LRU order, which totals cannot.

## Measured

`results/7-crosscheck/crosscheck.csv`: 328 runs (41 programs × 8 geometries), 60,032 accesses.

| Sets × ways × line | Misses | Writebacks | Event lines that differ |
|---|---|---|---|
| 2 × 1 × 8 B | 2,325 | 1,661 | 0 |
| 2 × 2 × 8 B | 2,104 | 1,552 | 0 |
| 2 × 1 × 16 B | 1,395 | 924 | 0 |
| 8 × 2 × 16 B | 235 | 149 | 0 |
| 8 × 4 × 16 B | 57 | 10 | 0 |
| 4 × 4 × 32 B | 39 | 10 | 0 |
| 32 × 2 × 16 B | 55 | 0 | 0 |
| 64 × 2 × 64 B (default since step 8) | 23 | 0 | 0 |

RTL and cache-sim agree on every count and every event line. The one difference the comparison turned up was in the testbench: Icarus prints an empty string argument as a space, which broke the event format for clean evictions.

## Does the check catch bugs?

`scripts/crosscheck_mutants.sh` injects a replacement bug into a copy of the RTL and runs the check on the C benchmark (`results/7-crosscheck/mutants.csv`):

| Injected bug | Geometry | Misses RTL / sim | Event lines that differ |
|---|---|---|---|
| Fill the last invalid way, not the first | 2 × 2 × 8 B | 2,080 / 2,080 | 6,694 of 6,694 |
| Same | 8 × 4 × 16 B | 42 / 42 | 6,694 of 6,694 |
| A refilled line is not made most recently used | 2 × 2 × 8 B | 2,110 / 2,080 | 3,895 |
| Same | 8 × 4 × 16 B | 43 / 42 | 33 |

The first bug changes no count at all, so a totals-only check would pass it; the event diff fails it on line 1. The second shows up in both.

## Limitations

- cache-sim models which accesses hit, not when; the RTL's stall per miss is fixed by design (step 6).
- These programs are small; step 8 repeats the check on Embench: 70 runs, 55.7 million accesses, 0 differences.
