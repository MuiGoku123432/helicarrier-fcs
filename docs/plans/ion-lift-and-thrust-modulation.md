# Plan: ion-carried lift, props for stabilisation, and finer thrust granularity

Status: **rough plan, recorded so it is not lost.** Nothing here is committed to
beyond step 1, which is built.

Recorded 2026-08-31, out of the drift-test work in HANDOFF.md.

## The idea

Split the two jobs the propulsion system currently shares:

- **Ion banks carry lift.** They are the large, coarse vertical authority.
- **Props handle stabilisation and movement.** They stop being part of the
  lift budget and become the fine, fast actuator.

Today the two are entangled. Props carry 52.1% of craft weight at 64 RPM and
the ions supply the rest, so every prop command is simultaneously a lift command
and a control command. Worse, prop thrust falls with air pressure (250-block
scale height, `fcs/atmosphere.lua`) while ion thrust does not, so the split
between the two silently changes with altitude. That is what put the ceiling at
about +116 blocks in drift-test runs 6 and 7, and it means control authority is
altitude-dependent in a way nothing currently models.

If ions carry lift on their own, prop authority stops being spent on holding the
craft up and the altitude coupling largely goes away.

## Step 1 — measure the ion lift curve (BUILT)

`fcs/wiredframe_ion_lift_profile.lua --ion-lift-profile`

Steps the ion command up one hardware level at a time, holds each for a
configurable dwell (default 30 s), then steps back down the same ladder. Tilt
and azimuth are exactly zero, props sit at a fixed RPM, and there is no drift
logic, position loop, or vertical feedback anywhere in it. The point is to
measure the plant, so nothing may quietly correct it.

Records per level: commanded power, quantised level, rise before and after,
vertical velocity before and after, peak velocity, the post-step acceleration,
and a thrust-to-weight estimate. Saves to
`/fcs/wiredframe_ion_lift_profile_result.txt`.

**What to read from the result.** `hover_level` is the number this test exists
to produce: the interpolated level where vertical acceleration crosses zero,
i.e. where thrust equals weight. It comes straight out of the measured
accelerations and does **not** depend on the configured gravity constant. The
`thrust_to_weight` column does depend on it and is indicative only.

Known from existing runs, to sanity-check against: level 2/15 is about 0.967 of
weight and level 3/15 about 1.189, so `hover_level` should land near 2.1-2.2.
If it does not, the assumed prop contribution is wrong and everything derived
from it in HANDOFF.md needs revisiting.

**Run 1 (2026-08-31) aborted, and taught the harness two things.**
`flight-logs/wiredframe_ion_lift_run1_abort.txt`. It stopped at
`abort_reason=horizontal speed limit exceeded` 18 s into level 3, with clean
transport throughout (363/363 frames, zero faults) and a clean shutdown.

- The 8 blocks/s horizontal stop was wrong for this test. It commands zero tilt,
  so there is no lateral control at all and drift accumulates unopposed; even
  the full stationkeeping loop saw 7.4 blocks/s fighting an off-centre load.
  Raised to 25 as a runaway stop rather than a drift stop.
- **Levels below hover cannot be measured from the ground.** Levels 1 and 2 held
  a full 30 s each and moved 0.0017 and 0.0155 blocks: the craft never flew, so
  their reported accelerations of +0.020 and +0.006 measure the floor carrying
  the craft, not thrust against weight. `hover_level` came back
  `not_bracketed` as a direct consequence -- nothing ever read negative, because
  the ground never let it.

The fix is that only **airborne** rows feed the hover fit, and the descent leg
is what supplies the sub-hover levels, since by then the craft is high enough to
actually fall. Each row is now classified `grounded`, `transition`, or
`airborne`, the classification is in the result file, and the self-test asserts
that grounded rows can neither produce a hover level on their own nor perturb a
correct airborne fit. Grounded levels on the way up are also abandoned after a
short probe instead of burning a full dwell on the floor.

One number worth carrying forward: level 3 measured 1.24 blocks/s^2. If 3/15 is
truly 1.189 of weight then gravity is about 6.6 blocks/s^2, not the 4.4 the
harness assumes for its indicative T/W column. That reading spans the
ground-to-flight transition so it is not clean, but the next run should settle
it and the constant should be updated from airborne data.

