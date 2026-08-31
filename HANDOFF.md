<!-- generated-by: gsd-doc-writer -->
# Helicarrier FCS handoff

Last updated: 2026-08-31

## Read this first

The communications problem is no longer the blocker it was at the start of the investigation.

### Proven operational FCS baseline

The direct-wired stationkeeping system is now the operational baseline for this carrier. Live run 3 (`flight-logs/wiredframe_stationkeep_run3.txt`, session `1-stationkeep-1788203667879`) passed after 126.082 seconds and an operator stop. FCS-DEV sent 521 complete four-corner frames; FL, FR, RL, and RR each applied all 521 with zero missing, duplicate, out-of-order, invalid, expired, apply-error, fallback, or fallback-stop events. Shutdown completed cleanly with `run_error=nil`, `abort_reason=nil`, and `shutdown_error=nil`.

The controller held maximum horizontal speed to 0.750938 blocks/s, limited peak position error to 18.832382 blocks while arresting the inherited drift, and used at most 1.327737 degrees of tilt. The signed trace shows the craft stopped its persistent rightward motion, held near-zero X/Z velocity, and began returning to the captured position. This is the frozen proven configuration for ordinary stationkeeping: `positionGain=0.0225`, `velocityGain=0.80`, `integralGain=0.010`, a 0.15 degree/s command-vector slew limit, and a 6 degree absolute tilt cap.

The production controller is `fcs/stationkeep_control.lua`; the live runner and report writer are `fcs/wiredframe_stationkeep.lua`; and `fcs/wired_stationkeep_protocol.lua` preserves the direct batched-frame contract. The deployed controller SHA-256 is `836e7d315286877be5a408a7c1d0a18d19b85a74417f1f640208d5d3231efed2`. Run 3 is archived with SHA-256 `489f22a80d936127595eda3bb8c105951c9ae26ce6e773b4acbfb9373cc09567`.

Treat changes to controller signs, gains, coordinate transforms, protocol fields, pod validation, or fallback behavior as changes to this baseline. Keep the run-3 controller rollback (`stationkeep_control.lua.pre-recapture-tune-20260831-v1`) until a later configuration has repeated live evidence.

The old command path used many Rednet messages and could amplify each logical command across multiple open modems and repeat channels. Those messages entered a fixed-size ComputerCraft event queue before Rednet could deduplicate them. Under all-corner command traffic, frames were silently lost before the pod command handler saw them. The result looked like unreliable bearings, slow game ticks, or a mysterious per-tick modem limit, but the decisive tests ruled those explanations out.

The replacement command path sends one batched, direct-modem frame over a shared wired network. Every frame contains commands for all four corners. Each pod receives the same frame, extracts its own corner, and places it in a latest-wins mailbox. A separate apply loop performs peripheral writes so a slow actuator call cannot block reception.

The direct-wired command path is now proven through physical bearing and propeller application, not only exact-zero ion writes:

- `wiredframe_corner_map_run1.txt` independently moved FL, FR, RL, and RR through `+5, 0, -5, 0` degrees at propeller RPM 8 while every inactive corner remained physically at zero.
- `wiredframe_response_map_ground_run3.txt` sent 351 frames at 10 Hz; every pod received all 351, with zero missing, duplicate, out-of-order, invalid, expired, or apply-error events.
- All eight gyroscopic bearings became active at stabilization strength 1 and spooled from roughly 1–6 rotation units during the first second to a stable magnitude near 19.2 by about 15 seconds at commanded RPM 64.
- Explicit shutdown and one local stale fallback per pod completed at ion power 0, propeller RPM 0, and tilt 0.

Run 3's printed `FAIL` was a harness false negative: CC:Sable returned `tiltAngle=nil` at exact zero deflection even though the measured thrust vectors were vertical `(0, +/-1, 0)`. The harness accepts that missing value only for the exact-zero ground gate and only when the physical vector is within a strict near-vertical tolerance; a nonzero-tilt test still requires a numeric angle, and `--self-test` pins that a missing angle cannot excuse a deflected bearing.

