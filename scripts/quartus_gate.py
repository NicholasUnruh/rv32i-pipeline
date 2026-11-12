#!/usr/bin/env python3
"""Fail a Quartus build that misses timing or places a pin other than where the QSF says.

quartus_gate.py timing <sta.rpt> | pins <pin report> <qsf>
"""
from __future__ import annotations

import re
import sys
from pathlib import Path


def worst_slack(sta_report: str) -> float | None:
    """Return the most negative multicorner slack (setup, hold, recovery, removal, pulse width)."""
    match = re.search(r"^; Worst-case Slack\s*;(.*)$", sta_report, flags=re.MULTILINE)
    if not match:
        return None
    cells = match.group(1).split(";")
    values = [float(cell) for cell in cells if re.fullmatch(r"\s*-?\d+(\.\d+)?\s*", cell)]
    return min(values) if values else None


def fmax(sta_report: str) -> list[str]:
    """Return the Fmax Summary rows (Fmax, restricted Fmax, clock, corner model)."""
    return [" ".join(cell.strip() for cell in line.strip(";").split(";"))
            for line in re.findall(r"^; [\d.]+ MHz.*$", sta_report, flags=re.MULTILINE)]


def pin_errors(qsf: str, pin_report: str) -> list[str]:
    """Compare every location and I/O standard assignment with the fitter's result."""
    pins = dict(re.findall(r"^set_location_assignment\s+PIN_(\S+)\s+-to\s+(\S+)", qsf, flags=re.M))
    wanted_pin = {signal: pin for pin, signal in pins.items()}
    wanted_io = {signal: io for io, signal in re.findall(
        r'^set_instance_assignment -name IO_STANDARD "([^"]+)" -to (\S+)', qsf, flags=re.M)}
    if not wanted_pin:
        return ["no location assignments in the QSF"]
    placed = {signal: (pin, io.strip()) for signal, pin, io in re.findall(
        r"^(\S+)\s*:\s*(\S+)\s*:\s*\S+\s*:\s*([^:]*?)\s*:", pin_report, flags=re.M)}
    errors = []
    for signal, pin in wanted_pin.items():
        actual = placed.get(signal, (None, None))
        if actual != (pin, wanted_io.get(signal)):
            errors.append(f"{signal}: wanted {pin} {wanted_io.get(signal)}, "
                          f"placed {actual[0]} {actual[1]}")
    return errors


def main() -> int:
    mode, report = sys.argv[1], Path(sys.argv[2])
    if mode == "pins":
        errors = pin_errors(Path(sys.argv[3]).read_text(encoding="utf-8"),
                            report.read_text(encoding="utf-8"))
        print("\n".join(errors) or "all pins placed as assigned")
        return 1 if errors else 0
    text = report.read_text(encoding="utf-8")
    slack = worst_slack(text)
    print("\n".join(fmax(text)))
    print(f"worst slack: {slack} ns")
    return 0 if slack is not None and slack >= 0 else 1


if __name__ == "__main__":
    sys.exit(main())
