# FCS mixer — design

Date: 2026-08-25. Handoff next-step #1.

## What this is

`fcs/mixer.lua`: a pure control allocator. It converts a demand vector
(collective, roll, pitch, yaw) into per-corner ion power commands and a common
propeller RPM.

It is **not** a controller. It has no sensors, no rednet, no clock, and no
memory. It does not fly the craft and it commands nothing — the tool that calls
it is separate, later work.

## Scope

In scope:

- A stateless `mixer.allocate(profile, demand)` returning a plan.
- A calibration profile file, `fcs/mixer_profile.lua`.
- An offline test suite, `tools/test_mixer.lua`.

Out of scope, deliberately:

- Any closed loop, altitude hold, or attitude hold.
- Any conversion from physical force to ion power (see Decision 1).
- Yaw actuation (see Decision 5).
- Differential propeller RPM (see Decision 3).
- Anything that sends a rednet message.

## Decisions

### 1. Units: the mixer works in actuator units, not physical ones

`demand.collective` is ion power in `0..1`. `demand.roll/pitch/yaw` are
normalized authority in `-1..1`.

The mixer distributes commands; it does not do physics. Converting a desired
force into a power number belongs to the controller above it, as does the
inertia-tensor weighting named in HANDOFF.md — the tensor maps desired angular
*acceleration* to torque, which is a control question, not an allocation one.

There is a second reason. **The force-per-power coefficient is not known.** The
hover data (power 0.185 → 0.446 of weight) extrapolates to about 2.4× weight at
full power; HANDOFF.md separately states roughly 3.5×. These disagree. The
"~1:1 against mass × gravity" line is a claim about *units*, not about power.
Working in power units keeps this unresolved number out of the command path
entirely. See Open questions.

### 2. Geometry: normalized now, physical later

No corner geometry has ever been measured — the repo holds no moment arms and
no corner positions relative to `rotationPoint`. The inertia tensor does not
supply them: it gives angular acceleration per torque, not torque per corner
force.

So roll and pitch enter as sign patterns scaled by two scalars, `Aroll` and
`Apitch`, which absorb the unmeasured arms. A demand of `roll = 1.0` shifts
each corner by `Aroll` power units. When the arms are measured, these two
numbers acquire physical meaning and no mixer code changes.

### 3. Propellers hold a common collective RPM

The mixer emits one RPM for all four corners, taken from the profile (the
64 RPM plan). It never commands differential RPM.

Propeller RPM is set-and-hold with no watchdog, deliberately — HANDOFF.md,
Safety posture. Coupling the unwatchdogged lift layer into the fast attitude
loop would turn a dropped `set_rpm` into an attitude fault. Prop command
latency is also ~1 s, against ions that are effectively continuous.

### 4. Saturation: collective is protected, attitude yields

On this craft the ions are half the lift under the 64 RPM plan, so losing
collective means falling. With ~80% of ion authority in reserve at hover,
saturation should only occur near the edges.

### 5. Yaw: channel now, actuation later

The mixer accepts `demand.yaw`, contributes nothing, and returns
`yawAvailable = false` with the demand echoed in `unmet.yaw`. Yaw is unsolved
(`getMagneticNorth()` is `{0,0,0}` here); handoff step 2 solves it via the
gyroscopic propeller bearings. Reserving the channel means that work plugs into
an existing interface instead of rewriting every caller.

## Interface

```lua
local plan = mixer.allocate(profile, demand)
```

Requires nothing. Stateless: same inputs, same outputs, always.

Demand:

```lua
{ collective = 0.195, roll = 0.0, pitch = 0.0, yaw = 0.0 }
```

Plan:

```lua
{
    props = { rpm = 64 },
    ions  = { FL = 0.21, FR = 0.21, RL = 0.18, RR = 0.18 },
    expected = { FL = <kN>, ... },   -- only when profile.ion.forcePerPower is set
    saturated = false,
    attitudeScale = 1.0,
    collectiveClamped = false,
    unmet = { yaw = 0.0 },
    yawAvailable = false,
}
```

## The mix

Body convention from `fcs/config.lua`: +X bow, +Y up, +Z starboard. Positive
roll is starboard-low; positive pitch is bow-high.

| corner | roll | pitch | effectiveness |
|---|---|---|---|
| FL | +1 | -1 | 1.00000 |
| FR | -1 | -1 | 1.00000 |
| RL | +1 | +1 | 1.00000 |
| RR | -1 | +1 | 0.98879 |

Port corners gain power to roll starboard-low; aft corners gain power to raise
the bow.

```
A_c    = roll x Aroll x rollCoeff[c] + pitch x Apitch x pitchCoeff[c]
raw[c] = (collective + A_c x s) / effectiveness[c]
```