**The ground gate has now passed repeatedly.** `flight-logs/wiredframe_response_map_ground_run5.txt` through `wiredframe_response_map_ground_run9.txt` all recorded `overall=PASS`. Each run delivered every sent frame to every pod with zero missing, duplicate, out-of-order, invalid, expired, or apply-error events; physical readback passed on every sample, shutdown was seen on all four corners, and each pod finished at ion 0, RPM 0, tilt 0 with one fallback. Run 8 delivered 350/350 frames per pod (1400 aggregate) and established the pre-write-elision timing baseline. After the write-elision deployment and guarded pod reboot, run 9 delivered 352/352 frames per pod (1408 aggregate), reduced mean apply time from roughly 200 ms to 0.7-1.0 ms, and reduced coalescing from roughly 208-209 frames per pod to 1-2. Rare frames that performed real peripheral writes still peaked at 198-253 ms. Communications, pod application, powered hover, and direct-wired stationkeeping are no longer blockers. The operational run-3 baseline above supersedes the earlier pre-flight status in this historical ground-gate narrative.

Two process notes from that sequence, both worth keeping:

- A prior session recorded the zero-tilt fix as deployed when it had not been written to FCS-DEV at all. Run 4 then failed for the original reason. Verify a deployment by hashing the live file against the repo copy; do not treat "deployed" in a session summary as evidence.
- `recv` counts varied 350/351/352 across runs 3/4/5 while `missing` stayed 0. That tracks `frames_sent`, which moves with loop timing. It was never loss.

## Current project goal

The first operational goal is achieved: the carrier has a direct-wired controller that arrests passive horizontal drift, holds near-zero X/Z velocity, and slowly returns toward a captured X/Z position while preserving bounded tilt and clean shutdown.

Future work should extend this proven baseline rather than replace it:

1. integrate explicit pilot movement targets with bumpless return to stationkeeping;
2. improve and validate roll/pitch damping and slow attitude reference under larger disturbances;
3. repeat the operational hold after meaningful symmetric and asymmetric load changes;
4. exercise stale-sensor, stale-pod, and actuator-fault behavior in the integrated controller; and
5. keep all controller and transport changes measurable, reversible, and compatible with the run-3 baseline.

## Computer and corner map

| Role | Computer | Corner |
|---|---:|---|
| FCS-DEV sender and flight controller | 1 | all corners |
| Front-left pod | 2 | FL |
| Front-right pod | 3 | FR |
| Rear-left pod | 4 | RL |
| Rear-right pod | 5 | RR |

<!-- VERIFY: In-world physical wiring remains one shared wired-modem cable network connecting FCS-DEV and all four pods after any world rebuild. -->

All five computers were operator-confirmed on one shared wired network for the successful direct-frame tests.

## Active command architecture

The production-direction command path is:

```text
sensors and future control laws on FCS-DEV
                 |
                 v
one four-corner control frame per control interval
                 |
       wired modem channel 42042
                 |
       +---------+---------+---------+
       |         |         |         |
      FL        FR        RL        RR
       |         |         |         |
validate -> latest-wins mailbox -> independent apply worker
       |         |         |         |
       +--------- status/ack on channel 42043 --------> FCS-DEV
```

Protocol identifier: `helicarrier.control-frame.v1`.

The active pod-side implementation is:

- `pod-template/pod/control_mailbox.lua` — wired modem discovery, frame validation, per-corner extraction, session/sequence accounting, latest-wins mailbox, and cumulative acknowledgements.
- `pod-template/pod/control_apply.lua` — consumes the newest fresh mailbox entry, performs the permitted actuator operation, records timing/errors, and enforces stale fallback.
- `pod-template/pod/main.lua` — runs the mailbox receive loop, mailbox status loop, independent apply loop, sensor sampler, regular telemetry/status loop, and display loop.
- `pod-template/pod/thrusters.lua` — provides the real `applyExact` ion-thruster write used by the current safe stage.

