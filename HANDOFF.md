# Helicarrier FCS — session handoff

Last updated: 2026-08-27, end of session. **READ THE BLOCK BELOW, THEN
`THE VELOCITY LOOP`.** In one line: station keeping works, and an intermittent
fault that stops the bearings answering in flight is what blocks confirming it.

What this session established, all of it measured:

- **The velocity loop closed and held** -- net drift 1.409 -> 1.019 blocks/s,
  against a design figure of 33%.
- **The bearing actuator is INVERTED and SLOW.** A tilt commanded to push the
  craft one way moves it the other once the hull catches up, after moving it
  the right way for a few seconds. That sign change is the old 1.76 -> 11.5
  blocks/s runaway, and it is now a measurement.
- **The bearing lateral gain is 4x what two files store**, read off live
  telemetry in a two-minute ground run rather than flown for.
- **The drift curve is ONE oscillator: roll.** Pitch is overdamped and levels
  itself, so it wants no damper -- which killed the premise the pitch tool was
  built on.
- **Three archived flight logs have TRANSPOSED angle columns**, including the
  one this document's standing offsets came from.

Written for a fresh session picking this up cold. Rewritten rather than
patched: superseded findings are REMOVED, not annotated, except where the wrong
answer is instructive. Keep it that way.

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

## WHERE THE 2026-08-27 SESSION LEFT OFF

Read this block, then **THE VELOCITY LOOP**. Everything else in this file is
background.

### THE GOAL IS ESSENTIALLY MET, AND ONE FAULT BLOCKS CONFIRMING IT

**Station keeping works.** Run 4 closed the velocity loop and cut net drift
**1.409 -> 1.019 blocks/s (28%)** against a proportional loop under-relaxed by
half, which is *designed* to remove 33%. The loop did what it was built to do.

**The gains reproduce**, which no bearing number on this craft had managed
before:

    pitch  -2.8029, -2.7900, -2.7814   three flights, 0.8% spread
    roll   -3.3601, -3.5603            two flights, 5.6% apart

**THE BLOCKER: the bearings intermittently ignore `set_tilt` IN FLIGHT.** Five
of five ground runs answer; two of six flights do not -- including one two
minutes after a clean ground run. See **THE INTERMITTENT TILT FAULT**. Until
that is understood, a flight can waste ten minutes or, worse, produce a number.

### WHAT TO DO NEXT, in order

1. **Isolate the tilt fault with a 90-second flight**: climb, confirm the tilt,
   land. No measurement. Repeat a few times for a hit rate, with a ground sweep
   either side. That is the one experiment that separates "airborne" from
   "our code" and it has not been run.
2. **Give `trimflight.lua` and `pitchdampflight.lua` the same treatment the
   velocity tool got** -- the set-and-hold throttle, the tilt readback, the
   stall guard. Both still re-send at the sample rate and neither confirms the
   tilt. Their measured couplings (-0.8205 / +0.5588) were taken without a
   readback and are 1.45x smaller than the confirmed-tilt flight measured, so
   **they are probably wrong**.
3. Only then, a clean velocity-hold run. And if more than a third of the drift
   is wanted, the lever is `relaxation` in `velocityhold.DEFAULTS` (0.5).

### THE THREE THINGS THAT WILL BITE A FRESH SESSION

- **A loop that stops is more dangerous than a loop that is wrong.** Run 6
  rolled to -15 degrees from a 1 degree command because the sample callback --
  which holds every abort, every limit and the damper -- stopped executing for
  six seconds. Guarded now; understand it before removing the guard.
- **This craft was intermittently anomalous all day**: bearings ignoring tilt in
  flight, lifting at 48 rpm where it had held to 64 three hours earlier, a
  six-second stall. Between episodes it measures consistently. **A surprising
  flight result is suspect until the craft has been shown to be behaving.**
- **LuaJIT is not the craft's Lua.** A `%+5s` passed every harness and killed a
  run on the carrier. `tools/test_formats.lua` catches that class now.

---

## START HERE: what to do first

Three actuators are now measured AND two of them have flown. The craft damps
its roll, holds altitude, levels its hull on command, and talks to its pods
without losing anything. What it still does is **drift**, and the plan for that
changed on 2026-08-27 when the obvious fix was flown and did not work.

### THE STRATEGY, and it is a reframe

**STOP TRYING TO FIX DRIFT THROUGH ATTITUDE.** That was the implicit plan for
this document's whole history. Two flights killed it: the only actuator with
the resolution to trim tilt is also a strong lateral thruster, so it pushes the
craft about as hard as the tilt it removes. **Trim is drift-neutral by
construction.**

The drift is TWO separable problems wanting DIFFERENT actuators:

| | what sets it | actuator | closed on |
|---|---|---|---|
| **speed** (1.2-1.7 blocks/s) | tilt magnitude against drag -> terminal velocity | bearing tilt | **velocity** |
| **direction** (the curve) | ROLL oscillating at 32.7 s against a slow pitch transient, winding the tilt vector | differential prop RPM | **rate** -- FLOWN |

The curve is not a separate mystery from the oscillation. It IS the
oscillation, seen from above.

#### Three layers, separated by TIMESCALE

    layer 1   RATE DAMPING       ~0.15 s   differential prop RPM
              roll: FLOWN AND WORKING.  pitch: DOES NOT NEED IT (measured).

    layer 2   VELOCITY HOLD      seconds   bearing common-mode tilt
              BUILT, not yet flown: fcs/velocityhold.lua +
              /fcs/velocityholdflight.lua. The actuator is INVERTED
              and SLOW -- see THE VELOCITY LOOP before touching it.

    layer 3   ATTITUDE REFERENCE slow, weak, subordinate to layer 2

**A velocity loop makes trim REDUNDANT.** Holding velocity at zero does not
care what the standing tilt is -- the loop commands whatever tilt cancels the
drift, INCLUDING the drift the standing tilt causes. Trim was worth flying
because it measured the coupling signs layer 2 needs. It should not survive as
a control layer.

**Why the layers do not fight: timescale separation.** A velocity command tilts
the bearings, which rolls the craft -- there is no pure attitude channel, that
is measured. The damper absorbs it because it is ~40x faster. Break the
separation and the two loops chase each other.

#### Do these in this order

1. ~~CALIBRATE THE BEARING LATERAL GAIN~~ **DONE, 2026-08-27, on the ground in
   two minutes.** `/fcs/bearingsweep.lua`, log in
   `flight-logs/bearingsweep_run1.txt`. **It never needed a flight** -- the
   lateral force is built out of `getThrust`, which the pods already push every
   second, so the question was answered by reading telemetry the craft had been
   sending all along. Numbers in **THE BEARING GAIN** below. Re-run it whenever
   the hull's load changes.
   Cheapest thing here and it unblocks the rest.
2. ~~PITCH DAMPING~~ **FLOWN 2026-08-27, AND IT KILLED ITS OWN PREMISE.**
   Pitch does not ring -- it is OVERDAMPED and it levels itself. No damper
   wanted. See **THE PITCH FLIGHT**. What replaces this: *what actually
   rotates the tilt vector*, since it is not an undamped pitch axis.
3. **FLY VELOCITY HOLD -- `/fcs/velocityholdflight.lua`, BUILT AND WAITING.**
   `--ground-only` first: it prints the plant, which is worth reading before
   committing to air. Then `--measure-only` (phase A, ~5 min) measures the NET
   gain per axis; the full run adds the A/B (~9 min). See **THE VELOCITY
   LOOP**.
4. Only then ask whether any standing trim is still wanted. Probably not.

### What has FLOWN and works

**ROLL DAMPER — `/fcs/rolldampflight.lua`, 2026-08-27.** A/B on an injected
3 rpm pulse (`flight-logs/rolldampflight_run1.txt`):

| | damper OFF | damper ON |
|---|---|---|
| peak roll rate | 1.184 | 1.096 deg/s (7.4% apart, so comparable) |
| **peak roll excursion** | **5.58** | **3.43 deg — 39% less** |
| time to 1/e | 4.6 | 2.8 s — 40% faster |

The pulse re-measured the authority for free at **0.0897 deg/s^2 per rpm**, a
fourth measurement agreeing with the three that set 0.0941.

**BEARING TRIM — `/fcs/trimflight.lua`, flown twice.** Standing tilt
0.721 -> 0.206 (-71%) and 0.706 -> 0.180 (-74%), on a craft whose two axes have
OPPOSITE coupling signs, using gains it measures itself. **The attitude trim
works and is reproducible.** The drift did not improve and pass 2 made it worse
-- see the strategy above. Keep the tool: it is how the coupling signs get
measured, and a level hull is the reference any controller needs.

**THE COUPLING SIGNS, measured at last** (`flight-logs/trimflight_probe1.txt`):

    roll    -0.8205 hull deg per commanded deg   NEGATIVE
    pitch   +0.5588                              POSITIVE

**The two axes disagree, and roll is opposite to the prediction.** Anything
assuming one sign for both is right on pitch and backwards on roll -- which is
almost certainly the 1.76 -> 11.5 blocks/s runaway, a roll event on a saturated
12 degree command. Any bearing loop must take the sign PER AXIS.

**COMMAND LOSS — FIXED.** The pods lost 2.5-5% of commands because
`status_request` was answered inline in `networkLoop`, and the 160-getter read
it triggers sits inside a nested `parallel.waitForAll` that pulls events
unfiltered and DISCARDS every one that is not `task_complete`. Each pod now has
ONE central sampler; `networkLoop` reads no peripheral, ever. Verified 80/80
with the logger running. See **THE POD SAMPLER**. FR was never the problem --
it answered 20 of 20.

### The actuator survey — still the durable result

Three actuators, each measured, each good at exactly one job. Every previous
design failed by asking one of them to do a job it is structurally incapable of.

| job | actuator | authority | status |
|---|---|---|---|
| **damp** (fast, large) | differential prop RPM | roll **0.0941**; pitch ~0.024 (unsettled), sign POSITIVE | roll FLOWN; pitch OVERDAMPED, no damper needed |
| **translate** (drift) | bearing tilt, common mode | **0.8165 blocks/s per deg at 64 rpm** — measured | never flown |
| **trim** (slow, tiny) | bearing tilt | roll -0.86, pitch +0.64 hull deg per deg | flown; drift-neutral |

- **IONS CANNOT DO ATTITUDE.** One level is 7.42 deg/s^2 against the 0.268
  damping needs -- 28x too coarse. They are the collective actuator, nothing else.
- **DIFFERENTIAL RPM CANNOT TRIM.** One rpm held constantly shifts the
  equilibrium 4.14 degrees against offsets of a few tenths. Great damper,
  hopeless trim.
- **BEARINGS CANNOT DAMP.** 0.011 deg/s^2 per degree, so the 12 degree clamp
  gives 0.13 against the 0.268 needed. They translate, and they trim.
- **BEARINGS HAVE NO PURE ATTITUDE CHANNEL.** The two props of a corner sit at
  the SAME height, so the same command makes lateral force AND roll. That is
  why trim pays back its own drift, and why layer 1 must absorb what layer 2
  commands.

### State of the craft, in one place

- **Grounded and disarmed.** Computer 1 and all four pods are running current
  code as of 2026-08-27.
- **bearing_5 repair: VERIFIED.** All four corners bit-for-bit identical under
  load. Do not re-investigate the RR deficit.
- **The axis convention is CALIBRATED: bow = body +Z, port = body +X.**
  `attitude.lua` had assumed +X forward and reported roll and pitch TRANSPOSED.
  Fixed, and pinned by `tools/test_attitude.lua` (133 assertions).
- **`getInertiaTensor()` is BODY-FRAME**, confirmed on five flights across
  tilts to 20 degrees.
