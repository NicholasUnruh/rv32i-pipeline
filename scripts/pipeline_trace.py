"""Cycle-by-cycle pipeline trace of the C benchmark, and a waveform dump of one hazard.

    python3 scripts/pipeline_trace.py <build>

Needs `make bench` outputs in <build>. Runs the benchmark with tb/probe.sv (+trace),
picks the shortest window that shows a load-use stall, forwarding from EX/MEM and
from MEM/WB, a misprediction flush and a correctly predicted taken branch (BTB hit),
plus TAIL cycles, and writes it with disassembly to docs/img/pipeline-trace.json.
Then reruns the shortest stretch with a load-use stall, its MEM/WB forward and a
flush with +vcd into <build>/trace/hazard.vcd for scripts/waveform.py.

Probe trace line, one per cycle: cycle, IF pc, ID pc, ID valid, EX pc, EX valid,
MEM pc, MEM valid, WB pc, WB valid, stall, flush, I-cache miss, rs1 source, rs2
source (2 = EX/MEM, 1 = MEM/WB, 0 = register file), EX is a branch or jump, EX was
predicted taken, EX is taken.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RISCV = os.environ.get(
    "RISCV", str(Path.home() / ".local/opt/xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-")
)
MIN_CYCLES, MAX_CYCLES, TAIL = 30, 54, 6  # trace window, plus TAIL cycles to drain
WAVE_MIN, WAVE_MAX, WAVE_PAD = 6, 16, 2  # waveform window, plus WAVE_PAD on each side
FWD = {1: "MEM/WB", 2: "EX/MEM"}


def sim(build: Path, plusargs: list[str]) -> None:
    vvp = build / "trace/probe.vvp"
    if not vvp.exists():
        subprocess.run(
            [
                "iverilog",
                "-g2012",
                "-s",
                "tb",
                "-s",
                "probe",
                "-o",
                str(vvp),
                str(ROOT / "tb/tb.sv"),
                str(ROOT / "tb/probe.sv"),
                *map(str, sorted((ROOT / "rtl").glob("*.sv"))),
            ],
            check=True,
            capture_output=True,
            timeout=120,
        )
    out = subprocess.run(
        ["vvp", "-n", str(vvp), f"+hex={build / 'bench/bench.hex'}", *plusargs],
        check=True,
        capture_output=True,
        text=True,
        timeout=300,
    ).stdout
    if not re.search(r"^PASS", out, re.M):
        sys.exit(out)


def disassemble(elf: Path) -> dict[int, str]:
    out = subprocess.run(
        [RISCV + "objdump", "-d", str(elf)], check=True, capture_output=True, text=True, timeout=60
    ).stdout
    asm = {}
    for m in re.finditer(r"^([0-9a-f]{8}):\s+[0-9a-f]{8}\s+(\S+)\s*([^#<\n]*)", out, re.M):
        asm[int(m[1], 16)] = f"{m[2]} {m[3].strip()}".strip()
    return asm


def parse(path: Path) -> list[dict]:
    cycles = []
    for line in path.read_text().splitlines():
        f = line.split()
        h = [int(x, 16) for x in f[1:10]]
        d = [int(x) for x in f[10:]]
        cycles.append(
            {
                "c": int(f[0]),
                "if": h[0],
                "id": (h[1], h[2]),
                "ex": (h[3], h[4]),
                "mem": (h[5], h[6]),
                "wb": (h[7], h[8]),
                "stall": d[0],
                "flush": d[1],
                "icmiss": d[2],
                "fwd": d[3:5],
                "ctrl": d[5],
                "pred": d[6],
                "taken": d[7],
            }
        )
    return cycles


def events(c: dict) -> set[str]:
    e = set()
    if c["stall"]:
        e.add("loaduse")
    if c["flush"]:
        e.add("flush")
    if 2 in c["fwd"]:
        e.add("fwd_mem")
    if 1 in c["fwd"] and not c["stall"]:
        e.add("fwd_wb")
    if c["ctrl"] and c["pred"] and c["taken"] and not c["flush"]:
        e.add("btb_hit")
    if c["icmiss"]:
        e.add("icmiss")
    return e


def shortest(cycles: list[dict], need: list[str], lo: int, hi: int) -> tuple[int, int]:
    """Shortest window of lo..hi cycles with every event in need; on a tie, the
    earliest. The run starts cold, so windows that are mostly I-cache misses are
    skipped."""
    count = {k: [0] for k in need + ["icmiss"]}  # prefix sums per event
    for c in cycles:
        e = events(c)
        for k, v in count.items():
            v.append(v[-1] + (k in e))
    for n in range(lo, hi + 1):
        for s in range(len(cycles) - n):
            if (
                all(count[k][s + n] > count[k][s] for k in need)
                and count["icmiss"][s + n] - count["icmiss"][s] < n // 4
            ):
                return s, n
    sys.exit(f"no window of {lo}..{hi} cycles shows {need}")


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    build = Path(sys.argv[1]).resolve()
    (build / "trace").mkdir(exist_ok=True)
    (build / "trace/probe.vvp").unlink(missing_ok=True)
    trace = build / "trace/bench.trace"
    sim(build, [f"+trace={trace}"])
    cycles = parse(trace)
    asm = disassemble(build / "bench/bench.elf")
    s, n = shortest(
        cycles, ["loaduse", "flush", "fwd_mem", "fwd_wb", "btb_hit"], MIN_CYCLES - TAIL, MAX_CYCLES
    )
    window = cycles[s : s + n + TAIL]

    def stage(pc: int, valid: int = 1):
        return {"pc": f"{pc:08x}", "asm": asm.get(pc, "?")} if valid else None

    rows = []
    for c in window:
        fwd = [
            {
                "operand": op,
                "from": FWD[src],
                "src_pc": f"{(c['mem'] if src == 2 else c['wb'])[0]:08x}",
            }
            for op, src in zip(("rs1", "rs2"), c["fwd"])
            if src
        ]
        row = {
            "c": c["c"],
            "IF": stage(c["if"]),
            "ID": stage(*c["id"]),
            "EX": stage(*c["ex"]),
            "MEM": stage(*c["mem"]),
            "WB": stage(*c["wb"]),
            "stall": bool(c["stall"]),
            "flush": bool(c["flush"]),
            "fwd": fwd,
            "icmiss": bool(c["icmiss"]),
        }
        if c["ctrl"]:
            row["branch"] = {"predicted_taken": bool(c["pred"]), "taken": bool(c["taken"])}
        rows.append(row)
    out = {
        "source": "scripts/pipeline_trace.py on the C benchmark (tests/bench/bench.c), "
        "core as on main, 10-cycle instruction memory latency",
        "cycles": rows,
        "notes": [
            "Each stage holds the instruction it works on during cycle c; null is a bubble.",
            "IF shows the PC being fetched; with icmiss it waits for the line and sends ID a bubble.",
            "stall: load-use hazard; the instruction in ID and the PC hold, EX gets a bubble.",
            "flush: EX found a misprediction; the instructions in IF and ID this cycle are "
            "discarded and fetch restarts at the right PC next cycle.",
            "fwd: an EX operand taken from the EX/MEM or MEM/WB pipeline register "
            "(src_pc is the producing instruction) instead of the register file.",
            "branch: the instruction in EX is a branch or jump; predicted_taken comes from "
            "the BTB at fetch. Predicted and taken with no flush is a correct BTB hit.",
        ],
    }
    (ROOT / "docs/img/pipeline-trace.json").write_text(
        json.dumps(out, separators=(",", ":")) + "\n"
    )
    print(
        f"window cycles {window[0]['c']}..{window[-1]['c']}:",
        sorted(set().union(*map(events, window))),
    )

    s, n = shortest(cycles, ["loaduse", "fwd_wb", "flush"], WAVE_MIN, WAVE_MAX)
    wave = cycles[s - WAVE_PAD : s + n + WAVE_PAD]
    first, last = wave[0]["c"], wave[-1]["c"]
    sim(build, [f"+vcd={build / 'trace/hazard.vcd'}", f"+vcd_from={first}", f"+vcd_to={last}"])
    print(f"waveform cycles {first}..{last}:", sorted(set().union(*map(events, wave))))


if __name__ == "__main__":
    main()