The RR effectiveness divisor corrects the measured 1.121% deficit on
`gyroscopic_propeller_bearing_5`. This trims a *propeller* asymmetry with *ion*
power: legitimate, because both act on the same corner in the same axis, and it
is the only lever available while props run common-mode. Do not "fix" this by
moving it to the prop channel.

## Saturation algebra

Every corner must satisfy `minPower <= (collective + A_c x s) / e_c <= maxPower`,
which bounds `s`:

- `A_c > 0`:  `s <= (maxPower x e_c - collective) / A_c`
- `A_c < 0`:  `s <= (minPower x e_c - collective) / A_c`
- `A_c = 0`:  unconstrained

`attitudeScale` is the minimum across corners, clamped to `[0, 1]`. Exact: at
the returned scale at least one corner sits precisely on a limit, and no
post-hoc clipping is needed. `saturated` is `attitudeScale < 1`.

Collective is resolved first and independently. If collective alone cannot fit
a corner inside the limits it is clamped and `collectiveClamped` is set — a
demand for more lift than the banks have is a fact the caller must be told, not
something to absorb silently. Attitude then scales against the clamped value.

**`attitudeScale = 0` is a legal result that looks like success.** At high
collective, a large roll demand can be scaled to nothing while the call returns
cleanly. Callers MUST read `saturated` / `attitudeScale`.

Quantisation is advisory only. `expected` is populated solely when the profile
carries `forcePerPower`, and never feeds back into the commands, so the
unresolved coefficient of Decision 1 stays quarantined in a reporting field.

## Calibration file

`fcs/mixer_profile.lua`, a new file — deliberately not a new section in
`fcs/config.lua`.

HANDOFF.md's first operational gotcha: deployed configs carry values the repo
templates lack (`podIds`, peripheral names), so pushing a repo config over a
deployed one destroys them, and the safe procedure is fetch-patch-assert. A
new file has no deployed counterpart and no hand-entered values, so it can be
pushed directly for the life of the project. Putting the profile in
`config.lua` would drag every gain tweak through that dance for no benefit.

## Testing

`tools/test_mixer.lua`, plain Lua under `luajit`. The mixer has no CC surface,
so `tools/cc_harness.lua` — which exists to reproduce CC's coroutine
scheduling — is the wrong tool here.

1. Neutral — zero attitude gives four equal commands, RR higher by `1/0.98879`.
2. Pure roll — port up, starboard down, by equal amounts.
3. Pure pitch — aft up, fore down, by equal amounts.
4. Axis independence — combined roll+pitch equals the sum of each applied alone.
5. Saturation is exact — one corner on a limit, none outside.
5b. Saturation is exact *on an asymmetric craft* — recompute each corner from
    the returned scale and require an exact match, proving the defensive output
    clamp never bites. Added after mutation testing: dropping the effectiveness
    factor from the scale solver survived every other test, because the named
    saturation tests run on a symmetric profile and the property sweep's
    overshoot was absorbed by that clamp. The defect is real — it clips one
    corner instead of scaling the attitude, distorting the commanded direction.
6. Collective protected — under saturation the collective term is unchanged.
7. Collective clamp — demand above `maximumPower` clamps and flags.
8. Attitude fully crushed — `attitudeScale = 0` returns cleanly and flags.
9. Yaw — corner powers identical to `yaw = 0`; echoed in `unmet.yaw`.
10. Property sweep — thousands of random demands, no output outside limits,
    `attitudeScale` always in `[0, 1]`.
11. Hover regression — `collective = 0.195` reproduces the measured hover point
    with props at 64.

Test 4 catches a sign-table error that tests 2 and 3 pass individually. Test 10
catches saturation algebra wrong in an unconsidered case Test 5b exists
because mutation testing proved 5 and 10 together did not.

The suite was mutation-tested: three deliberate defects were injected (swapped
roll signs, effectiveness dropped from the scale solver, collective clamped
against maximumPower instead of the weakest corner). Two were caught; the third
motivated 5b and is now caught.

## Open questions

- **Force-per-power coefficient.** 2.4x weight at full power (from the hover
  point) versus roughly 3.5x (HANDOFF.md). One measurement resolves it. Blocks
  nothing in the mixer; blocks the controller above it.
- **`Aroll` / `Apitch` are uncalibrated.** They are placeholders until the
  corner moment arms are measured or a per-axis response run is flown.
- **RR effectiveness is a propeller figure.** Whether the ion banks share the
  same 1.121% asymmetry is unmeasured; the correction assumes they do not and
  trims the craft, not the bank.

## Not done here

This mixer is never called in-game until HANDOFF.md step 3 (`fallbackPower`) is
fixed. Under the 64 RPM plan the ions are half the lift and currently fail to
zero on a 750 ms comms loss.
