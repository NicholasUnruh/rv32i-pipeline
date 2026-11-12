#!/usr/bin/env python3
"""Compile the DE1-SoC build at several fitter seeds and print its fit and timing.

fmax_seeds.py SEED...

Placement changes with the fitter's seed, and so does Fmax, so one compile can't
tell a design change from placement noise. Each seed gets its own copy of the
project in build/quartus-seed<seed>/ (needs build/bench/bench.hex from `make check`).
Prints one CSV row per seed: ALMs, registers, M10K blocks, slow 85 °C Fmax and
setup slack, and the worst setup path's end points.
"""

from __future__ import annotations

import csv
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COMPILE_TIMEOUT_S = 3600

PATH_TCL = """project_open rv32i
create_timing_netlist -model slow -temperature 85 -voltage 1100
read_sdc
update_timing_netlist
report_timing -setup -npaths 1 -detail summary -file worst_path.txt
delete_timing_netlist
project_close
"""


def compile_seed(seed: int) -> dict:
    # The QSF names sources as ../../rtl/..., so the copy sits two levels below ROOT.
    project = ROOT / "build" / f"quartus-seed{seed}"
    shutil.rmtree(project, ignore_errors=True)
    project.mkdir(parents=True)
    for f in (ROOT / "quartus").iterdir():
        shutil.copy(f, project)
    shutil.copy(ROOT / "build" / "bench" / "bench.hex", project / "program.hex")
    with open(project / "rv32i.qsf", "a") as qsf:
        qsf.write(f"set_global_assignment -name SEED {seed}\n")
    subprocess.run(["quartus_sh", "--flow", "compile", "rv32i"], cwd=project, check=True,
                   stdout=subprocess.DEVNULL, timeout=COMPILE_TIMEOUT_S)
    (project / "worst_path.tcl").write_text(PATH_TCL)
    subprocess.run(["quartus_sta", "-t", "worst_path.tcl"], cwd=project, check=True,
                   stdout=subprocess.DEVNULL, timeout=COMPILE_TIMEOUT_S)
    fit = (project / "output_files/rv32i.fit.summary").read_text()
    sta = (project / "output_files/rv32i.sta.rpt").read_text()
    summary = (project / "output_files/rv32i.sta.summary").read_text()
    path = next(l for l in (project / "worst_path.txt").read_text().splitlines()
                if re.match(r"^; -?\d+\.\d+ ;", l))
    cells = [c.strip() for c in path.strip(";").split(";")]
    num = lambda s: int(s.replace(",", ""))
    return {
        "seed": seed,
        "alms": num(re.search(r"Logic utilization \(in ALMs\) : ([\d,]+)", fit)[1]),
        "registers": num(re.search(r"Total registers : ([\d,]+)", fit)[1]),
        "m10k": num(re.search(r"Total RAM Blocks : ([\d,]+)", fit)[1]),
        "fmax_mhz": float(re.search(
            r"; Slow 1100mV 85C Model Fmax Summary +;.*?\n; ([\d.]+) MHz", sta, re.S)[1]),
        "setup_slack_ns": float(re.search(
            r"Slow 1100mV 85C Model Setup 'CLOCK_50'\nSlack : ([-\d.]+)", summary)[1]),
        "worst_from": cells[1],
        "worst_to": cells[2],
    }


def main() -> int:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    writer = None
    for seed in map(int, sys.argv[1:]):
        row = compile_seed(seed)
        if writer is None:
            writer = csv.DictWriter(sys.stdout, fieldnames=list(row))
            writer.writeheader()
        writer.writerow(row)
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