**Run 2 (2026-08-31) passed, and showed the test cannot answer the question as
posed.** `flight-logs/wiredframe_ion_lift_run2.txt`. Clean run: 534/534 frames,
zero faults, grounded levels probed and skipped, descent leg reached, ceiling
hit at +220 blocks. It reported `hover_level=3.552`. **That number is an
artifact.**

The same ion level gave opposite results at different heights:

| 3/15 ascending | from 0.03 blocks | climbed to 122.55 | a = +1.284 |
|---|---|---|---|
| 3/15 descending | from 220.50 blocks | fell to 90.69 | a = -1.922 |

It bracketed 3/15 measured at 220 blocks against 4/15 measured at 122 blocks.
Props lose 32% of their thrust across that gap, so the interpolation compared
two effectively different craft.

**There is no single hover level.** Prop thrust falls with air pressure and ion
thrust does not, so hover level is a function of altitude. Any answer must carry
the height it was measured at. The harness now refuses to interpolate across
more than `HOVER_COMPARE_MAX_ALTITUDE_GAP` (25 blocks) and reports why.

Two further defects the run exposed, both fixed:

- Rows were classified by where the craft ENDED the dwell, so the descent from
  90 blocks to the ground was marked `grounded` and its perfectly good 90-block
  reading was discarded. Classification now uses the measurement window.
- Acceleration is only `(T - W)/m` near rest. Run 2's descent readings were
  taken at +9.7 and -2.8 blocks/s, where drag dominates. Only one of three
  points (`up 4`, at +0.48 blocks/s) was clean. Readings above `DRAG_FREE_SPEED`
  are now recorded as `airborne_dragged` and never fitted.

**On the thrust constants.** Fitting `a = g(kL + p*exp(-y/250) - 1)` to run 2's
three points gives k=0.165, p=0.791, g=10.8, which reproduces the independently
measured 3/15 equilibrium at 115.7 blocks to within 3%. But it puts ground hover
at 1.27/15, and run 2 shows 2/15 failing to lift off the ground at all, so the
fit is refuted by the run's own liftoff evidence and is being dragged by the two
contaminated points. The prior figures (k=0.223, p=0.521) survive both checks:
ground hover 2.15 and 3/15 equilibrium at 113.4 against 115.7 observed. **Keep
the prior constants until a run produces several drag-free points.**

### The real blocker for this measurement

Props are what make T/W altitude-dependent. With props off, ion thrust is
altitude-independent and the curve is a clean function of level alone -- one
measurement per level, no altitude confound, no atmosphere model needed.

**That run cannot be commanded today.** `control_mailbox.lua` requires
`command.propRpm == 64` for stationkeep and response_map_test, and the only
modes permitting `propRpm == 0` also force `ionPower == 0`. So there is no way
to run ions without props, which is both the clean measurement AND the
architecture this plan is aiming at. A pod-side change is on the critical path
for both.

Caveats built into the harness:

- The sweep is **altitude-bounded, not level-bounded**. Upper levels accelerate
  hard enough that a full dwell at 15/15 would leave the world; the ascent stops
  at `CEILING_BLOCKS` and begins the descent from wherever it got to.
- Descent stops stepping down at `FLOOR_BLOCKS` and holds, rather than walking
  the craft into the ground. The operator ends the run.
- Vertical speed is deliberately **not** an abort condition, because large
  vertical speed is the measurement. Hull tilt, angular speed, horizontal speed,
  and falling below the start altitude all remain armed.

## Step 2 — decide the lift/stabilisation split

Depends entirely on step 1's curve. Open questions:

- What ion level actually hovers the craft, and how far is it from a hardware
  level? If hover falls between two levels the craft cannot hold altitude on
  ions alone without either prop trim or step 3.
- Does the ion curve stay linear in level all the way to 15/15, or does it
  saturate? The reported thrust quanta (0.223 of weight per level) predict
  linearity, but that has only been checked at levels 1-3.
- How much prop RPM is actually needed for stabilisation once lift is removed
  from their job? If it is far below 64 RPM, the altitude coupling shrinks with
  it, since prop thrust is the pressure-dependent term.
