<!-- generated-by: gsd-doc-writer -->
# Auto-Level and Horizontal Velocity-Hold Plan

## Objective

Build a controller that keeps the helicarrier dynamically calm and nearly stationary in the horizontal plane while allowing intentional movement.

The target behavior is:

- damp roll and pitch rates so the ship does not strafe because an attitude oscillation keeps rotating the thrust vector;
- keep X/Z horizontal velocity at zero when no movement command is active;
- track a bounded non-zero X/Z velocity target when the pilot or another controller requests movement;
- tolerate changes in mass, center of mass, and actuator authority as the carrier is built out;
- remain stable with delayed, coalesced, or stale data; and
- fall back safely when control confidence is lost.

The controller does not need to force roll to exactly zero. A small steady attitude offset is acceptable if horizontal velocity is near zero and all safety limits are respected.

## Scope boundary

This document plans control development after the direct-wired command path. It does not authorize flight or non-zero actuation by itself.

The current proven boundary includes lossless grounded RPM 64 propeller/bearing actuation, physical zero-tilt readback, explicit shutdown, and local fallback in `response_map_test`, repeated as formal PASS in ground runs 5-8. No nonzero-ion flight data exists. Grounded nonzero ion, neutral hover, and paired tilt pulses remain separate gates with explicit bounds, aborts, and rollback steps.

Position hold is deferred. Velocity hold can make motion nearly imperceptible, but small velocity bias can still accumulate into position drift over time. A later position loop may convert X/Z position error into a slow, bounded velocity request.

## Control contract

1. Rate damping owns fast roll and pitch motion.
2. Attitude reference owns slow hull orientation and safety bounds.
3. Horizontal velocity hold owns X/Z drift and normally requests zero velocity.
4. An explicit movement command replaces the zero-velocity request; it does not bypass damping or safety.
5. A later position loop may request velocity but must remain slower than the velocity and attitude loops.
6. FCS-DEV computes whole-craft state, control effort, adaptation, and four-corner mixing.
7. Pods validate and apply only their own newest fresh command and enforce local fallback.
8. No controller integrates error while its actuator is saturated, acknowledgement is stale, state quality is invalid, or the corresponding authority is unavailable.

## Control hierarchy

```text
optional future position target
             |
             v
bounded X/Z velocity request <--- pilot movement request
             |
             v
horizontal velocity controller
  velocity error -> desired horizontal acceleration/force
             |
             v
attitude/force allocator and four-corner mixer
             |
      +------+------+
      |             |
      v             v
slow attitude     fast angular-rate damping
reference         roll/pitch rate feedback
      |             |
      +------ sum --+
             |
             v
bounded per-corner ion / prop / tilt / azimuth state
             |
             v
one direct wired control frame -> pod mailboxes -> apply workers
```

The loops are separated by purpose and timescale:

- rate damping reacts fastest;
- attitude reference reacts more slowly and supplies a stable frame for translation;
- velocity hold reacts to sustained X/Z motion rather than individual noisy samples;
- optional position hold reacts slowest.

Exact update rates and bandwidth ratios must come from measured sensor noise, delay, and actuator response. They must not be copied blindly from the old Rednet-era flight scripts.

### Measured read budget

Every CC:Sable global-API call on FCS-DEV costs one server tick, roughly 50 ms, independent of which call it is; the cost is main-thread scheduling latency, not computation. Each layer's achievable rate is therefore set by how many quantities it samples per cycle, and the timescale separation above is bought by sampling less in the fast loop rather than by running the same read set faster:

| Layer | Reads per cycle | Sensor-read ceiling |
|---|---|---|
| Rate damping (inner) | `getAngularVelocity` only | ~20 Hz |
| Attitude reference | + `getLogicalPose` | ~10 Hz |
| X/Z velocity hold | + `getVelocity` | ~6.67 Hz |

Sampling all three together measured 149.8 ms per cycle, or 6.67 Hz, and a fixed 10 Hz cadence missed every deadline by exactly one tick. Mass, centre of mass, and the inertia tensor must stay off the control cycle entirely: the exploratory probe reading fourteen methods achieved only 2.5 Hz. Evidence: `flight-logs/sensor_rate_hub_on.txt` and `sensor_rate_hub_off.txt`.

Adding a second computer to read sensors does not raise these rates and must not be used to try; see the communications architecture for the measurement that rejected it.

