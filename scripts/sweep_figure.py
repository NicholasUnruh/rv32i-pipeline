"""Figure for a cache sweep: geometric-mean CPI over the Embench programs by size
and ways (the chosen policy, best line size at each point), and each program's
modelled stall cycles per instruction at the old and the chosen geometry.

    uv run --with matplotlib python scripts/sweep_figure.py d|i <sweep.csv> <out.png>

Reads scripts/cache_sweep.py output for that side.
"""

import csv
import math
import sys
from collections import defaultdict

# side: name, policy plotted, (size, ways, line) of the old and the chosen cache
SIDES = {
    "d": ("D-cache", "lru", (1024, 2, 16), (8192, 2, 64)),
    "i": ("I-cache", "brrip", (1024, 1, 16), (16384, 8, 16)),
}


def label(key: tuple[int, int, int]) -> str:
    size, ways, line = key
    ways_text = "direct-mapped" if ways == 1 else f"{ways}-way"
    return f"{size // 1024} KB, {ways_text}, {line} B"


def main() -> None:
    if len(sys.argv) != 4 or sys.argv[1] not in SIDES:
        sys.exit(__doc__)
    name, policy, OLD, CHOSEN = SIDES[sys.argv[1]]
    rows = [r for r in csv.DictReader(open(sys.argv[2])) if r["policy"] == policy]
    by = defaultdict(list)
    for r in rows:
        by[(int(r["size"]), int(r["ways"]), int(r["line"]))].append(r)
    geo = {k: math.exp(sum(math.log(float(r["cpi"])) for r in rs) / len(rs))
           for k, rs in by.items()}
    best = min(geo.values())

    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    ink, muted = "#1d1d24", "#6b6b78"
    colors = {1: "#9bc3f2", 2: "#3987e5", 4: "#199e70", 8: "#e3a21a"}
    fig, (a, b) = plt.subplots(1, 2, figsize=(13, 4.8), gridspec_kw={"width_ratios": [1.2, 1]})

    sizes = sorted({k[0] for k in geo})
    for ways, color in colors.items():
        xs, ys = [], []
        for s in sizes:
            points = [v for k, v in geo.items() if k[0] == s and k[1] == ways]
            if points:
                xs.append(s)
                ys.append(min(points))
        a.plot(xs, ys, "o-", color=color, label=f"{ways}-way", ms=4)
    a.axhspan(best, best * 1.01, color="#c9c9d1", alpha=0.5, lw=0)
    a.text(sizes[0], best * 1.012, "within 1% of the best", fontsize=9, color=muted)
    for key, text in ((OLD, f"previous: {label(OLD)}"), (CHOSEN, f"chosen: {label(CHOSEN)}")):
        a.annotate(f"{text}\n{geo[key]:.3f}", (key[0], geo[key]), xytext=(12, 18),
                   textcoords="offset points", fontsize=9, color=ink,
                   arrowprops={"arrowstyle": "-", "color": muted})
    a.set_xscale("log", base=2)
    a.set_xticks(sizes, [f"{s // 1024} KB" if s >= 1024 else f"{s} B" for s in sizes])
    a.set_xlabel(f"{name} size (best line size at each point; {policy.upper()})", color=muted)
    a.set_ylabel("Geometric-mean CPI, 14 programs", color=muted)
    a.set_title("cache-sim sweep on the core's Embench traces, latency 10", loc="left",
                color=ink, fontsize=12)
    a.legend(frameon=False, fontsize=9)

    per = {k: {r["program"]: int(r["stall"]) / int(r["instret"]) for r in by[k]}
           for k in (OLD, CHOSEN)}
    programs = sorted(per[OLD], key=lambda p: per[OLD][p])
    programs = [p for p in programs if per[OLD][p] >= 0.01]
    y = range(len(programs))
    b.barh([j + 0.2 for j in y], [per[OLD][p] for p in programs], 0.4, color="#9bc3f2",
           label=label(OLD))
    b.barh([j - 0.2 for j in y], [per[CHOSEN][p] for p in programs], 0.4, color="#199e70",
           label=label(CHOSEN))
    b.set_yticks(list(y), programs, fontsize=9)
    b.set_xlabel(f"Modelled {name} stall cycles per instruction", color=muted)
    b.set_title("Programs with ≥ 0.01 stall CPI in the old cache", loc="left", color=ink,
                fontsize=12)
    b.legend(frameon=False, fontsize=9, loc="lower right")
    for ax in (a, b):
        ax.tick_params(colors=muted)
        for s in ("top", "right"):
            ax.spines[s].set_visible(False)
    fig.tight_layout()
    fig.savefig(sys.argv[3], dpi=110)


if __name__ == "__main__":
    main()