Reception is deliberately actuator-free. The apply worker may take longer than one control interval; reception can continue and newer commands can replace older unapplied commands. This is intentional control behavior, not packet loss.

The full design and message contract are in `docs/communication-architecture.md`.

## Current safety boundary

The active pod runtime accepts separate, explicitly bounded modes:

- `shadow`: disarmed and mailbox-only; no actuator write.
- `ground_apply`: disarmed and exact-zero actuator fields only.
- `ground_bearing_test`: disarmed, ion power 0, propeller RPM 8, azimuth 0, and bearing tilt limited to `+/-5` degrees.
- `response_map_test`: armed test envelope with ion power from 0 through 1, fallback ion power no greater than the commanded value, propeller RPM exactly 64, azimuth from 0 through 360 degrees, and tilt limited to `+/-1` degree. Its explicit shutdown frame requires every actuator field to be exactly zero.
- `stationkeep`: operational direct-wired hold mode at propeller RPM 64 with the proven high/low vertical duty commands, per-corner bearing azimuth, and tilt bounded to `+/-6` degrees. FCS-DEV owns the controller and sends one complete frame; pods retain the same validation, latest-wins application, freshness, acknowledgement, and exact-zero shutdown semantics.

The response-map sender still exposes only `--ground-check`: ion power 0, tilt 0, RPM 64 for a 30-second spool window, followed by exact-zero shutdown and fallback verification. A separate `fcs/wiredframe_ground_ion_test.lua` harness now exposes `--ground-ion-check`. It requires the operator to type `GROUND-ION`, proves fresh clean zero-ion acknowledgements from all four pods before applying power, commands ion power 0.14 for five seconds at RPM 64 with tilt and azimuth exactly zero, then deliberately stops frames to prove the two fallback stages before sending exact-zero shutdown. Neutral hover and all tilt pulses remain locked.

A valid frame also needs `kind="control_frame"`, a non-empty session, a positive integer sequence, a timestamp, and a validity window between 50 and 5000 ms. Duplicate, older, malformed, wrong-protocol, expired, or unsafe frames are refused or counted. When the last safe applied command becomes stale, the pod performs the mode-specific local fallback once and records it.

Do not interpret the physical RPM 64 ground pass as authorization to fly. The next nonzero ion/tilt pulse must be introduced as a separately gated, abort-bounded response-map stage.

## What was removed from active pod runtime

The old pod command receiver applied peripheral work inside the Rednet receive path and handled multiple message types separately. Its active `networkLoop`, watchdog loop, sequence helpers, and command reply path were removed from `pod-template/pod/main.lua`.

Older server-side diagnostic and transport scripts were moved to recoverable `/archive/legacy-transport/` directories on the live computers. The repository-side archive explanation is `archive/legacy-transport/README.md`.

Some legacy source and historical logs remain in the repository for evidence. Their presence does not mean they are part of the active runtime.

## What the tests established

