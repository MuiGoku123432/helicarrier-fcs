# Helicarrier FCS — session handoff

Last updated: 2026-08-26. bearing_5 repair VERIFIED; the craft is symmetric.
Written for a fresh session picking this up cold. Rewritten rather than patched: superseded findings are REMOVED, not
annotated, except where the wrong answer is instructive. Keep it that way.

---

## What this is

A ComputerCraft flight-control stack for a Create Aeronautics / CC:Sable
helicarrier on a **creative superflat test server**. Five Advanced Computers:
one main telemetry computer and four engine pods, over rednet.

It logs flight data, commands propeller RPM, ion thruster power and bearing
tilt, and can fly short scripted profiles (climb, hold, land). It does **not**
have a pilot-facing controller yet.

Source repo: **`~/repos/mine/luaScripts/helicarrier-fcs`** — a git repo, remote
`git@github.com:MuiGoku123432/helicarrier-fcs.git`. Moved here 2026-08-26 from
`~/repos/fcs-wireless-pods-v2`, which was NOT under version control and is now
superseded; the two were byte-identical at the import, so nothing was lost.

**There is a safety net now.** The old "back up before large edits" warning is
retired — commit instead. That matters more than it sounds: this session found
four separate cases of a test or harness encoding the flight code's mistaken
belief, and being able to bisect is worth more than any of the individual
fixes.

**Creative test world. The craft is expendable.** Prefer deploying a tool and
gathering real data over perfecting the offline harness — but see
**THE RULE** below, which is the hardest-won lesson here.

---

## START HERE: what to do first

**The bearing_5 repair is VERIFIED. It took.** The previous session's headline
open question is closed, and everything that hung off it collapses with it.

Measured from the live pod heartbeats, all four corners now agree:

| corner | bearings | per-bearing \|thrust\| | pod sail |
|---|---|---|---|
| FL | _1, _2 | 6980.5197679275 | 534 |
| FR | _3, _4 | 6980.4918912001185 | 534 |
| RL | _7, _8 | 6980.5197679275 | 534 |
| **RR** | **_5, _6** | **6980.4918912001185** | **534** |

`bearing_5` now reads bit-for-bit identical to `bearing_6`, its own partner, and
to the FR pair. Pod total `getThrust` = **13,960.98**, exactly the predicted
post-repair figure (was 13,804.41). Pod sail = **534** = 267 + 267 (was 532).

**Why a 0-RPM reading is legitimate here, given THE RULE.** It is legitimate
because the archived pre-repair probes prove it, not because it seemed safe:
`flight-logs/stabprobe_RR.txt` (isActive **false**) and
`stabprobe_RR_active.txt` (isActive **true**, 4.8 rad/s) were taken 3 minutes
apart and report `getStressImpact` = **530 in both**. The structural getters do
not depend on rotation, so comparing them at rest is valid. That same pair is
what pinned the deficit in the first place: 530 on `_5` against 534 on `_6`.

The residual FL/RL vs FR/RR split of 0.0279 units is **0.0004%** — four orders
of magnitude below the 1.121% deficit that was just fixed. Do not chase it.

**Consequences — this is the part that matters:**

- The standing roll torque is **gone**: the equilibrium offset fell from
  1.23 deg to ~0.3-0.6 deg. **But the craft still strafes** — 81 blocks in 48 s
  on a passive flight. The cause is different from what this document long
  assumed, and it is now the main open problem. See **THE STRAFE**.
- **`tiltctl.lua rolltrim` now REFUSES**, and that is deliberate: it tilts the
  port bearings 4.29 deg to cancel a torque the craft no longer has, so running
  it would CREATE the strafe it was written to remove. Manual vectoring is
  untouched and is the part that matters for yaw. `--force` overrides.
- **"Is the deficit a constant fraction or a constant offset?" is retired,
  not answered.** It only ever mattered for scaling a trim correction from 16
  RPM to 64. There is no deficit left to scale. Do not spend a sweep on it.

**So the next thing to do is item 4 on the old list, now item 1:**

**Calibrate `Aroll` / `Apitch` with `/fcs/axisresponse.lua`** (pulse demand
0.30, above the ion quantum). `authority.roll` / `authority.pitch` in
`mixer_profile.lua` are still placeholders at 0.25, and they are the hard
blocker on any attitude controller. Its roll/pitch ratio also settles the
axis-convention question the inertia tensor raised. This now runs on a
**symmetric craft**, which is exactly the condition that makes the measurement
clean — it would have been contaminated before.

Worth re-running `/fcs/rolldrift.lua` first if you want the self-levelling
stiffness re-measured without the standing torque; it is a passive +5 block
flight and it is cheap.

---

## THE RULE: an inactive bearing reading proves nothing

Four separate "findings" in this document turned out to be readings taken while
`isActive` was false:

| reading | recorded as | actually |
|---|---|---|
| `getThrustVector` | "returns nil on all eight" | array `{1=,2=,3=}`, always populated |
| `setManualTarget` | "stored but ignored" | tracks exactly, when active |
| `getRotationSpeed` | "always 0" | 4.8 at 16 RPM, when active |
| `getStabilizationStrength` | "0 — nothing holds it" | **1.0**, when active |

**Check `isActive` before believing any bearing reading.** Two more were value
SHAPE errors — `getThrustVector` is an array, not `{x,y,z}`; CC:Sable
quaternions are `{v=,a=}`, not `{x,y,z,w}` — so a `nil` on this mod is a shape
question until proven otherwise.

And the harness corollary, learned expensively: **a harness only tests what you
already believe about the hardware.** A crash-landing descent passed every
harness run because the harness modelled ion thrust as continuous, exactly as I
wrongly did.

---

## Current state

- All four pods online, sub-second telemetry, ~5% command rejections (all the
  tail of an occasional disarm — do not chase it to zero)
- Logging to `/fcs/logs/flight_<utc-ms>.csv`, 600 KB x 10 files
- The craft has flown under script: climb, hold, and a rate-controlled landing
- **The hull self-levels** (measured — see below)
- bearing_5 repair: **VERIFIED** — all four corners symmetric (see START HERE)
- **The craft is now symmetric.** No standing roll torque — but it STILL
  STRAFES, for a different reason. See **THE STRAFE**.

## Topology

| Computer | Role | Label | Corner | RSC | Bearings |
|---|---|---|---|---|---|
| 0 | unrelated flight instrument (do not touch) | — | — | — | — |
| 1 | FCS-DEV, telemetry + commands | — | — | none | none |
| 2 | pod | ENG-FL | FL | `Create_RotationSpeedController_0` | `gyroscopic_propeller_bearing_1, _2` |
| 3 | pod | ENG-FR | FR | `Create_RotationSpeedController_1` | `_3, _4` |
| 4 | pod | ENG-RL | RL | `Create_RotationSpeedController_3` | `_7, _8` |
| 5 | pod | ENG-RR | RR | `Create_RotationSpeedController_2` | `_5, _6` |

**RSC numbering does not follow corner order** (FL=0, FR=1, RR=2, RL=3). Always
read each pod's own `/pod/device_report.txt`; never extrapolate indices.

Each pod: 32 ion thrusters, one RSC, two counter-rotating gyroscopic propeller
bearings. FCS-DEV: ender modem + wired modem + monitor. All five use **ender
modems** (unlimited range).

## Where things live

Remote host `cfanch06@192.168.10.29`, server dir
`server/creative-test-superflat`. Computer files:
`server/creative-test-superflat/world/computercraft/computer/<id>/`

Deploy/inspect via `packDev/pack_config.py` helpers (`cfg.ssh_prefix()`, rsync).
The instance's sync tooling lives in
`"~/Library/Application Support/PrismLauncher/instances/F&F Server/packDev/"`
and never touches `world/`, so computer files are safe from pack syncs.

Rescued flight logs: `~/repos/mine/luaScripts/helicarrier-fcs/flight-logs/`

---

## MEASURED PHYSICS — use these numbers