These are sensor-read ceilings, not achievable closed-loop output rates. Run 8 measured a full pod write at about 200 ms (`ion` ~55 ms, `rpm` ~45 ms, two-bearing `tilt` ~100 ms); with the apply-loop sleep, the current changing-state path is roughly 250 ms, or 4-5 Hz. Design and tune against the slower active layer. Write-elision is installed on pods 2-5 but pending reboot; it can make unchanged fields cheap, does not raise the worst-case rate when all fields change, and its live improvement must be measured against run 8 before flight.

## Coordinate and sign contract

Before closing any loop, define one canonical frame and test every conversion:

- world X/Z: horizontal velocity and requested travel;
- world Y: altitude/vertical motion;
- body axes: bow/starboard/up or another explicitly named convention;
- roll, pitch, yaw: fixed sign conventions;
- angular rates: body-frame rates with timestamps;
- corner order: FL, FR, RL, RR;
- actuator sign: positive command and measured response for every actuator family.

Every log and controller input must state whether a value is in world or body coordinates. Transform horizontal velocity into the control frame using current attitude/yaw. A sign mistake in this layer can produce a stable-looking controller that accelerates in the wrong world direction.

## State estimator requirements

The control laws need a single time-aligned state snapshot containing at least:

| State | Use |
|---|---|
| source timestamp and computed `dt` | derivative/integral correctness and stale-data detection |
| roll and pitch | attitude reference and safety envelope |
| roll and pitch rates | rate damping |
| yaw or orientation basis | world/body X/Z transforms |
| X/Z velocity | velocity hold |
| vertical velocity and altitude | collective compensation and flight safety |
| actuator command and acknowledgement state | saturation, delay, and fault detection |
| estimated mass/weight and authority | feed-forward and load adaptation |

Before tuning, log the stationary sensor noise floor, normal sample interval, worst observed jitter, dropouts, and bias. Choose filter bandwidth and deadbands from those measurements.

Filtering must not hide freshness. A smooth value derived from stale samples is still stale.

## Actuator roles

The exact mixer will be confirmed experimentally, but ownership should remain clear:

- differential propeller RPM is the primary candidate for fast roll-rate damping;
- bearing tilt/azimuth and the hull's thrust vector provide horizontal authority;
- ion power remains collective lift/vertical authority unless testing proves a safely resolvable differential role;
- slow attitude correction is subordinate to velocity hold and must not demand a geometrically impossible combination such as exact-zero roll plus zero drift when the available actuator layout cannot produce both.

The mixer must output one complete command for every corner every interval, apply per-actuator limits and slew limits, and report saturation back to the controllers.

## Load adaptation strategy

The ship's build state will change. Fixed mass constants and one-time gains are not sufficient.

Use a two-part approach:

### Feed-forward from live physical estimates

Where reliable sensors expose mass, weight, thrust, or actuator state, compute the nominal effort needed to hover and translate from the current values. This keeps large load changes out of the feedback controller.

### Slow bounded response identification

Estimate effective authority from safe command/response windows:

```text
effective authority = measured acceleration change / applied command change
```

Update that estimate only when:

- command acknowledgement is fresh;
- the actuator is not saturated;
- the command change is large enough to rise above sensor noise;
- the craft is inside the safe attitude/rate envelope;
- no fallback, timeout, or conflicting pilot command occurred; and
- the measured response has the expected sign.

Clamp estimates to physically plausible ranges and change them slowly. A bad transient must not instantly rewrite the plant model.

Integral action may remove residual bias after feed-forward and proportional control, but it is not the primary load estimator. Integral terms need anti-windup, leak/reset rules, and explicit behavior on mode changes.

## Safety state machine

A production controller should use explicit states instead of scattered booleans:

```text
DISARMED
   |
   v
READY -- all pods, sensors, and zero-output checks healthy
   |
   v
ARMING -- safe output confirmed and acknowledgements fresh
   |
   v
ACTIVE -- controller allowed inside current envelope
   |
   +----> DEGRADED -- bounded temporary limitation, if explicitly designed
   |
   +----> ABORTING -- command safe state and verify application
   |
   v
DISARMED
```

Minimum reasons to leave ACTIVE:

- missing or stale pod acknowledgement;
- received/applied sequence lag outside the allowed bound;
- sensor timestamp, orientation, or velocity invalid;
- attitude, angular rate, altitude, or speed outside the current test envelope;
- actuator application error or unexpected fallback;
- wrong command sign or unexpected response;
- mixer saturation that persists beyond its allowed duration;
- adaptation estimate outside plausible bounds;
- operator abort.

Abort must command and verify a defined safe state. A pod's local stale fallback remains the final layer if FCS-DEV cannot complete that transition.

