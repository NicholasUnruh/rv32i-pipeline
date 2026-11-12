#!/usr/bin/env python3
"""Sweep cache size, ways, line and policy in cache-sim on the core's traces.

cache_sweep.py --side d|i --cachesim PATH --measured CSV --latency L trace...

Data side: the traces are the core's data accesses (+dtrace), which do not depend
on the cache. The core stalls L + W + 3 cycles per miss and W + 1 more per dirty
victim (W = words per line, docs/6-dcache.md).

Instruction side: the traces are the I-cache lookups that hit or request a line
(+itrace, 16 B granularity). Wrong-path fetches make them depend slightly on the
cache they were recorded with (docs/10-icache.md). A miss stalls fetch for
L + W + 2 cycles (docs/4-icache.md, plus the valid bit's cycle from step 5).

For each geometry and policy, cache-sim gives the misses and writebacks. The
measured CSV (scripts/measure.py at latency L) gives each program's cycles without
that side's stalls (cycles - dcmiss, or cycles - icmiss), so the predicted cycles
are that plus the modelled stalls. Prints one CSV row per program, geometry and
policy.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import csv
import subprocess
import sys
from pathlib import Path

SIZES = [256, 512, 1024, 2048, 4096, 8192, 16384]
WAYS = [1, 2, 4, 8]
LINES = [16, 32, 64]
POLICIES = ["lru", "srrip", "brrip"]


def cachesim(binary: str, size: int, ways: int, line: int, policy: str,
             trace: Path) -> tuple[int, int, int]:
    out = subprocess.run(
        [binary, "--size", str(size), "--ways", str(ways), "--line", str(line),
         "--policy", policy, str(trace)],
        check=True, capture_output=True, text=True, timeout=600).stdout
    l1 = next(l.split() for l in out.splitlines() if l.startswith("L1"))
    return int(l1[1]), int(l1[2]), int(l1[4])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--side", choices=["d", "i"], required=True)
    parser.add_argument("--cachesim", required=True)
    parser.add_argument("--measured", required=True)
    parser.add_argument("--latency", type=int, default=10)
    parser.add_argument("--jobs", type=int, default=6)
    parser.add_argument("trace", nargs="+")
    args = parser.parse_args()

    measured = {r["program"]: r for r in csv.DictReader(open(args.measured))
                if int(r["latency"]) == args.latency}
    configs = [(s, w, l, p) for s in SIZES for w in WAYS for l in LINES for p in POLICIES
               if s // (w * l) >= 2]  # the RTL needs at least two sets
    jobs = [(Path(t), c) for t in args.trace for c in configs]
    writer = csv.writer(sys.stdout)
    writer.writerow(["program", "size", "ways", "line", "policy", "accesses", "misses",
                     "writebacks", "stall", "cycles", "instret", "cpi"])
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        futures = [pool.submit(cachesim, args.cachesim, *c, t) for t, c in jobs]
        for (trace, (size, ways, line, policy)), future in zip(jobs, futures):
            accesses, misses, writebacks = future.result()
            row = measured[trace.stem]
            words = line // 4
            if args.side == "d":
                stall = misses * (args.latency + words + 3) + writebacks * (words + 1)
                cycles = int(row["cycles"]) - int(row["dcmiss"]) + stall
            else:
                stall = misses * (args.latency + words + 2)
                cycles = int(row["cycles"]) - int(row["icmiss"]) + stall
            instret = int(row["instret"])
            writer.writerow([trace.stem, size, ways, line, policy, accesses, misses,
                             writebacks, stall, cycles, instret, f"{cycles / instret:.5f}"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