### Propellers

    thrust     = 6968.34 per RPM, exactly linear (r2 = 1.000000, 8 to 96 RPM)
    real force = getThrust x air_pressure(at the PROPELLER's altitude)

`getThrust` reports the value **before** the air-density factor. Air pressure at
the logged craft origin is 1.4309, but the pressure that explains the measured
hover occurs **+14.0 blocks above the origin** (`/fcs/airprofile.lua`; the
exponential fit agrees at +14.8). The propellers sit about there. Effective
correction at this altitude: **×1.353**.

| RPM | share of craft weight |
|---|---|
| 16 | 13.0% |
| 64 | **52.1%** |
| 122–124 | 100% (props-only hover, bracketed) |

**The atmosphere IS very nearly a clean exponential below y=280** — H = **250
blocks**, not 263.9. Every control-point segment below 280 has
`slope/value = -0.004` to five digits. The old r2 = 0.976 fit failed because it
was fitted ACROSS the collapse above 280, not because the atmosphere is messy.

**HARD CEILING at y = 320: pressure is exactly 0.** Props make no thrust there.
The curve departs the exponential at y=280 and dives to zero over the last 40
blocks. This is a flight envelope limit and it had not been recorded anywhere.

The whole curve is five control points from `getPoints()`, interpolated with a
**cubic Hermite** spline on (altitude, value, slope) — derived from the data,
not assumed: Hermite matches the measured pressures to 3e-6..8e-6, the
exponential to only 6e-5. Use **`fcs/atmosphere.lua`**, which reads those points
once and evaluates locally for zero Sable cost.

Because pressure falls with altitude, prop thrust falls as the craft climbs:
**altitude is self-stabilising** (rise → less thrust → sink). Good for control,
but "hover RPM" is meaningless without a stated altitude.

### The craft is NOWHERE NEAR power-limited

The +23 hold ceiling is a control failure, not a thrust shortage. The hold uses
**17% of available ion thrust**.

Held continuously, with props at 64 RPM (prop share back-calculated from the
measured hold: **48.1% of weight at origin**, 43.9% at +23):

| ion level | ions, as weight | hovers at |
|---|---|---|
| 2 | 0.446 | cannot lift |
| **3** | **0.668** | **+93 blocks** |
| 4 | 0.891 | above the y=320 ceiling |
| 5+ | 1.114+ | anywhere — ions alone exceed weight |

- **Level 3 held continuously would hover at +93 blocks.** The craft settles at
  +23 because it spends only ~50% of the time there.
- **Level 5 hovers with no prop help at all**, so the y=320 pressure ceiling is
  not a thrust limit either.
- Full applied ion power is **3.342x weight** = **25.8 blocks/s^2** of climb.
- Holding +30 needs **57% duty** on level 3. The loop reached 61% transiently
  during the climb and settled to 48-57% — right on the boundary, which is
  exactly why it touched +27.6 and then sank.

So the fix is control authority, not more thrusters: let the altitude loop
command duty cycle directly, or reach level 4. There is margin everywhere.

*(Caveat: this back-calculation puts props at 48.1% of weight at 64 RPM where
MEASURED PHYSICS above says 52.1%. The difference is probably the altitude
reference for the air-density correction. It does not change the conclusion —
at either figure the craft is using well under a quarter of its thrust.)*

### The settle gate worked — pitch measured clean, ratio now legal

2026-08-26 11:05, `flight-logs/axisresponse_result_run12_settlegate.txt`.

| | run 11 (old gate) | run 12 (new gate) |
|---|---|---|
| roll at pitch-pulse start | **-6.89 deg** | **+0.48 deg** |
| roll/pitch ratio | **11.02** — exceeds the 4.49 bound | **1.67** — legal |
| pitch response | 2.0681 (contaminated) | **8.4040** |

    RESPONSE MATRIX (deg/s^2 per unit demand):
      demand              roll resp     pitch resp
      roll                  14.0724        -1.4054
      pitch                  4.9651         8.4040

No SUSPECT flag: both pulses started from a genuinely settled craft. **Pitch
has now been measured properly for the first time**, and the ratio 1.67 implies
an arm ratio of 0.37 — a craft about 2.7x longer than wide, which independently
matches the ~2.4x estimated from run 8's geometry. Two different runs agreeing
on the hull's proportions is a real cross-check.

**BUT ROLL IS STILL DRIFTING, and it is not converging:**

| run | roll response | collective at hold |
|---|---|---|
| 9 | 28.33 | — |
| 10 | 26.93 | 0.223 |
| 11 | 22.79 | 0.192 |
| **12** | **14.07** | 0.197 |

A **2.0x range, monotonically declining**. That is not measurement noise; noise
scatters, it does not trend. Do not quote a roll authority until this is
understood.

**Leading hypothesis: the pulse differential is quantisation-dependent and the
trim is moving collective underneath it.** The demand is 0.3 x authority 0.25 =
+/-0.0375 per corner, a total spread of 0.075 = **1.125 ion quanta**. Whether
that lands as a ONE-level or TWO-level differential depends on where collective
sits on the level grid:

    collective 0.200 -> corners 0.2375 / 0.1625 -> levels 3 / 2 -> 1 level
    collective 0.230 -> corners 0.2675 / 0.1925 -> levels 4 / 2 -> 2 LEVELS
    collective 0.170 -> corners 0.2075 / 0.1325 -> levels 3 / 1 -> 2 LEVELS

A 2x swing in applied torque, which is exactly the observed range. The
collective REPORTED at hold does not settle it, because trim keeps moving
collective during the pulse.

**Confirming it needs the per-sample corner powers, i.e. `main.lua` running.**
It has been down since 09:57 (heartbeat frozen at sequence 1113) and no flight
CSV exists for runs 9-12. Start the logger in its own tab before the next run.

The honest reading of this project's own lesson — *"a correction smaller than
one ion level is not a small correction, it is an intermittent large one"* —
is that a pulse spanning 1.125 quanta was never a clean experiment. A pulse
sized to an EXACT integer number of levels, or one that pins collective for
its duration, would remove the ambiguity.

### First COMPLETE run — and why the pitch number is still not usable

2026-08-26 10:52. No abort, both axes pulsed, landed clean. The cancel worked:
residual **0.0000** and **0.0375** deg/s.

    RESPONSE MATRIX (deg/s^2 per unit demand):
      demand              roll resp     pitch resp
      roll                  22.7856         4.0426
      pitch                 -2.3428         2.0681

**The roll/pitch ratio of 11.02 is physically impossible.**

`alpha = torque/I`, and both axes are driven by the same one-level force, so
the ratio is `arm_ratio x t[1][1]/t[3][3]` = `arm_ratio x 4.49`. A ratio of
11.02 needs `arm_ratio` = 2.45, i.e. a craft two and a half times WIDER than
long. But `t[3][3]` — the bow axis — is the SMALLEST of the three diagonals,
and rolling about the bow swings the craft's width; a wide craft would have the
LARGEST inertia there. **The craft is long and narrow, so `arm_ratio < 1` and
the ratio cannot exceed 4.49.** 11.02 is not merely high, it is on the wrong
side of a hard bound.

**The cause was in the report all along:** the pitch pulse began with the craft
**banked -6.89 degrees**. The hull self-levels, so a residual bank is not a
harmless offset — the restoring moment ACCELERATES the craft throughout the
measurement, and `t[2][3]` coupling the axes at 32% puts part of that on the
other channel. Pitch cross-talk to roll was -2.34, **113% of the pitch
diagonal**: the pitch pulse rotated the craft about roll as hard as it did
about pitch.

The old settle gate could not catch it. It checked only the commanded axis,
only its RATE and never the angle, took that rate from `Session:rates` — the
Sable channel that reads exactly 0.0000 in a third of samples — and then waited
a fixed 8 s once and proceeded regardless.

Replaced with `waitUntilSettled`: **both axes, angle AND rate**, rate
differenced from the angle, and an explicit SUSPECT flag on any axis that had
to give up waiting. The summary now also checks the ratio against the
`t[1][1]/t[3][3]` bound and says so loudly when it is exceeded — a number on
the wrong side of physics must never be quotable as a calibration.

**Settling is PASSIVE and slow.** The cancel nulls the RATE, which parks the
craft at whatever bank it reached. Only self-levelling recovers that, measured
at 6.2 -> 1.5 deg over 47 s with a ~42 s period — and being underdamped, angle
and rate peak in antiphase, so "level AND still" takes more than one period to
coincide. The timeout is 90 s for that reason.

**The real fix is ACTIVE damping** — a rate term using the authority this tool
measures. That is the next piece of work, and it is what the whole calibration
exists to enable. Roll is already good enough to build it:

| run | roll response |
|---|---|
| 9 | 28.33 |
| 10 | 26.93 |
| 11 | 22.79 |

Spread 20%, all three from properly-commanded pulses. Pitch has **never** been
measured from a settled craft.

### The pulse budget itself was unsafe — 10 degrees was never viable

Both 40-degree events had a second cause underneath the starved cancel, and it
would have bitten even with the cancel working.

**Budget the whole maneuver, not just the pulse.** The cancel undoes the same
rate at the same alpha, so it sweeps roughly AS FAR AGAIN:

| pulse cap | peak rate | cancel sweep | sampling lag | TOTAL | vs 28 deg abort |
|---|---|---|---|---|---|
| 10 deg | 12.9 deg/s | 10 deg | 3.2 deg | **23.2** | marginal |
| 8 deg | 11.5 | 8 | 2.9 | 18.9 | ok |
| **6 deg** | **10.0** | **6** | **2.5** | **14.5** | comfortable |

Run 10's pulse reached 12.9 deg (overshooting the 10 cap through sampling
lag). Even a perfect cancel would have put the total near 29 — **it would have
aborted on geometry alone.**

Two changes: the cap is **6 degrees**, and the pulse now stops on the
**PROJECTED** angle — one sample ahead at the current rate — rather than the
measured one, since the craft keeps rotating between samples at several degrees
each. Verified in the harness: it stops at 5.54 deg with no overshoot, 8
samples, and still measures 12.0024, identical to the full-length pulse.

### The CANCEL was starved too — the safety action was the last one fixed

Second 40-degree abort, 2026-08-26 10:35. The pulse itself was fine: it ended
on angle at 1.88 s / 7 samples / 12.9 deg exactly as designed, and measured
26.93 against the previous run's 28.33.

Then: **`residual roll rate after cancel: 5.7496 deg/s`**. The reversed pulse
had not taken, the craft kept rolling, and it aborted at 40 deg.

`session.cheapRead = false` was being restored just BEFORE the cancel, so the
cancel loop ran on ~1.6 s telemetry reads — longer than the pods' 750 ms
`COMMAND_TIMEOUT`. The watchdog forced every bank to a uniform
`commsLossPower`, which applies no differential, so the cancel was
substantially never applied. **The pulse had been fixed and the thing meant to
undo it had not**, which is the worse half to leave starved.

Two changes:

- `cheapRead` now stays on through the cancel AND the recovery hold, and both
  pass their sample to `trim()` instead of making a second full read.
- **The cancel ends when the RATE IS ARRESTED**, not after a fixed time
  (`cancelTimeoutSeconds` 6.0 s is only a ceiling, and failing to arrest within
  it now prints a warning). Equal-and-opposite for equal time only nulls the
  rate if the torque actually applied for that time — precisely the assumption
  that had just failed twice.

The rate is obtained by **differencing the angle**, not from `Session:rates`:
the Sable angular channel reads exactly 0.0000 in about a third of samples at
this loop period, and a cancel must never be steered by a channel that reports
"stopped" when it is not.

It stops on the rate crossing back through zero rather than on a small
threshold. At 0.25 s sampling and ~8 deg/s^2 the rate resolution is about
2 deg/s, so some overshoot is unavoidable — and a slightly REVERSED rate walks
the angle back toward level, while stopping short leaves it still rolling the
way it was.

### Roll authority is now repeatable

| run | roll response (deg/s^2 per unit demand) |
|---|---|
| 9 | 28.33 |
| 10 | 26.93 |

**4.9% apart**, against 27% when the watchdog was eating the pulse. The
measurement is sound; what was wrong was that the craft was barely being
commanded. **Pitch has still never been measured on a completed run** — both
aborts happened during the roll phase, before pitch ran.

### The pulse was never fully applied — the watchdog was eating it

With the cheap read in place the craft rolled **33.5 degrees** on a pulse that
had previously swept 9, tripped the 28 degree abort, and peaked at 44. It
recovered and landed itself; the craft was never in danger of anything worse.

That is not a regression. It is the first time the pulse was actually applied
for its full duration, and it revealed the earlier numbers were measuring
almost nothing:

| run | roll response (deg/s^2 per unit demand) | samples |
|---|---|---|
| 6 | 3.98 | 2 |
| 8 | 5.43 | 2 |
| **9** | **28.33** | **8** |

**The cause was the send cadence, not the sampling** — but the first version
of this explanation was WRONG and the flight log disproved it. It claimed the
watchdog suppressed the differential entirely. The corner powers from run 5 say
otherwise: during the pulse they read `[3,2,3,2]`, a real differential.

What actually happens is a **DUTY CYCLE**. `hold()` runs *send-if-due, then
read*. A full read blocked ~1.6 s with no `set_power` going out, against a pod
`COMMAND_TIMEOUT` of 750 ms — so the pod held the differential for 750 ms and
then reverted to a uniform `commsLossPower` for the remaining ~850 ms. The
differential was applied about **47%** of the time, not 0%.

That, compounded with the inflated `elapsed`, explains the old numbers
quantitatively:

    real alpha                8.30 deg/s^2
    x duty cycle 0.47  ->     7.78 deg swept in a 2.0 s pulse
    / inflated elapsed 3.35 s -> reported alpha 1.39 deg/s^2
    run 8 actually reported                     1.63 deg/s^2

A 6x deflation from two compounding causes, and the model lands within 15% of
what the tool printed. **Check the mechanism against the log before believing
it** — the first story was plausible, arithmetically unnecessary, and wrong.

**This is bug 13 in a new costume.** That one was "a sleep at the bottom of a
loop silently caps every other rate in it". This is a blocking READ in the
middle of a loop capping the send rate. The lesson generalises further than it
was written: *anything* slow inside a control loop caps the command cadence,
and a watchdog turns that into silently wrong physics rather than an error.

