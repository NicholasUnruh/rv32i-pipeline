"""CPI stack per design step: rebuild each step's core and split its cycles into
retired instructions and the bubbles that reached WB, by cause.

    uv run --with matplotlib python scripts/cpi_stack.py <build> <history>

Needs `make tests bench` outputs in <build> for this checkout (step 6). Steps 2
to 5 are rebuilt from the development history, programs included, since their
memory map differs: <history> is a git ref whose log holds each step's commit,
found by its subject (the public repository starts at the finished design, so it
cannot rerun them). tb/probe.sv tags every lost cycle with its cause (fill,
load-use stall, flush, I-cache miss, D-cache miss). Writes
docs/img/cpi-stack.json and docs/img/cpi-stack.png.
"""

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# (step, title, commit subject in <history> or None for this checkout, probe
# defines, extra plusargs). Step 1 is single-cycle: CPI 1 by construction, and its
# testbench counts no cycles. Step 2 is measured where the benchmark was added.
STEPS = [
    (
        2,
        "Five\nstages",
        "Add a bare-metal C benchmark for CPI",
        ["PROBE_NO_ICACHE", "PROBE_NO_TRACE", "PROBE_NO_DCACHE"],
        [],
    ),
    (
        3,
        "Branch\nprediction",
        "Predict branches with a BTB and 2-bit counters",
        ["PROBE_NO_ICACHE", "PROBE_NO_TRACE", "PROBE_NO_DCACHE"],
        [],
    ),
    (
        4,
        "I-cache\nL=10",
        "Fetch through a direct-mapped instruction cache",
        ["PROBE_NO_TRACE", "PROBE_NO_DCACHE"],
        [],
    ),
    (5, "Block RAM\nL=10", "Close timing on the DE1-SoC at 67.6 MHz", ["PROBE_NO_DCACHE"], []),
    (6, "D-cache\nL=10", None, [], []),
    (6, "D-cache\nL=1 (board)", None, [], ["+mem_latency=1"]),
]
CAUSES = ["fill", "loaduse", "flush", "icmiss", "dcmiss"]
STACK = re.compile(r"STACK cycles=(\d+) instret=(\d+) " + " ".join(rf"{c}=(\d+)" for c in CAUSES))


def git(*args: str) -> bytes:
    return subprocess.run(
        ["git", "-C", str(ROOT), *args], check=True, capture_output=True, timeout=60
    ).stdout


def build_step(
    history: str, subject: str | None, defines: list[str], build: Path, work: Path
) -> tuple[Path, Path]:
    """Compile one step's core with the probe; return it and the step's programs."""
    src = ROOT
    if subject is not None:
        commits = (
            git("log", "--format=%H", "--fixed-strings", f"--grep={subject}", history)
            .decode()
            .split()
        )
        if len(commits) != 1:
            sys.exit(f"{subject!r}: {len(commits)} commits in {history}")
        src = work / commits[0]
        src.mkdir()
        subprocess.run(
            ["tar", "-x", "-C", str(src)],
            input=git("archive", commits[0], "Makefile", "rtl", "tb", "tests", "scripts"),
            check=True,
            timeout=60,
        )
        subprocess.run(
            ["make", "-C", str(src), "tests", "build/bench/bench.hex",
             f"ISA={ROOT}/third_party/riscv-tests/isa"],
            check=True,
            capture_output=True,
            timeout=600,
        )
        build = src / "build"
    vvp = work / f"{len(list(work.glob('*.vvp')))}.vvp"
    subprocess.run(
        [
            "iverilog",
            "-g2012",
            *[f"-D{d}" for d in defines],
            "-s",
            "tb",
            "-s",
            "probe",
            "-o",
            str(vvp),
            str(src / "tb/tb.sv"),
            str(ROOT / "tb/probe.sv"),
            *map(str, sorted((src / "rtl").glob("*.sv"))),
        ],
        check=True,
        capture_output=True,
        timeout=120,
    )
    return vvp, build


def run(vvp: Path, hexfile: Path, plusargs: list[str]) -> dict:
    out = subprocess.run(
        ["vvp", "-n", str(vvp), f"+hex={hexfile}", "+stack", *plusargs],
        check=True,
        capture_output=True,
        text=True,
        timeout=120,
    ).stdout
    if not re.search(r"^PASS", out, re.M):
        sys.exit(f"{vvp.name} {hexfile.name}: no PASS\n{out}")
    m = STACK.search(out)
    counts = dict(zip(["cycles", "instret", *CAUSES], map(int, m.groups())))
    lost = sum(counts[c] for c in CAUSES)
    if counts["cycles"] != counts["instret"] + lost:
        sys.exit(f"{vvp.name} {hexfile.name}: causes do not add up: {counts}")
    return counts


def stack(counts: dict) -> dict:
    n = counts["instret"]
    return {
        **counts,
        "cpi": round(counts["cycles"] / n, 4),
        "cpi_parts": {"base": 1.0, **{c: round(counts[c] / n, 4) for c in CAUSES}},
    }