- **Force-per-power is 3.342x craft weight**, confirmed in flight at 0.0%
  residual.
- **Propeller thrust is LINEAR in rpm** (r^2 = 1.000000, 8 to 96 rpm). The
  harness default of 2.0 predates that measurement; every runner sets 1.0.
- **AZIMUTH 0 PUSHES TO STARBOARD**, measured on all four corners.
  `lateralhold.azimuthForHeading` encodes heading = azimuth + 90.
- **Pods push full telemetry at ~1 Hz and are never polled while healthy.**
  Steady-state pod-directed traffic is zero from any number of tabs.
- **`/fcs-dev.lua` (the monitor hub) is still NOT deployed.**

### THE VELOCITY LOOP -- the actuator is INVERTED and SLOW

Built 2026-08-27: `fcs/velocityhold.lua` and `/fcs/velocityholdflight.lua`.
**Flown once, and the flight measured nothing -- see RUN 1 at the end of this
section. The bearings did not move.**

#### THE PLANT, and why every previous attempt ran away

A commanded bearing tilt does two things to the craft's velocity, and as of
today both halves are measured:

| | | |
|---|---|---|
| **direct**, and it is **FAST** | the bearings make a horizontal force | **+0.8165** blocks/s per commanded deg |
| **through the hull**, and it is **SLOW and BIGGER** | the same command rolls the craft, and a leaning hull points its lift sideways | roll **-1.751**, pitch **-1.192** |

    roll axis    +0.8165 - 1.7505  =  NET -0.934 blocks/s per commanded degree
    pitch axis   +0.8165 - 1.1921  =  NET -0.376

**A tilt commanded to push the craft starboard moves it PORT** once the hull
catches up -- after moving it starboard for the first few seconds. The direct
force arrives with drag's 11 s time constant; the hull term arrives on the
hull's own, and roll rings at 32.7 s.

**THAT SIGN CHANGE BETWEEN FAST AND SLOW IS THE 1.76 -> 11.5 BLOCKS/S
RUNAWAY.** A loop that closes quickly is closing on the fast half, which is the
half with the wrong sign: it sees the craft move the right way, watches it
reverse, and answers by commanding harder. It is no longer a mystery and it
does not need a special mode to avoid -- it needs a slow loop.

#### WHAT THE TOOL DOES ABOUT IT

- **Phase A measures the NET per axis**, by reverse pairs, with 35 s settles so
  the hull has finished moving -- a short settle measures the fast half and
  gets the SIGN backwards. It also records the first 6 s of the reversal, so
  the inversion appears in the log as a measurement rather than as a claim in
  a comment.
- **Phase B rate-limits the command to 0.05 deg/s.** A full 4 degree command
  takes 80 s to build, against the hull's ~30 s response, so the loop cannot
  outrun the half of the plant that makes it stable. This is the single most
  important line in the file.
- **The loop acts on a 15 s MEAN velocity, not a reading.** The velocity
  carries the hull's 32.7 s oscillation, and commanding against the swing
  injects energy: in the harness the loop acted properly, averaged a quarter
  degree of tilt, and left the craft drifting twice as fast until the mean was
  put in front of it.
- **It refuses** below a net gain of 0.10 blocks/s per degree. Dividing a drift
  by a gain that small is a saturated command derived from noise.
- **Judged on NET DISPLACEMENT**, never mean ground speed -- trim run 1 was
  judged on mean speed and could not be.

`velocityhold.lua` stores no gain. The net is built from the bearing thrust and
the craft's mass, both of which move when the hull is loaded.

#### TWO THINGS THE HARNESS CAUGHT, both of them mine

- The baseline window opened the instant phase A's last 2 degree probe was
  released, so it measured a craft still coasting out of a commanded tilt --
  0.519 blocks/s on a craft whose standing drift is nearer 1.0 -- and the loop
  was then blamed for the craft returning to normal. `trimflight` settles
  before its baseline; this did not. It does now.
- A "WORSE, 108% MORE" verdict on a run where the loop ended at +0.015 deg.
  **Attribution requires action**: if the loop did not act, the A/B says
  nothing about the loop, whatever the two numbers did. There is a guard for
  that now.

#### RUN 1, 2026-08-27: THE BEARINGS DID NOT MOVE

`flight-logs/velocityholdflight_run1_noresponse.txt`, `--measure-only`.

    at +2.0 deg   v_bow -1.342  v_stbd +0.455  roll +0.20  pitch +0.58
    at -2.0 deg   v_bow -1.345  v_stbd +0.447  roll +0.20  pitch +0.58

    NET GAIN  +0.0020 (roll axis)   -0.0069 (pitch axis)

**Reversing a 2 degree command changed nothing.** Not the velocity, not the
hull attitude, on either axis. The craft flew and drifted at 1.417 blocks/s,
which is its ordinary standing drift, and sat at roll +0.20 / pitch +0.58,
which is its ordinary standing offset.

That is not a small gain. **That is no response at all**, and the tool reported
it as a measurement -- then correctly refused to close the loop on it, and
told the reader that one of three earlier measurements must be wrong. The
refusal was right. The framing was not: nothing was wrong with the earlier
measurements, the actuator simply never moved.

For contrast, the same 2 degree command on the same day in `trimflight` drove
the craft to 6.3 and 4.3 blocks/s on the two halves of its pair.

**THE PODS WERE DISARMING.** Found by comparing fault counts in the flight CSV
against a ground run of the same length on the same day:

    velocity flight   344 s   72 new COMMAND_TIMEOUTs   3.14 per pod per minute
    ground sweep      371 s    0

`COMMAND_TIMEOUT` means the pod was armed and no command reached it inside
750 ms, so it **disarmed** and dropped to comms-loss power. Every number that
flight produced came from a craft whose banks were dropping out several times a
minute, and nothing in the report said so.

The hull was also unnaturally rigid: **roll moved 0.366 degrees across the
entire 344 s flight**, against +/-4 in the passive drift flight. Bearings
reported `active` on all four corners with props at 64 the whole time.

**And `set_tilt` is not the problem.** The ground sweep now sends the
flight-shaped command -- all four corners, same angle, same mirror -- and all
four answer 8.00 (`flight-logs/bearingsweep_run4_allcorners.txt`). The pods are
not refusing anything.

**RUN 2 REPRODUCED IT IN TEN SECONDS**
(`flight-logs/velocityholdflight_run2_tiltrefused.txt`). The confirmation gate
fired: `reported tilt: FL 0.00 FR 0.00 RL 0.00 RR 0.00`. So the craft gives a
clean A/B on itself:

| | set_tilt sent | all four report |
|---|---|---|
| **ground**, `/fcs/bearingsweep.lua` | ONCE, then wait | **8.00** |
| **flight**, velocity tool | every 0.15 s sample | **0.00** |

Same craft, twenty minutes apart, same command shape.

**TRAFFIC WAS *A* CAUSE, NOT *THE* CAUSE -- corrected by run 7.** The throttle
below fixed the watchdog starvation outright (212 COMMAND_TIMEOUTs to 4) and
the tilt answered on four flights running. Then run 7 failed the same way at
**8 messages a second**. The flooding is real and worth fixing; it is not what
stops the bearings answering. See **THE INTERMITTENT TILT FAULT**.

The reasoning that led to the throttle, kept because the traffic problem it
fixed was genuine: `set_tilt` and `set_rpm` have NO watchdog
pod-side -- "it is set-and-hold" (`pod/main.lua`) -- so re-sending them every
sample buys nothing but load: 4 corners x 2 command types x 6.7 Hz is about
**107 messages a second** on top of the ion keepalive. One saturated link
explains both symptoms at once -- the tilt never arriving AND ion commands
missing their 750 ms watchdog.

`Session:hold`'s own header records the same failure from the other side: "a
200 ms keepalive silently became ~550 ms against a 750 ms watchdog and produced
79 straight COMMAND_TIMEOUT faults."

**FIXED IN THE VELOCITY TOOL:** set-and-hold commands are re-sent at most once
a second, and immediately on any CHANGE -- so the damper still gets every
command the instant it asks. 107 messages/s down to about 9. The tool reports
the achieved rate during the confirmation.

**CONFIRMED BY RUN 3.** With the throttle in, all four corners answered 2.00 at
11 messages/s and phase A ran properly for the first time
(`flight-logs/velocityholdflight_run3_gains.txt`). The traffic was the fault.

#### THE NET GAINS, MEASURED AT LAST

    roll axis    -3.3601 blocks/s per commanded degree
    pitch axis   -2.8029

**INVERTED on both axes, as predicted -- and 3.6x and 7.6x LARGER than
predicted.** The direction was right; the magnitude was not. The fast/slow sign
flip was measured directly on the same flight: reversing to -2 degrees gave
v_stbd -5.573 in the first 6 s against +6.946 at steady state.

**AND THE PARTS DO NOT ADD UP, which is now the open question on this axis.**
Working backwards from the measured net and this flight's own hull angles:

    roll   net -3.360 = direct +0.823 + coupling -1.218 x H  ->  H = 3.44
    pitch  net -2.803 = direct +0.823 + coupling +0.803 x H  ->  H = 4.52

against a modelled 2.13 blocks/s per hull degree -- and the two axes do not
agree with each other either. Either the hull-tilt drift law is wrong, or
something else is pushing. **The loop does not care** -- it divides by the
measured net -- but the model in `velocityhold.predictNet` is not describing
this craft and should not be trusted for anything but a sanity check.

**THE TRIMFLIGHT COUPLINGS ARE SUSPECT.** This flight measured -1.2175 and
+0.8025 hull deg per commanded deg, against the probe's -0.8205 and +0.5588 --
larger by 1.48x and 1.44x, a consistent factor. trimflight flew through the
command flood with no tilt readback, so **the tilt it actually applied is
unknown** and its couplings read low. Anything built on -0.8205 / +0.5588
inherits that, including this section's original -0.934 / -0.376 prediction.

**SO GIVE `trimflight.lua` AND `pitchdampflight.lua` THE SAME THROTTLE** before
trusting another number from either. Both still re-send at the sample rate.

#### RUN 4: THE LOOP CLOSED, AND IT WORKED AS DESIGNED

`flight-logs/velocityholdflight_run4_loopclosed.txt`, the full run at 1 degree.

**Phase A reproduced across probe amplitudes**, which is the first time any
bearing number on this craft has:

    roll    -3.3601 (2 deg probe)  vs  -3.5603 (1 deg)   5.6% apart
    pitch   -2.8029                vs  -2.7900           0.5% apart

**Phase B:**

    NET drift    1.409  ->  1.019 blocks/s     28% less
    loop reached +0.134 starboard, -0.547 bow

**That is the loop working, not falling short.** A proportional loop
under-relaxed by half settles at `v/(1+0.5)` of the disturbance -- it is BUILT
to remove 33%, and it removed 28%. The measured gain says 0.396 degrees cancels
a 1.409 blocks/s drift, half of that is 0.198, and the loop averaged 0.173.

**The report said INCONCLUSIVE, and the report was wrong.** The attribution
floor was a fixed 0.25 degrees, written when the gain was expected to be four
times smaller. With a gain of -3.56 the correct command IS small. The floor now
scales with the measured gain, and the verdict is stated against the design
rather than against zero.

**AND THE THROTTLE HAD A HOLE.** Phase B logged **212 COMMAND_TIMEOUTs and a
slowest loop of 2419 ms** against a 750 ms watchdog, where phase A -- holding a
fixed tilt -- was clean. The throttle only suppressed an UNCHANGED command, and
the loop is rate-limited to 0.05 deg/s, so at a 0.15 s sample it moves the
command 0.0075 degrees every iteration and "changed" was always true. It sent
at full rate again. There is a 0.05 degree change deadband now, below anything
the bearings resolve.