**Strong hypothesis worth checking now:** the level-2/level-3 dither observed
during every hold may be substantially this same watchdog, not the trim loop —
commanded 0.221 (level 3) alternating with a watchdog-forced 0.195 (level 2)
reproduces the observed ~50% duty exactly. If so, the +23 block hold ceiling
may lift on its own now.

**Two fixes, both mine to own:**

- **Measure first, then everything else.** `elapsed` and `endAngle` were being
  read *after* a tensor sample and a full telemetry read — about 3 s during
  which the craft kept rotating with nothing cancelling it. That is what turned
  a 17 degree pulse into a 44 degree abort. They are now captured the instant
  the pulse ends, with a cheap read, and `sampleTensor` uses the cheap read too
  since it sits between the pulse and its cancel.
- **The pulse now ends on ANGLE, not just time** (`plan.pulseMaxAngle`, 10 deg,
  well inside the 28 deg abort). A fixed duration assumes you already know the
  authority — which is the thing being measured. Verified: with the limit
  tightened to 2 deg the pulse stopped at 1.25 s and 6 samples and measured
  **11.92** against **12.00** for the full-length pulse. A short pulse measures
  just as well, because alpha comes from the angle swept and the time taken.

### The pulse measurement was starved by its own telemetry — fixed

Two samples in a 3.3 s pulse, and 27% run-to-run disagreement on roll
authority. The cause was never the craft:

| | Sable calls per hold() tick |
|---|---|
| `sensors.read` (full sample) | ~12 |
| `Session:trim` making its OWN full read | ~12 |
| **total, before** | **~24** |
| **after** | **2** |

Two things were wrong. `trim()` called `self:read()` internally, so every tick
that trimmed paid for a **second** complete telemetry sample — it now accepts
the state the caller already has. And the pulse window used full telemetry when
only attitude is needed.

**`Session:readCheap()`** reads the pose (position AND orientation in one call)
plus linear velocity — two Sable calls — which is everything `checkLimits` and
`trim` require. At ~65 ms per call that is 1.56 s of Sable time per tick
becoming 0.13 s, which matches the observed ~1.6 s loop almost exactly. The
cadence should now be limited by `sampleSeconds` (0.25 s): roughly **13 samples
per pulse instead of 2**, which also means the quadratic fit finally engages
rather than silently falling back to the endpoint formula.

It is enabled ONLY for the pulse window and restored immediately after — the
hold and descent phases want full telemetry.

It deliberately omits angular velocity: `Session:rates` is unreliable at this
loop period (exactly 0.0000 in a third of samples), and the fit uses ANGLES,
taking its start rate from one full read before the pulse begins.

**A faster read that quietly disagreed would be far worse than a slow one**, so
`tools/test_flight_window.lua` (49 assertions) checks the cheap and full reads
return the same roll, pitch, altitude and vertical velocity across four
attitudes, that `checkLimits` accepts a cheap sample, that an over-tilt still
aborts on one, and that a missing pose marks the sample invalid rather than
letting the abort path wave through a craft it cannot see.

The converters are REUSED from `sensors.lua` rather than copied — duplicating
them would risk re-introducing bug 3, where CC:Sable's `{v=, a=}` quaternion
read as `.x` gives nils that pass every `if quaternion` guard.

### First fully clean run — and the numbers are not yet repeatable

2026-08-26 10:13, every phase completed and every earlier fix held:

    RESPONSE MATRIX (deg/s^2 per unit demand):
      demand              roll resp     pitch resp
      roll                   5.4299        -0.0800
      pitch                 -0.7945         2.5862

**Diagonal, and both diagonal entries POSITIVE** — the mixer pitch-sign flip
worked. Phase A came back exact again (3,870,720.2 kN = 3.34x, 0.0% residuals)
and the mode aggregation earned its place immediately: it FLAGGED two
contaminated rows ("2 DISTINCT thrust values across 14 samples") and picked the
right value anyway.

**But do not write these into `mixer_profile.lua` yet.** Against the previous
run:

| | run 6 | run 8 | spread |
|---|---|---|---|
| roll | 3.9828 | 5.4299 | **27%** |
| pitch | 2.1246 | 2.5862 | **18%** |
| ratio | 1.87 | 2.10 | |

**Both runs rest on 2 samples per pulse.** That is now the limiting factor and
the only thing standing between here and a usable `authority.roll` /
`authority.pitch`. The pulse is 2.0 s planned but runs 3.3 s, so the loop
period is ~1.6 s and a "quadratic fit" over two points is really just the
endpoint formula with a start-rate correction.

Fixing it means more samples inside the pulse, which means a cheaper read
during phase C — the full `sensors.read` makes a dozen blocking Sable calls and
only attitude is needed while pulsing. That is the next piece of work on this
tool.

Cross-talk is small on roll (1.5%) and **31% on pitch->roll**, which is either
the real `t[2][3]` coupling or contamination from an unsettled start; the pitch
pulse began at -0.514 deg/s.

### Tensor frame: moved into axisresponse, no longer needs main.lua

Two runs in a row produced **no flight CSV at all** — `main.lua` stops when a
flight tool is launched in the same shell tab, and it had been down since
09:57 (heartbeat frozen at sequence 1113, `last_error.txt` empty, so it was
terminated rather than crashed).

Rather than depend on remembering `shell.openTab`, `/fcs/axisresponse.lua` now
samples the tensor itself — at the settled point and at PEAK TILT of each pulse
— and prints the verdict in its own report under **INERTIA TENSOR FRAME**. This
tool is the right home for it anyway: the pulses deliberately tilt the craft,
which is exactly the attitude spread the comparison needs, and it costs two
extra Sable calls per axis.

The CSV columns and `tools/analyze_tensor.py` remain for when `main.lua` IS
running, but nothing depends on that now.

### The stable-hold window gate was a divisibility lottery

`Session:climb` failed on 2026-08-26 10:03 with *"no full window sampled"*
after passing on three earlier runs. It was not the craft.

The first version trimmed the window by dropping every sample older than
`windowMs`. That leaves `span <= windowMs`, while the gate needs
`span >= windowMs` — so the two meet **only when a sample lands exactly on the
boundary**, which happens if and only if the loop period divides the window
length. Simulated over 200 ticks:

| loop period | passes | |
|---|---|---|
| 250, 500, 1000, 2000, 2500 ms | 120-192 | divides 20 s |
| **950, 1600, 3000 ms** | **0** | does not |

Not "rarely" — **never**, at 200 ticks or 200,000. Earlier runs happened to sit
on a friendly period and looked fine, which is the worst way for a bug to
behave: it validated the tool three times before failing.

Fixed by keeping `window[1]` as the NEWEST sample still at least a full window
old, so the span genuinely covers `windowMs`. Extracted as
**`flight.trimWindow`** specifically so the test can call the real function —
`tools/test_flight_window.lua` (23 assertions) exercises every plausible loop
period including the three that scored zero. A test that reimplemented the
trim would have reimplemented the bug and agreed with it.

### Phase A: take the MODE of a quantised measurement, never the mean

The same run fitted 3.32x with a 3.1% worst residual, down from an exact 3.34x.
One row averaged to **248,619.3 kN** — which is 3.854 pods' worth of one ion
level. **No such reading exists.** Thrust is quantised, so every settled sample
must read one of a handful of exact values; that number came from averaging
across samples where one pod was still a level behind.

Phase A now takes the **mode** of each row and reports when samples disagree:
"N DISTINCT thrust values across M samples". For a quantised quantity a spread
within a settled row is not noise to be averaged away — it is evidence the row
is contaminated, and the mean is a value the hardware cannot produce.

### Tensor logging did not capture — main.lua was not running

`main.lua` had stopped 17 s before the run started (heartbeat frozen at
sequence 1113, `last_error.txt` empty — so it never reached its own exit
handler, meaning it was terminated rather than crashed). No flight CSV was
written for that run, so there are no tensor rows.

The code is fine: `main.lua` loads, `sensors.read` returns populated
`inertia` values, and the deployed file carries the columns. **It just needs to
be running during the flight.** Check `/fcs/heartbeat.txt` is advancing before
starting a run that is supposed to log.

### The axis fix worked — the response matrix is diagonal now

Flown 2026-08-26 after the correction:

    RESPONSE MATRIX (deg/s^2 per unit demand):
      demand              roll resp     pitch resp
      roll                   3.9828        -0.0679
      pitch                  1.2040        -2.1246

Roll cross-talk is **1.7%** — the roll axis is clean, and **3.98 deg/s^2 per
unit demand is a usable `authority.roll`** once the sample count is fixed.
Before the correction the same craft reported roll response 0.4993 with the
real response landing on the other channel.

**The magnitude ratio is moment arms, not a broken axis.** 3.98/2.12 = 1.87
where inertia alone predicts 4.49, which implies a lateral/longitudinal moment
arm ratio of 0.42 — a craft about 2.4x longer than wide. For a uniform plate
the response ratio would be exactly l/w, so this is the right ballpark and
mutually consistent.

**The mixer's pitch sign was inverted — FIXED.** A **+0.3** pitch demand
produced **-2.12 deg/s^2**. `mixer_profile.lua` gave the aft corners
`pitch = +1`, raising the stern and dropping the bow, while its own comment
said positive pitch is bow-high. The four coefficients are now flipped:
forward corners push harder for positive pitch.

**`attitude.lua` was reporting BOTH axes correctly** — that is how the fault
was localised, and it is worth following:

| pulse | corners raised | physically | convention says | measured |
|---|---|---|---|---|
| roll | FL, RL (port) | starboard low | roll POSITIVE | **+3.98** ✓ |
| pitch | RL, RR (aft) | bow down | pitch NEGATIVE | **-2.12** ✓ |

Both readings were right. The fault was that a POSITIVE pitch DEMAND produced
bow-down. That also independently confirms the bow is **+Z with the right
sign** — a -Z bow would have made this reading come back positive.

**Two more places carried the same inversion, and both had to be fixed:**

- `tools/test_mixer.lua` asserted *"aft must exceed forward on positive pitch"*
  — the bug, written down as a requirement. It passed against the inverted
  table for the life of the project. Now states it physically: a positive pitch
  demand raises the BOW, so the forward corners push harder.
- `tools/cc_harness.lua` computed `pitchTorque = arm * ((rl + rr) - (fl + fr))`,
  believing that pushing the stern up raises the bow. It matched the inverted
  mixer, so harness and flight code agreed with each other and both disagreed
  with the craft.

**That is the FOURTH instance of the same failure mode in this project**: the
harness and the tests encoding the flight code's belief rather than the craft's
behaviour. The atan bug, the axis labels, the RR-deficit constant, and now the
pitch sign. When a test and a harness both confirm a flight-code assumption,
they are not three pieces of evidence — they are one, repeated.

### Does turning the ship reintroduce any of this? No.

Worth stating plainly, because it is the natural worry with a craft that
rotates:

- **The corner map is bolted to the hull.** FL is the bow-port corner whichever
  way the ship faces, so "forward corners push harder for bow-up" is a
  hull-relative statement.
- **Roll and pitch are yaw-invariant**, proven in `tools/test_attitude.lua`
  across a full 360 deg of heading.
