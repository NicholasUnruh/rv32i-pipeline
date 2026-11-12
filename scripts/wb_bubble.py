"""Waveform of the data-miss bug found in step 6: the first version sent bubbles into
WB while a miss held the pipeline, so the instruction held in EX lost the result
it was forwarding from WB.

    uv run --with matplotlib python scripts/wb_bubble.py <build> <out.png>

Needs `make bench` outputs in <build>. Builds this checkout's core and a copy with
the original behaviour patched back in, runs the C benchmark on both with
tb/probe.sv (+trace), and plots the first miss whose EX instruction forwards from
WB. The buggy core never reaches tohost, so its run stops at a cycle limit.
"""

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# The step-6 fix, undone: WB takes a bubble during a miss, and retire is ungated.
BUG = [
    ("    end else if (!dstall) begin\n",
     "    end else if (dstall) begin\n      mem_wb <= '0;\n    end else begin\n"),
    ("  assign retire = mem_wb.valid && !dstall;", "  assign retire = mem_wb.valid;"),
]


def run(rtl: Path, bench: Path, work: Path, name: str) -> list[list[str]]:
    """Run the benchmark on the core in rtl/; return the probe's trace rows."""
    vvp, trace = work / f"{name}.vvp", work / f"{name}.trace"
    subprocess.run(
        ["iverilog", "-g2012", "-s", "tb", "-s", "probe", "-o", str(vvp),
         str(ROOT / "tb/tb.sv"), str(ROOT / "tb/probe.sv"), *map(str, sorted(rtl.glob("*.sv")))],
        check=True, capture_output=True, timeout=120)
    subprocess.run(
        ["vvp", "-n", str(vvp), f"+hex={bench}", f"+trace={trace}", "+max_cycles=60000"],
        check=True, capture_output=True, timeout=300)
    return [line.split() for line in trace.read_text().splitlines()]


def window(rows: list[list[str]]) -> int:
    """Index of the first miss cycle whose EX instruction forwards from MEM/WB."""
    for i, r in enumerate(rows):
        if r[18] == "1" and r[5] == "1" and "1" in (r[13], r[14]):
            return i
    sys.exit("no data miss with a forward from WB")


def lanes(rows: list[list[str]]) -> dict[str, list[int]]:
    """Per cycle: the stall, WB's contents, and where EX's operand comes from."""
    def fwd(r):
        return 1 if "1" in (r[13], r[14]) else 0  # 1 = from MEM/WB, 0 = register file
    return {
        "dstall (MEM miss)": [int(r[18]) for r in rows],
        "MEM/WB valid": [int(r[19]) for r in rows],
        "EX operand from MEM/WB": [fwd(r) for r in rows],
    }


def plot(panels: list[tuple[str, list[list[str]]]], out: Path) -> None:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    bg, ink, muted, hi, bad = "#ffffff", "#1d1d24", "#6b6b78", "#3987e5", "#d1495b"
    fig, axes = plt.subplots(1, len(panels), figsize=(13, 3.2), facecolor=bg, sharey=True)
    for ax, (title, rows) in zip(axes, panels):
        data = lanes(rows)
        cycles = [int(r[0]) for r in rows]
        for k, (name, values) in enumerate(data.items()):
            y = (len(data) - 1 - k) * 1.5
            xs, ys = [], []
            for c, v in zip(cycles, values):
                xs += [c, c + 1]
                ys += [y + 0.9 * v, y + 0.9 * v]
            color = bad if name.startswith("EX operand") and "bubble" in title else hi
            ax.plot(xs, ys, color=color, linewidth=2)
            ax.fill_between(xs, y, ys, color=color, alpha=0.15, step=None)
            ax.text(cycles[0] - 0.5, y + 0.45, name, ha="right", va="center", color=ink,
                    fontsize=10)
        ax.set_title(title, color=ink, loc="left", fontsize=12)
        ax.set_xlabel("Cycle (from reset release)", color=muted)
        ax.set_yticks([])
        ax.tick_params(colors=muted)
        for s in ("top", "right", "left"):
            ax.spines[s].set_visible(False)
    fig.tight_layout()
    fig.savefig(out, dpi=110, facecolor=bg)


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    build, out = Path(sys.argv[1]).resolve(), Path(sys.argv[2])
    bench = build / "bench/bench.hex"
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        buggy_rtl = work / "rtl"
        buggy_rtl.mkdir()
        for f in (ROOT / "rtl").glob("*.sv"):
            text = f.read_text()
            if f.name == "core.sv":
                for old, new in BUG:
                    if text.count(old) != 1:
                        sys.exit(f"core.sv no longer matches the patch: {old!r}")
                    text = text.replace(old, new)
            (buggy_rtl / f.name).write_text(text)
        fixed = run(ROOT / "rtl", bench, work, "fixed")
        buggy = run(buggy_rtl, bench, work, "buggy")
    start = window(buggy) - 3
    end = start + 24
    plot([("First version: WB takes a bubble during the miss", buggy[start:end]),
          ("Fixed: WB holds with the rest of the pipeline", fixed[start:end])], out)
    print(f"cycles {buggy[start][0]}..{buggy[end - 1][0]}; "
          f"buggy run {len(buggy)} cycles without a result, fixed run {len(fixed)} cycles")


if __name__ == "__main__":
    main()