So run 4's phase B numbers are real but taken through a starved link, and the
next run is the clean one.

#### RUN 5: THE THROTTLE FIX HELD, AND THE GUARD WAS TOO STRICT

`flight-logs/velocityholdflight_run5_rollrefused.txt`.

    run 4 phase B, throttle hole    212 timeouts / 120 s = 1.77 per second
    run 5 roll pair, after the fix    4 timeouts /  60 s = 0.07

**A factor of 26.** The change deadband did its job. But the refusal rule was
`any timeout at all`, so four hiccups threw away a roll gain and phase B never
ran. The rule is now **six per 30 s window** -- one every five seconds -- with
anything less reported and used.

**THE GAINS ARE NOW WELL REPRODUCED:**

    pitch   -2.8029, -2.7900, -2.7814   three flights, 0.8% spread
    roll    -3.3601, -3.5603            two flights, 5.6% apart

The residual 2155 ms loop stalls are not the command rate -- 12 messages a
second cannot stall a loop for two seconds. Most likely chunk loading as the
craft drifts; `Session:hold` re-arms on its next keepalive, which is why four
of them do no harm.

#### RUN 6: THE LOOP STOPPED RUNNING, AND THE CRAFT ROLLED TO -15 DEGREES

`flight-logs/velocityholdflight_run6_abort.txt` and
`velocityhold_run6_settle_csv.csv`. **This is the most important safety finding
in this document, and it is not about the control law.**

From the CSV, during the first settle at a ONE degree command:

    t=26.0  roll  -0.10   speed  0.18   props 64/64   normal
    t=28.7  roll  -6.81   speed  1.58   props 64/64   PAST the 6 deg abort
    t=32.3  roll -15.05   speed  8.49   props 64/64   past the speed abort
    t=34.9  roll  -9.31   speed 12.5    props 60/64   damper acts, 9 s late

**The props stayed symmetric while the hull rolled 15 degrees in six seconds,
and the tilt abort never fired although the hull passed it at t=28.7.** Neither
the roll damper nor `limits()` ran. The loop was not executing samples.

Nothing was wrong with the control law, the gain, or the actuator. **The loop
simply stopped**, and everything that keeps the craft safe lives inside it.
This is the same stall that read 2155 ms in runs 4 and 5, longer -- and the
throttle had already cut traffic tenfold, so it is not the command rate. The
likeliest remaining cause is server-side: chunk loading as the craft drifts
several hundred blocks during phase A.

**WHAT CHANGED, and it is a rule for every flight tool here:**

- **A late sample neutralises.** If a sample arrives more than 1.5 s after the
  last one, the tilt is cleared and the window ends. The craft has been flying
  on a standing command with nothing watching it, and carrying on with that
  command is how run 6 reached 13.74 blocks/s.
- Abort limits tightened to **5.0 blocks/s and 4.0 degrees** from 8.0 and 6.0.
  The expected response at 1 degree is 3.5 blocks/s, so 5.0 is still well clear
  of the signal and leaves far more room when the loop returns from a stall.

**THE CRAFT HAS BEEN INTERMITTENTLY ANOMALOUS ALL DAY** -- bearings ignoring
`set_tilt` in flight while answering on the ground, lifting at 48 rpm where it
had held to 64 three hours earlier, and now a six-second loop stall. Between
episodes it measures consistently. **Treat a surprising flight result as
suspect until the craft has been shown to be behaving**, and prefer ground runs.

#### THE INTERMITTENT TILT FAULT -- the live blocker

**In flight, the bearings sometimes ignore `set_tilt`. On the ground they never
have.** Every tilt-confirm result from 2026-08-27:

| run | conditions | all four corners report |
|---|---|---|
| 2 | no throttle | **0.00 FAILED** |
| 3 | throttle | 2.00 ok |
| 4 | throttle | 1.00 ok |
| 5 | throttle | 1.00 ok |
| 6 | throttle | 1.00 ok, then a 6 s loop stall |
| 7 | throttle, **8 msg/s** | **0.00 FAILED** |

Ground sweep tilt readback: **five runs, five successes** -- including one taken
**two minutes before run 7 failed**
(`flight-logs/bearingsweep_run5_postanomaly.txt` then
`velocityholdflight_run7.txt`). That pair is the cleanest statement of the
fault available: same craft, same command shape, two minutes apart, ground
works and flight does not.

What is ruled out: the command shape (all four corners answer it on the
ground), the pods refusing it (no faults), `prop.active` being false (it reads
true in flight), and message rate (run 7 failed at 8/s where runs 3-6 succeeded
at 10-12/s).

What is left, untested: something about being AIRBORNE, or a craft state that
persists after an event -- run 7 followed run 6's stall and -15 degree roll by
eleven minutes.

**The next session should start here.** The cheapest discriminator that has not
been run: a flight that climbs, confirms the tilt, and lands -- nothing else.
Ninety seconds, no measurement, repeated a few times to get a hit rate. If it
fails while a ground run either side of it succeeds, the fault is altitude or
motion, not the code.

#### AND THE PROBE IS NOW 1 DEGREE, NOT 2

At -3.36 blocks/s per degree a 2 degree probe drove the craft to 6.9 blocks/s
against an 8.0 abort. trimflight flew 2 degrees twice "without incident" -- but
through the flood, so that is not the reassurance it looks like.

 A bearing only obeys a manual target while
it is ACTIVE -- "at 0 RPM the target is stored and completely ignored:
getTiltAngle stays 0 and getThrustVector does not move" (`props.lua`) -- and
this tool read neither `prop.active` nor the achieved `prop.tiltAngle`.
`bearingsweep` does; five findings in this document died of not doing it.

**FIXED, and this is THE RULE again.** Phase A now commands the probe tilt for
6 s and reads every corner's `tiltAngle` back before measuring anything. If the
four corners do not answer it aborts in ten seconds with the diagnosis instead
of flying four minutes of nothing. Every measurement window also reports the
achieved tilt, and a reverse pair whose halves did not reach the commanded
angle is refused rather than reported as a gain.

**THE CHEAP NEXT STEP IS ON THE GROUND.** `/fcs/bearingsweep.lua` tilts FL to
8 degrees at 64 rpm and reads the angle back -- two minutes, nothing armed. It
returned `reported tilt 8.00` on 2026-08-27. If it still does, `set_tilt` works
and the problem is specific to this tool or to flight; if it does not,
something on the craft has changed since that run.

#### WHAT THIS SUPERSEDES

`fcs/lateralhold.lua` answered the runaway by making ROLL the controlled
variable and tilt the thing that holds it -- a reasonable response to an
unexplained event. With the plant measured the simpler statement is that the
actuator is inverted and slow, and a loop that respects both works. lateralhold
remains the truth about azimuths and body velocity and is used by the new code.

### THE DRIFT ANALYSIS -- 2026-08-27, from the CSVs, no flight required

`luajit tools/analyse_drift.lua flight-logs/rolldrift_run2/*.csv`. The passive
drift flight is the only clean free-oscillation record here -- run16, run18,
run19 and the axisresponse runs were all commanding attitude, and their period
spreads (60-119%) say so.

#### FIRST: three archived logs have TRANSPOSED angle columns

`attitude.lua` once assumed +X forward and reported roll and pitch swapped.
Flights either side of that fix are both in `flight-logs/` and nothing in the
files says which is which -- so `analyse_drift` recomputes every angle from
`quaternion_*`, which is raw sensor output, and compares:

| log | verdict |
|---|---|
| `rolldrift_run2/flight_1787719926829.csv` | **TRANSPOSED** |
| `axisresponse_run4/*`, `axisresponse_run5/*` | **TRANSPOSED** |
| `run16_csv`, `run18_csv`, `run19_csv` | correct, to 0.0000 deg |

Recomputed ROLL equals logged PITCH to 0.0000 on the transposed files. **Any
conclusion drawn by reading `roll_deg`/`pitch_deg` out of those three has the
two axes swapped** -- and that includes the recorded standing pair
**+0.368 roll / -0.638 pitch**, which comes from the passive drift flight and
which the whole trim case was built on. Over the corrected window the means are
**roll -0.615, pitch -0.338**.

That also closes open item 3's puzzle -- "only pitch looks stable, at about
+0.68, OPPOSITE in sign to the recorded value". It was not drifting. It was the
other axis.

**Never read the angle columns of an archived flight. Derive from the
quaternion.** `analyse_drift` does, and says so when a file disagrees.

#### THE CURVE IS ONE OSCILLATOR PLUS ONE TRANSIENT

With the axes corrected, over the 48 s passive window:

| | mean | range | amplitude | crossings | period |
|---|---|---|---|---|---|
| **roll** | -0.615 | -4.07 .. +4.11 | 4.09 | 3 | **32.7 s**, spread 0% |
| **pitch** | -0.338 | -4.66 .. +1.88 | 3.27 | 1 | none |

**Roll oscillates. Pitch does not** -- it makes a single overdamped return from
-4.7 to +1.9 over about 30 s and stays there. All three independent sources now
agree with each other for the first time: the damper flight's roll period
("nearer 35 s than 42"), the pitch flight's OVERDAMPED verdict, and this CSV.

So **"roll and pitch oscillate out of phase" was wrong**, and the corrected
mechanism is simpler: one axis oscillating fast against one axis traversing
slowly still winds the tilt VECTOR round. It does not need two oscillators.

#### AND THE TILT REALLY IS STEERING THE CRAFT

Every artifact that could have faked this was checked and none of them did:

    velocity heading, WORLD      +208.9 deg in 48 s   (+4.31 deg/s)
    yaw                            -3.5 deg           -- 2%, NOT a yaw artifact
    tilt magnitude       min 0.97, mean 2.88 deg      -- never near zero, so
                                                         not an atan2 artifact
    speed                min 2.32, mean 4.65 blocks/s -- never near zero either

    velocity rotation vs tilt rotation:  r = 0.75 at a lag of 2.7 s

**Nothing other than hull tilt needs to be invoked.** Lift points along the
hull's up axis, the hull leans, the craft goes that way, and drag gives it a
lag of a few seconds against the 11 s that `1/universalDrag` implies.

One methodological note, because it produced a wrong answer first: comparing
NET SWEEPS said the velocity was rotating **1.61x faster than the tilt driving
it**, which would have been a real anomaly. It is an artifact of the window --
the tilt winds forward and then unwinds while the velocity is still catching
up. Correlating the two RATES at a range of lags is the honest test.

#### WHAT THIS MEANS FOR THE PLAN

**Damping roll IS the fix for the curve, and it already flew.** 39% less
excursion, 40% faster decay. There is nothing to add on pitch: it is not an
oscillator, and what it contributes to the curve is a one-time settling
transient rather than a persistent one.

So layer 1 is DONE, and the drift work is now entirely layer 2 -- the velocity
loop, at the bearing gain measured on the ground.

### THE PITCH FLIGHT -- 2026-08-27, two runs, and the second corrects the first

`/fcs/pitchdampflight.lua`. Logs: `flight-logs/pitchdampflight_run1.txt` and
`_run2_measureonly.txt`. **Read run 2. Run 1's authority is void** -- see the
sign section.

#### 1. PITCH DOES NOT RING, AND IT COMES HOME. No damper wanted.

    baseline +0.805  ->  peak +3.357  ->  settled +0.582 deg
    gave back 109% of the excursion
    zero crossings in 120 s ...... 1
    rate to 1/e .................. 7.8 s
    VERDICT ...................... OVERDAMPED

Roll rings through 5 zero crossings over 105 s. Pitch crosses once, decays in
under 8 s, and **returns to where it started**. There is a real restoring
moment and enough damping that the axis creeps home without overshooting.

