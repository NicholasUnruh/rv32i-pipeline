#!/usr/bin/env python3
"""Run programs on the core under Verilator and print one CSV row per run.

measure.py [--cache SETS_BITS,WAYS,OFFSET_BITS ...] [--latency N ...] [--jobs N] hex...

Each data cache geometry gets its own Verilator build in build/vl/, with
tb/probe.sv. Every program runs at every latency; the columns are the
testbench's PASS fields, then the probe's lost cycles by cause (fill, loaduse,
flush, icmiss, dcmiss), which with instret add up to the cycles. Exits 1 if any
run fails.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import csv
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAX_CYCLES = 200_000_000
RUN_TIMEOUT_S = 1800


def build(cache: tuple[int, int, int]) -> Path:
    """Build the testbench for one data cache geometry; return the binary."""
    index_bits, ways, offset_bits = cache
    out = ROOT / "build" / "vl" / f"i{index_bits}w{ways}o{offset_bits}"
    out.mkdir(parents=True, exist_ok=True)
    sources = [ROOT / "tb" / "tb.sv", ROOT / "tb" / "probe.sv",
               *sorted((ROOT / "rtl").glob("*.sv"))]
    subprocess.run(
        ["verilator", "--binary", "--timing", "-j", "4", "-O3",
         "-Wno-fatal", "-Wno-lint", "-Wno-style", "-Wno-INITIALDLY", "-Wno-MULTITOP",
         f"-GDCACHE_INDEX_BITS={index_bits}", f"-GDCACHE_WAYS={ways}",
         f"-GDCACHE_OFFSET_BITS={offset_bits}",
         "-Mdir", str(out), "-o", "vtb", *map(str, sources)],
        check=True, stdout=subprocess.DEVNULL, timeout=600)
    return out / "vtb"


def run(binary: Path, hex_file: str, latency: int, extra: list[str]) -> dict[str, str]:
    """Run one program; return the PASS line's fields."""
    result = subprocess.run(
        [str(binary), f"+hex={hex_file}", f"+mem_latency={latency}",
         f"+max_cycles={MAX_CYCLES}", "+stack", *extra],
        capture_output=True, text=True, timeout=RUN_TIMEOUT_S)
    line = next((l for l in result.stdout.splitlines()
                 if l.startswith(("PASS", "FAIL", "ERROR"))), "no result")
    if not line.startswith("PASS"):
        raise RuntimeError(f"{hex_file} L={latency}: {line}")
    fields = dict(re.findall(r"(\w+)=(\S+)", line))
    stack = next(l for l in result.stdout.splitlines() if l.startswith("STACK"))
    causes = {k: v for k, v in re.findall(r"(\w+)=(\S+)", stack)
              if k not in ("cycles", "instret")}
    return {**fields, **causes}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--cache", action="append", default=[],
                        help="SETS_BITS,WAYS,OFFSET_BITS (default 6,2,6)")
    parser.add_argument("--latency", action="append", type=int, default=[])
    parser.add_argument("--jobs", type=int, default=6)
    parser.add_argument("--plusarg", action="append", default=[],
                        help="extra testbench plusarg, e.g. +dtrace=x (use {name} for the program)")
    parser.add_argument("hex", nargs="+")
    args = parser.parse_args()
    caches = [tuple(int(x) for x in c.split(",")) for c in args.cache] or [(6, 2, 6)]
    latencies = args.latency or [10]

    binaries = {cache: build(cache) for cache in caches}
    jobs = [(cache, hex_file, latency)
            for cache in caches for hex_file in args.hex for latency in latencies]
    writer = None
    failed = False
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        futures = {}
        for cache, hex_file, latency in jobs:
            name = Path(hex_file).stem
            extra = [p.format(name=name) for p in args.plusarg]
            futures[pool.submit(run, binaries[cache], hex_file, latency, extra)] = (
                cache, name, latency)
        for future in futures:  # in submission order, so the output is stable
            cache, name, latency = futures[future]
            try:
                fields = future.result()
            except (RuntimeError, subprocess.TimeoutExpired) as error:
                print(error, file=sys.stderr)
                failed = True
                continue
            row = {"program": name, "sets_bits": cache[0], "ways": cache[1],
                   "offset_bits": cache[2], "latency": latency,
                   **{k: v for k, v in fields.items() if k != "CPI"}}
            if writer is None:
                writer = csv.DictWriter(sys.stdout, fieldnames=list(row))
                writer.writeheader()
            writer.writerow(row)
            sys.stdout.flush()
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