- **`config.axes` names BODY axes**, not world directions.

Both sides of every sign relationship are hull-referenced, so turning rotates
them together and nothing changes.

**What CAN invalidate it: disassembling and rebuilding the contraption.** The
body frame is established by the assembly, so a rebuild — especially one that
seats the craft facing differently — can redefine which body axis is the bow.
`config.axes.bowAxis` would then be wrong again, and silently.

**After any disassembly, re-run `/fcs/axisresponse.lua` and check the response
matrix is diagonal with positive diagonal entries.** That is a two-minute
check, and it is the only thing standing between a rebuild and a controller
pushing the wrong axis.



**Still open:**

- **Only 2 samples per pulse**, against 8 in the harness. The pulse is 2.0 s
  planned but runs 3.25 s, so the loop period is ~1.6 s. Every number here
  rests on two points and a start-rate correction.
- **Pitch -> roll cross-talk is 1.20**, 57% of the pitch diagonal. Could be the
  real `t[2][3]` coupling, or contamination — the pitch pulse began with the
  craft still moving at 0.636 deg/s after a "not settled" wait.

### Rotation safety: what is frame-independent here and what is not

A Sable craft turns, so world X and Z are not a stable reference. Three
separate places in this document depend on frames, and they are not all equally
safe.

**SAFE — roll and pitch are yaw-invariant, by construction.** `bow`, `port` and
`up` are BODY axes expressed in world coordinates, and roll and pitch read only
their world **.y** components. A yaw is a rotation about world Y, which leaves
the .y component of every vector untouched. Proven, not asserted:
`tools/test_attitude.lua` spins the craft through a full 360 deg of yaw at
fixed attitude and roll holds at **exactly 12.000** and pitch at **-7.000**
across every heading (133 assertions).

This is also why `config.axes` names BODY axes — "the bow is body +Z" — rather
than a world direction. The body mapping is fixed by how the hull was built and
does not change as the craft turns. A world-direction setting would have been
wrong the moment the craft rotated.

**SAFE — the strafe spiral is not a yaw artifact.** This was worth checking:
a craft holding a constant body-frame tilt while yawing 225 deg would trace the
same world-frame curve. It did not. Over the passive flight the craft yawed
**3.87 degrees** while the velocity heading swept **-225**, and the BODY-frame
velocity components rotate through the full range too. The tilt vector really
is precessing.

**CONVENTION — yaw runs backwards from the right-hand rule.**
`yaw = atan2(bow.z, bow.x)` increases from +X toward +Z, while a right-handed
rotation about world +Y carries +Z toward +X. So reported yaw DECREASES as the
craft turns the right-handed way. `config.axes.yawSign` exists for this. Not a
bug, but anyone wiring a yaw controller must know the sign before closing a
loop.

**UNVERIFIED — is `getInertiaTensor()` body-frame or world-frame?** Both
archived reads were taken grounded and level, so they cannot distinguish. It
matters because:

- the response ratio 4.60 vs `t[1][1]/t[3][3]` = 4.49 was used as
  CORROBORATION for the bow being +Z;
- the "axes are coupled, t[2][3] is 32% of the smallest diagonal" claim is a
  body-frame statement and only means what it says if the tensor is body-frame;
- any controller using it needs to know.

**The bow=+Z conclusion does NOT depend on this.** It stands on two
tensor-free legs: FL is physically the bow-port corner, so a port/starboard
split is a roll and it read as pitch; and the SIGN of that reading (+3.76 for
port-high, with `pitch = asin(bodyX.y)`) puts body +X on port, after which
handedness forces Z to be the bow. The tensor only agreed.

**ANSWERED 2026-08-26: BODY-FRAME.** Measured by `/fcs/axisresponse.lua`
across a tilt of 1.0 to 20.4 degrees:

| | t[1][1] | t[2][2] | t[3][3] |
|---|---|---|---|
| level | 389,361,687.85 | 435,885,566.53 | 86,754,831.18 |
| 20.4 deg roll | 389,362,106.72 | 435,884,798.61 | 86,755,192.60 |

Largest spread across any component: **0.0045%**. A world-frame tensor at 20.4
degrees would have mixed `t[1][1]` and `t[2][2]` — which differ by 46.5 million
— by `sin^2(20.4 deg)` = 12%, moving `t[1][1]` by about **1.45%**. The observed
change is **300x smaller** than that prediction.

So `t[i][j]` indexes BODY axes. **"Index 3 (+Z, the bow) is the cheap axis" and
the 32% coupling figure both hold as written**, and the 4.60-vs-4.49 ratio that
corroborated the bow being +Z was a fair comparison after all.

*Historical, for the method:* `sensors.lua` reads the tensor every
Nth sample (`sensors.tensorEveryNth`, default 10) and `main.lua` logs
`inertia_xx/yy/zz/xy/xz/yz`. Run `python3 tools/analyze_tensor.py <flight csv>`
and it prints the verdict.

Sampled periodically, NOT every tick, and that is deliberate: these are
sequential main-thread Sable calls at ~50 ms each on a loop already slow enough
that the axis-response pulse gets only 2 samples in 3.25 s. A handful of reads
at varied attitudes settles the question; 1 Hz of them costs the one thing the
pulse measurement is short of. **The columns are SPARSE by design** — a blank
means "not read this tick", not zero.

The test: the craft routinely tilts 4-5 deg, which would mix `t[1][1]` and
`t[2][2]` — they differ by 46 million — by roughly `sin^2(5 deg)` = 0.8%, about
350,000 units. The two archived reads agree to 0.00015%, so that signal is far
above the noise. Constant across attitudes means body-frame.

**Needs a reboot of computer 1** — the running logger holds the old column
list, so until then the new columns are simply absent.

### The axes were transposed — the BOW IS +Z, not +X (fixed)

The axis-calibration test `config.lua` had always asked for finally ran on
2026-08-26, and the convention this project was built on was wrong.

The pulses were genuinely applied — the flight log confirms full one-level
differentials in the right corner patterns:

| pulse | corner levels FL FR RL RR | d_roll | d_pitch |
|---|---|---|---|
| **roll** demand (port/stbd split) | `[3,2,3,2]` | **+0.05 deg** | **+3.76 deg** |
| **pitch** demand (fore/aft split) | `[2,2,3,3]` | **+1.84 deg** | +0.31 deg |

A roll command moved the PITCH channel **77x** more than roll.

**The corner map was NEVER the problem.** FL is physically the bow-port corner
(confirmed against the build), so a port/starboard split really is a roll — and
`mixer_profile.lua`'s corner coefficients were right all along. The fault was
`attitude.lua`, which assumed "+X forward, +Y up, +Z right".

Three independent lines put the bow on **+Z** and port on **+X**:

1. **FL is bow-port**, so the port/starboard split is physically roll — and it
   landed on the pitch channel, so the reporting is transposed.
2. **The inertia tensor.** alpha ~ 1/I, and that split drove the CHEAP axis:
   measured ratio **4.60** against `t[1][1]/t[3][3]` = **4.49**, agreeing to
   2.5%. Roll is rotation about the longitudinal axis, so the bow is index 3.
3. **Handedness.** With X x Y = Z and Y up, port x up = bow — so X port makes Z
   the bow.

The sign follows too: a port-high pulse read `pitch_deg` **+3.76**, and
`pitch = asin(column1.y)` is positive for port rising only if body +X is port.

**Fixed** in `fcs/attitude.lua`, which now takes `config.axes.bowAxis` /
`portAxis` rather than hardcoding a guess:

    roll  = atan2(port.y, up.y)     -- about the BOW axis
    pitch = asin(bow.y)
    yaw   = atan2(bow.z, bow.x)

**`tools/cc_harness.lua` had the same wrong labels**, building its quaternions
as roll-about-X / pitch-about-Z. So the harness and the flight code agreed with
each other and both disagreed with the craft — which is exactly why nothing
caught this. It now builds `q_pitch(about -X) * q_roll(about +Z)`; the order is
not cosmetic, the reverse is off by 4.75 deg at 35/-25.

`tools/test_attitude.lua` (25 assertions) pins all of it, including a
regression guard that FAILS if the old mapping ever comes back.

**Every logged `roll_deg` and `pitch_deg` before this fix is transposed.** They
are each other. Combined with the earlier `math.atan` bug, treat all historical
attitude data as suspect.

**Computer 1 must be rebooted** for the running logger to pick up the new
config — `axisresponse.lua` re-reads config when launched, so its report will
be correct while the CSV columns are still transposed until that reboot.

**Still unmeasured: the mixer's PITCH SIGN.** The profile comments say positive
pitch is bow-high, but it gives the aft corners +1, which pushes the stern up
and the bow DOWN. The new 2x2 matrix will show the sign directly on the next
run — measure it rather than reasoning about it.

### There is a HOLD CEILING at about +23 blocks, and it is not the clamp

The craft cannot hold +30 with the current controller. Measured across a
472-second flight (`flight-logs/axisresponse_run4/`):

| | |
|---|---|
| stable hold altitude | **+21 .. +25 blocks** |
| best 20-s mean rates there | **-0.005, -0.008, +0.009, -0.014** blocks/s |
| at +27.6 | **-0.85 blocks/s** — a real sink |
| commanded collective, airborne | 0.1819 .. **0.2450** |
| level-4 boundary | **0.2667** |
| trim() clamp | 0.60 |

**It is parked, not saturated.** The commanded collective never reaches the
level-4 boundary, and everything between 0.2000 and 0.2667 is level 3 — so the
integrator can wind through that entire span and change nothing at all. Lift is
set by the level-2/level-3 **duty cycle**, and that duty balances craft weight
at about +23 blocks. Climbing past it requires level 4 in the mix.

Once the craft holds, the RATE error is zero, so the fast term stops pushing;
only the slow integrator remains, and it is winding inside a dead zone. This is
what a PI loop does against a quantised actuator: it finds a duty-cycle
equilibrium and stops.

`/fcs/axisresponse.lua` now targets **+22** rather than +30, because that is
where the craft demonstrably holds. Ion pulse response does not depend on
altitude — ions are unaffected by air pressure — so phase C measures the same
thing either way. **Lower the target, not the tolerance.**

Worth fixing properly later: give the altitude loop authority to reach level 4
(the honest fix is duty-cycle control rather than commanding a power that
quantises away).

### Ion thrusters — the quantisation governs everything

**`setPowerNormalized` quantises to 15 levels: `applied = floor(commanded x 15) / 15`.**
Measured on FL, 14 of 14 steps exact (`flight-logs/thrustprobe_FL.txt`).
Verified over 0.00..0.15; the uniform step is assumed to continue to 1.0.

All four thrust getters (`getCurrentThrustKN`, `getCurrentThrustPN`,
`getDisplayedThrustKN`, `getDisplayedThrustPN`) agree exactly — PN is kN x 1000
and offers no extra resolution.

| quantity | value |
|---|---|
| power quantum | 1/15 = 0.0667 |
| thrust per level, one thruster | 2016 kN |
| thrust per level, ONE POD (32) | 64,512 kN = **5.57% of craft weight** |
| thrust per level, all four pods | 258,048 kN = **22.28% of craft weight** |
| full applied power | 3,870,720 kN = **3.342x craft weight** |