**Pitch is the healthy axis, and a rate damper on it buys nothing.** The tool
says so itself and refuses to run the A/B.

**The NO-SPRING worry is dead**, and that is the good news. "It did not ring"
could have meant the hull simply parks at whatever pitch it is left at, which
would have meant every standing pitch offset here is a parked attitude rather
than an equilibrium, and that the velocity loop gets no self-levelling help on
this axis. It gives back 109% of an excursion. It levels itself.

**This left the drift curve without an explanation for about an hour, and then
the CSVs supplied one** -- see **THE DRIFT ANALYSIS**. "Roll and pitch
oscillate out of phase" was wrong, but only in its detail: roll oscillating at
32.7 s against a slow pitch transient winds the tilt vector just as well, and
the tilt steers the craft at r = 0.75.

#### 2. THE SIGN IS POSITIVE. The contradiction was mine, not the craft's.

Raising the FORWARD corners raises the bow, exactly as the geometry and
`mixer_profile.lua` both say. **There is no contradiction with the 2026-08-26
ion measurement.** An earlier draft of this section claimed there was; it was
wrong, and the wrongness is worth keeping because of how it happened.

Run 1 read **-0.0440** and run 2 read **+0.0237** -- opposite signs, same
command, same code. Run 1 pulsed straight out of the climb with no quiet window
first, and its "peak" was **the first sample after release**: it measured the
craft's leftover climb motion, not the pulse. Run 2 sat quiet for 12 s first and
its peak arrives 2.7 s after release, which is the propellers spinning down
(the roll flight saw 1.4 s).

**A single pulse measures the pulse PLUS whatever the craft was already doing,
and on this craft the second term is as large as the first.** Two fixes, both
now in the tool:

- the pre-pulse rate is measured over a 12 s baseline window and SUBTRACTED,
  which is what makes the measurement linear;
- phase A now flies a REVERSE PAIR, +P then -P, and differences them. Drift
  common to both halves cancels; the response reverses and adds. The same
  technique, for the same reason, as `trim.staticGain` on the bearings.

Verified against synthetic drift: unsubtracted single pulses read -0.0333 and
+0.0484 for a craft whose true authority is +0.0234; the pair reads +0.0231
whatever the drift.

#### 3. THE AUTHORITY IS NOT SETTLED YET

    predicted   0.0493 deg/s^2 per rpm   (measured roll / the unit-free 1.91)
    run 2       0.0237                   48% of it, single pulse
    run 1       void

An earlier draft of this section said the ratio prediction landed at 89% and
called it the first prediction on this craft to come in close. **That was run
1's contaminated number and it should not have been quoted.** The honest state:
the ratio route is still the best prediction available -- it cancels the
unexplained 2.9x in the force chain, where the from-scratch thrust model does
not -- but on the one clean reading it is 2x high, which is the same
order of error the thrust model has. **Re-fly to get the reverse-pair value
before believing either.**

`pitchdamp.MEASURED` still ships every field **nil**. Two runs have disagreed by
a factor of two and a sign; nothing here is safe to store yet.

### RUN 2 OF THE SWEEP: THE CRAFT LIFTED AT 48 RPM

`flight-logs/bearingsweep_run2_lifted.txt`, 2026-08-27, three hours after run 1.

    run 1   16 / 32 / 48 / 64 rpm all completed, hull on the ground throughout
    run 2   16 / 32 completed; at 48 rpm the hull ROSE 0.89 blocks and aborted

**On the same thrust and the same mass.** 13646 vs 13519 per bearing at 16 rpm
(+0.9%), live mass 105296.4 against 105299.4. Nothing about the craft's lift or
its weight changed, so **the craft is not resting the way it was** -- it is
supported differently, or not fully supported. It drifted for about five
minutes at 1.4 blocks/s during the failed velocity flight before landing, which
is a few hundred blocks from where it started.

This matters beyond the sweep: "64 rpm is 52.1% of weight and props-only hover
is 122-124 rpm" is a measured fact from a craft sitting flat on the floor. A
hull that lifts at 48 is not in that condition, and **no ground reading taken
in that state should be trusted** -- including the bearing gain itself.

**FIXED IN THE TOOL.** A lift abort used to skip the tilt readback entirely,
which is how run 2 came back without the one number it had been flown for. It
now cuts the props, waits for the hull to come down, and runs the tilt check at
the highest rpm that DID hold the ground -- or says plainly that the hull never
came back down. Every rpm row also reports the altitude gain, so a craft
creeping upward is visible before it aborts.

### THE BEARING GAIN -- measured, 2026-08-27, on the ground

`/fcs/bearingsweep.lua`, ~2 minutes, nothing armed, the craft never left the
floor. Log: `flight-logs/bearingsweep_run1.txt`.

| rpm | thrust per bearing | per rpm | corner spread |
|---|---|---|---|
| 16 | 13519.2 | 844.95 | 0.4% |
| 32 | 27496.9 | 859.28 | 0.2% |
| 48 | 41390.8 | 862.31 | 0.1% |
| 64 | **55420.5** | 865.94 | 0.1% |

**It is a straight line with a small offset:**

    thrust = 872.49 x rpm - 442.6      r2 = 0.999997, every point inside 0.11%

**THE SLOPE IS THE RECORDED CONSTANT TO 0.0085%.** 872.49 against the
872.56 per bearing that 6968.34 craft-wide implies -- measured days apart, by a
different tool, and they agree to one part in twelve thousand. That agreement
is what closes the question rather than any single reading.

**THE GAIN, at 64 rpm and the live mass of 105296.4:**

    0.8165 blocks/s of terminal drift per degree of common-mode tilt
    3.97x the 0.2057 that fcs/trim.lua and lateralhold.terminalSpeed store

**THE LATERAL FORCE ITSELF SCALES 4.00x -- not merely the thrust reading.**
Same corner, same 8 degree mirrored command, two tools two days apart:

    vectorprobe  16 rpm   lateral  3886.0    lift  -27650.2
    bearingsweep 64 rpm   lateral 15540.3    lift -110574.9
    ratio                          3.9990          3.9991

That was the one real doubt left -- whether the *lateral* component takes the
rpm scaling the way lift does -- and it is now measured, not argued. It also
retires the worry that the x1.353 air-density factor is hiding in here: the
ratio is 4.00, not 5.4.

**THE PAIR STILL ADDS AT FLIGHT RPM.** Coherence 1.000, pushing 90 deg =
STARBOARD at azimuth 0. Verified at 16 rpm and never above it until now; if it
had come back CANCELS, every lateral number in this document would have been
describing a force the craft does not feel.

**WHAT IT MEANS.**

- The trim flights are explained with no new theory. A 1 degree trim was costed
  at 0.206 blocks/s and really costs 0.817, so the actuator pays back what it
  removes. That is exactly what flew, twice.
- For layer 2: holding against the measured 1.2-1.7 blocks/s drift wants
  **1.47 to 2.08 degrees** of tilt, comfortably inside the 4 degree clamp.
- The vertical sum reads NEGATIVE on this craft (-110574.9 for a corner that is
  lifting it). That is a handedness convention in `getThrust`, it is consistent
  across both tools, and it is now modelled in the harness. Not a fault.
- The per-corner spread is 0.1-0.4%. The four corners are still symmetric.

**One caveat, stated because it is the only one left.** The offset means a fit
forced through the origin BENDS: read proportionally, thrust/rpm climbs
844.95 -> 865.94 and a naive linearity test cries NONLINEAR on textbook data.
`bearinggain.scalingVerdict` returns **LINEAR+OFFSET** for this and still hands
out the gain, because a constant offset does not change a gain read AT an rpm.
It only matters extrapolating down toward zero, where the offset is the whole
signal.

### NOTHING MAY BE A STORED CONSTANT -- the craft is going to change

**The hull is going to gain machines, and every stored gain decays silently as
it does.** Mass rises, the centre of mass shifts, the moment arms move. A
number measured on 2026-08-27 and pasted into a control path is correct on
exactly one craft, and this project has already been bitten by the milder
version of that: `thrustPerBearing = 13960.98` is a real measurement of a real
craft at 16 rpm on the ground, and using it at 64 rpm in flight is 4x wrong.

So the rule, and it applies to everything built from here on:

**Read the live value. The telemetry is already there.**

| what | live source | who reads it |
|---|---|---|
| bearing thrust at the current rpm | `prop.perBearing[i].thrust`, pushed ~1 Hz | `fcs/bearinggain.lua` |
| craft mass | `sublevel.getMass()` | `bearinggain.weightFromMass` |
| moment arms / hull box | `sublevel.getInertiaTensor()` | `fcs/craftgeom.lua` |
| standing tilt | a measured window, never a recorded pair | `fcs/trim.lua` reverse pairs |
| coupling sign per axis | measured in flight, per axis | `trim.staticGain` |

`fcs/bearinggain.lua` is the pattern to copy: it takes thrust, mass, pressure
and bearing count as arguments, defaults them only to the calibration day for
*comparison*, and has a `driftFromReference()` whose whole job is to say how
far the craft has moved from the day the constants were written. Bolting a
machine to the hull and re-running `/fcs/bearingsweep.lua` is then the entire
recalibration procedure.

**AND THIS IS WHY LEVELLING MUST BE A LOOP, NOT A TABLE.** A static trim
computed once is a standing error the moment the load changes. The velocity
loop is already the adaptive answer for drift -- holding velocity at zero does
not care what the standing tilt is, or what caused it -- and the same argument
applies to attitude: measure the offset in the window you are flying, correct
from the residual, re-measure. `trimflight.lua` already does exactly that (it
measures its own gains and its own baseline every flight, and its pass 2
corrects from the residual rather than from a stored figure). Keep that
property in anything that replaces it.

The remaining static assumption worth naming: the four corners are assumed
symmetric, and after a repair they were verified to be. A load bolted to one
side breaks that, and nothing currently checks it -- `/fcs/bearingsweep.lua`
prints the per-corner thrust spread, which is where that check would start.

### What is still open, in the order the strategy needs it

1. **CLOSED 2026-08-27 -- see THE BEARING GAIN.** Measured 3.97x, ADDS at
   flight rpm, confirmed against vectorprobe to 0.03%. The reasoning that
   framed it is kept below because it is still how the answer is checked, and
   because the shape of the mistake is worth remembering -- two files stored a
   number instead of reading one, and it cost two flights:
   `2*T*sin(tilt)` uses **T = 13960.98, which is the bearing thrust at 16 RPM
   from a measurement taken ON THE GROUND** -- it reproduces vectorprobe's
   3886.3 at 8 degrees exactly, which is how we know. The craft flies at 64 rpm.
   If lateral force scales with rpm the way lift does, the real figure is ~4x
   and every drift cost in `fcs/trim.lua` is 4x optimistic. The flights bracket
   it at 0.23 (roll) to 0.47 (pitch) blocks/s per degree against a modelled
   0.205, but the hull tilt moves at the same time so it is not clean.
   **Measure it: hull level under the damper, a known tilt at 64 rpm, terminal
   net drift.**

2. ~~WHAT ROTATES THE TILT VECTOR?~~ **ANSWERED from the CSVs -- see THE DRIFT
   ANALYSIS.** Roll oscillating at 32.7 s against a slow pitch transient, and
   the tilt steers the craft at r = 0.75. Damping roll is the fix and it has
   flown.

   What is left on this axis: the pitch AUTHORITY is not settled (two runs, 2x
   apart, one of them void). `pitchdamp.MEASURED` ships every field **nil** on
   purpose. One `--measure-only` run with the reverse pair closes it, and it is
   no longer on the critical path.

