"""FPGA resources per step: Yosys Cyclone V mapping of the core (steps 1 to 5) and the
two Quartus builds of the DE1-SoC top (step 5).

    uv run --with matplotlib python scripts/fpga_resources.py <build>

Steps 1 to 4: the Yosys counts in docs/1-*.md to docs/4-*.md. Step 5: <build>/synth.log
from `make synth` (ALUTs are MISTRAL_ALUT2 to ALUT6, as in the step notes). Quartus:
the synchronous-array build from <build>/quartus/output_files (fit summary and timing
report); the first, asynchronous-array build is no longer on disk, so its column is
read from the table in docs/5-de1-soc.md. Writes docs/img/fpga-resources.json and .png.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TITLES = ["Single-cycle", "Five stages", "Branch prediction", "I-cache", "Block RAM"]


def num(s: str) -> int:
    return int(s.replace(",", ""))


def yosys_from_doc(path: Path) -> dict:
    text = " ".join(path.read_text().split())
    m = re.search(r"([\d,]+) ALUTs, ([\d,]+) carry cells,? (?:and )?([\d,]+) flip-flops", text)
    mlab = re.search(r"([\d,]+) MLAB cells", text)
    return {
        "aluts": num(m[1]),
        "carry": num(m[2]),
        "ffs": num(m[3]),
        "mlab": num(mlab[1]) if mlab else None,
        "source": str(path.relative_to(ROOT)),
    }


def yosys_from_log(path: Path) -> dict:
    stat = path.read_text().rsplit("=== core ===", 1)[1]
    cell = {k: int(v) for k, v in re.findall(r"MISTRAL_(\w+)\s+(\d+)", stat)}
    return {
        "aluts": sum(cell.get(f"ALUT{i}", 0) for i in range(2, 7)),
        "carry": cell["ALUT_ARITH"],
        "ffs": cell["FF"],
        "mlab": cell.get("MLAB", 0),
        "m10k": cell.get("M10K", 0),
        "source": "build/synth.log (make synth)",
    }


def quartus_sync(build: Path) -> dict:
    out = build / "quartus/output_files"
    fit = (out / "rv32i.fit.summary").read_text()
    sta = (out / "rv32i.sta.rpt").read_text()
    summary = (out / "rv32i.sta.summary").read_text()
    setup = re.search(r"Slow 1100mV 85C Model Setup 'CLOCK_50'\nSlack : ([-\d.]+)", summary)
    holds = re.findall(r"Model Hold 'CLOCK_50'\nSlack : ([-\d.]+)", summary)
    return {
        "alms": num(re.search(r"Logic utilization \(in ALMs\) : ([\d,]+)", fit)[1]),
        "registers": num(re.search(r"Total registers : ([\d,]+)", fit)[1]),
        "m10k": num(re.search(r"Total RAM Blocks : ([\d,]+)", fit)[1]),
        "fmax_mhz": float(
            re.search(r"; Slow 1100mV 85C Model Fmax Summary +;.*?\n; ([\d.]+) MHz", sta, re.S)[1]
        ),
        "setup_slack_ns": float(setup[1]),
        "worst_hold_slack_ns": min(map(float, holds)),
        "source": "build/quartus/output_files/rv32i.fit.summary, rv32i.sta.rpt",
    }


def quartus_async_from_doc(path: Path) -> dict:
    rows = {}
    for line in path.read_text().splitlines():
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) == 3:
            rows[cells[0]] = cells[1]
    return {
        "alms": num(rows["ALMs"]),
        "registers": num(rows["Registers"]),
        "m10k": num(rows["M10K blocks"]),
        "fmax_mhz": float(rows["Fmax, slow 85 °C"].split()[0]),
        "setup_slack_ns": float(rows["Setup slack at 50 MHz"].split()[0]),
        "source": str(path.relative_to(ROOT)),
    }


def plot(data: dict, path: Path) -> None:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    bg, ink, muted, grid = "#0a0b12", "#f2f2f0", "#9a9aa6", "#2a2b36"
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
    fig, (a, b) = plt.subplots(
        1, 2, figsize=(12, 5.2), facecolor=bg, gridspec_kw={"width_ratios": [1.5, 1]}
    )
    steps = data["yosys"]
    x = range(len(steps))
    series = [
        ("aluts", "ALUTs", "#3987e5"),
        ("ffs", "Flip-flops", "#f07a45"),
        ("mlab", "MLAB cells", "#199e70"),
    ]
    w = 0.26
    for i, (key, label, color) in enumerate(series):
        vals = [s[key] for s in steps]
        a.bar(
            [j + (i - 1) * w for j in x],
            [v or 0 for v in vals],
            w,
            color=color,
            label=label,
            edgecolor=bg,
            linewidth=1.5,
        )
        for j, v in enumerate(vals):  # None: the step note does not record it
            a.text(
                j + (i - 1) * w,
                v or 0,
                "n/r" if v is None else f"{v:,}",
                ha="center",
                va="bottom",
                fontsize=8,
                color=muted,
            )
    a.set_xticks(
        list(x),
        [
            f"{s['step']}\n{s['title']}" + (f"\n+{s['m10k']} M10K" if s.get("m10k") else "")
            for s in steps
        ],
        fontsize=9,
    )
    a.set_title("Core only, Yosys Cyclone V mapping", color=ink, loc="left", fontsize=13, pad=12)
    a.set_ylabel("Cells (n/r: not recorded)")
    a.legend(frameon=False, labelcolor=ink, fontsize=10, loc="upper left")

    q = data["quartus"]
    builds = [
        ("Asynchronous\narrays (first build)", q["async"]),
        ("Synchronous\narrays", q["sync"]),
    ]
    for i, (key, label, color) in enumerate(
        [("alms", "ALMs", "#3987e5"), ("registers", "Registers", "#f07a45")]
    ):
        vals = [bd[key] for _, bd in builds]
        pos = [j + (i - 0.5) * 0.36 for j in range(2)]
        b.bar(pos, vals, 0.36, color=color, label=label, edgecolor=bg, linewidth=1.5)
        for p, v in zip(pos, vals):
            b.text(p, v, f"{v:,}", ha="center", va="bottom", fontsize=9, color=ink)
    b.set_xticks(
        [0, 1],
        [f"{t}\nFmax {bd['fmax_mhz']:.2f} MHz\n{bd['m10k']} M10K" for t, bd in builds],
        fontsize=9,
    )
    b.set_title("DE1-SoC top, Quartus fit (step 5)", color=ink, loc="left", fontsize=13, pad=12)
    b.legend(frameon=False, labelcolor=ink, fontsize=10, loc="upper right")
    for ax in (a, b):
        ax.set_facecolor(bg)
        ax.grid(axis="y", color=grid, linewidth=0.8)
        ax.set_axisbelow(True)
        ax.tick_params(axis="x", length=0)
        for s in ax.spines.values():
            s.set_visible(False)
    fig.tight_layout()
    fig.savefig(path, dpi=110, facecolor=bg)


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    build = Path(sys.argv[1]).resolve()
    docs = sorted((ROOT / "docs").glob("[1-4]-*.md"))
    yosys = [yosys_from_doc(p) for p in docs] + [yosys_from_log(build / "synth.log")]
    for i, y in enumerate(yosys):
        y.update(step=i + 1, title=TITLES[i])
    data = {
        "source": "scripts/fpga_resources.py",
        "device": "Cyclone V 5CSEMA5F31C6",
        "yosys": yosys,
        "quartus": {
            "async": quartus_async_from_doc(ROOT / "docs/5-de1-soc.md"),
            "sync": quartus_sync(build),
        },
    }
    out = ROOT / "docs/img"
    (out / "fpga-resources.json").write_text(json.dumps(data, indent=1) + "\n")
    plot(data, out / "fpga-resources.png")
    print(json.dumps(data["quartus"]), [(y["step"], y["aluts"], y["ffs"]) for y in yosys])


if __name__ == "__main__":
    main()