**Force-per-power is 3.342x — CONFIRMED IN FLIGHT 2026-08-26.**
`/fcs/axisresponse.lua` phase A measured **3,870,720.2 kN = 3.34x craft
weight** with **0.0% residual on every row**, independently reproducing the
value derived from quantisation. An earlier ~2.4x, and a 2.30x recurrence,
both came from dividing measured force by COMMANDED rather than APPLIED
power.

**With props at 64 RPM there is NO HOVER LEVEL:**

    level 0 -> 0.5210 of weight   net -5.27 blocks/s^2
    level 1 -> 0.7438             net -2.82
    level 2 -> 0.9666             net -0.37   <- gentle descent, SURVIVABLE
    level 3 -> 1.1893             net +2.08   <- climb

Holding altitude means dithering between 2 and 3 at a ~15% duty cycle on 3.
This also explains the old hover bracket exactly: commanded 0.185 and 0.195
both floor to level 2 and held; 0.200 reaches level 3 and lifted. **"Hover =
0.195" was never a measurement** — anything in [0.1333, 0.1999] is level 2.

**Resolution, which decides where fine control belongs:**

| actuator | increment |
|---|---|
| ions, all four corners | 22.28% of weight per step |
| ions, one corner | 5.57% of weight per step |
| propeller RPM | 0.81% of weight per RPM |
| **bearing tilt** | **continuous** |

The plan of "ions as the fast fine-trim loop, props as the slow altitude-stable
one" is **backwards**. Bearings are the only continuous actuator on the craft.

**A correction smaller than one ion level is not a small correction — it is an
intermittent large one.** A sub-quantum bias does nothing until collective
lands near a level boundary, then delivers a whole level. `tools/test_mixer.lua`
fails any sub-quantum bias.

### The atmosphere

`aero.getRaw().pressureFunction.getPoints()` returns the WHOLE curve — five
control points — interpolated with a **cubic Hermite** spline on
(altitude, value, slope). Derived from data, not assumed: Hermite matches
measured pressures to 3e-6..8e-6, an exponential to only 6e-5.

    altitude   -38.366   63.000   263.000   280.000   320.000
    value        1.500    1.000     0.449     0.420     0.000
    slope       -0.0060  -0.0040  -0.001797 -0.001679 -0.020990

- **Below y=280 it IS very nearly a clean exponential, H = 250 blocks.** The
  old "not a clean exponential, H=263.9, r2=0.976" came from fitting ACROSS the
  collapse above 280.
- **HARD CEILING at y = 320: pressure is exactly 0.** Props make no thrust
  there. This is a flight envelope limit.
- `evaluateFunction(y)` takes a single number and returns ABSOLUTE pressure
  (ratio 1.000000 against `getAirPressure` at nine altitudes).
- **Swapping `getAirPressure` for `evaluateFunction` buys nothing**: 49.98 vs
  49.02 ms/call, both main-thread Sable calls. The win is `getPoints` once at
  startup — `fcs/atmosphere.lua` does exactly that and then costs zero.
- **Unvalidated: the 280->320 segment.** Nothing was measured between. Confirm
  with `atmosphere.verify(model, {285, 290, 300, 310})`.

Pressure at the craft origin (y = -26.5736) is **1.430872**, independently
predicted by `fcs/atmosphere.lua` to six decimals. At +30 blocks it is 1.2690,
so props carry 46.2% instead of 52.1% and hover ions rise to ~0.221.

### Craft properties

| quantity | value |
|---|---|
| mass | **105,284.9** (was 105,299.4 — the craft has changed) |
| gravity | -11 |
| weight | 1,158,293 |
| rotation point | `getLogicalPose().rotationPoint` = centre of mass, sublevel-local |
| air pressure @origin | 1.430872 |

### The inertia tensor, read directly

`rows` and `columns` are DIMENSION COUNTS (3.0), not containers. Index the
matrix as `t[i][j]`.

    t[1][1] = 389,348,390.47   t[1][2] =  2,804,477.48   t[1][3] = -4,623,985.48
    t[2][2] = 435,866,268.08   t[2][3] = 27,995,138.25
    t[3][3] =  86,744,908.79

**The cheap axis is index 3** (4.49x cheaper than index 1). Under
`fcs/config.lua`'s convention (+X bow, +Y up, +Z starboard) index 3 is the
starboard axis, i.e. **PITCH** — so the older claim that "roll is ~4.5x
cheaper" is probably mislabelled. Treat the NUMBER as solid and the LABEL as
unverified: `config.lua` itself says to change axis signs only after an
axis-calibration test that has never been run.

**The axes are COUPLED.** `t[2][3]` is **32% of the smallest diagonal**, so the
principal axes are not the body axes: torque about one rotates the craft about
another. The allocator can ignore this; a controller cannot.

### The hull self-levels — re-measured on the SYMMETRIC craft

Flown twice. The second run (`flight-logs/rolldrift_result_postrepair.txt`,
105.3 s at +5 blocks, all four corners commanded identically) is the one that
counts, because it is the only one taken after the bearing_5 repair.

| | pre-repair (78.7 s) | **post-repair (105.3 s)** |
|---|---|---|
| roll range | -2.75 .. +0.82 deg | -2.42 .. **+4.63** deg |
| zero crossings | 2 | **5** |
| **equilibrium offset** | **~1.23 deg** | **+0.311 deg** |
| pitch offset | — | -0.573 deg |
| lateral drift | 0.236 blocks/s^2, 425 blocks/60 s | **0.060 blocks/s^2, 107 blocks/60 s** |

**Read the EQUILIBRIUM, not the peak.** The peak got bigger and that is not a
regression: peak is oscillation amplitude, and the second run was 34% longer
with more time to ring. A restoring moment parks the hull where the residual
torque balances the spring, so the MEAN angle is what measures standing
torque. It fell from 1.23 deg to **0.311 deg** — the repair did what it was
supposed to.

**0.311 deg is at the edge of this measurement's noise.** Do not treat it as a
real residual until a longer run reproduces the same sign. The honest statement
is "no standing torque detectable above ~0.5 deg", not "0.311 deg of torque".

Stiffness from the crossings: period ~42 s -> **~0.0223 deg/s^2 per degree**,
about 2.4x the ~0.0091 measured pre-repair. Treat both as order-of-magnitude:
they come from counting sign changes over a short window, and the pre-repair
figure was contaminated by the standing torque.

`getStabilizationStrength` reads **1.0** on every bearing when ACTIVE.

**The gate this satisfies:** `/fcs/axisresponse.lua` is safe to fly *because
the hull self-levels*, and this run re-confirms that on the symmetric craft.
That was the open condition — it is now met.

## The gyroscopic propeller bearings are an untapped control surface

**`props.lua` wraps 11 of the 32 methods these bearings expose.** Everything
needed for vectored thrust and yaw is already there and unused. Full list from
`/pod/device_report.txt`:

    assemble, clearManualTarget, disassemble, getAirflow, getAngle,
    getAngularSpeed, getAxis, getBlockNormal, getFacingVector, getKind,
    getManualTarget, getNetworkId, getRotationSpeed, getSailPower, getSelfId,
    getSourceId, getSpeed, getStabilizationStrength, getStressContribution,
    getStressImpact, getSubnetworkAnchorId, getThrust, getThrustHandedness,
    getThrustVector, getTiltAngle, hasSource, isActive, isAssembled,
    isOverstressed, isWoodenTop, setManualTarget, setThrustHandedness

The ones that matter:

- **`setManualTarget` / `clearManualTarget` / `getManualTarget`** — point the
  bearing. This is **thrust vectoring**: tilt a corner's props to produce lateral
  force and yaw torque without touching RPM. The most promising route to the
  unsolved yaw axis, and it gives translation authority that differential RPM
  cannot.
- **`setThrustHandedness` / `getThrustHandedness`** — flip a bearing's thrust
  sense. Each corner is a **counter-rotating pair** (measured: `+13,960.98` and
  `−13,960.98`), so flipping one of a pair changes the net reaction torque — the
  other yaw route — and lets a corner push down as well as up.
- **`getTiltAngle` / `getAngle` / `getAxis` / `getBlockNormal` /
  `getFacingVector`** — closed-loop feedback for vectoring. Without these,
  commanding a tilt is open-loop guessing.
- **`getStressImpact` / `getStressContribution` / `getStabilizationStrength`** —
  Create drivetrain headroom. Directly relevant: the plan runs props at 64 RPM
  and may want more, and a stalled RSC is already an abort condition in
  `sweep.lua`.
- **`assemble` / `disassemble`** — a bearing only makes thrust once its
  contraption is formed. Read `isAssembled` before trusting any reading; all
  eight currently report assembled.

**`getThrustVector` does NOT return nil — that was a shape error.** Measured on
FL bearing_1 at 0 RPM, no manual target:

    getThrustVector   {1=0.000000, 2=1.000000, 3=0.000000}

It is an **array** table indexed 1/2/3, not `{x=,y=,z=}`. Reading `.x/.y/.z`
off it gives three nils — the same mistake as the `{v=,a=}` quaternion in bug
3, and the reason it was recorded as nil here. **Check the shape before
believing a nil on this mod.**

It agrees exactly with `getBlockNormal` and `getFacingVector`, and reads
`{0,-1,0}` on the counter-rotating partner, so it is a *direction*, not a
force, and it is not gated on thrust. Magnitude summing is still only valid
while every corner points the same way — but now there is a per-bearing
direction to check that against.

---

## CC:Sable API

`airprofile.lua` enumerates both APIs and prints what each no-argument getter
actually returns. The project had been using 12 methods found ad hoc; there are
20. Use these instead of reconstructing them:

- **`aero.getRaw()` / `getDefault()`** — the atmosphere model itself:
  `{pressure, universalDrag, magneticNorth, gravity, dimension, priority,
  pressureFunction={getPoints, evaluateFunction}}`. **`pressureFunction` is the
  real pressure curve** — better than sampling points and fitting a poor
  exponential.
- **`sublevel.getInertiaTensor()` / `getInverseInertiaTensor()`** — proper 3×3
  with `rows`/`columns`, indexed `t[i][j]`. What the mixer needs for roll/pitch
  authority.
- **`sublevel.getInverseMass()`** — independent check on `getMass()`.
- **`sublevel.getLogicalPose()`** also carries **`rotationPoint`** and `scale`,
  not just `position`/`orientation`. `rotationPoint` is what the craft actually
  rotates about, so it is what moment arms are measured from.
- **`sublevel.getLastPose()`** — previous pose, for clean derivatives.
- **`sublevel.setName()`** — would fix the empty `craft_name`.
- **`aero.getMagneticNorth()` returns `{0,0,0}`** — not configured in this
  dimension, so it does **not** solve yaw. Logged anyway in case that changes.

---

---

## THE STRAFE — still present, and it is NOT what this document assumed

**The craft still strafes. Measured, after the repair.** The previous framing —
a standing roll torque displacing the equilibrium — was correct pre-repair and
is now the SMALLER part of the problem.

From the passive rolldrift flight (nothing commanded to rotate,
`flight-logs/rolldrift_run2/`):