3. **THE STANDING OFFSETS ARE NOT CONSTANTS -- and the recorded pair was
   TRANSPOSED.** The "+0.368 roll / -0.638 pitch" that the whole trim case rests
   on comes from a log whose angle columns are swapped; corrected, that window
   reads **roll -0.615, pitch -0.338**. See **THE DRIFT ANALYSIS**. That also
   explains why "pitch looks stable at +0.68, OPPOSITE in sign to the recorded
   value" -- it was the other axis all along.

   The later readings (-0.490/+0.498, +0.205/+0.692, -0.244/+0.695) are from
   post-fix flights and stand. They still move every flight: anything that
   re-measures is right, anything that stores a number is not.

4. **THE HULL DAMPS ITSELF MORE THAN THIS DOCUMENT SAYS.** Undamped, run 1's
   roll went +5.57 -> -0.72 -> +0.44: an 87% amplitude drop in the FIRST half
   cycle, period nearer 35 s than the recorded 42. "5 zero crossings over 105 s"
   reads as barely damped and that is not what flew. Worth re-deriving
   `springPerDegree` from -- it changes what pitch damping is expected to buy.

5. **Measured roll authority is 35% of prediction and nobody knows why.** NOT
   the moment arm: ion authority validated against the same craftgeom arm at
   97% and 102%. Something in the propeller force-per-RPM chain is off by ~3x,
   and that chain feeds any thrust model built later.

### Do not repeat these

- **Do not trim standing tilt to fix drift.** Flown twice, measured, does not
  work. The actuator pays back what it removes.
- **Do not put the damper on the bearings.** This document recommended it for
  most of its life; the measurements retired it. Bearings translate and trim;
  RPM damps.
- **Do not put a blocking ack-waiter in a control loop.** `set_rpm` is
  idempotent and set-and-hold, so a loop re-sending every iteration IS the
  retry. A blocking waiter turns a dropped command into a full second of
  silence.
- **Do not judge drift by mean ground speed.** It is a magnitude, so the hull's
  oscillation contributes even when the mean velocity is zero. Run 1 of the
  trim was judged on it and could not be. Use NET DISPLACEMENT over the window.
- **Do not chase FR.** It answered 20 of 20. The per-pod hunt is over.
- **LuaJIT is not the craft's Lua, and format strings are where they differ.**
  A `%+5s` shipped and killed a ground run on its second line -- "invalid
  conversion specification" -- after the harness had run the same line minutes
  earlier without complaint. The `+`, space and `#` flags are numeric-only;
  LuaJIT ignores them on `%s`, CC:Tweaked rejects them. `tools/test_formats.lua`
  catches the class now. Every harness being green is not the same as the craft
  being able to load the file.
- **A loop that stops is more dangerous than a loop that is wrong.** Every
  abort, every limit and the whole damper live inside the sample callback, so a
  stalled loop is a craft flying a standing command with nothing watching it.
  Run 6 rolled to -15 degrees and 13.7 blocks/s that way, from a 1 degree
  command, with both abort limits already passed. Measure the gap between
  samples and neutralise on a long one.
- **Watch COMMAND_TIMEOUT, not just the numbers.** A flight whose pods disarm
  three times a minute is not flying the way the measurement assumes, and the
  fault counts are in the CSV the whole time. The velocity tool now reads them
  per window and refuses a gain measured through a starved link.
- **Do not measure a response without confirming the actuator moved.** Run 1 of
  the velocity tool measured a net gain of 0.002 blocks/s per degree from
  windows in which the bearings never tilted, and reported it as a physical
  result contradicting three earlier measurements. Read `prop.tiltAngle` back.
- **Do not close a fast loop on the bearings.** The actuator's fast half has
  the OPPOSITE sign to its slow half. That is the runaway, measured. Rate-limit
  the command and feed the loop a mean, not a reading.
- **Do not open a measurement window straight after releasing a command.** The
  craft is still coasting out of it. Settle first -- trimflight always did, and
  the velocity tool's first version did not and blamed its own loop for the
  difference.
- **Do not read `roll_deg` / `pitch_deg` out of an archived CSV.** Three of the
  logged flights predate the axis fix and have the two columns swapped.
  Recompute from `quaternion_*` -- `tools/analyse_drift.lua` does, and reports
  which files disagree.
- **Do not compare NET SWEEPS of two rotating vectors.** It said the velocity
  was rotating 1.61x faster than the tilt driving it, which would have been a
  real anomaly and is only a window artifact. Correlate the RATES at a lag.
- **Do not pulse an axis without a quiet window first, and subtract the
  pre-pulse rate.** A pulse measures itself PLUS whatever the craft was already
  doing, and here the second term is as large as the first: run 1 of the pitch
  flight came straight out of the climb and read an authority of the WRONG SIGN
  off its own leftover motion. Reverse pairs on top of that, always.
- **Do not search a whole window for an impulse peak.** It works only while
  the window is short against the spring. The pitch tool's first harness run
  read an authority of -0.0015 -- 3% of prediction and BACKWARDS -- because on
  a 120 s window the largest rate is the oscillation's own swing 46 s later,
  not the pulse. `authorityFromPulse` takes a bound now; pass one.
- **Do not store a gain, and do not fly to measure something the telemetry
  already reports.** The bearing lateral gain cost two trim flights and was
  sitting in `getThrust` the whole time. Before planning a flight, ask which
  live reading would answer it on the ground.

### What is being measured, and why it kept failing

`authority.roll` / `authority.pitch` in `mixer_profile.lua` are **0.25, and
that is fine** — read the comment there before touching them. They are not a
measured physical constant; they are the demand→power scalar, a design choice.
What was missing was the *response* that scalar produces, and that is now known
(27.84 / 14.60 deg/s^2 per unit demand at 0.25).

That was the hard blocker on any attitude controller — and the attitude
controller is what fixes the strafe, because the strafe is an underdamped
oscillation and you cannot trim away an oscillation.

Chasing it by flight took **nine flights**, because FIVE separate distortions were
stacked on top of each other. All five are now fixed, but a fresh session
should know they existed, because each one produced plausible numbers:

| # | distortion | effect on the measurement |
|---|---|---|
| 1 | logger dead (`fcs.snapshot` missing) | no flight CSV at all, runs 9-15 |
| 2 | unbounded pod fault list | 30 KB/row, logs rotated every 17 s, pulse data lost |
| 3 | watchdog starvation | differential applied only ~47% of the time |
| 4 | pod slew-rate limit, no wait | torque ramped in DURING the measurement |
| 5 | 0.25 s sampling | 3 samples on the fast axis once 1-4 were fixed |

Roll authority read 3.98, 5.43, 28.33, 26.93, 22.79, 14.07, 17.32, 20.01,
12.97, 86.03 across those runs. **None of that spread was physics.**

### Runs 18 and 19 flew with all five off, and BOTH are physically impossible

They are archived as `flight-logs/axisresponse_result_run18.txt` / `_run19.txt`
with their CSVs. The five fixes held — `spread 0.1500 of 0.1500` on both axes,
Phase A exact at 0.0% residual, the flight CSV surviving the whole run — and
the numbers still came out wrong:

| | run 18 | run 19 | samples |
|---|---|---|---|
| roll | 46.69 | 75.29 | 7 → 6 |
| pitch | 11.47 | 13.47 | 13 → 13 |

The axis with 13 samples repeats to 17%. The axis with 6 has a **61% spread**.

**Do not fly this again to get a better number. The measurement was never the
route.** See the next section — the answer was in the inertia tensor the whole
time, and it says roll is about **27**, so both of these are 1.7x and 2.7x
over what the craft can physically produce.

### The arms come from the tensor — no flight required

`mixer_profile.lua` offered two routes: *"Calibrate by measuring the arms, or
by flying a per-axis step response."* Nineteen flights went into the second.
The first is arithmetic.

`getInertiaTensor()` returns three diagonals, which **over-determine** the hull
box for a known mass. `fcs/craftgeom.lua` solves it:

    beam 87.1  x  length 205.1  x  height 47.9 blocks   (2.35x longer than wide)

Checked three ways: the solve round-trips all three diagonals, all three
edge-squares come out positive, and this document had already derived "about
2.4x longer than wide" from runs 6/8 by a completely different route.
`getCenterOfMass()` and `rotationPoint` agree to ~1e-5, so the craft rotates
about its COM and that is where the arms measure from — checked, not assumed.

A pod cannot sit outboard of the hull, so half the box is a hard ceiling on the
moment arm. With ion force already exact, the unit chain closes (it reproduces
the documented 3.342x weight with no fudge factor):

    ceiling: roll 27.84   pitch 14.60   expected roll/pitch ratio 1.91

| run | roll | % of ceiling | ratio | |
|---|---|---|---|---|
| 6 | 3.98 | 14% | 1.88 | starved, but proportioned right |
| 8 | 5.43 | 20% | 2.10 | same |
| **9** | **28.33** | **102%** | — | **at the ceiling** |
| **10** | **26.93** | **97%** | — | **at the ceiling** |
| 18 | 46.69 | 168% | 4.07 | IMPOSSIBLE |
| 19 | 75.29 | 270% | 5.59 | IMPOSSIBLE |

**Runs 9 and 10 — dismissed as distorted — were the honest ones**, and they
agreed with each other to 4.9%.

### The 4.49 bound was wrong, and it is why run 18 passed

`axisresponse.lua` checked the ratio against `t[1][1]/t[3][3]` = **4.49**.
That is the value for a craft whose lateral and longitudinal moment arms are
**equal** — a square craft. This hull's arm ratio is **0.425**, so the expected
ratio is **1.91**. Run 18's 4.07 sailed through a check that was measuring the
wrong quantity, and being one-sided it could never have caught a low reading
either.

**That is the fifth instance of this project's signature failure mode** — a
test or harness encoding what the code believed rather than what the craft is.
The others: the atan bug, the axis labels, the RR-deficit constant, the pitch
sign. Fixed in `d7a4770`; both checks now derive from the live tensor, the
ratio check is two-sided, and there is a per-axis absolute ceiling.

### Also open, not on the critical path

- **Yaw is unsolved.** `getMagneticNorth()` is `{0,0,0}`; vectoring is the
  route and the command path exists. `mixer.allocate` already accepts
  `demand.yaw`, echoes it in `unmet.yaw`, and gates it behind
  `yawAvailable = false` -- turning it on is a coefficient table and a flag.
  Measure the sign of the lateral force from a bearing tilt first; the
  calibration in strategy step 1 gives it.
- **The +23 block hold ceiling** was measured while the watchdog was forcing
  `commsLossPower` roughly half the time -- exactly the level-2/level-3 dither
  that set the ceiling. That watchdog problem is long fixed, so the ceiling may
  have lifted on its own. Untested.
- **Validate the 280->320 atmosphere segment** with
  `atmosphere.verify(model, {285, 290, 300, 310})`. Nothing was ever measured
  between, and y=320 is a hard flight-envelope ceiling.
- **`mixer_profile.lua`'s `authority.roll` / `authority.pitch` are 0.25 and
  that is fine.** They are the demand->power scalar, a design choice, not a
  measured constant. The response they produce is known: 27.84 / 14.60
  deg/s^2 per unit demand at 0.25.

---

## MEASURING ANYTHING ON THIS CRAFT: two techniques that finally worked

Both were forced by the same fact -- **the hull's oscillation is larger than
whatever you are trying to measure.** 42 s period, peak rate 0.90 deg/s, so up
to 3.6 degrees of hull motion inside a 4 s window against a signal of 2.2.

### REVERSE PAIRS: fly +N then -N and take half the difference

Two adjacent windows sit at nearly the same phase of a 42 s oscillation, so the
hull's contribution is near-identical in both while the commanded torque flips
sign. Differencing cancels it to first order AND doubles the signal.

