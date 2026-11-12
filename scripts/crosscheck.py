#!/usr/bin/env python3
"""Check the RTL data cache against cache-sim, access by access.

crosscheck.py [--cachesim PATH] [--cache SETS_BITS,WAYS,OFFSET_BITS ...] hex...

For every program and geometry, the testbench writes the core's data accesses as
a cache-sim trace and its own per-access events (hit or miss, victim, dirty
writeback, the set's tags afterwards). cache-sim replays the trace with the same
geometry and LRU and writes its events. Prints one CSV row per run with both
sides' counts and the number of event lines that differ; exits 1 on any
difference.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import csv
import subprocess
import sys
from pathlib import Path

from measure import ROOT, build, run

OUT = ROOT / "build" / "crosscheck"


def cachesim(binary: str, cache: tuple[int, int, int], trace: Path, events: Path) -> list[int]:
    """Replay a trace in cache-sim; return its L1 accesses, misses and writebacks."""
    index_bits, ways, offset_bits = cache
    size = (1 << (index_bits + offset_bits)) * ways
    out = subprocess.run(
        [binary, "--size", str(size), "--ways", str(ways), "--line", str(1 << offset_bits),
         "--policy", "lru", "--events", str(events), str(trace)],
        check=True, capture_output=True, text=True, timeout=600).stdout
    l1 = next(line.split() for line in out.splitlines() if line.startswith("L1"))
    return [int(l1[1]), int(l1[2]), int(l1[4])]


def differing_lines(a: Path, b: Path) -> tuple[int, int, str]:
    """Count lines that differ (comments skipped); also return the first one."""
    lines_a = [l for l in a.read_text().splitlines() if not l.startswith("#")]
    lines_b = b.read_text().splitlines()
    diffs = [i for i in range(max(len(lines_a), len(lines_b)))
             if i >= len(lines_a) or i >= len(lines_b) or lines_a[i] != lines_b[i]]
    first = ""
    if diffs:
        i = diffs[0]
        first = (f"line {i + 1}: cache-sim {lines_a[i] if i < len(lines_a) else 'EOF'!r} "
                 f"RTL {lines_b[i] if i < len(lines_b) else 'EOF'!r}")
    return len(lines_b), len(diffs), first


def check(binary: Path, sim: str, cache: tuple[int, int, int], hex_file: str) -> dict:
    name = Path(hex_file).stem
    out = OUT / "i{}w{}o{}".format(*cache)
    out.mkdir(parents=True, exist_ok=True)
    trace, rtl_events, sim_events = (out / f"{name}.trace", out / f"{name}.rtl.events",
                                     out / f"{name}.sim.events")
    rtl = run(binary, hex_file, 10, [f"+dtrace={trace}", f"+devents={rtl_events}"])
    sim_counts = cachesim(sim, cache, trace, sim_events)
    lines, differing, first = differing_lines(sim_events, rtl_events)
    if differing:
        print(f"{name} {cache}: {first}", file=sys.stderr)
    rtl_counts = [int(rtl["daccesses"]), int(rtl["dmisses"]), int(rtl["dwritebacks"])]
    return {"program": name, "sets": 1 << cache[0], "ways": cache[1], "line": 1 << cache[2],
            "rtl_accesses": rtl_counts[0], "sim_accesses": sim_counts[0],
            "rtl_misses": rtl_counts[1], "sim_misses": sim_counts[1],
            "rtl_writebacks": rtl_counts[2], "sim_writebacks": sim_counts[2],
            "event_lines": lines, "differing_lines": differing,
            "match": rtl_counts == sim_counts and differing == 0}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--cachesim", default=str(ROOT.parent / "cache-sim/build/cachesim"))
    parser.add_argument("--cache", action="append", default=[],
                        help="SETS_BITS,WAYS,OFFSET_BITS (default 6,2,6)")
    parser.add_argument("--jobs", type=int, default=6)
    parser.add_argument("hex", nargs="+")
    args = parser.parse_args()
    caches = [tuple(int(x) for x in c.split(",")) for c in args.cache] or [(6, 2, 6)]

    binaries = {cache: build(cache) for cache in caches}
    writer = None
    ok = True
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        futures = [pool.submit(check, binaries[c], args.cachesim, c, h)
                   for c in caches for h in args.hex]
        for future in futures:
            row = future.result()
            ok &= row["match"]
            if writer is None:
                writer = csv.DictWriter(sys.stdout, fieldnames=list(row))
                writer.writeheader()
            writer.writerow(row)
            sys.stdout.flush()
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