| | |
|---|---|
| horizontal drift | **81 blocks in 48 s** |
| mean ground speed | **1.67 blocks/s** |
| mean roll / pitch | +0.368 deg / **-0.638 deg** |
| **net heading change** | **-225 degrees** |

And from the axis-response flight: 191 blocks in 84 s at 2.27 blocks/s.

### It is a CURVE, not a strafe

The velocity heading swept **-225 degrees** over 47 s, and the tilt direction
swept with it (311 deg -> 57 deg). The craft is not sliding along a fixed
bearing — it is carving a spiral.

The mechanism: the hull's self-levelling is **underdamped** (5 zero crossings,
established independently), and it oscillates in **roll AND pitch out of
phase**. Two out-of-phase oscillations make the tilt VECTOR rotate. Lift points
along the hull's up axis, so the lateral force rotates with it and the craft
flies a circle. Tilt magnitude decays 6.2 deg -> 1.5 deg over the window, so
the spiral is a decaying transient — but it lays down 80+ blocks while decaying.

**`universalDrag = 0.09` sets the speed.** A tilt-implied acceleration reaches
terminal velocity rather than integrating: 0.0706 blocks/s^2 (roll axis) and
0.1225 (pitch) give terminal speeds of 0.78 and 1.36 blocks/s, against a
measured mean of 1.67. That is why the craft cruises instead of accelerating
away — and why the old "425 blocks in 60 s" projection, which integrated
`0.5*a*t^2` with no drag, overstated the pre-repair case too.

### Why the repair did not fix it, and what will

- **Pitch offset now exceeds roll offset** (-0.638 vs +0.368). Everything here
  focused on ROLL because the RR deficit was a roll torque. Nobody has looked
  for a pitch asymmetry, and the tensor says t[2][3] couples them at 32%.
- **You cannot trim away an oscillation.** Trim cancels a DC offset. This is AC.
  Adding trim against a rotating tilt vector chases its own tail.
- **The fix is DAMPING**: feed roll/pitch RATE back as an opposing torque. That
  turns the underdamped spiral into a dead-beat return to level, which kills
  both the rotation of the tilt vector and most of the accumulated drift.

**This is what makes `/fcs/axisresponse.lua` the critical path.** A rate-damping
term needs to know how much angular acceleration a unit of demand buys —
`Aroll` / `Apitch`, still placeholders at 0.25. Calibrate them and the damping
term becomes writable; without them it is a guess with the craft's attitude as
the stake.

And it belongs on the **bearings**, not the ions: one ion level is 22.28% of
weight across four corners, while bearing tilt is continuous. The actuator
table below is unchanged by the repair and is the reason.

| actuator | increment | trimming a small moment |
|---|---|---|
| 1 ion level, one corner | 64,517 | **103x too coarse** |
| 1 RPM, one corner | 1,742 | 2.8x — overshoots |
| **bearing tilt** | **continuous** | **exact** |

**Still UNVERIFIED and now blocking:** the sign of the lateral force from a
bearing tilt. `getThrust` is signed by handedness and `getThrustVector` reports
each bearing's own axis. Measure it before closing any loop.

---

## Tools

| tool | what it does | safety |
|---|---|---|
| `/fcs/main.lua` | telemetry logger, auto-started by `startup.lua` | read-only |
| `/fcs/flight.lua` | shared flight primitives (hold, trim, descent, aborts) | library — canonical safety code |
| `/fcs/mixer.lua` + `mixer_profile.lua` | control allocation, demand -> per-corner power | pure, commands nothing |
| `/fcs/atmosphere.lua` | pressure curve, read once, evaluated locally | pure |
| `/fcs/rolldrift.lua` | does anything hold the craft level? | **FLIES passively**, +5, aborts at 10 deg |
| `/fcs/axisresponse.lua` | calibrates Aroll/Apitch + force-per-power | **FLIES**; `--ground-only` safe |
| `/fcs/tiltctl.lua` | thrust vectoring: manual tilt. `rolltrim` now REFUSES (needs `--force`) — it trims a repaired defect | commands bearings; safe grounded |
| `/fcs/sweep.lua` | prop RPM sweep + liftoff bracket | **will fly the craft** |
| `/fcs/ionsweep.lua` | ion thrust vs power | **will fly the craft** |
| `/fcs/airprofile.lua` | pressure vs altitude + API dump | read-only, safe |
| `/fcs/reboot.lua` | reboot pods from FCS-DEV | refuses while banks carry thrust |
| `/fcs/propctl.lua`, `/fcs/bankctl.lua` | manual single commands | commands hardware |
| probes | `/pod/yawprobe.lua`, `obstructionprobe.lua`, `thrustprobe.lua`, `stabprobe.lua`, `/fcs/pressureprobe.lua` | read-only diagnostics |
| `tools/test_mixer.lua` | 101 assertions | offline |
| `tools/test_atmosphere.lua` | 37 assertions, pinned to in-game measurements | offline |
| `tools/test_attitude.lua` | 133 assertions; axis mapping, yaw-invariance, harness round-trip, transposition guard | offline |
| `tools/test_flight_window.lua` | 23 assertions; the stable-hold window gate across loop periods | offline |
| `tools/analyze_tensor.py` | body- vs world-frame verdict from a flight CSV | offline |
| `tools/run_*_harness.lua` | sweep, ionsweep, reboot, axisresponse, rolldrift | offline |

Reports from every probe are archived in `flight-logs/`.


### `/fcs/sweep.lua`

Phase A steps RPM on the ground and fits `thrust = a·rpm^k`; Phase B walks up
from the highest RPM proven safe (coarse 8, then fine 2) and brackets liftoff.
It does **not** fly to a target RPM: above thrust/weight 1 there is no
controller, so it detects the first sustained climb — which *is* T/W = 1 — then
steps back and holds. The abort target is always a known sub-hover RPM, so a
bail-out settles rather than drops.

### `/fcs/ionsweep.lua`

Parks props at 64 RPM, arms the banks, ramps power in fine steps through the
liftoff band. Prints a **COMMAND ACCOUNTING** block per pod — *sent-but-not-seen
is radio loss; seen-but-rejected is a guard*. Always disarms on exit.

### `/fcs/reboot.lua`

    /fcs/reboot.lua all | FL RR | all --force

Each pod runs `/pod/reboot_listener.lua` in its own tab, launched by
`pod/startup.lua` **before** `main.lua`. That matters: `startup.lua` runs
`main.lua` in the foreground, so a crashed controller leaves the pod deaf — and
that is exactly when a reboot is wanted.

It is **not** a watchdog: it cannot notice `main.lua` died, only act when told.
Automatic detection belongs on the FCS, which already receives the heartbeats
that would reveal a silent pod.

- **Refuses while any ion bank is armed** unless `--force`. A rebooting pod runs
  `thrusters.applyExact(fallbackPower)` = 0.0, and props at 64 RPM carry only
  52% of weight — rebooting mid-flight on ion lift is a fall.
- Props are unaffected: the RSC is a Create block and holds its target across a
  pod reboot. Expected rather than verified, so reboot grounded.
- Accepted **only from the configured `mainComputerId`**.
- Confirmed by **boot stamp** (`bootedAt` in telemetry), not by presence — a pod
  that ignored the command is online too.

**BOOTSTRAP GOTCHA — the remote reboot cannot install itself.** A running pod
holds its old `protocol.lua` in memory; without `reboot` in `allowedTypes`,
`protocol.validate()` rejects the message before dispatch sees it, and the
listener only starts at boot. The first restart after deploying it must be done
by hand (hold Ctrl+R on each pod terminal).

*How to spot a pod that never restarted:* `/pod/heartbeat.txt` will lack
`booted_at` and `commands_seen`, and `telemetry_sends` will be far higher than a
fresh boot allows (sample it twice a few seconds apart for the rate). A full run
was analysed before anyone noticed the pods were still on old code.

---

## Diagnostics (built for this project — use them)

Runtime state is written to disk because CC failures are invisible otherwise:

- `/pod/heartbeat.txt` — per pod, every ~2 s: send/reply counters, `booted_at`,
  `commands_seen` / `commands_applied` / `commands_rejected` / `last_reject`,
  `untrusted_msgs`, prop diagnostics incl. per-bearing rows
- `/fcs/heartbeat.txt` — receive counters: `msgs_seen`, `accepted`, and a
  counter for every rejection path, plus per-corner ages
- `/pod/last_error.txt`, `/fcs/last_error.txt` — written when loops stop,
  **including when they exit without erroring**
- `/pod/device_report.txt` — full peripheral dump with method lists

**The reliable method here: sample a counter twice N seconds apart and compare
rates on both sides.** Static reasoning about CC has repeatedly produced wrong
answers on this project; measurement has not.

## Testing without going in game

`tools/cc_harness.lua` is a ComputerCraft stand-in — virtual clock, four
simulated pods using the carrier's real numbers, craft physics with air density,
ion banks with the watchdog and rate limit, and **CC's actual coroutine
scheduling**. That last part is the point: CC delivers an event to a coroutine
only when it matches that coroutine's filter and **drops it otherwise**.

    luajit tools/run_sweep_harness.lua [exponent] [maxRpm] [silent] [telemMs] [dropNth] [nodensity]
    luajit tools/run_ionsweep_harness.lua [dropNth] [ionForceFraction]
    luajit tools/run_reboot_harness.lua [armed] all [--force]

It reproduces the real "pods offline" bug, survives 25% silent command loss,
brackets hover correctly for exponents 1.0–3.5, and picks the right thrust model
in both directions. **Run it after any change to the sweep tools.** Several bugs
were caught there in minutes that would each have cost an in-game session, and
two would have wrecked the carrier.

Known limitation: on the *failure* path it can raise "attempt to yield across
C-call boundary" while unwinding. The tool's own cleanup still runs.

---

**The harness now models**: rotation (rigid-body, ions AND props), ion power
quantisation, the measured atmosphere (H=250), and an OPTIONAL restoring moment
— default OFF, because a harness that assumes stabilization is forgiving in
exactly the way that wrecks a carrier. `run_rolldrift_harness.lua stable` and
`run_axisresponse_harness.lua stable` enable the measured self-levelling.

**The RR deficit is no longer modelled by default** (repaired and verified
2026-08-26). Pass `rrdeficit` to either runner to restore the pre-repair
asymmetry for regression. The flag is self-checking: `run_rolldrift_harness.lua`
ends at roll **0.000 deg** symmetric and **19.505 deg** with `rrdeficit`, and
that 19.5 deg independently reproduces the 20.1 deg / 60 s figure derived from
the torque — so the deficit model was real, and it is genuinely gone now.

### Before flying `/fcs/axisresponse.lua`, know this

On the symmetric craft with **no** restoring moment the harness run still
**aborts at roll 28.1 deg and ends at 115 deg**. That is not asymmetry — it is
the tool's own measurement pulse, and nothing cancels the rate it induces, so
the roll integrates all the way through the abort descent.

With the measured self-levelling (`stable`) the same run completes cleanly:
roll **1.50 deg**, pitch **0.67 deg**, touchdown 0.00.