## Development phases

Each phase is a gate. Do not start the next phase merely because the previous code exists; start it only after the previous acceptance evidence passes.

### Phase 0 — Preserve the proven transport baseline

Status: complete for direct transport, exact-zero ion application, bounded grounded bearing motion, RPM 64 spool-up, explicit shutdown, and local fallback. Nonzero-ion flight remains unproven.

Deliverables:

- one batched four-corner frame;
- direct wired control/status channels;
- latest-wins pod mailbox;
- independent apply worker;
- received-versus-applied counters;
- stale zero fallback.

Acceptance evidence:

- `flight-logs/wiredframe_actuator_run1.txt` shows 301/301 received and applied on every pod, no transport/application errors, and one expected fallback per pod after stop.

Regression gate before later phases:

- repeat a zero-output run after any protocol or apply-path change;
- require all four pods present;
- require no missing, invalid, expired, or apply-error growth;
- require fallback to occur and be reported after sender stop.

### Phase 1 — Extend the pod apply layer by actuator family

Goal: make bearings and propellers available without widening the existing exact-zero mode.

Status: complete for the grounded envelopes. Runs 5-8 formally pass the RPM 64 ground gate with physical readback, shutdown, and fallback.

Work:

1. Define separate named disarmed test modes for bearings and props.
2. Add mode-specific bounds and slew limits.
3. Add per-actuator application functions to the independent worker.
4. Record requested, accepted, and measured/applied values per corner.
5. Define a safe fallback for each actuator family.
6. Preserve zero-output and malformed-frame rejection tests.

Test order:

1. exact zero;
2. zero plus sender-stop fallback;
3. smallest command with no expected motion;
4. smallest measurable command while grounded or restrained;
5. command reversal to validate sign;
6. repeated all-corner run under normal telemetry load.

Exit gate:

- every pod reports the same session/sequence progression;
- measured actuator state matches the bounded request;
- receiver remains lossless while actual peripheral calls run;
- no unsafe field can cross the wrong mode.

### Phase 2 — Characterize timing, signs, and authority

Goal: produce a trustworthy plant map before closing a controller.

Measure for each relevant command:

- command-to-ack delay;
- command-to-measured-actuator delay;
- command-to-angular-acceleration response;
- command-to-horizontal-acceleration response;
- actuator deadband, resolution, saturation, and slew;
- coupling between horizontal force, roll, pitch, and vertical lift;
- response differences by corner;
- repeatability after changing ship load.

Use paired positive/negative probes and return to the same safe baseline between them. Log enough settling time to distinguish fast direct force from slow hull reorientation.

Expect and check one specific asymmetry: at zero commanded tilt, RL reports its per-bearing-index thrust orientation inverted relative to FL, FR, and RR, and FR's bearing-1 rotation sign is inverted relative to the other three (`flight-logs/wiredframe_response_map_ground_run5.txt`). If allocation maps by bearing index, an identical command may deflect RL opposite to the rest. Read an unexpected RL sign as this orientation map before changing any gain.

Current timing evidence: `flight-logs/wiredframe_response_map_ground_run8.txt` measures `apply_mean_ms` near 200 ms per pod, with ion about 55 ms, RPM about 45 ms, tilt about 100 ms, and readback about 0.2 ms. Including the apply-loop sleep, use 4-5 Hz as the present full-write actuator ceiling. The next gate is a write-elision ground regression compared by `apply_mean_ms` and per-stage timings, followed by sender-owned fallback selection, grounded nonzero ion, neutral hover, and only then paired `+/-1` degree pulses.

Exit gate:

- signs are repeatable;
- usable authority is above the sensor noise floor;
- actuator latency and update rate are bounded;
- a conservative mixer can be written without relying on an unverified coupling sign.

### Phase 3 — Validate the state estimator

Goal: prove the controller sees the ship correctly before it moves the ship.

Work:

- define and test world/body transforms;
- compute roll/pitch rates from the best available sensor source;
- time-align attitude, velocity, and pod acknowledgement;
- reject invalid and stale samples;
- measure in-motion noise and lag, not stationary noise: a resting CC:Sable physics body deactivates and reads exact zero, so a grounded sample yields a noise floor of zero and would justify an arbitrarily small deadband;
- confirm `getLinearVelocity` actually tracks motion before using it as the velocity-hold input. It read exactly zero in every grounded sample while `getVelocity` showed float noise; if it stays pinned at zero in flight, use `getVelocity`. A source stuck at zero produces zero error forever and a loop that never corrects;
- record raw and filtered values together.

