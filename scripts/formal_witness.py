"""Draw the formal reach witness: the tracked word A stored, evicted dirty,
refilled and read back, one column per cycle.

    uv run --with matplotlib python scripts/formal_witness.py <trace.vcd> <out.png>

<trace.vcd> is formal/dcache_reach/engine_0/trace.vcd from `sby -f dcache.sby reach`.
"""

import sys

STATES = ["", "WB", "REQ", "FILL", "RERD"]  # IDLE shows as blank


def read_vcd(path: str, names: list[str]) -> dict[str, list[int]]:
    """Each named top-level signal's value at every rising clock edge."""
    ids, cur, rows, scope = {}, {}, [], []
    for line in open(path):
        w = line.split()
        if not w:
            continue
        if w[0] == "$scope":
            scope.append(w[2])
        elif w[0] == "$upscope":
            scope.pop()
        elif w[0] == "$var":
            name = ".".join(scope[1:] + [w[4]])
            if name in names:
                ids[w[3]] = name
        else:
            if w[0][0] == "b" and len(w) == 2 and w[1] in ids:
                name, value = ids[w[1]], int(w[0][1:].replace("x", "0"), 2)
            elif w[0][0] in "01" and w[0][1:] in ids:
                name, value = ids[w[0][1:]], int(w[0][0])
            else:
                continue
            if name == "clk" and value == 1 and cur.get("clk") == 0:
                rows.append(dict(cur))  # values before this edge: the cycle just ended
            cur[name] = value
    rows.append(dict(cur))
    return {n: [r.get(n, 0) for r in rows] for n in names}


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    names = ["clk", "a", "read", "write", "addr", "stall", "dut.state", "mem_wstrb",
             "mem_addr", "mem_a", "expected", "rdata"]
    v = read_vcd(sys.argv[1], names)
    n = len(v["clk"])
    a = v["a"][0]
    lines = {}  # line address -> letter, A's line first
    def label(addr: int) -> str:
        line = addr >> 3
        if line == a >> 1:  # 8-byte lines: A' is the other word of A's line
            return "A" if (addr >> 2) == a else "A'"
        lines.setdefault(line, "BCDEFG"[len(lines)])
        return lines[line]

    rows = {"access": [], "state": [], "mem write": [], "memory[A]": [], "expected": [],
            "load data": []}
    for t in range(n):
        done = not v["stall"][t]
        acc = ""
        if v["read"][t] or v["write"][t]:
            acc = ("ST " if v["write"][t] else "LD ") + label(v["addr"][t])
        rows["access"].append(acc)
        rows["state"].append(STATES[v["dut.state"][t]] if v["dut.state"][t] < 5 else "?")
        rows["mem write"].append(label(v["mem_addr"][t]) if v["mem_wstrb"][t] else "")
        rows["memory[A]"].append(f"{v['mem_a'][t]:08x}")
        rows["expected"].append(f"{v['expected'][t]:08x}")
        hit_a = done and v["read"][t] and (v["addr"][t] >> 2) == a
        rows["load data"].append(f"{v['rdata'][t]:08x}" if hit_a else "")

    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import Rectangle

    ink, muted, stall_c, good = "#1d1d24", "#6b6b78", "#f2d7a0", "#9fd8bf"
    fig, ax = plt.subplots(figsize=(15, 3.6))
    keys = list(rows)
    for t in range(n):
        if v["stall"][t]:
            ax.add_patch(Rectangle((t - 0.5, -0.5), 1, len(keys), color=stall_c, lw=0))
        for r, k in enumerate(keys):
            text = rows[k][t]
            if k in ("memory[A]", "expected") and t and text == rows[k][t - 1]:
                text = ""  # print hex values only where they change
            if k == "load data" and text:
                ax.add_patch(Rectangle((t - 0.5, r - 0.5), 1, 1, color=good, lw=0))
            ax.text(t, r, text, ha="center", va="center", fontsize=7, color=ink,
                    rotation=90 if k in ("memory[A]", "expected", "load data") and text else 0)
    ax.set_xlim(-0.5, n - 0.5)
    ax.set_ylim(len(keys) - 0.5, -0.5)
    ax.set_yticks(range(len(keys)), keys, fontsize=9)
    ax.set_xticks(range(0, n, 2))
    ax.set_xlabel("Cycle (shaded: cache stalls the pipeline)", color=muted)
    ax.set_title("Formal witness: A is stored, evicted dirty (written back), refilled and "
                 "loaded; the load returns the stored value", loc="left", color=ink, fontsize=11)
    ax.tick_params(colors=muted, length=0)
    for s in ax.spines.values():
        s.set_visible(False)
    fig.tight_layout()
    fig.savefig(sys.argv[2], dpi=110)


if __name__ == "__main__":
    main()