So the run is safe **because the hull self-levels**, which is measured fact
(`flight-logs/rolldrift_result.txt`), not because the craft is now symmetric.
The repair did not make this tool safe; the restoring moment does. If a
re-run of `rolldrift.lua` ever fails to show self-levelling, this tool becomes
dangerous again.

Note also that the harness's roll/pitch ratio of 4.36 is a product of the
harness's OWN assumptions and settles nothing about the real axis convention.
Only the in-game run does that.

---


## Bugs found and fixed (do not regress these)

1. **Module resolution** — CC resolves relative `require` against the *running
   program's* directory. Fixed by rooting `package.path` at `/`.
2. **Launcher** — `multishell.launch` calls `os.run()` and injects no
   `require`/`package`; only `shell.lua` does. Use `shell.openTab`.
3. **Quaternion shape** — CC:Sable orientations are `{v = <vector>, a = <w>}`,
   not `{x,y,z,w}`. Reading `.x` gave four nils that passed every
   `if quaternion` guard.
4. **Telemetry stall** — 160 sequential peripheral calls at a server tick each
   (~6 s/sample). Dispatched concurrently via `parallel.waitForAll`.
5. **Disk quota** — `computer_space_limit` (now 16 MB); log rotation added.
   Deleting computer files over SSH does not update CC's cached space
   accounting — that needs a server restart.
6. **96% message loss — the big one.** In CC a *filtered* event wait **discards**
   non-matching events. `sensors.read` makes ~12 blocking Sable calls per sample,
   each discarding any `rednet_message`. Fixed with a listener in its own
   coroutine under `parallel.waitForAny`.
7. **Thrust aggregation** — `getThrust` is signed by *handedness*, not world
   direction. Counter-rotating pairs report `+x`/`−x`; summing annihilated them
   to 0 and made three corners look dead. Sum magnitudes; keep the signed sum as
   `thrust_imbalance`.
8. **Bug 6, second occurrence** — `sweep.lua` reported four healthy pods offline.
   A separate program gets its own `banks` with everything offline, and the
   `SWEEP` prompt is a filtered wait that discards arriving telemetry. Fixed by
   waiting for telemetry *and* running under `parallel.waitForAny`.
9. **Sweep Phase B could launch the craft** — the lift search started from the
   last *planned* ground RPM rather than the last one actually flown. At k=3 the
   first probe was 40 RPM against a true hover of 34.9: 21 blocks up, ceiling
   blown, and the abort then dropped it. Now starts from `lastSafeRpm`.
10. **Pods swallowed `set_rpm` silently.** Two paths in the pod skipped without
    replying, so "no reply within 1000 ms" was indistinguishable from a lost
    packet. Fixed at both ends — see **Command loss** below.
11. **Nothing watched the craft while a command was retried.** A retry leaves the
    other three corners already at the new RPM, and three of four lifts the
    carrier. Altitude is now watched *during* commanding.
12. **Ion sweep never got power off zero** — the hold loop called a blocking
    `armAll(3)`, sending no `set_power` for up to 3 s, guaranteeing the 750 ms
    `COMMAND_TIMEOUT` that disarmed the bank, which tripped the same check again.
    79 consecutive `COMMAND_TIMEOUT` faults. Re-arm is now a single inline send.
13. **The keepalive never ran at its configured rate.** `holdPower` ended in an
    unconditional `sleep(sampleSeconds)` = 0.5 s, which caps *every* other rate
    in that loop — so `keepAliveMs = 200` did nothing and sends went out every
    ~0.55 s against a 750 ms watchdog. Send and sample now run on separate
    clocks. **A sleep at the bottom of a loop silently caps every other rate in
    it** — any control loop with a watchdog must decouple command cadence from
    sampling cadence.

### Force-per-power came out 2.30x again — the SAME commanded/applied error

`axisresponse.lua` phase A fitted measured force against `pod.currentPower`,
which is the pod's **commanded** hold value, in a variable named `applied`. The
thrusters apply `floor(commanded * 15) / 15`. Result: 2.30x craft weight,
residuals -100% .. +29%, and the tool declaring its own data unusable.

The data was exact. Re-fitted against true applied power, every row agrees to
the kN:

| cmd | applied | level | measured kN | kN per unit applied |
|---|---|---|---|---|
| 0.030 | 0.0000 | 0 | 0 | — |
| 0.060 | 0.0000 | 0 | 0 | — |
| 0.090 | 0.0667 | 1 | 258,048 | 3,870,720 |
| 0.120 | 0.0667 | 1 | 258,048 | 3,870,720 |
| 0.150 | 0.1333 | 2 | 516,096 | 3,870,720 |

3,870,720 kN = **3.342x craft weight**, zero residual — exactly the
quantisation-derived value. **This is the second recurrence of a bug this
document already records** ("an earlier ~2.4x came from dividing measured force
by COMMANDED rather than APPLIED power"). Knowing it was not enough; there was
no helper enforcing it.

Fixed with `flight.appliedPower(commanded)`, and the phase A table now prints
cmd / applied / level side by side so two commands landing on one level is
visible rather than hidden.

### The climb success test was unsatisfiable, and called a good hold a failure

`Session:climb` required **instantaneous** `|vy| < 0.10` with altitude within
2.0 blocks. There is no hover level, so the craft cannot rest — it dithers
between ion levels 2 and 3 and vy is a sawtooth.

Measured over the 2026-08-26 hold window (85 s, +23 blocks):

| | |
|---|---|
| ion level occupancy | **50.5% level 2 / 49.5% level 3** |
| vy range | **-1.56 .. +2.04** blocks/s |
| **mean vy** | **+0.0001 blocks/s** |
| samples with \|vy\| < 0.10 | 12 of 95 (13%) |
| samples meeting BOTH conditions | **1 of 95** |
| altitude limit cycle | ~+/-4 blocks, period ~20 s |

**A mean vertical rate of +0.0001 blocks/s is a textbook hold**, and the test
reported "did not stabilise at altitude". The instantaneous rate says where the
craft is in the dither; only the MEAN says whether it is holding station.

Now judged over a 20 s window (one measured limit-cycle period): mean rate
below 0.10 and mean altitude within 5.0 blocks (the measured limit cycle is
about +/-4). The failure message now reports the best window achieved instead
of one phrase covering both a good hold at the wrong altitude and a runaway.
Climb timeout raised 90 -> 180 s; the climb alone took ~75 s, leaving no room
for the window.

**Watch for this class:** a threshold on an instantaneous value, applied to a
quantised system that has no steady state. `dt` in `Session:hold` is
`os.epoch("utc")` — MILLISECONDS — and a window constant named `...SECONDS`
compared against it directly satisfies in 20 ms while reporting a 20-second
hold. That was caught before flying, but only just.

### `rolldrift.lua` scored itself against a repaired defect

The tool hardcoded `PREDICTED_ACCEL = 0.0112` — the RR bearing_5 standing
torque — as its free-drift baseline, then reported the observed peak as a
percentage of it. After the repair that disturbance does not exist, so the
first post-repair run printed a **"free-drift prediction over 105 s: 62.09
deg"** for a torque of zero, scored 7% against it, and closed with the stale
line *"The RR deficit is NOT cancelled"*. Every number in that comparison was
fictional.

Rewritten so the verdict rests on **zero crossings**, which need no model of
the disturbance: damping bounds the RATE, it does not carry the angle back
THROUGH zero, so a crossing is direct evidence of a restoring moment. The
free-drift ratio now only prints when a known standing torque is configured.

It also now reports the **equilibrium offset** (observe-phase mean), which is
the number that actually measures residual standing torque on a symmetric
craft, and derives stiffness from the crossing period. A dead-level run is
classified HELD instead of "re-run longer to be sure".

Verified against both worlds: `stable` -> HELD, `rrdeficit` -> DRIFTING ONE
WAY. The tool's own header demands this ("a diagnostic that only ever prints
one answer is not a diagnostic") and it had stopped being true.

**The general lesson, and this is the third instance of it in this project:**
a constant measured from a defect outlives the defect. The harness had the same
0.0112 baked in; `mixer_profile.lua` still carries RR commentary. Grep for the
NUMBER when a physical fault is repaired, not for the fault's name.

### The `getThrustVector` shape bug was documented but never actually fixed

`pod/props.lua` carried a correct comment saying getThrustVector is an ARRAY
indexed 1/2/3 and that reading `.x/.y/.z` yields nils — and then, 80 lines
later, did exactly that:

    vx = vec and vec.x, vy = vec and vec.y, vz = vec and vec.z,

So every `prop_per_bearing` row in every pod heartbeat read `vec=nil,nil,nil`,
and the closed-loop feedback that thrust vectoring depends on was silently
absent the whole time. Now reads `vec[1] or vec.x` (either shape), matching how
`getManualTarget` was already handled correctly three functions above.

**The lesson: a comment recording a bug is not a fix.** This one was written
down accurately, carried in the handoff as a known finding, and left in the
code. Grep for the mistake, not for the note about it.

### `/pod/stabprobe.lua` could not read the numbers it existed to check

The probe's getter list omitted **`getThrust` and `getSailPower`** — the two
values a sail-count repair is verified with. Both added, and listed first.

### `math.atan` silently ignored its second argument (roll and yaw were wrong)

`fcs/attitude.lua` computed `math.atan(-right.y, up.y)` for roll and
`math.atan(forward.z, forward.x)` for yaw. **Two-argument `math.atan` is Lua
5.3+.** Under Lua 5.1 semantics — LuaJIT, and CC's Cobalt — `math.atan` takes
ONE argument and drops the second without complaint.

So roll lost its denominator and its quadrant:

| true roll | reported |
|---|---|
| 5° | 4.98° |
| 20° | 18.88° |
| 45° | 35.26° |
| 80° | 44.56° |

It also cannot exceed ±90°. Yaw, being `atan(z, x)`, lost its quadrant
entirely. **Every logged `roll` and `yaw` value predating this fix is
suspect** — small angles are only mildly low, large ones badly so.

Fixed with `local atan2 = math.atan2 or math.atan`, which is correct on both:
5.1 has `math.atan2`, 5.3 removed it and gave `math.atan` a second argument.

**Do not "verify" this with `atan(1, 1)`** — `atan(1)` and `atan2(1, 1)` are
both π/4, so that test passes under the bug. It cost me a wrong diagnosis
before the numbers gave it away. Use unequal arguments.

Confirmed in LuaJIT (the harness). CC's Cobalt is 5.1-based so it is almost
certainly affected there too; the fix is correct either way.

### Acks WERE being clobbered by status messages (the "wrong" diagnosis was right)

This document lists "acks were being clobbered by status messages (tested in
the harness — not reproduced)" as a disproved theory. **It reproduces, and it
was real.**

`actuators.waitForReply` decided by reading `pod.type`, which is simply the
most recent message. Pods broadcast unprompted status every
`telemetryPeriodSeconds` (200 ms), so an ack had to be observed inside the gap
before the next status overwrote it. A coin flip — and a losing one as soon as
a listener coroutine drains the queue concurrently, which is why the original
harness test could not reproduce it and `tools/run_axisresponse_harness.lua`
hit it immediately: `no reply from the FL pod within 1000 ms` on a `set_rpm`
the pod had in fact applied.

