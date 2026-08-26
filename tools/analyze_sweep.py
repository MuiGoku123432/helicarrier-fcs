#!/usr/bin/env python3
"""Analyse an RPM sweep produced by /fcs/sweep.lua.

Fits the propeller thrust curve, checks the thrust/weight unit question, and
reports the per-bearing spread that the corner aggregates cannot show.

    tools/analyze_sweep.py flight-logs/sweep_<utc>.csv

Also accepts a full flight CSV from /fcs/main.lua (--flight), in which case
rows are grouped by commanded RPM and the settled tail of each group is used.
"""

import argparse
import csv
import math
import sys
from collections import defaultdict

CORNERS = ["FL", "FR", "RL", "RR"]
BEARINGS = [1, 2]


def number(value):
    """CSV cells are strings; empty means 'not reported', which is not zero."""
    if value is None or value == "":
        return None
    try:
        return float(value)
    except ValueError:
        return None


def fit_power_law(points):
    """Least squares on log(thrust) vs log(rpm): thrust = a * rpm^k."""
    usable = [(r, t) for r, t in points if r > 0 and t and t > 0]
    if len(usable) < 2:
        return None, "need at least two non-zero RPM points with thrust"

    n = len(usable)
    xs = [math.log(r) for r, _ in usable]
    ys = [math.log(t) for _, t in usable]
    sx, sy = sum(xs), sum(ys)
    sxx = sum(x * x for x in xs)
    sxy = sum(x * y for x, y in zip(xs, ys))

    denominator = n * sxx - sx * sx
    if abs(denominator) < 1e-12:
        return None, "all RPM points identical; cannot fit"

    k = (n * sxy - sx * sy) / denominator
    intercept = (sy - k * sx) / n
    a = math.exp(intercept)

    mean_y = sy / n
    ss_tot = sum((y - mean_y) ** 2 for y in ys)
    ss_res = sum((y - (intercept + k * x)) ** 2 for x, y in zip(xs, ys))
    r2 = 1 - ss_res / ss_tot if ss_tot > 0 else 1.0

    return {"k": k, "a": a, "r2": r2, "n": n}, None


def load_sweep(path):
    """Sweep CSV: already one settled row per step."""
    steps = []
    with open(path, newline="") as handle:
        for row in csv.DictReader(handle):
            rpm = number(row.get("commanded_rpm"))
            if rpm is None:
                continue
            steps.append((rpm, row))
    return steps


