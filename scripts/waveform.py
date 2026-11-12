"""Turn the hazard VCD from scripts/pipeline_trace.py into WaveJSON and an SVG.

    uv run --with wavedrom python scripts/waveform.py <build>

Reads <build>/trace/hazard.vcd (signals of tb/probe.sv) and <build>/bench/bench.elf
for mnemonics. Each column is one clock cycle (numbered from reset release), sampled
at the falling edge, when the cycle's values are settled. Writes docs/img/hazard-wave.json and hazard-wave.svg.
"""

import json
import re
import sys
from pathlib import Path

import wavedrom

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pipeline_trace import ROOT, disassemble  # noqa: E402

STAGES = [
    ("IF", "pc_if", None),
    ("ID", "pc_id", "v_id"),
    ("EX", "pc_ex", "v_ex"),
    ("MEM", "pc_mem", "v_mem"),
    ("WB", "pc_wb", "v_wb"),
]
FWD = {0: "regfile", 1: "MEM/WB", 2: "EX/MEM"}


def read_vcd(path: Path) -> tuple[dict[str, list[tuple[int, int]]], int, int]:
    """Value changes per signal name, as (time, value); the times of $dumpon and
    of the last $dumpoff."""
    ids, changes, t, start, end = {}, {}, 0, None, None
    for line in path.read_text().splitlines():
        if m := re.match(r"\$var \S+ \d+ (\S+) (\w+)", line):
            ids[m[1]] = m[2]
            changes[m[2]] = []
        elif line.startswith("#"):
            t = int(line[1:])
        elif line.startswith("$dumpon"):
            start = t
        elif line.startswith("$dumpoff"):
            end = t
        elif m := re.match(r"b([01xz]+) (\S+)$", line) or re.match(r"([01xz])(\S+)$", line):
            if m[2] in ids:
                value = int(m[1], 2) if set(m[1]) <= {"0", "1"} else None
                changes[ids[m[2]]].append((t, value))
    return changes, start, end


def at(changes: list[tuple[int, int]], t: int) -> int:
    return [v for time, v in changes if time <= t][-1]


def lane(name: str, values: list) -> dict:
    """A data lane: '=' for a new value, '.' to hold it, 'x' for a bubble (None)."""
    wave, data, prev = "", [], object()
    for v in values:
        if v is None:
            wave += "x"
        elif v == prev:
            wave += "."
        else:
            wave += "="
            data.append(v)
        prev = v
    return {"name": name, "wave": wave, "data": data}


def bit(name: str, values: list[int]) -> dict:
    wave = "".join("." if i and v == values[i - 1] else str(v) for i, v in enumerate(values))
    return {"name": name, "wave": wave}


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    build = Path(sys.argv[1]).resolve()
    changes, start, end = read_vcd(build / "trace/hazard.vcd")
    asm = disassemble(build / "bench/bench.elf")
    # Falling edges in the dump; the clock is low at $dumpon and $dumpoff.
    falls = [t for t, v in changes["clk"] if v == 0 and start <= t < end]
    signals = [{"name": "clk", "wave": "p" + "." * (len(falls) - 1)}]
    for label, pc, valid in STAGES:
        signals.append(
            lane(
                label,
                [
                    f"{at(changes[pc], t) & 0xFFF:03x} {asm[at(changes[pc], t)].split()[0]}"
                    if valid is None or at(changes[valid], t)
                    else None
                    for t in falls
                ],
            )
        )
    signals.append({})
    signals.append(bit("stall", [at(changes["stall"], t) for t in falls]))
    signals.append(bit("flush", [at(changes["flush"], t) for t in falls]))
    signals.append(bit("icmiss", [at(changes["icmiss"], t) for t in falls]))
    for operand, sig in [("EX rs1 from", "fwd_a"), ("EX rs2 from", "fwd_b")]:
        signals.append(lane(operand, [FWD[at(changes[sig], t)] for t in falls]))
    wave = {
        "signal": signals,
        "config": {"hscale": 2},
        "head": {
            "text": "Load-use stall, MEM/WB forward and misprediction flush "
            "(C benchmark; x = bubble)",
            "tick": at(changes["vcd_from"], start),
        },
    }
    out = ROOT / "docs/img"
    (out / "hazard-wave.json").write_text(json.dumps(wave, indent=1) + "\n")
    svg = wavedrom.render(json.dumps(wave)).tostring()
    # Opaque background, so the black strokes stay visible on dark pages.
    svg = re.sub(r"(<svg[^>]*>)", r'\1<rect width="100%" height="100%" fill="#fff"/>', svg, 1)
    (out / "hazard-wave.svg").write_text(svg + "\n")


if __name__ == "__main__":
    main()