Fixed in `fcs/banks.lua`: acks and faults now get their own stamps
(`lastAckAt`, `lastFaultAt`) that a later status cannot overwrite, and
`actuators.waitForReply` reads those instead of `pod.type`.

**Lesson for this project's harness discipline:** a race that needs a
concurrent consumer to appear will not reproduce in a single-threaded test. The
harness had no listener coroutine until the axis-response runner added one.

### The descent was a crash landing, and the harness approved it

`descend()` originally walked collective down with no rate feedback. Under
CONTINUOUS ion thrust that is a gentle descent — and it passed every harness
run, because the harness shared the wrong belief.

Quantised, a power ramp walks DOWN THROUGH THE LEVELS: -0.37, then -2.82, then
-5.27 blocks/s^2. From +30 blocks that reaches the ground at **17.8 blocks/s**,
and no abort catches it because `minAltitudeGain` is below ground.

Now rate-controlled: it dithers between levels 2 and 3 to hold a bounded
descent rate and never commands below level 2 while airborne. Harness result:
peak 1.18 blocks/s, touchdown 0.00.

Related fixes in the same area:

- **Aborts blocked their own recovery.** Attitude limits do not un-trip, so the
  next `hold()` aborted on its first sample and the descent never ran — the
  craft was left airborne. Limits are now skipped once an abort has tripped.
- **Aborts now go to the survivable level** (level 2), not to whatever
  collective happened to be doing.
- **A `local` declared after the function that closes over it** silently
  becomes a nil global. `hoverTrim` did this and killed a run mid-flight.


### Command loss — what it actually was

Most of the "~25% loss" was never loss.

- **The sequence guard consumed numbers for commands it then discarded.**
  `newCommand()` advanced `lastSequence` before the command was known to be
  actionable; a `set_power` arriving while disarmed burned a sequence and did
  nothing, and anything behind it was refused as a replay. Split into
  `isNewCommand()` (check) and `acceptCommand()` (commit) — a sequence is
  consumed only when the command is applied.
- **Every rejection path was silent.** Now every path answers: `ack`, or a
  `fault` carrying `rejected` with the reason.
- `arm` refreshes `lastCommandAt` even when already armed (a repeat is a valid
  keepalive); `disarm` is never sequence-gated, because refusing one as a replay
  would leave the banks live.

Measured after all fixes, per pod over one run:

| | before | after |
|---|---|---|
| commands seen | 171 | **497** |
| rejected | 12.9% | **5.2%** |
| re-arms per step | 2–6 | **0–1** |
| replay rejections | 0 | 0 |

Residual rejections are all `not_armed` — the tail of an occasional disarm.
**Do not chase it to zero:** the only lever left is raising the pods'
`commandTimeoutMs` above 750 ms, which weakens the failsafe that returns the
banks to `fallbackPower` on a real comms loss. Tight watchdog + sender retry is
the right trade for a lift system. True radio loss is a few percent.

Two wrong diagnoses along the way, both disproved by measurement: that acks were
being clobbered by status messages (tested in the harness — not reproduced), and
that the pod's ack cost was starving the watchdog (made the ack cheap — disarms
continued). The cheap ack was kept anyway: it removes ~250 ms of main-thread work
per command, which any inner control loop will need.

---

---

## Open questions and known issues

- ~~bearing_5 repair~~ — **CLOSED, verified.** See START HERE.
- ~~Constant fraction vs constant offset~~ — **RETIRED, not answered.** It only
  mattered for scaling a trim correction; there is no deficit left to scale.
- ~~The axis convention is unverified~~ — **CALIBRATED AND FIXED 2026-08-26.
  The bow is +Z, port is +X.** `attitude.lua` had it as +X forward and was
  transposing roll with pitch. The corner map was always correct.
- **The sign of the lateral force from a bearing tilt.** See THE STRAFE.
- **`authority.roll` / `authority.pitch` in `mixer_profile.lua` are
  placeholders (0.25).** `/fcs/axisresponse.lua` measures them; its pulse
  demand is now 0.30, above the ion quantum. Under quantisation the smallest
  meaningful pulse is one level (~3.4 deg/s^2), so pulses cannot be made
  gentle — the tool measures the ANGLE swept, not the rate.
- **The angular RATE channel is unreliable at this loop period** — it read
  exactly 0.0000 in 5 of 12 samples. Prefer angle-based fits.
- **Yaw is unsolved.** `getMagneticNorth()` is `{0,0,0}`. Vectoring is the
  route and the command path now exists; nothing has been wired to the axis.
- **Loop period ~950 ms** against `samplePeriodSeconds = 0.25`. Sable calls
  dominate. Fine for logging, marginal for control.
- **`getObstruction` returns exactly 0 always**, idle and at full thrust, and
  there is no `isObstructed`. The predicate is now `clearance > 0`, which is
  correct if 0 means "nothing found" and harmless if the getter is
  uninformative. To settle it: put a block against one thruster and re-run
  `/pod/obstructionprobe.lua`.
- **`getThrustVector` does not yet drive anything.** It tracks a manual target
  exactly and is the closed-loop feedback vectoring needs. The pod heartbeat
  now actually reports it (see the shape bug in Bugs found and fixed) — before,
  every `vec=` column read `nil,nil,nil` and nobody had usable direction data.
- **Chunk loading.** CC computers only tick while chunks are loaded.
  `simulation-distance=8`. Chunky is a pre-generator, not a loader.
- **`craft_name` empty** — `getName()` returns nil; `setName()` exists.

---


## Operational gotchas

- **Never push a repo config file over a deployed one.** Deployed
  `/fcs/config.lua` carries `podIds = {FL=2, FR=3, RL=4, RR=5}` and pod configs
  carry peripheral names — none of which exist in the templates. Fetch, patch
  with a targeted regex, assert the values survived, then push.
- `rsync --delete` on computer directories is **approved**, but keep excluding
  generated files: `thruster_manifest.lua`, `device_report.txt`, `logs/`,
  `peripheral_manifest.txt`.
- sshpass auth to the host is flaky (~1 in 30). Retry loops are built into the
  deploy commands. `ssh-copy-id` would remove this class of error.
- Changing config values requires **rebooting the affected computer**; changing
  `computer_space_limit` requires restarting the Minecraft server.
- Editing `fcs/main.lua`'s column list requires rebooting computer 1 — the
  running logger holds the old set in memory.

- **Adding a protocol message type requires a pod restart.** A running pod
  holds its old `protocol.lua` in memory, so `protocol.validate()` rejects the
  new type before dispatch sees it. `reboot` is already in the allowed types,
  so `/fcs/reboot.lua all` works — you do NOT need to hand-restart, provided
  the craft is grounded and disarmed.

---

## Safety posture

- Propeller RPM and bearing tilt are **set-and-hold with no watchdog**,
  deliberately: both are trims, and snapping either back on a dropped packet
  would inject the disturbance they exist to remove.
- **The ion failsafe is two constants, not one:**

  | constant | value | applied when |
  |---|---|---|
  | `fallbackPower` | 0.0 | boot, explicit disarm, apply failure, program exit |
  | `commsLossPower` | 0.195 | `watchdogLoop` only — armed bank stops hearing commands |

  They used to be one, which conflated "everything is off" with "we were flying
  and the link dropped". Raising the single old constant would have made a
  booting pod produce lift unattended and stopped `disarm` meaning off.

  0.195 floors to ion **level 2** = 0.9666 of weight with props at 64: a gentle
  self-arresting descent toward the altitude where it balances.

- **A watchdog fire leaves a pod DISARMED AND STILL LIFTING.** Anything
  reasoning about live lift must check `currentPower`, not `armed`.
  `fcs/reboot.lua` was corrected for this;
  `tools/run_reboot_harness.lua holding all` covers it.
- **NEVER disarm while airborne** — `fallbackPower` is 0.0. Every abort path in
  `fcs/flight.lua` restores the survivable level instead. Disarm only when
  grounded.
- **Level 2 is the safe resting state in flight.** Level 1 is -2.82 blocks/s^2
  and level 0 is -5.27; both are falls.

---

## Suggested next steps

The first three items on the previous list are done or retired. What is left:

1. **Calibrate `Aroll` / `Apitch`** with `/fcs/axisresponse.lua` (pulse demand
   0.30, above the ion quantum). `mixer_profile.lua` still carries placeholder
   0.25s. This is the hard blocker on any attitude controller, and its
   roll/pitch ratio settles the axis-convention question. It now runs on a
   symmetric craft, so the measurement is clean.
   ~~Re-run `/fcs/rolldrift.lua` first~~ — **DONE 2026-08-26.** Self-levelling
   re-confirmed on the symmetric craft (5 zero crossings), which is the safety
   gate this run depended on. See *The hull self-levels*.
2. **Solve yaw with the bearings.** The vectoring command path exists and is
   closed-loop; nothing is wired to the axis. `mixer.allocate` already accepts
   `demand.yaw`, echoes it in `unmet.yaw`, and gates it behind
   `yawAvailable = false` — turning it on is a coefficient table and a flag.
   Measure the sign of the lateral force first (see THE STRAFE).
3. **Validate the 280->320 atmosphere segment** with
   `atmosphere.verify(model, {285, 290, 300, 310})`. Nothing was ever measured
   between, and y=320 is a hard flight-envelope ceiling.
4. **Then, and only then, a controller.** Note what it must respect: no hover
   level (dither between ion levels 2 and 3), 32% axis coupling, ~950 ms loop,
   and fine trim living on the bearings rather than the ions.

**`props.lua` fix is LIVE** (pods rebooted 2026-08-26). Confirmed by the
heartbeat: `vec=` now reports real direction vectors — `{~0, +/-1, ~0}`, the
bearings pointing straight up and down — where it used to print `nil,nil,nil`.
The closed-loop feedback that thrust vectoring needs is finally readable.

**Repair re-confirmed under load:** with props loaded, all four corners report
pod thrust **111687.8702592019, bit-for-bit identical**. At rest they split
into two families 0.0004% apart; under load they are exactly equal. The
symmetry claim no longer rests on a single at-rest reading.

---

## What is deliberately NOT worth doing

- **Chasing the ~5% command rejection tail.** It is all `not_armed` from an
  occasional disarm. The only lever is raising `commandTimeoutMs` above 750 ms,
  which weakens the failsafe. Tight watchdog plus sender retry is the right
  trade for a lift system.
- **Anything about the RR deficit.** It was repaired and verified. Also do not
  chase the residual 0.0004% FL/RL vs FR/RR split.
- **Swapping `getAirPressure` for `evaluateFunction`.** Measured: no gain.

---

## fcs-dev hub

A read-only monitor dashboard on FCS-DEV, built 2026-08-26. See
`docs/fcs-dev-hub.md` for the design invariants and the test commands, and
`docs/fcs-dev-in-world-steps.md` for the deployment and acceptance steps that
still need doing in-world.

The one thing to carry in your head: **`fcs/main.lua` is the only program on
that computer that talks to CC:Sable or to the pods.** The hub listens and
draws. It requires none of `fcs.banks`, `fcs.sensors`, `fcs.network`, and must
not start to.