def load_flight(path):
    """Flight CSV: group by commanded RPM, keep the settled tail of each group.

    The first samples after a command still show the kinetic network spinning
    up, so averaging the whole group biases every point low. Take the last
    third, which is settled by construction.
    """
    groups = defaultdict(list)
    with open(path, newline="") as handle:
        for row in csv.DictReader(handle):
            rpms = {number(row.get(f"{c.lower()}_target_rpm")) for c in CORNERS}
            rpms.discard(None)
            # Only rows where all four corners agree on the command are a clean
            # data point; mixed rows are mid-transition.
            if len(rpms) != 1:
                continue
            groups[rpms.pop()].append(row)

    steps = []
    for rpm in sorted(groups):
        rows = groups[rpm]
        tail = rows[max(0, len(rows) * 2 // 3):]
        if tail:
            steps.append((rpm, tail[-1]))
    return steps


def corner_thrust(row, corner):
    return number(row.get(f"{corner.lower()}_thrust"))


def total_thrust(row):
    values = [corner_thrust(row, c) for c in CORNERS]
    present = [v for v in values if v is not None]
    return sum(present) if len(present) == len(CORNERS) else None


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("csv", help="sweep_<utc>.csv, or a flight CSV with --flight")
    parser.add_argument("--flight", action="store_true",
                        help="input is a full flight log rather than a sweep log")
    parser.add_argument("--mass", type=float, default=None,
                        help="craft mass; read from the CSV when present")
    parser.add_argument("--gravity", type=float, default=None,
                        help="gravity magnitude; read from the CSV when present")
    args = parser.parse_args()

    steps = load_flight(args.csv) if args.flight else load_sweep(args.csv)
    if not steps:
        sys.exit("no usable rows found")

    # Mass and gravity live in the flight CSV; the sweep CSV does not repeat
    # them, so fall back to the flags there.
    mass, gravity = args.mass, args.gravity
    for _, row in steps:
        mass = mass or number(row.get("mass"))
        g = number(row.get("gravity_y"))
        gravity = gravity or (abs(g) if g is not None else None)

    print(f"source      : {args.csv}")
    print(f"steps       : {len(steps)}")

    # ---- thrust curve ----------------------------------------------------
    points = []
    print()
    print("RPM CURVE")
    print(f"  {'rpm':>6}  {'total thrust':>14}  {'per corner':>12}  {'T/W':>8}")
    weight = mass * gravity if mass and gravity else None

    for rpm, row in steps:
        total = total_thrust(row)
        points.append((rpm, total))
        tw = f"{total / weight:.4f}" if (total and weight) else "-"
        per = f"{total / 4:.1f}" if total else "-"
        shown = f"{total:.1f}" if total is not None else "-"
        print(f"  {rpm:>6.0f}  {shown:>14}  {per:>12}  {tw:>8}")

    fit, error = fit_power_law(points)
    print()
    print("FIT  thrust = a * rpm^k")
    if not fit:
        print(f"  failed: {error}")
    else:
        print(f"  k  (exponent) = {fit['k']:.4f}")
        print(f"  a  (coeff)    = {fit['a']:.6g}")
        print(f"  r2            = {fit['r2']:.6f}  over {fit['n']} points")
        if fit["r2"] < 0.99:
            print("  WARNING: poor fit -- hover prediction is unreliable")

        nearest = round(fit["k"] * 2) / 2
        print(f"  nearest simple exponent: {nearest:g}"
              f"{'  (classic propeller square law)' if abs(fit['k'] - 2) < 0.1 else ''}")

        if weight:
            hover = (weight / fit["a"]) ** (1 / fit["k"])
            print()
            print("UNITS CHECK")
            print(f"  mass                 = {mass:.1f}")
            print(f"  gravity              = {gravity:.3f}")
            print(f"  weight (mass*g)      = {weight:.1f}")
            print(f"  predicted hover RPM  = {hover:.2f}")
            print("  NOTE: thrust vs MASS is dimensionally meaningless; the")
            print("        comparison that matters is thrust vs WEIGHT.")

    # ---- per-bearing spread ---------------------------------------------
    print()
    print("PER-BEARING THRUST  (magnitudes; sign is handedness, not direction)")
    header = "  {:>6}".format("rpm")
    for corner in CORNERS:
        for b in BEARINGS:
            header += f"  {corner}b{b:>1}".rjust(14)
    print(header)

    deficits = defaultdict(list)
    for rpm, row in steps:
        line = f"  {rpm:>6.0f}"
        magnitudes = {}
        for corner in CORNERS:
            for b in BEARINGS:
                value = number(row.get(f"{corner.lower()}_b{b}_thrust"))
                magnitudes[(corner, b)] = abs(value) if value is not None else None
                line += f"{abs(value):>14.2f}" if value is not None else f"{'-':>14}"
        print(line)

        present = [v for v in magnitudes.values() if v]
        if present and rpm > 0:
            best = max(present)
            for key, value in magnitudes.items():
                if value:
                    deficits[key].append(100 * (1 - value / best))

    if deficits:
        print()
        print("  deficit vs the strongest bearing at each RPM (mean %):")
        for key in sorted(deficits, key=lambda k: -sum(deficits[k]) / len(deficits[k])):
            values = deficits[key]
            mean = sum(values) / len(values)
            flag = "  <-- OUTLIER" if mean > 0.5 else ""
            print(f"    {key[0]} bearing {key[1]}: {mean:6.3f}%{flag}")

    # ---- corner-level asymmetry -----------------------------------------
    print()
    print("CORNER TOTALS AND SUPPORT READINGS")
    for rpm, row in steps:
        if rpm == 0:
            continue
        parts = []
        for corner in CORNERS:
            thrust = corner_thrust(row, corner)
            sail = number(row.get(f"{corner.lower()}_sail_power"))
            air = number(row.get(f"{corner.lower()}_airflow"))
            parts.append(f"{corner}={thrust:.1f}/sail{sail:g}/air{air:.4g}"
                         if None not in (thrust, sail, air) else f"{corner}=?")
        print(f"  {rpm:>4.0f} rpm  " + "  ".join(parts))


if __name__ == "__main__":
    main()