- Does reducing prop RPM cost bearing authority? The gyroscopic bearings spool
  with RPM (HANDOFF records the spool to ~19.2 at 64 RPM), so props may be
  load-bearing for attitude control in a way that is not about lift at all.
  **This is the most likely reason the plan does not work as stated.**

## Step 3 — finer thrust granularity by thruster subsetting

The driver quantises ion power to fifteenths per thruster
(`applied = floor(commanded * 15) / 15`), which is a coarse 6.7% of full range
per step. Near hover that is the difference between sinking at 96.7% of weight
and climbing at 118.9% — there is no setting in between, which is the root of
several problems already hit.

Idea: **modulate at the thruster level rather than the power level.** A pod
holds multiple ion thrusters. Running some at level N and the rest at level N+1
gives an effective pod-average between the two hardware steps. With 8 thrusters
per pod, switching them one at a time between adjacent levels yields 8
intermediate points per level — roughly 0.8% granularity instead of 6.7%.

Rough sketch, not designed:

- Pod-side, since it needs per-thruster addressing. `thrusters.applyExact`
  currently drives every device to the same power via `runSetters`.
- The command would become something like a level plus a count of thrusters to
  promote to the next level, or a fractional level the pod resolves.
- Spatial distribution matters. Promoting thrusters on one side of a pod creates
  a moment, so the promoted set should be chosen to stay balanced about the pod
  centre, or rotated over time so the average is balanced.
- Interacts with the tilt/bearing authority the pods already apply. Needs
  thinking about before it touches the flight protocol.

Open questions:

- Does per-thruster addressing cost extra peripheral calls per frame? The write
  elision work got apply time from ~200 ms down to 0.7-1.0 ms precisely by not
  writing unchanged values; N distinct values per pod could undo that. Check
  against the timing baseline in HANDOFF before committing.
- Is thrust actually linear in the quantised level, so that averaging across
  thrusters produces the intended intermediate force? Step 1 answers this for
  the whole bank; per-thruster linearity is a further assumption.
- Is there a simpler answer? If the props can trim the gap between ion levels
  cheaply, subsetting may not be worth the complexity.

## Two pod-side constraints found while writing this

Both live in `pod-template/pod/control_mailbox.lua`, in the `validMode`
validator, and both are bare literals with no comment or named constant. All
four pods currently run the identical file (SHA-256 `5cd1274f...`), so changing
either means redeploying to pods 2-5 and rebooting them -- it is not an FCS-side
change.

**1. Prop RPM is locked to 64.** The validator requires `command.propRpm == 64`
for stationkeep and response_map_test modes. Anything else is rejected at every
pod and the run dies on invalid-frame counters. This directly blocks the step 2
question "how much prop RPM is actually needed once lift is removed from their
job" -- that experiment cannot be run without a pod redeploy. The ion lift
profile harness asserts `PROP_RPM == 64` in its self-test so a future edit fails
offline rather than in flight.

**2. The 6-degree tilt cap is enforced in three places.** `local bearingLimit =
stationkeepMode and 6 or 1` in the pod validator, `protocol.MAX_TILT_DEGREES = 6`
in `fcs/wired_stationkeep_protocol.lua`, and `stationkeep.DEFAULTS.maxTiltDegrees
= 6.0` in the controller, with `tools/test_stationkeep.lua` asserting the
boundary. Raising it is therefore a four-file change plus a pod redeploy, not a
gain tweak.

**No rationale for the number 6 is recorded anywhere in the repo.** It is
enforced by tests, which makes it look more deliberate than the evidence
supports. Note that the related `GROUND_BEARING_LIMIT_DEGREES` is 5 and the
non-stationkeep bearing limit is 1, so 6 may simply be "a bit above the ground
test limit" rather than a measured structural or authority bound.

## Related open item

The 6-degree tilt cap is currently the binding constraint on disturbance
rejection: the bedrock test (run 8) saturated it for 92 consecutive seconds and
the craft could arrest velocity but never recover position, parking 204 blocks
downrange. It is probably raisable, but that is a separate decision from this
plan and should not be bundled with it. Before raising it, find out whether the
number came from a measured limit or was chosen freehand -- see above.
