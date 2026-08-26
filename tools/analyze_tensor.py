#!/usr/bin/env python3
"""Is getInertiaTensor() body-frame or world-frame?

    python3 tools/analyze_tensor.py <flight_*.csv> [...]

The tensor columns are SPARSE -- sensors.lua reads them every Nth sample -- so
this pulls the populated rows and groups them by attitude.

A BODY-frame tensor is constant no matter how the craft is tilted. A WORLD-frame
one rotates with the craft, and the craft's own 4-5 deg of tilt is enough to see
it: t[1][1] and t[2][2] differ by 46 million, so a 5 deg mix moves them by about
sin^2(5 deg) = 0.8%, roughly 350,000 units. Two archived reads taken at the same
attitude agreed to 0.00015%, so that signal sits far above the noise floor.
"""
import csv, sys, math

COLS = ["inertia_xx", "inertia_yy", "inertia_zz",
        "inertia_xy", "inertia_xz", "inertia_yz"]

rows = []
for path in sys.argv[1:]:
    with open(path) as fh:
        for r in csv.DictReader(fh):
            if not r.get("inertia_xx"):
                continue
            try:
                rows.append({
                    "roll": float(r.get("roll_deg") or 0),
                    "pitch": float(r.get("pitch_deg") or 0),
                    "yaw": float(r.get("yaw_deg") or 0),
                    **{c: float(r[c]) for c in COLS if r.get(c)},
                })
            except (ValueError, KeyError):
                pass

if not rows:
    sys.exit("No populated inertia rows found. Was computer 1 rebooted after "
             "the column change? The running logger holds the old column list.")

print(f"{len(rows)} tensor samples\n")
print(f"{'roll':>7} {'pitch':>7} {'tilt':>6} " + " ".join(f"{c[8:]:>14}" for c in COLS))
for r in rows[:: max(1, len(rows) // 20)]:
    tilt = math.hypot(r["roll"], r["pitch"])
    print(f"{r['roll']:7.2f} {r['pitch']:7.2f} {tilt:6.2f} "
          + " ".join(f"{r.get(c, float('nan')):14.2f}" for c in COLS))

print()
tilts = [math.hypot(r["roll"], r["pitch"]) for r in rows]
print(f"attitude range sampled: tilt {min(tilts):.2f} .. {max(tilts):.2f} deg")
if max(tilts) - min(tilts) < 2.0:
    print("WARNING: too little attitude spread to decide. Need samples at")
    print("         clearly different tilts -- fly a pulse and re-run.")

print()
verdict = "BODY-frame"
for c in COLS:
    vals = [r[c] for r in rows if c in r]
    if len(vals) < 2:
        continue
    lo, hi = min(vals), max(vals)
    scale = max(abs(lo), abs(hi)) or 1.0
    spread = (hi - lo) / scale * 100
    flag = ""
    if spread > 0.1:
        flag = "  <- VARIES"
        verdict = "WORLD-frame (rotates with the craft)"
    print(f"  {c:12s} {lo:16.2f} .. {hi:16.2f}   spread {spread:7.4f}%{flag}")

print(f"\nVERDICT: {verdict}")
print("A body-frame tensor means t[i][j] indexes BODY axes, so 'index 3 is the")
print("cheap axis' and the 32% coupling claim both hold as written.")