| Test | Load | Result | What it proves |
|---|---|---|---|
| `flight-logs/linkwatch_single_FL_10hz_run1.txt` | One wireless corner | 397/397 aligned commands received and acted | No one-message-per-tick or roughly 5 Hz per-pod modem ceiling |
| `flight-logs/wiredframe_test_run1.txt` | Standalone all-wired direct frames | 301 frames received by every pod; 1204/1204 deliveries | One batched direct frame reliably reaches all four pods |
| `flight-logs/wiredframe_shadow_run1.txt` | Normal pod telemetry/peripheral workload, no actuation | 601 frames received by every pod; 2404/2404 deliveries | Mailbox reception remains lossless under normal pod workload |
| `flight-logs/wiredframe_actuator_run1.txt` | Normal workload plus real exact-zero ion writes | 301 received and 301 applied per pod; 1204/1204 applications | Receive/apply separation and stale zero fallback work together |
| `flight-logs/wiredframe_bearing_rpm8_run1.txt` | All bearings at RPM 8 with `0,+5,0,-5,0` tilt phases | 152/152 received per pod; all physical phases observed | Bounded bearing application and physical readback work |
| `flight-logs/wiredframe_corner_map_run1.txt` | Independent FL/FR/RL/RR `+5,0,-5,0` mapping | 551/551 received per pod; 2204/2204 deliveries | Corner addressing and bearing signs are independent and repeatable |
| `flight-logs/wiredframe_response_map_ground_run3.txt` | All bearings RPM 64, ion 0, tilt 0 for 30 seconds | 351/351 received per pod; rotation settled near `+/-19.2`; safe shutdown | Flight-baseline propeller spool and physical bearing activity work; printed FAIL was only the corrected nil-zero-tilt predicate |
| `flight-logs/wiredframe_response_map_ground_run5.txt` through `wiredframe_response_map_ground_run9.txt` | Repeated RPM 64 ground gates after the predicate, timing instrumentation, and write-elision fixes | 350-352 received per pod per run, zero faults, every run `overall=PASS`; run 9 delivered 1408 aggregate with 0.7-1.0 ms mean apply time | Grounded communications, physical readback, shutdown, and fallback are repeatable; run 8 is the pre-write-elision baseline and run 9 confirms write-elision under live load |
| `flight-logs/wiredframe_stationkeep_run2.txt` | First corrected-direction operational hold, 175.919 seconds | 720/720 applied per pod, zero faults, max speed 0.786118, max position error 23.036153, max tilt 1.294172 degrees | Corrected direct-plant sign arrests the former runaway and returns toward the captured X/Z position |
| `flight-logs/wiredframe_stationkeep_run3.txt` | Tuned operational hold, 126.082 seconds | 521/521 applied per pod, zero faults, max speed 0.750938, max position error 18.832382, max tilt 1.327737 degrees | Proven operational FCS baseline; stronger position recapture retained stability and clean shutdown |

The legacy all-corner tests are useful negative evidence:

- Three batch-8 baseline runs pooled 1354 missing of 6418 requested commands, about 21.1%, with 123 timeouts.
- The tiered-telemetry 5 Hz run lost 896 of 2344, about 38.2%, with 88 timeouts.
- Reducing the request rate to 2.5 Hz still lost 118 of 662, about 17.8%, although timeouts disappeared.

Those failures were not fixed by merely making telemetry cheaper. The single-corner and direct-frame tests isolated aggregate Rednet/event amplification as the relevant difference.

## Root cause and rejected explanations

Official CC:Tweaked behavior and the measured runs support this explanation:

1. `rednet.send` transmits on every open modem and uses recipient and repeat channels.
2. Modem messages enter each computer's event queue before Rednet filtering/deduplication.
3. The per-computer event queue has a fixed capacity of 256 and drops new events silently when full.
4. The old all-corner command format created many logical messages, which could become more physical transmissions and more queued events.
5. The pod receiver also performed slow peripheral work inline, extending the time during which it was not draining command events.

No supported server configuration knob was found for enlarging that event queue. No one-message-per-tick modem throttle was found. Wired versus wireless radio quality was not the decisive difference: the message shape, duplication, event pressure, and receive/apply coupling were.

Changing generic ComputerCraft main-thread budgets is not the planned fix and is not required by the passing direct-frame results.

## Current telemetry status

Direct control acknowledgements use wired channel 42043 and report cumulative receive/apply counters, sequence positions, mailbox age, errors, coalescing, expiration, fallback count, and apply latency.

The regular pod telemetry/status path still exists alongside the direct command transport. Treat this as a transitional architecture: control frames and control acknowledgements are direct-modem traffic, while existing flight telemetry has not yet been fully consolidated into the same protocol.

Do not add high-rate request/reply polling back into the command path. Future telemetry should be cached, periodic, staggered, and limited to values the controller or operator actually needs.