def plot(rows: list[dict], path: Path) -> None:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    bg, ink, muted, grid = "#0a0b12", "#f2f2f0", "#9a9aa6", "#2a2b36"
    colors = {
        "base": "#5b5e70",
        "loaduse": "#3987e5",
        "flush": "#f07a45",
        "icmiss": "#199e70",
        "dcmiss": "#c94f9a",
    }
    names = {
        "base": "Base: 1 per instruction, plus pipeline fill",
        "loaduse": "Load-use stall (at most {:.4f})".format(
            max(r[k]["cpi_parts"]["loaduse"] for r in rows for k in ("bench", "tests"))
        ),
        "flush": "Branch flush",
        "icmiss": "I-cache miss",
        "dcmiss": "D-cache miss",
    }
    plt.rcParams.update(
        {
            "font.family": "DejaVu Sans",
            "font.size": 11,
            "text.color": ink,
            "axes.labelcolor": muted,
            "xtick.color": muted,
            "ytick.color": muted,
        }
    )
    fig, axes = plt.subplots(
        1, 2, figsize=(12, 5.2), facecolor=bg, gridspec_kw={"width_ratios": [1.25, 1]}
    )
    for ax, key, title in [
        (axes[0], "bench", "C benchmark (35,324 instructions)"),
        (axes[1], "tests", "riscv-tests, all 40"),
    ]:
        ax.set_facecolor(bg)
        labels = [f"{r['step']}\n{r['title']}" for r in rows]
        bottom = [0.0] * len(rows)
        for part in ["base", *CAUSES[1:]]:
            vals = []
            for r in rows:
                p = r[key]["cpi_parts"]
                vals.append(p["base"] + p["fill"] if part == "base" else p[part])
            ax.bar(
                labels,
                vals,
                bottom=bottom,
                color=colors[part],
                width=0.62,
                edgecolor=bg,
                linewidth=1.5,
                label=names[part],
            )
            bottom = [b + v for b, v in zip(bottom, vals)]
        for i, r in enumerate(rows):
            ax.text(
                i,
                bottom[i],
                f"{r[key]['cpi']:.3f}",
                ha="center",
                va="bottom",
                color=ink,
                fontsize=11,
            )
        ax.set_title(title, color=ink, loc="left", fontsize=13, pad=12)
        ax.set_ylabel("Cycles per instruction")
        ax.tick_params(axis="x", labelsize=9, length=0)
        ax.grid(axis="y", color=grid, linewidth=0.8)
        ax.set_axisbelow(True)
        for s in ax.spines.values():
            s.set_visible(False)
        ax.set_ylim(0, max(bottom) * 1.12)
    handles, lbls = axes[0].get_legend_handles_labels()
    fig.legend(
        handles, lbls, loc="lower center", ncol=3, frameon=False, fontsize=10, labelcolor=ink
    )
    fig.tight_layout(rect=(0, 0.08, 1, 1))
    fig.savefig(path, dpi=110, facecolor=bg)


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    build, history = Path(sys.argv[1]).resolve(), sys.argv[2]
    by_construction = {"cpi": 1.0, "cpi_parts": {"base": 1.0, **dict.fromkeys(CAUSES, 0.0)}}
    rows = [
        {
            "step": 1,
            "title": "Single-\ncycle",
            "note": "CPI 1 by construction (docs/1-single-cycle.md); not simulated",
            "bench": by_construction,
            "tests": by_construction,
        }
    ]
    with tempfile.TemporaryDirectory() as tmp:
        for step, title, subject, defines, plusargs in STEPS:
            vvp, step_build = build_step(history, subject, defines, build, Path(tmp))
            tests = sorted((step_build / "tests").glob("*.hex"))
            bench = step_build / "bench/bench.hex"
            total = dict.fromkeys(["cycles", "instret", *CAUSES], 0)
            for t in tests:
                for k, v in run(vvp, t, plusargs).items():
                    total[k] += v
            rows.append(
                {
                    "step": step,
                    "title": title,
                    "source": subject or "this checkout",
                    "plusargs": plusargs,
                    "bench": stack(run(vvp, bench, plusargs)),
                    "tests": stack(total),
                }
            )
            print(
                step, title.replace("\n", " "), rows[-1]["bench"]["cpi"], rows[-1]["tests"]["cpi"]
            )
    out = ROOT / "docs/img"
    out.mkdir(parents=True, exist_ok=True)
    (out / "cpi-stack.json").write_text(
        json.dumps(
            {
                "source": "scripts/cpi_stack.py",
                "tests": len(tests),
                "causes": "cycles = instret + fill + loaduse + flush + icmiss + dcmiss",
                "steps": rows,
            },
            indent=1,
        )
        + "\n"
    )
    plot(rows, out / "cpi-stack.png")


if __name__ == "__main__":
    main()
