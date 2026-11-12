"""Figure for the cache-sim cross-check: RTL and cache-sim counts per geometry, and
what each injected bug changes.

    uv run --with matplotlib python scripts/crosscheck_figure.py <results dir> <out.png>

Reads crosscheck.csv (scripts/crosscheck.py) and mutants.csv
(scripts/crosscheck_mutants.sh) from <results dir>.
"""

import csv
import sys
from collections import defaultdict
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    results, out = Path(sys.argv[1]), Path(sys.argv[2])
    rows = list(csv.DictReader(open(results / "crosscheck.csv")))
    mutants = list(csv.DictReader(open(results / "mutants.csv")))

    totals = defaultdict(lambda: defaultdict(int))
    for r in rows:
        key = f"{r['sets']}×{r['ways']}×{r['line']} B"
        for k in ("rtl_misses", "sim_misses", "rtl_writebacks", "sim_writebacks",
                  "event_lines", "differing_lines"):
            totals[key][k] += int(r[k])
    keys = sorted(totals, key=lambda k: -totals[k]["rtl_misses"])

    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    ink, muted, rtl, sim, bad = "#1d1d24", "#6b6b78", "#3987e5", "#9bc3f2", "#d1495b"
    fig, (a, b) = plt.subplots(1, 2, figsize=(13, 4.6), gridspec_kw={"width_ratios": [1.6, 1]})

    x = range(len(keys))
    w = 0.2
    for i, (field, label, color) in enumerate([
        ("rtl_misses", "Misses, RTL", rtl), ("sim_misses", "Misses, cache-sim", sim),
        ("rtl_writebacks", "Writebacks, RTL", "#199e70"),
        ("sim_writebacks", "Writebacks, cache-sim", "#8fd3b9")]):
        a.bar([j + (i - 1.5) * w for j in x], [totals[k][field] or float("nan") for k in keys], w,
              color=color, label=label)
    a.set_yscale("log")
    for j, k in enumerate(keys):
        if totals[k]["rtl_writebacks"] == 0:
            a.text(j + w, 1.1, "0", ha="center", fontsize=9, color=ink)
    a.set_xticks(list(x), keys, fontsize=9)
    a.set_xlabel("Sets × ways × line (C benchmark + 40 riscv-tests per geometry)", color=muted)
    a.set_ylabel("Count", color=muted)
    lines = sum(t["event_lines"] for t in totals.values())
    differ = sum(t["differing_lines"] for t in totals.values())
    a.set_title(f"RTL vs cache-sim: {differ} of {lines:,} per-access events differ",
                loc="left", color=ink, fontsize=12)
    a.legend(frameon=False, fontsize=9, ncol=2)

    labels = [f"{m['mutant'].replace('_', ' ')}\n{m['sets']}×{m['ways']}×{m['line']} B"
              for m in mutants]
    count_error = [abs(int(m["rtl_misses"]) - int(m["sim_misses"]))
                   + abs(int(m["rtl_writebacks"]) - int(m["sim_writebacks"])) for m in mutants]
    events = [int(m["differing_lines"]) for m in mutants]
    y = range(len(mutants))
    b.barh([j + 0.2 for j in y], [c or float("nan") for c in count_error], 0.4, color=muted,
           label="Count difference (misses + writebacks)")
    b.barh([j - 0.2 for j in y], events, 0.4, color=bad, label="Event lines that differ")
    for j, c in zip(y, count_error):
        if c == 0:
            b.text(1, j + 0.2, "0: totals agree", va="center", fontsize=9, color=ink)
    b.set_xscale("log")
    b.set_yticks(list(y), labels, fontsize=9)
    b.invert_yaxis()
    b.set_title("Injected RTL bugs, C benchmark", loc="left", color=ink, fontsize=12)
    b.legend(frameon=False, fontsize=9, loc="lower right")
    for ax in (a, b):
        ax.tick_params(colors=muted)
        for s in ("top", "right"):
            ax.spines[s].set_visible(False)
    fig.tight_layout()
    fig.savefig(out, dpi=110)


if __name__ == "__main__":
    main()
