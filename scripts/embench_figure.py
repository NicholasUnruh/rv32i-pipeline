"""CPI stack per Embench program: retired instructions plus the cycles lost to
each cause, as measured by tb/probe.sv (scripts/measure.py output).

    uv run --with matplotlib python scripts/embench_figure.py <measure.csv> <out.png> <title>
"""

import csv
import sys

CAUSES = [("loaduse", "Load-use stall", "#e3a21a"), ("flush", "Branch flush", "#d1495b"),
          ("icmiss", "I-cache miss", "#3987e5"), ("dcmiss", "D-cache miss", "#199e70")]


def main() -> None:
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    rows = list(csv.DictReader(open(sys.argv[1])))
    rows.sort(key=lambda r: int(r["cycles"]) / int(r["instret"]))

    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    ink, muted = "#1d1d24", "#6b6b78"
    fig, ax = plt.subplots(figsize=(10, 5.2))
    y = range(len(rows))
    ax.barh(y, [1.0] * len(rows), color="#c9c9d1", label="Base (1 per instruction)")
    left = [1.0] * len(rows)
    for key, label, color in CAUSES:
        part = [int(r[key]) / int(r["instret"]) for r in rows]
        ax.barh(y, part, left=left, color=color, label=label)
        left = [a + b for a, b in zip(left, part)]
    # The 4-cycle pipeline fill is too small to draw; the label is the full CPI.
    for j, total, r in zip(y, left, rows):
        ax.text(total + 0.03, j, f"{int(r['cycles']) / int(r['instret']):.2f}", va="center",
                fontsize=9, color=ink)
    ax.set_yticks(list(y), [r["program"] for r in rows], fontsize=9)
    ax.set_xlabel("Cycles per instruction", color=muted)
    ax.set_title(sys.argv[3], loc="left", color=ink, fontsize=12)
    ax.legend(frameon=False, fontsize=9, loc="lower right")
    ax.tick_params(colors=muted)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    fig.tight_layout()
    fig.savefig(sys.argv[2], dpi=110)


if __name__ == "__main__":
    main()