Shadow tests:

- calculate controller errors and proposed outputs without applying them;
- rotate or move the craft manually and verify every sign;
- compare expected versus measured X/Z direction;
- inject stale/missing samples and verify state-quality transitions.

Exit gate:

- no unexplained sign or axis mismatch;
- filters reduce noise without unacceptable lag;
- `dt` and sample age remain valid under normal server jitter;
- shadow outputs stay bounded and respond in the expected direction.

### Phase 4 — Add roll/pitch rate damping

Goal: suppress angular motion without forcing an exact attitude.

Controller form:

```text
rate effort = -K_rate * measured angular rate
```

Add feed-forward or more complex terms only if measured results require them.

Requirements:

- separate roll and pitch signs/gains;
- output bounds and slew limits;
- saturation reporting;
- zero effort inside a measured noise deadband;
- immediate disable on stale state or acknowledgement;
- bumpless enable/disable transitions.

Test progression:

1. shadow output;
2. restrained low-authority pulse;
3. one-axis disturbance with damping off/on comparison;
4. combined-axis disturbance;
5. repeat after a meaningful load change.

Exit gate:

- peak angular rate or excursion is consistently reduced;
- no sustained oscillation or cross-axis runaway appears;
- damping remains stable across the tested load range;
- controller output returns near zero when rates settle.

### Phase 5 — Add slow attitude reference and leveling

Goal: keep roll and pitch inside a calm operating envelope while allowing the velocity loop to choose a small steady offset.

The attitude controller should create a rate request rather than directly fighting the fast damping loop:

```text
attitude error -> bounded desired angular rate -> rate damping effort
```

The default reference may be near level, but exact zero is not a hard objective. Velocity hold may bias the attitude/force allocation if that is required to cancel drift.

Requirements:

- slow bandwidth relative to rate damping;
- bounded angle and rate requests;
- no integral action until proportional behavior is proven;
- anti-windup if integral action is later added;
- explicit priority for attitude safety limits over velocity performance.

Exit gate:

- the craft returns to a bounded calm attitude after disturbance;
- no loop fighting is visible between leveling and rate damping;
- a small steady roll/pitch offset is tolerated when horizontal speed improves;
- enable/disable and target changes are smooth.

### Phase 6 — Add X/Z horizontal velocity hold

Goal: drive horizontal velocity toward the requested target.

Target selection:

```text
if explicit movement command is active:
    velocity target = bounded requested X/Z velocity
else:
    velocity target = 0, 0
```

Controller structure:

```text
velocity error
  -> deadband/filter based on measured noise
  -> proportional desired horizontal acceleration/force
  -> optional bounded integral bias for residual drift
  -> attitude/force allocator
  -> four-corner mixer
```

Requirements:

- operate on time-aligned X/Z velocity;
- transform consistently between world and body frames;
- use live mass/authority feed-forward;
- limit desired acceleration, attitude bias, actuator demand, and slew;
- freeze or unwind integral terms during saturation, stale data, abort, manual override, or target changes;
- transition smoothly between zero hold and intentional movement;
- keep rate damping active throughout.

Acceptance target selection:

1. measure the stationary velocity estimate's bias and standard deviation;
2. choose a deadband above the noise floor;
3. choose the smallest sustained speed the operator can perceive in the test environment;
4. set the hold target no lower than the estimator can honestly resolve;
5. report both RMS and worst sustained horizontal speed, not a single favorable sample.

Exit gate:

- sustained X/Z speed settles inside the agreed near-imperceptible band;
- no sustained attitude or velocity oscillation appears;
- disturbance recovery is repeatable in both axes;
- movement commands track and return cleanly to zero hold;
- no hidden growth in saturation, integral state, sequence lag, or fallback count.

### Phase 7 — Validate load-change adaptation

Goal: keep performance acceptable while the carrier's build state changes.

Test at several controlled load states:

- baseline ship;
- added symmetric load;
- added asymmetric load if safe;
- removed load or other reversible configuration change.

For each state, record:

- mass/weight estimate;
- center-of-mass change if available;
- hover/collective requirement;
- effective roll/pitch/horizontal authority;
- controller gains and adaptive estimates;
- settling time, overshoot, steady horizontal speed, and actuator margin.

Exit gate:

- the system detects a meaningful authority/load change;
- adaptation moves in the correct direction and stays within bounds;
- the craft restabilizes without manual retuning for each tested state;
- adaptation freezes safely when excitation or data quality is inadequate;
- returning to the baseline load does not leave a dangerous learned bias.