**Averaging more single-sided steps does not work** -- the contamination is not
zero-mean over a few samples. Single-sided steps gave 0.1060, 0.2556, 0.3335
for 1, 2, 3 rpm: rising, but nowhere near the 1:2:3 the physics requires.
Paired, the same craft gave 0.0910 and 0.0931 per rpm.

Also check the pair is ANTISYMMETRIC. If the common-mode term exceeds the
signal, the hull moved more than the command did and no differencing rescues
it. That check caught a step where FR never received its command: the reverse
half measured +0.0079, essentially zero, because no differential existed.

### START EVERY STEP NEAR LEVEL

A step ends after sweeping its budget (3 deg) and the roll abort fires at 6. So
a step begun at 4 degrees of roll -- entirely normal on this hull -- aborts
before it finishes. The 3 rpm pair failed twice running for exactly this
reason, while 2 rpm passed by being slower and luckier.

Waiting for the hull to swing back through level costs a few seconds against a
42 s period, and it is the difference between a measurement and a discarded
step.

### AND CROSS-CHECK EVERY FIT AGAINST THE ANGLE ACTUALLY SWEPT

A quadratic fit with a free rate term will happily read noise. One phase
reported alpha = +0.0884 while the craft rolled 0.07 degrees -- that alpha
implies 0.38, five times what happened. The sign gate believed it and
authorised a flight on it.

Require a minimum real sweep, and discard any step whose fitted alpha disagrees
with the sweep. This has caught bad steps three times since.

---

## TELEMETRY FIELDS THAT DO NOT REPORT WHAT THEY LOOK LIKE

THE RULE's shape, in new places. Every one of these cost at least one flight.

| field | looks like | actually |
|---|---|---|
| `prop.bearingRpm` | bearing speed | **0 in every sample ever logged**, including at a verified 64 rpm |
| `prop.bearingAngularSpeed` | bearing speed | 0 on all eight at 16 rpm with `active true` |
| `prop.controllerRpm` | — | **this is the one that tracks.** Gate on it |
| `getThrust` | a static structural value | **oscillates under rotation; denormal ~1e-20 at rest.** Not comparable across corners in ANY state |
| `prop.hasSource` | — | reliable, and it is what caught FR's real failure |

**`getThrust` deserves its own warning.** Four runs were spent trying to make a
per-corner thrust comparison work as a preflight check. Spinning, it named
three different corners as faulty on three consecutive runs; at rest it is
denormal noise, so the percentages are ratios of nothing and it printed
"thrust 0.00 (43%)". The one reading that ever discriminated (7.6e-32 against
111688 on a genuinely dead FR) caught a state where three corners happened to
retain a value from recent rotation. That was luck, not a measurement.

Gate on the DISCRETE signals instead: `hasSource`, reaching the commanded RPM
on the RSC, `active`, and overstress. Between them they catch both failures
actually seen -- a lost kinetic source, and a stalled drivetrain.

**Topology note that makes this make sense:** each corner has ONE Rotation
Speed Controller driving BOTH its bearings. The pair always turns together, so
RPM is a per-corner control and never per-bearing, and the RSC's own speed is
the authoritative per-corner health signal. Per-bearing thrust is downstream.

---

## TWO WAYS THIS CRAFT ENDS A RUN ON ITS SIDE — both fixed, both worth knowing

### Asymmetric propellers are a large roll couple

Props carry ~52% of craft weight at 64 rpm, so three corners at 64 against one
at 0 rolls the craft hard. It happened from a craft that had ALREADY LANDED:

    t=219.1  y -26.47  roll -0.00  speed 0.09   FL 64  FR 0  RL 64  RR 64
    t=228.1  roll 29.35  speed 7.0  airborne again

It thrashed for seventy seconds and settled on its side. Two causes, both now
fixed in `fcs/flight.lua` and `fcs/vectorprobe.lua`:

1. `Session:setAllProps` returned on the FIRST corner that failed, leaving the
   rest untouched. It now attempts all four, retries the stragglers, and
   announces an asymmetric outcome loudly. **A craft with all four props at the
   wrong speed is level, which is recoverable. Asymmetric is not.**
2. **`parallel.waitForAny` kills the listener the moment the main loop
   returns**, so cleanup ran with nothing pumping rednet and every reply timed
   out. No number of retries produces a reply when nothing is listening. Run
   shutdown under its own parallel with the listener.

### Never cut the props while airborne

They carry ~52% of the lift, and `finish()` deliberately leaves the ion banks
at level 2. Zeroing props at +4.7 blocks removes half the support; zeroing them
unevenly adds the roll on top. Above ~1.5 blocks, leave them running and level
and land with `/fcs/bankctl.lua`.

---

## THE POD SAMPLER: one central data loop

Every pod reads its hardware in exactly ONE place -- `samplerLoop` in
`pod/main.lua`. Replies, telemetry sends, the display and `/pod/heartbeat.txt`
all read the published sample and touch no peripheral. That is not tidiness; it
is the fix for a measured 2.5-5% command loss (see START HERE).

    samplerLoop      the ONLY coroutine that reads a peripheral. Samples,
                     publishes, sends to the FCS, answers pending requests.
                     Listens for nothing, so being deaf costs nothing.
    networkLoop      receives commands. Reads no peripheral, ever.
    displayLoop      renders and writes the heartbeat FROM THE SAMPLE
    watchdogLoop     unchanged; reads nothing

Four things about it are load-bearing:

- **`status_request` is queued, not answered inline.** It is a request for
  DATA, so it is served from a FRESH sample -- `ionsweep` and `axisresponse`
  command a power and read it back, and a cached `averagePower` would hand them
  the value from before their own command. It costs no more than the old code:
  the same ~250 ms read, on a coroutine that is not listening. `ping` is
  different -- liveness, answered immediately from cache.
- **The queue is the state; the event is only a wakeup.** A request landing
  while the sampler is sampling has its `pod_sample_request` event dropped (that
  work yields on `task_complete`). So the wait loop's condition reads
  `#pendingStatus` rather than trusting the event. Without that, a request in
  that window waits a whole telemetry period instead of ~250 ms.
- **The sample is replaced wholesale, never updated in place**, so a reader
  taking a local reference gets a consistent set of readings.
- **A failed read keeps the previous half** rather than publishing nil.
  `banks.acceptStatus` copies keys over stored pod state, so nil-ing a half
  would silently freeze it with nothing to show why. `sampleAgeMs` is the tell,
  and it is in every message.

**The two rules `pod/payload.lua` exists to keep**, both pinned by
`tools/test_pod_payload.lua` (41 assertions, and both were mutation-tested --
each rule broken on purpose, each caught):

1. **Never hand back the snapshot's own tables.** The old code appended
   `state.faults` into the table `thrusters.telemetry()` returned. Harmless
   while that table was built fresh and thrown away; against a CACHED table the
   same line appends the fault list to itself on every message, forever. That
   is the unbounded-fault-list bug that destroyed six runs of flight data,
   reintroduced by changing nothing but the lifetime of a table.
2. **Cheap scalars are always live, never sampled.** `armed` and `currentPower`
   change on command boundaries, and `fcs/reboot.lua` decides whether rebooting
   a pod will drop lift by reading exactly those. A one-second-old arm state is
   a safety-relevant lie.

### The FCS side: poll only what has gone quiet

`banks.tick` used to send a `status_request` to all four corners every 2 s
regardless of whether anything was wrong, and **its timer is per PROCESS** --
the logger polls, and so does every flight tool in another tab. So the forced
sampling scaled with how many tabs happened to be open. Two tabs doubled it.
Nothing would ever have shown that; the pods just quietly did twice the work.

That was survivable when a poll was answered from whatever the pod had lying
around. It is not now: a `status_request` deliberately forces a FRESH ~250 ms
sample, so that a caller reading back its own command is not served a value
from before it.

**The pods PUSH full telemetry every ~1 s, so the poll is redundant except when
that stream fails.** `banks.tick` now asks a corner for a status only when the
corner has gone quiet for `quietPollAfterMs` (2500), rate-limited per corner by
`statusRequestPeriodMs` (2000, now a MINIMUM SPACING rather than a period).

- Steady state is **zero** pod-directed traffic, from any number of tabs.
- A fresh program still probes immediately -- never-heard-from counts as
  infinitely quiet, so a tool does not start blind for two seconds.
- Offline detection got FASTER, not slower: a quiet corner is probed at 2.5 s
  instead of waiting on a 2 s round-robin, and `offlineAfterMs` is still 5000.
- `quietPollAfterMs` must sit BETWEEN the pod push period and `offlineAfterMs`.
  Above the push period or a healthy pod is polled forever; below
  `offlineAfterMs` or a pod is declared dead before anyone asked it anything.
  `tools/test_banks_poll.lua` pins that invariant along with the policy.

The key is **defaulted in `banks.lua`, not assumed**: the deployed
`fcs/config.lua` deliberately differs from the repo template, so a new key does
not reach the craft just because it was added here -- and a nil on the right of
a `>=` would crash the logger the moment it ticked.

`actuators.getPropellerStatus` still forces a fresh sample on demand, which is
exactly what it is for. That is the supported way to get a guaranteed-current
reading; everything else should consume the push and read `sampleAgeMs` if it
cares how old the numbers are.

Writes are still done inline in `networkLoop` (`props.setRpm`,
`thrusters.applyCommand`), which is about one tick of deafness per command
applied. That is self-limiting for a steady sender -- the pod applies, then
listens, then the next command arrives -- so it is left alone until measured to
matter. If it ever does, the same pattern extends: park the value in a
last-write-wins slot and let an actuator loop apply it, which is what
set-and-hold actuators want anyway.

## THE BEARING PAIR: mirrored translates, unmirrored does nothing

Measured on the ground, all four corners, coherence 1.000, agreeing within
0 degrees:

    UNMIRRORED (both bearings same azimuth)  lateral 0.0     CANCELS
    MIRRORED   (down-facing flipped 180)     lateral 3886.3  ADDS

`props.lua`'s `tiltTarget` now mirrors by default, keyed off each bearing's own
`getBlockNormal`. Commanding a common azimuth is not a weak input, it is
**exactly zero** -- opposite normals AND opposite thrust signs mean the
partner's lateral force cancels its mate's.

**Lateral force = 2 * T * sin(tilt) per corner**, linear to 0.06% over 4/6/8
degrees. At 8 deg on four corners that is 1.34% of weight, terminal 1.64
blocks/s; the 15 deg clamp gives 2.49% and 3.05 blocks/s.

**AZIMUTH 0 PUSHES TOWARD STARBOARD (heading 90).** Measured, on all four
corners. Neither the old `props.lua` comment (which said bow, and predates the
axis correction) nor the naive reading of "+X is port" was right -- bearing 1
carries NEGATIVE thrust, which flips the force relative to its vector.
`lateralhold.azimuthForHeading` encodes it: heading = azimuth + 90.

**The two props of a corner are at the SAME height, not straddling the COM.**
"One faces up, one faces down" is thrust direction, not position. So opposing
their forces cancels the torque as well as the force -- a "pure couple" made
from them rolled 0.07 degrees in 3 seconds. There is no pure attitude channel
in the bearings. Same-direction tilt gives force AND roll together, and that
coupling is what ran the craft away.

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
- **Session of 2026-08-26 (late morning), current state:**
  - SSH key auth to the host is set up; `ssh mcserver` / `scp mcserver:...`.
    **Do not use sshpass.** `pack_config.py` defaults `USE_SSH_KEY = 1`.
  - FCS-DEV opens THREE tabs at boot: shell, **FCS Telemetry** (the logger),
    and **Flight Tools** (focused). Run flight tools in the third tab —
    running one in the telemetry tab kills the logger.
  - Repo moved to `~/repos/mine/luaScripts/helicarrier-fcs`, git-tracked, and
    indexed by Gortex.
  - Deployed and current: `axisresponse.lua`, `flight.lua`, `sensors.lua`,
    `attitude.lua`, `mixer_profile.lua`, `main.lua`, `snapshot.lua`,
    `startup.lua` on computer 1; `pod/main.lua` on all four pods.
  - `fcs/config.lua` deliberately DIFFERS from the repo template (it carries
    `podIds`); the repo template also has a `hub` block that is not deployed.
  - **`/fcs-dev.lua` (the monitor hub) is NOT deployed.** The repo's
    `startup.lua` would launch it; the deployed one does not. Deploy it as its
    own piece of work if you want the hub live.
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