## Control-rate budget

Measured on FCS-DEV, zero actuation, by `/fcs/sensor_rate_test.lua`. Reports: `sensor_rate_hub_on.txt`, `sensor_rate_hub_off.txt`.

**Every CC:Sable global-API call costs one server tick (~50 ms), whatever the call does.** `getLogicalPose`, `getVelocity`, `getAngularVelocity`, `getLinearVelocity`, and `getMass` all measured a mean of 49.1-49.9 ms across 60 calls each. Five methods doing very different work cannot cost the same by coincidence: the cost is main-thread task scheduling latency, not computation. Each call queues a task and waits for the next tick to deliver the result. This confirms the older note at `fcs/sensors.lua:66`.

Everything else follows arithmetically:

- Three reads per cycle measured 149.8 ms, or **6.67 Hz**. That is the ceiling for a loop that samples pose, velocity, and angular velocity together.
- A fixed 10 Hz cadence made 0 of 51 deadlines with a mean overrun of 50.1 ms, exactly the one extra tick it was short. 10 Hz is not achievable for a three-read cycle.

**A second Sable-reading computer would not help, and the reason matters.** The hub-on and hub-off runs are identical to within a tenth of a millisecond on every method and on cycle mean, with achieved rate 6.67 Hz in both. There is no per-computer budget being exhausted that offloading could relieve; a call takes a tick because it waits for a tick. The only remaining benefit of extra computers is reading different quantities during the same tick, which then costs a modem hop of at least one more tick to collect, and reintroduces exactly the event-queue exposure the direct-frame path exists to avoid. Do not add a sensor computer to buy control rate.

**Stagger reads by loop rate instead.** This is free and maps onto the control hierarchy already required below:

| Layer | Reads per cycle | Achievable rate |
|---|---|---|
| Rate damping (inner) | `getAngularVelocity` only | ~20 Hz |
| Attitude reference | + `getLogicalPose` | ~10 Hz |
| X/Z velocity hold | + `getVelocity` | ~6.67 Hz |

Slow-changing quantities -- mass, centre of mass, inertia tensor -- must stay off the control cycle entirely. The exploratory probe that read all fourteen methods achieved only 2.5 Hz.

Pod-side actuator peripherals have their own measured ceiling. In run 8, bearing readback cost only about 0.2 ms for twelve calls, while the three write stages averaged roughly 55 ms for ion, 45 ms for RPM, and 100 ms for the two-bearing tilt write. The write itself therefore averaged about 200 ms; with the apply-loop sleep, a full changing-state path is roughly 250 ms, or about **4 applies/s**. Treat 4-5 Hz as the current end-to-end actuator ceiling even though individual sensor layers can sample faster. `max_apply_ms` is not a tuning metric; compare `apply_mean_ms` and the per-stage timing line.

Write-elision now skips a peripheral stage when its requested value equals the last successfully written value. The cache is invalidated after every stale fallback and every session change, so the next live command reasserts all fields. Pod computers 2-5 were rebooted into the verified module and run 9 confirmed it under live load: mean apply time fell from roughly 200 ms in run 8 to 0.7-1.0 ms, while coalescing fell from roughly 208-209 frames per pod to 1-2. Rare frames that actually changed actuator state still took as much as 198-253 ms, so flight-loop rate must remain bounded by measured changing-state latency rather than the unchanged-frame mean.

## Moving-ship sensor findings

The operational stationkeeping runs resolved the practical gate: the active runner's X/Z velocity input tracked motion, drove correction in the expected world direction, and returned to zero-valued samples as the craft settled. The signed run-3 trace exposes the sensor's coarse steps directly (notably Z values of `0.00` and `+/-0.70` blocks/s), so future filtering and gain changes must preserve that quantization rather than assume a smooth noise floor.

The original pre-flight questions remain below for historical context:

- **Does `getLinearVelocity` track?** It returned exactly `0.000000000` in every sample of every grounded run, while `getVelocity` showed float noise. On a stationary ship both are consistent with working correctly. If `getLinearVelocity` stays pinned at zero in motion it is unusable as the velocity-hold input and `getVelocity` must be used instead. Confirm this on the first pulse that produces motion.
- **What is the real noise floor?** A resting physics body deactivates and reads exact zero: the response probe showed ~1e-6 noise for five samples and then exact zeros from t=2.4 s onward. The design rule "measure the sensor noise floor before choosing a velocity deadband" therefore cannot be satisfied on the ground. Size the deadband from in-flight data only.

## Actuator orientation map

From `wiredframe_response_map_ground_run5.txt` bearing readback, at zero commanded tilt:

| Corner | Bearing 1 thrust | Bearing 2 thrust | Bearing 1 rotation |
|---|---|---|---|
| FL | `(0, 1, 0)` | `(0, -1, 0)` | +19.2 |
| FR | `(0, 1, 0)` | `(0, -1, 0)` | -19.2 |
| RL | `(0, -1, 0)` | `(0, 1, 0)` | +19.2 |
| RR | `(0, 1, 0)` | `(0, -1, 0)` | +19.2 |

RL's per-index thrust orientation is inverted relative to the other three corners, and FR's bearing-1 rotation sign is inverted relative to the other three. If command allocation maps by bearing index, an identical commanded tilt may deflect RL opposite to the rest. This is a prediction to verify with the paired positive/negative pulses, not a known defect -- but read an unexpected RL sign as this, not as a control bug, before changing any gain.

## Deployment and rollback notes

Deployment is a file copy to the server that hosts the world; the CC computer directories are at `<world>/computercraft/computer/<id>/`. FCS-DEV is computer 1; pods FL/FR/RL/RR are 2 through 5.

**Always hash the live file against the repo copy after deploying.** A session summary claiming a deploy is not evidence one happened: the zero-tilt fix was reported deployed, was not written to FCS-DEV at all, and ground run 4 then failed for the original reason.

<!-- VERIFY: Live computer files and rollback copies still match the 2026-08-30 deployment after subsequent manual edits. -->

Known rollback copies:

- `/pod/main.lua.pre-ground-apply-20260829-v1`
- `/pod/main.lua.pre-shadow-mailbox-20260829-v1`
- `/fcs/wiredframe_response_map_test.lua.pre-zero-tilt-readback-20260829-v1`
- `/pod/control_apply.lua.pre-write-elision-20260830-v1` on pods 2-5 (SHA-256 `2b8c074a...`)
- `/fcs/wired_stationkeep_protocol.lua.pre-highpower-20260831` on FCS-DEV (SHA-256 `3243666f...`, the run-3 baseline `HIGH_POWER=0.20`)

Known deployment hashes recorded at the time:

| File | Recorded SHA-256 prefix |
|---|---|
| pod `main.lua` | `8e90c52a` |
| pod `control_mailbox.lua` | `9f67aaa8` |
| pod `control_apply.lua` | `26a6ac0b` on pods 2-5; rebooted and live-verified by response-map ground run 9 |
| FCS `wiredframe_actuator_test.lua` | `5bde2f6e` |
| FCS `wiredframe_response_map_test.lua` | `198129a1` (local/live verified 2026-08-30) |
| FCS `sensor_rate_test.lua` | `76f26c31` |
| FCS `stationkeep_control.lua` | `836e7d315286877be5a408a7c1d0a18d19b85a74417f1f640208d5d3231efed2` (run-3 baseline) |
| FCS `wiredframe_stationkeep.lua` | `2106005d9a246ca29a147bd7e0c9de1b31f08a7b475f9104c25536222ed83abd` (signed-trace runner) |
| FCS `wired_stationkeep_protocol.lua` | `67f7bf3e4049ec974886873a7be09a0555f84b4817ff3bc5b02f1545a04a4955` (deployed 2026-08-31; `HIGH_POWER` raised 0.20 -> 0.27, ion level 3/15 -> 4/15, for flight-height testing) |