### Phase 8 — Expand the flight envelope

Goal: move from isolated controller proofs to an integrated stationkeeping system.

Progress one variable at a time:

1. longer hold duration;
2. larger but bounded disturbances;
3. combined roll/pitch disturbances;
4. zero-hold to movement-command transitions;
5. movement-command to zero-hold recovery;
6. altitude changes while holding X/Z velocity;
7. controlled load changes;
8. fault injection: stale sensor, stale pod, dropped sender, one actuator error;
9. repeatability across server restarts and normal tick variation.

Do not add position hold until the integrated velocity system passes this phase.

## Test record required for every live run

Every result should include:

- code/deployment identifier;
- test mode and safety bounds;
- session identifier;
- requested and achieved send rate;
- per-pod first/last/received/applied sequence;
- missing, duplicate, reordered, invalid, replaced, coalesced, expired, error, and fallback counts;
- receive-to-apply latency, `apply_mean_ms`, per-stage ion/RPM/tilt timings, and maximum actuator-call duration;
- raw and filtered sensor timestamps;
- attitude, angular rates, X/Z velocity, altitude, and vertical velocity;
- requested controller targets and each controller's contribution;
- unsaturated and saturated mixer output;
- measured actuator state;
- mass/load/authority estimates;
- abort reason and final safe-state confirmation;
- a plain-language PASS/FAIL verdict tied to the phase gate.

A run that lacks received-versus-applied evidence cannot distinguish a control-law error from an application-path error.

## Proposed quantitative metrics

Do not freeze final thresholds until Phase 2 and Phase 3 establish noise, latency, and authority. Use these metric definitions from the beginning:

| Area | Metric |
|---|---|
| Communications | missing/invalid/expired/apply-error count per pod |
| Freshness | maximum mailbox and applied-command age |
| Application | received-to-applied sequence lag and apply duration |
| Rate damping | peak rate, peak excursion, settling time, oscillation count |
| Leveling | steady attitude band and recovery time |
| Velocity hold | RMS X/Z speed, worst sustained speed, recovery time, bias |
| Movement tracking | target error, overshoot, settle time, return-to-hold transient |
| Adaptation | estimate convergence time, bounds, repeatability by load state |
| Safety | abort detection time, safe-command receipt, safe-state confirmation |

The communications expectation for a healthy run remains strict: zero missing, invalid, expired, and apply-error events. Coalescing may be acceptable only when the applied state stays fresh and the controller was designed for it.

## Implementation boundaries

Keep the following separations in code:

- transport knows frames, freshness, sequences, and acknowledgements;
- pod application knows local devices and safe mode bounds;
- state estimation knows sensors, timestamps, coordinates, filters, and quality;
- controllers produce bounded generalized efforts or targets;
- the mixer converts those efforts into four-corner actuator states;
- the safety supervisor decides whether outputs may be applied;
- logging observes every boundary without being required for safety.

This makes it possible to shadow-test a controller, substitute a plant model, replay a log, and fault-inject a stale component without rewriting transport or actuator code.

## Open decisions to resolve with measurement

- Which sensor source gives the cleanest and least delayed roll/pitch rates?
- What is the stationary X/Z velocity noise floor and bias?
- How much does live write-elision improve the roughly 4-5 Hz current full-write actuator ceiling when only a subset of fields changes?
- Which actuator combination provides the cleanest horizontal force with the least vertical/attitude coupling?
- Does pitch require active rate damping, or is it already sufficiently damped at the new build state?
- How much steady roll/pitch offset is required for zero horizontal velocity?
- Which live mass/weight signals are reliable enough for feed-forward?
- How quickly can authority adaptation change without following noise or transient disturbances?
- What exact near-imperceptible velocity band should become the acceptance threshold?
- Is a degraded three-pod or partial-actuator mode ever safe, or should any missing corner always abort?

Resolve these in the indicated phases. Do not answer them with fixed constants carried over from a different load state.

## Definition of done

The first stationkeeping milestone is complete when repeated live tests show all of the following:

- all four pods receive and apply fresh direct-wired frames without unexplained loss;
- local fallback and FCS abort behavior are verified;
- roll/pitch motion is damped and bounded;
- no-control X/Z velocity target defaults to zero;
- intentional velocity targets override zero hold smoothly;
- sustained horizontal motion remains inside the measured near-imperceptible band;
- the controller remains stable and regains that band after representative load changes;
- no loop hides saturation, stale state, command/application lag, or integral windup;
- every success claim is supported by saved telemetry and a reproducible test procedure.