### Fixing the ramp made the fast axis too fast to measure

Run 17, first with the reach gate: **`differential applied: spread 0.1500 of
0.1500 wanted`** on both axes — the gate does what it says.

But with full torque from the first instant, roll accelerates at ~25.8 deg/s^2
and crosses the 6 deg cap in **0.75 s = THREE samples**, the bare minimum for
the fit and with a 0.464 deg/s start rate to subtract. It reported roll 86.03
and a ratio of 7.23, which the bound check caught.

The 0.25 s sample period was set when a sample cost a full `sensors.read`
(~1.6 s), so it was never the binding constraint. With the cheap read it is:
two Sable calls is ~0.1 s, so 0.25 was discarding half the available samples.

**`pulseSampleSeconds = 0.12`** for the pulse window, and
**`pulseMinSamples = 5`** so the angle cap cannot end a pulse before the fit has
enough points. Harness: roll 6 -> **10 samples**, pitch 8 -> **14**. Sends stay
on their own clock (`keepAliveMs`), so the watchdog margin is untouched, and the
6 deg safety budget is unchanged.

### The bound check needed a tolerance

The hard bound had none, and the harness — whose TRUE ratio is the tensor's
4.48 — measures 4.80, 7% high from discretisation alone. Flagging that as "one
of these numbers is wrong" trains the reader to ignore the check.

Now graded at 20%: above that is a real flag, between the bound and 20% reads
as "at the bound, consistent within measurement error". Applied to the runs so
far, it flags exactly the two that were genuinely broken:

| run | ratio | verdict |
|---|---|---|
| 11 | 11.02 | HARD FLAG (146% over) — unsettled pitch start |
| 15 | 5.04 | at the bound (12%) — within error |
| 17 | 7.23 | HARD FLAG (61% over) — 3-sample roll fit |
| 12, 13, 14, 16 | 1.67-3.70 | ok |

### THE SCATTER, FOUND: the pods slew-rate-limit power, and the pulse never waited

With the logger alive and the CSV no longer 30 KB per row, the pulse window was
finally readable. Run 16, corner powers sample by sample:

    ROLL  pulse  t=148.1  FL 0.2706  FR 0.1206  ->  levels [4,1,4,1]  spread 0.150
                 t=149.0  FL 0.2671  FR 0.1171  ->  levels [4,1,4,1]  spread 0.150

    PITCH pulse  t=173.3  FL 0.2918  RL 0.1418  ->  levels [4,4,2,2]  spread 0.150
                 t=174.2  FL 0.2720  RL 0.1220  ->  levels [4,4,1,1]  spread 0.150
                 t=175.1  FL 0.2161  RL 0.1661  ->  levels [3,3,2,2]  spread 0.050

**The applied torque changed by 3x WITHIN a single pitch pulse**, and the last
line is not quantisation — the commanded spread itself was a third of nominal.

**Cause: `config.maximumChangePerCommand = 0.05`.** The pods slew-rate-limit
power. The pulse steps each corner by `demand x authority` = 0.075, so it takes
**two commands** to reach full differential, and the cancel's 0.15 swing takes
**three**. Every watchdog fire drops the pod to `commsLossPower` and the ramp
restarts from there.

So alpha was being averaged over the ramp-in, and how much of the ramp landed
inside the measurement window varied with command timing. **That is the 2x
scatter** (14.07 .. 28.33).

Also note: the differential is **3 ion levels**, not the 1 assumed earlier in
this document. `[4,1,4,1]` — the earlier arithmetic that reasoned about a
one-level differential was wrong about the magnitude too.

**Fix: wait until the differential is actually applied before starting the
clock.** `pulseReachTimeoutSeconds` / `pulseReachFraction` (3.0 s, 0.9) hold
until the corner spread reaches 90% of nominal, THEN reset `startAt` and the
reference angle. If it never gets there the run is flagged suspect rather than
quietly under-reporting.