Verify live files before relying on these values after any manual server-side change.

Both current FCS harnesses support `--self-test`, which runs offline with no CC APIs, no modem, and no actuation. Run it after deploying to confirm the file that loaded is the file you sent.

## Next work

Keep run 3 frozen as the operational stationkeeping baseline. The next production work is integration and repeatability, not another gain increase:

1. repeat the same hold after a meaningful ship load or geometry change and compare the signed trace;
2. add an explicit bounded pilot X/Z velocity target with a bumpless transition back to the captured position;
3. exercise stale-sensor, stale-pod, and operator-abort paths while confirming exact-zero shutdown on all corners;
4. improve roll/pitch damping only from measured disturbance data; and
5. do not change the direct protocol, pod validator, plant sign, or baseline gains without a saved comparison run and rollback.

## Historical development sequence

The sequence below led to the operational baseline and is retained as provenance. Its ground/first-flight gates are complete; do not treat it as the current task list.

Do not return to broad communications optimization unless a direct-frame regression is measured. Bearing addressing, bounded tilt, RPM 64 spool-up, receive/apply separation, and local fallback are now established.

The ground gate passed (`wiredframe_response_map_ground_run5.txt`), the control-rate budget above is measured rather than assumed, and the pod runtime now carries the slow readback lane and the two-stage fallback described below.

Immediate sequence:

1. The provisional first-pulse policy is `fallbackIonPower=0.07` and `fallbackStopAfterMs=5000`. The thruster driver quantises these commands to fifteenths: the grounded test commands 0.14 (level 2/15) and falls back to 0.07 (level 1/15). Both are below the documented 0.195 hover command. These values belong to FCS policy, not the pod, and remain provisional until live motion data validates descent behavior.
2. Deploy and run `/fcs/wiredframe_ground_ion_test.lua --ground-ion-check` only while grounded and restrained. Require `overall=PASS`, fresh clean precheck acknowledgements, nonzero application at all four pods, both fallback stages, exact-zero shutdown, and zero transport/application faults.
3. Only after that grounded report passes, implement and run a separate low-altitude neutral-hover proof with live pose/velocity/rate aborts. The grounded harness deliberately does not expose a hover flag, and no tilt pulse is authorized yet.
4. Map one axis and one sign at a time with paired `+/-1` degree pulses and a return to the same safe baseline. Measure command-to-ack, command-to-motion latency, angular acceleration, X/Z acceleration, vertical coupling, and recovery.
5. Build the live loop around the slower of the measured sensor layer and the changing-state actuator latency. Stagger reads by layer and keep mass, centre of mass, and inertia off the control cycle.
6. Use the plant map to implement shadow-only roll/pitch rate damping before applying any closed-loop correction. Then add the slower attitude reference, X/Z velocity hold, and finally slow bounded mass/authority adaptation.

The detailed staged plan and acceptance gates are in `docs/stationkeeping-control-contract.md`.

## Stale-link fallback contract

Correcting a misreading worth recording: the response-mode fallback has **never** cut propeller RPM. `runWrite` zeroes RPM only for the ground modes; in `response_map_test` it overrides that and holds the commanded baseline. The descent already came from dropping ion to `fallbackIonPower` while the bearings level. `tools/test_wiredframe_response.lua` pins this ("fallback retains response rpm").

The fallback is now two stages:

1. **Descent.** Once a command passes `validForMs`, the pod levels bearings to zero tilt and azimuth, holds the commanded propeller RPM, and applies `fallbackIonPower`. Unchanged, and still the proven behavior.
2. **Stop.** If, and only if, the sender declared `fallbackStopAfterMs`, the pod writes exact-zero ion, RPM, and tilt once that long has elapsed since stage 1. Absent the field, stage 1 holds indefinitely, exactly as before.

Rules that made it this shape:

- The pod cannot know from local state whether it is still airborne, so it must not invent a descent duration. The sender owns the number; the pod owns the enforcement.
- The allowance is bounded to 1000-60000 ms at the mailbox, so it cannot be a cutout racing stage 1 nor an effectively infinite value.
- A shutdown frame must not carry the field: shutdown is already the zero state.
- Stage 2 is not routed through `runWrite`, so no mode's command values can reach the terminal write. It uses the exact-zero ion writer that ground shutdown already proves.
- Each stage fires once per command, and both counters are reported separately (`fallbackCount`, `fallbackStops`) so "levelled and descending" is distinguishable from "stopped".

## Bearing readback lane

`props.readBearingState()` is twelve peripheral calls -- six methods on each of two bearings. It ran on every tilt write to prove spool-up for the ground gate; it is confirmation, not control feedback, because the controller already knows what it commanded and the pod acknowledges what it applied.

It now samples immediately on the first apply after the worker starts and then at most once per `readbackIntervalMs` (default 1000 ms). The mailbox latches the last sample and reports `appliedBearingStateAgeMs`, so an apply that carries no readback does not erase the last known physical state. A failed readback cannot fail a write that already succeeded, and an elided tilt write must not replay an older readback as a fresh sample.

## Non-negotiable design rules

- FCS-DEV owns sensing, state estimation, control laws, adaptation, command allocation, and four-corner mixing.
- Pods own local validation, newest-command selection, actuator application, acknowledgement, and stale-command fallback.
- Send one batched frame for all corners per control interval.
- Prefer current state over replaying every intermediate command.
- Never block command reception on a peripheral call.
- Never apply an expired, older-session, out-of-order, malformed, or unsafe command.
- Zero or another explicitly safe fallback must be local to each pod; it cannot depend on FCS-DEV still being reachable.
- Preserve separate received and applied sequence counters so transport loss, coalescing, expiration, and actuator failure remain distinguishable.
- Measure the sensor noise floor before choosing a velocity deadband, and measure it in flight: a resting physics body reads exact zero.
- Budget every CC:Sable call in the control loop as one server tick. Choose each layer's read set from its required rate, not from what is convenient to sample together.
- Keep diagnostic readback off the actuator write path. Instrumentation that proved a gate must be moved to a slow lane before that path carries flight commands.
- Rate damping must be faster than attitude correction; attitude correction must be faster than optional position hold.
- Integral action must be bounded, conditional, and protected against saturation and stale data.
- Load adaptation must be slow, bounded, and disabled when measurements are unsafe or uninformative.

## Resume checklist

Before any new actuator test:

1. Confirm the craft is grounded, restrained if appropriate, and disarmed.
2. Confirm all four pods and FCS-DEV are connected to the intended wired network.
3. Confirm pod startup loads the current mailbox and apply modules.
4. Confirm FCS-DEV sees fresh acknowledgements from FL, FR, RL, and RR. Note that `ready=false` was reported by all four corners in ground runs 3 through 9 while every other counter was clean and runs 5-9 passed; the response-map harness never sets that field. Treat `ready` as unwired until it is either implemented or removed, and do not gate a run on it.
5. Confirm each pod reports zero missing, invalid, expired, and apply-error counts before the test.
6. Use a new session identifier for every run.
7. Start with exact zero, then the smallest bounded command that can produce a measurable response.
8. Stop immediately on stale telemetry, sequence regression, unexpected actuation, growing attitude/rate, or fallback failure.
9. Save the result before starting another run that would overwrite it.

## Documents to keep aligned

- `HANDOFF.md` — current operational state and immediate next steps.
- `docs/communication-architecture.md` — definitive communications design and protocol responsibilities.
- `docs/stationkeeping-control-contract.md` — control hierarchy, staged implementation plan, and acceptance gates.
- `archive/legacy-transport/README.md` — what was retired and why it remains available for reference.

When implementation changes any safety boundary, mode, message field, fallback, or controller ownership rule, update these documents in the same change.