Phase A had solved exactly this for its power steps ("the pod has actually
REACHED the commanded power") since the beginning. The pulse never did — the
lesson was already in the file, applied one function away.

**Validated in the harness, which models the slew limit:** measured roll went
12.76 -> 25.57 and pitch 2.39 -> 4.16 once the ramp was excluded. Very close to
the 2x dilution seen in flight, from an independent implementation of the same
physics.

### THE WATCHDOG WAS EATING EVERY FLIGHT — confirmed, and I had wrongly cleared it

The first flight CSV since run 8 (the logger had been dead — see the
`fcs.snapshot` gotcha) settled this outright.

**1716 `COMMAND_TIMEOUT` faults across the four pods in one session.** The
watchdog guard requires `state.armed` and CLEARS it when it fires, so that is
~429 separate arm -> timeout cycles PER POD PER FLIGHT.

That is `hold()` exactly: *send-if-due, then read*. A full `sensors.read`
blocks ~1.6 s with no `set_power` going out, against a 750 ms
`COMMAND_TIMEOUT`. So:

    armed, holding the commanded differential : ~750 ms
    disarmed, forced to uniform 0.195         : ~850 ms
    duty cycle of the real differential       : 47%

**A uniform `commsLossPower` applies NO differential.** Every pulse was being
delivered at roughly half strength, varying run to run with loop timing — the
leading explanation for roll authority scattering 2x (14.07 .. 28.33) across
otherwise identical runs.

**I had reported this theory DISPROVED and that was wrong.** I checked run 5's
corner powers, saw `[3,2,3,2]` in some samples, and concluded the watchdog was
not suppressing the differential. But a 47% duty cycle looks exactly like that
— and the uniform rows I filtered out of the listing read **0.1950**, which is
`commsLossPower` to four decimals. I discarded the evidence and then reported
its absence. **Do not "disprove" a mechanism with a filtered view of the data.**

**Fix: cheap reads for the ENTIRE axis-response flight**, not just the pulse
window. Two Sable calls instead of a dozen puts the send gap at ~0.13 s,
comfortably inside the watchdog. The climb, the hold, the cancel and the
descent were all being starved the same way the pulse was.

`rolldrift.lua` is deliberately NOT switched over: it calls `session:rates()`
inside its sample loop, which needs angular velocity that the cheap read omits.
It is also a passive symmetric test, so a watchdog that forces all four corners
to the same power does not bias its conclusion.

### The fault list was unbounded, and it destroyed six runs of flight data

`state.faults` in `pod/main.lua` was appended to and **never cleared**.
`statusMessage` copies the whole list into every telemetry message and
`fcs/main.lua` writes it into every CSV row — so each row carried **30 KB** of
repeated fault strings.

Flight logs then rotated every ~17 seconds at 20 rows each, and with only a few
kept, the pulse window a run existed to capture was gone before it could be
pulled. Combined with the logger being down, runs 9-15 produced no usable
per-sample data at all.

Now capped at 12 entries and run-length collapsed: **`COMMAND_TIMEOUT x1716`**
is 21 bytes and strictly more informative than 1716 copies. A running
`faultTotal` is kept so trimming loses nothing.

**Note the ordering trap this nearly repeated.** `recordFault` was first placed
below its call sites — and a `local function` declared after the code that
calls it is a nil global at that point, silently. This document already records
that exact bug (`hoverTrim`, which killed a run mid-flight). Caught before
deploy this time, but only by reading the line numbers.

**Both fixes need a POD REBOOT to take effect** — a running pod holds its old
`main.lua` in memory. `/fcs/reboot.lua all` works while grounded and disarmed.

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

**BOTH AXES SCATTER ABOUT 2x, AND THE CAUSE IS NOT YET KNOWN:**

| run | roll | pitch | ratio | collective at hold |
|---|---|---|---|---|
| 9 | 28.33 | — | — | — |
| 10 | 26.93 | — | — | 0.223 |
| 11 | 22.79 | 2.07 (unsettled) | 11.02 | 0.192 |
| 12 | 14.07 | 8.40 | 1.67 | 0.197 |
| 13 | 17.32 | 4.68 | 3.70 | 0.219 |

roll: **14.07 .. 28.33, a 2.01x range**, mean 21.89, sd 6.12.
pitch, settled runs only: 8.40 and 4.68, a 1.80x spread.

**A CORRECTION.** After run 12 this document said roll was *"monotonically
declining — noise scatters, it does not trend"*. Run 13 went 14.07 -> 17.32.
It scattered. That was four points of noise read as a trend, and the inference
drawn from it was wrong. **Do not quote a roll authority yet** — but the reason
is plain scatter, not a systematic drift.

**A SECOND CORRECTION, to the arithmetic.** The pulse was described as spanning
1.125 ion quanta. That is the offset applied to EACH corner
(0.3 x 0.25 = 0.075 = 1.125 quanta); the SPREAD between the raised and lowered
corners is twice that, **2.25 quanta**.

**The quantisation hypothesis does not survive its own test.** Computing the
realized level differential from the collective reported at hold:

    run 10  coll 0.223 -> levels 4/2 -> 2 levels -> roll 26.93
    run 13  coll 0.219 -> levels 4/2 -> 2 levels -> roll 17.32
    run 11  coll 0.192 -> levels 4/1 -> 3 levels -> roll 22.79
    run 12  coll 0.197 -> levels 4/1 -> 3 levels -> roll 14.07

More levels should mean more torque. It does not, and the two runs sharing a
differential disagree by as much as the whole spread. So the hold collective
does not explain the scatter — and it could not, because trim keeps moving
collective throughout the 1.75-2.1 s pulse.

**This is now blocked on data, not on theory.** Diagnosing it needs the
per-sample per-corner powers during the pulse, which only `main.lua` logs. It
has been down since 09:57 (heartbeat frozen at sequence 1113) and **no flight
CSV exists for runs 9-13**. Start the logger in its own tab before the next
run; without it, any further explanation is guesswork of the kind that has
already been wrong twice here.

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

**The reasoning is right; 4.49 was far too generous a bound.** `arm_ratio` is
not merely "< 1" — the tensor pins it at **0.425**, so the real expectation is
**1.91**. The loose bound let run 18's 4.07 through. See *The arms come from
the tensor* in START HERE.

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
`tools/test_flight_window.lua` (49 assertions) exercises every plausible loop
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
the 32% coupling figure both hold as written.**

**But strike the 4.60-vs-4.49 corroboration — it was never evidence.** 4.49 is
`t[1][1]/t[3][3]`, which is the expected response ratio only if the lateral and
longitudinal moment arms are EQUAL. This hull is 2.35x longer than wide, so the
expected ratio is **1.91**, and a measured 4.60 against it is a 2.4x
discrepancy, not agreement. The frame question was decided correctly on the
tilt data above; the ratio "confirmation" was reading the right number off the
wrong yardstick.

**The bow=+Z conclusion is unaffected**, because it never rested on this — it
stands on the two tensor-free legs stated above.

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
| mean roll / pitch | +0.368 deg / **-0.638 deg** (see open item 3 -- these WANDER) |
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
- **You cannot trim away an oscillation.** Trim cancels a DC offset. This is
  AC. That was written before trim was flown, and the flights went further:
  trim does not fix the drift's DC part either, because the actuator pays back
  what it removes. See THE STRATEGY.
- **The direction is fixed by DAMPING BOTH AXES.** Feeding rate back as an
  opposing torque turns the underdamped spiral into a dead-beat return to
  level, which stops the tilt vector rotating. Roll damping is FLOWN and works.
  **Pitch damping does not exist**, so the vector still sweeps.
- **The speed is fixed by a VELOCITY LOOP on the bearings**, not by levelling
  the hull. `fcs/lateralhold.lua` implements it and has never flown.

**THE DAMPER IS FLOWN**, and not on the actuator this section spent its life
recommending. See the actuator survey in START HERE:

    differential propeller RPM   0.0941 deg/s^2 per rpm, MEASURED
    critical damping reached at 3.2 rpm, clamp 4
    FLOWN 2026-08-27: 39% less roll excursion, 40% faster decay

The table below is still correct about TRIMMING a small moment, and it is why
trim belongs on the bearings. It was wrong to conclude that DAMPING belongs
there too, and the distinction is the whole lesson:

| actuator | increment | trimming a small moment | DAMPING a 0.9 deg/s rate |
|---|---|---|---|
| 1 ion level, one corner | 64,517 | **103x too coarse** | 28x too coarse |
| **1 RPM, one corner** | 1,742 | 2.8x — overshoots | **the right size** |
| bearing tilt | continuous | **exact** | 0.13 of the 0.268 needed |

Damping and trimming have opposite requirements. Damping fights RATES, which
are large -- 0.9 deg/s needs 0.268 deg/s^2, which is 3 rpm of differential.
Trimming fights OFFSETS, which are tiny -- 0.31 degrees of standing roll needs
0.0069 deg/s^2, which is 0.075 rpm, a thirteenth of the smallest step there is.
An actuator coarse enough to damp is far too coarse to trim, and vice versa.
**That is why this craft needs both, and why every single-actuator design in
this document's history failed.**

**MEASURED 2026-08-27, and it was blocking for a long time**
(`flight-logs/trimflight_probe1.txt`, reverse pairs at +/-2 degrees, damper
running):

| axis | gain, hull deg per commanded deg | sign | vs predicted +0.493 |
|---|---|---|---|
| **roll** | **-0.8205** | **NEGATIVE** | **wrong sign**, 1.66x |
| pitch | +0.5588 | POSITIVE | 1.13x |

**THE TWO AXES HAVE OPPOSITE SIGNS**, and the roll one is opposite to the
prediction. Anything that assumed the predicted sign would DRIVE the roll
offset rather than cancel it -- which is almost certainly the 1.76 -> 11.5
blocks/s runaway, since that was a roll event on a saturated 12 degree command.
Measuring rather than assuming is the whole reason the probe exists, and it
earned itself on its first flight.

Any loop that tilts the bearings must take the sign per AXIS. One sign for both
is right on pitch and backwards on roll.

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
| `/fcs/podprobe.lua` | why a pod stops answering: ghost host vs slow pod vs packet loss | grounded; echoes each corner its OWN rpm |
| `/fcs/rolldampflight.lua` | does differential-RPM damping actually damp? A/B on an injected pulse | **FLIES**; `--ground-only` safe |
| `/fcs/trimflight.lua` | measures the bearing coupling SIGN, then cancels the standing tilt | **FLIES**; `--ground-only` and `--probe-only` |
| probes | `/pod/yawprobe.lua`, `obstructionprobe.lua`, `thrustprobe.lua`, `stabprobe.lua`, `/fcs/pressureprobe.lua` | read-only diagnostics |
| `tools/test_mixer.lua` | 102 assertions | offline |
| `tools/test_atmosphere.lua` | 37 assertions, pinned to in-game measurements | offline |
| `tools/test_attitude.lua` | 133 assertions; axis mapping, yaw-invariance, harness round-trip, transposition guard | offline |
| `tools/test_flight_window.lua` | 49 assertions; the stable-hold window gate across loop periods, and the cheap read vs the full read | offline |
| `tools/analyze_tensor.py` | body- vs world-frame verdict from a flight CSV | offline |
| `tools/run_*_harness.lua` | sweep, ionsweep, reboot, axisresponse, rolldrift, podprobe | offline |

Reports from every probe are archived in `flight-logs/`.


### `/fcs/podprobe.lua`

    /fcs/podprobe.lua            census + 10 ack round trips per corner
    /fcs/podprobe.lua 25         more round trips
    /fcs/podprobe.lua --force    run with a propeller still turning

Three phases. **RESOLUTION** prints what `rednet.lookup` hands the sender.
**CENSUS** listens passively for 6 s and prints who is actually transmitting as
each corner — pods send telemetry directed at the main they resolved, so this
is the one fact `rednet.lookup` cannot be trusted for. **ACK** then times real
`set_rpm` round trips in a 4000 ms window, deliberately wider than the 1000 ms
`actuators.lua` allows, because a 1000 ms window cannot tell 1100 ms apart from
never.

It reads the wire RAW rather than through `banks.handle`, for the reason that
makes it worth having: the messages `banks` throws away on `senderMismatch` are
invisible from inside `banks`, and they are the signature of a ghost host.

Two things it deliberately does not do. It never guesses an RPM — each corner
is echoed the RPM its own telemetry reports, and a corner whose RPM never
arrived is skipped, because sending 0 to a corner that might be lifting is the
documented way to end a run on the craft's side. And it never treats a `status`
as a reply: only `ack` and `fault` answer a command, which is the same trap
`banks.lua` documents, and reading `type` loosely shows up here as a phantom
200 ms round trip.

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

**Start here — the whole suite, and two lints built from real crashes:**

    luajit tools/test_globals.lua       undefined globals, read from bytecode
    luajit tools/test_forwardrefs.lua   a local function used above its definition
    luajit tools/test_rolldamp.lua      the damper, pinned to the flight numbers
    luajit tools/test_lateralhold.lua   the translation law and its sign guards
    luajit tools/test_vectoring.lua     bearing pair maths, ADDS vs CANCELS
    luajit tools/test_craftgeom.lua     hull box and authority ceilings
    luajit tools/test_pod_payload.lua   the pod sampler's two cached-data rules
    luajit tools/test_banks_poll.lua    poll only what has gone quiet
    luajit tools/run_rolldampflight_harness.lua damped|undamped|wrongsign
                                        the damper A/B, and its two negative controls
    luajit tools/test_trim.lua          the trim maths, for EITHER coupling sign
    luajit tools/run_trimflight_harness.lua positive|negative|nocoupling
                                        the trim flight; both signs must work
    luajit tools/run_podprobe_harness.lua all   the comms probe, in each
                                        failure mode it must tell apart

**THE TWO LINTS EXIST BECAUSE DEPLOYED FLIGHT CODE DIED TWICE ON A NIL NAME.**
`commandAllTilts` was a `local function` referenced fifty lines above its own
definition; `thrusts` was a `local` deleted during an edit. Both loaded
cleanly, both passed every unit test, because the code touching them only runs
in flight. The first died at +11 blocks with the craft accelerating away and
cost a forced pod reboot.

luajit compiles a read of an undeclared name into a GGET, so the bytecode says
exactly which names a file expects in `_G`. Both lints were verified against
the ACTUAL defects, not synthetic ones. **Run them after any edit to a flight
tool** -- they catch the one class of bug that no offline test can.

    luajit tools/test_craftgeom.lua

Solves the hull box from the inertia tensor and prints the authority ceiling
(roll 27.84, pitch 14.60, ratio 1.91) in about a second, on the ground. 27
assertions, including that the ceiling still sorts the flight record into
possible and impossible — if a change ever makes run 19's 75.29 admissible,
the bound has stopped meaning anything. **This is the tool that ended a
nineteen-flight measurement campaign.**


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
- ~~The sign of the lateral force from a bearing tilt~~ — **MEASURED
  2026-08-27, and the two axes DISAGREE: roll -0.8205, pitch +0.5588 hull deg
  per commanded deg.** See START HERE. What is still open is its MAGNITUDE in
  blocks/s per degree at flight rpm, which is uncertain by 4x and blocks the
  velocity loop -- strategy step 1.
- **The angular rate channel is unusable for control**, and there is a working
  answer: `Session:readCheap` omits angular velocity entirely, so the damper
  takes a least-squares slope over ANGLES instead
  (`rolldamp.newRateEstimator`, 0.6 s window). Flown.
- ~~`authority.roll` / `authority.pitch` are placeholders~~ — **RETIRED as a
  question.** They are 0.25 and that is correct: a demand->power scalar, a
  design choice, not a measured constant. The RESPONSE they produce is measured
  (27.84 / 14.60 deg/s^2 per unit demand). Read the comment in
  `mixer_profile.lua` before touching them.
- **The angular RATE channel is unreliable at this loop period** — it read
  exactly 0.0000 in 5 of 12 samples. Prefer angle-based fits.
- **Yaw is unsolved.** `getMagneticNorth()` is `{0,0,0}`. Vectoring is the
  route and the command path now exists; nothing has been wired to the axis.
- ~~Loop period ~950 ms~~ — **STALE.** With `Session:readCheap` the flight
  loops run at ~0.13-0.15 s, which is what makes the damper possible.
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

- **CHECK THE DEPENDENCY CLOSURE BEFORE PUSHING ANY MODULE.** The repo is ahead
  of the deployed computers, so a repo file can `require` something the target
  has never had. Pushing `main.lua` for the sake of six new CSV columns also
  brought in `require("fcs.snapshot")` from the undeployed monitor-hub work,
  and `snapshot.lua` was not on computer 1. The logger then failed at line 19
  on EVERY boot, silently:

      /fcs/main.lua:19: module 'fcs.snapshot' not found

  It cost runs 9-14 — six flights with no CSV at all, which is exactly the data
  needed to explain the 2x scatter in measured authority. And it was invisible
  from outside: the error goes to the tab's screen, `last_error.txt` stays
  EMPTY because the program dies before its own handler is reached, and the
  heartbeat simply stops updating.

  Before pushing a module, diff its `require` list against the target:

      grep -oE 'require\("fcs\.[a-zA-Z_]+"\)' fcs/<file>.lua | sort -u
      ssh <host> "cd <computer>/fcs && ls *.lua"

  **A frozen `/fcs/heartbeat.txt` sequence is the symptom.** Sample it twice a
  few seconds apart before trusting any run that is supposed to log.
- `rsync --delete` on computer directories is **approved**, but keep excluding
  generated files: `thruster_manifest.lua`, `device_report.txt`, `logs/`,
  `peripheral_manifest.txt`.
- **SSH KEY AUTH IS SET UP (2026-08-26). Do not use sshpass any more.**
  `~/.ssh/id_ed25519` (no passphrase) is authorised on the host, and there is a
  `mcserver` alias in `~/.ssh/config`:

      ssh mcserver
      scp mcserver:server/creative-test-superflat/... .

  `packDev/pack_config.py` now defaults `USE_SSH_KEY = 1`, so `ssh_prefix()`
  returns `[]`. Set `FNF_USE_SSH_KEY=0` to fall back to the password on a
  machine without the key.

  This retires the old "sshpass is flaky (~1 in 30), retry loops are built into
  the deploy commands" note — that flakiness was an artifact of password auth
  and is gone with it.
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

**They live in START HERE now, under THE STRATEGY**, in the order the work
actually depends on: calibrate the bearing lateral gain at flight rpm, then
pitch damping, then fly velocity hold. Keeping a second list here is how this
document ended up recommending the damper go on the bearings for months after
the measurements said otherwise.

What was on this list and is now DONE: the axis-response calibration (roll
authority measured, then re-measured by the damper flight), the roll damper
itself, the bearing coupling sign, and the pod command loss.

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
