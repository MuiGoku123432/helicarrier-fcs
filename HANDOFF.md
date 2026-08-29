<!-- generated-by: gsd-doc-writer -->
# Helicarrier FCS handoff

Last updated: 2026-08-29

## Read this first

The communications problem is no longer the blocker it was at the start of the investigation.

The old command path used many Rednet messages and could amplify each logical command across multiple open modems and repeat channels. Those messages entered a fixed-size ComputerCraft event queue before Rednet could deduplicate them. Under all-corner command traffic, frames were silently lost before the pod command handler saw them. The result looked like unreliable bearings, slow game ticks, or a mysterious per-tick modem limit, but the decisive tests ruled those explanations out.

The replacement command path sends one batched, direct-modem frame over a shared wired network. Every frame contains commands for all four corners. Each pod receives the same frame, extracts its own corner, and places it in a latest-wins mailbox. A separate apply loop performs peripheral writes so a slow actuator call cannot block reception.

The newest zero-output actuator run passed completely:

- 301 physical frames sent at a requested 10 Hz for 30 seconds.
- FL, FR, RL, and RR each received all 301 frames.
- All four pods applied all 301 frames.
- Zero missing, duplicate, out-of-order, invalid, expired, coalesced, or apply-error events.
- Maximum observed application time was 114 ms.
- Each pod performed one expected zero-output fallback after the sender stopped.

That proves the new transport, mailbox handoff, real ion-thruster write, and stale-command fallback together. It does not yet prove non-zero bearing, propeller, or ion control.

## Current project goal

Build a flight-control system that:

1. damps roll and pitch rates without requiring the hull to sit at exactly zero roll;
2. holds horizontal X/Z velocity at zero, or close enough to be visually imperceptible, whenever no movement command is active;
3. accepts a non-zero X/Z velocity target when the ship is intentionally commanded to move;
4. remains stable as the ship's mass and actuator authority change while structures are added; and
5. fails safely when commands, sensors, or actuators become stale or invalid.

Velocity hold is not position hold. A later, slower position-hold layer may create velocity requests, but it is outside the first stationkeeping milestone.

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

Only two incoming modes are accepted:

- `shadow`: disarmed and mailbox-only; no actuator write.
- `ground_apply`: disarmed and all commanded outputs exactly zero.

For `ground_apply`, the mailbox rejects any frame unless all of the following are true:

- `armed == false`
- `ionPower == 0`
- `propRpm == 0`
- `tiltDegrees == 0`
- `azimuthDegrees == 0`

The current apply worker calls the real ion-thruster path with exact zero. Non-zero thrust, RPM, tilt, and azimuth cannot cross this boundary yet.

A valid frame also needs a non-empty session, a positive integer sequence, a timestamp, and a validity window between 50 and 5000 ms. Duplicate, older, malformed, wrong-protocol, expired, or unsafe frames are refused or counted. When the last safe applied command becomes stale, the pod performs a zero-output fallback once and records it.

Do not interpret the passing test as authorization to fly or to send non-zero actuator commands.

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

## Deployment and rollback notes

The last verified live deployment used the new mailbox/apply runtime on pods 2 through 5 and the wired actuator test on computer 1.

<!-- VERIFY: Live computer files and rollback copies still match the 2026-08-29 deployment after subsequent manual edits. -->

Known rollback copies from that deployment:

- `/pod/main.lua.pre-ground-apply-20260829-v1`
- `/pod/main.lua.pre-shadow-mailbox-20260829-v1`

Known deployment hashes recorded at the time:

| File | Recorded SHA-256 prefix |
|---|---|
| pod `main.lua` | `8e90c52a` |
| pod `control_mailbox.lua` | `e6b0976a` |
| pod `control_apply.lua` | `ab6dabe5` |
| FCS `wiredframe_actuator_test.lua` | `5bde2f6e` |

Verify live files before relying on these values after any manual server-side change.

## Next work

Do not return to broad communications optimization unless a direct-frame regression is measured. The next engineering job is to extend the proven apply path one actuator family at a time:

1. Add bearing and propeller application while retaining the current mode, session, sequence, validity, and fallback rules.
2. Prove zero and very small bounded commands on the ground or while tethered.
3. Validate sensor coordinates, timestamps, noise, angular rates, and X/Z velocity.
4. Introduce bounded roll/pitch rate damping.
5. Add a slow attitude reference that does not fight velocity hold or require roll to be exactly zero.
6. Add X/Z velocity hold with zero as the default target and explicit movement velocity as the override.
7. Adapt authority/feed-forward slowly from measured response so added ship weight does not invalidate the controller.
8. Expand the flight envelope only after each prior safety gate passes.

The detailed staged plan and acceptance gates are in `docs/stationkeeping-control-contract.md`.

## Non-negotiable design rules

- FCS-DEV owns sensing, state estimation, control laws, adaptation, command allocation, and four-corner mixing.
- Pods own local validation, newest-command selection, actuator application, acknowledgement, and stale-command fallback.
- Send one batched frame for all corners per control interval.
- Prefer current state over replaying every intermediate command.
- Never block command reception on a peripheral call.
- Never apply an expired, older-session, out-of-order, malformed, or unsafe command.
- Zero or another explicitly safe fallback must be local to each pod; it cannot depend on FCS-DEV still being reachable.
- Preserve separate received and applied sequence counters so transport loss, coalescing, expiration, and actuator failure remain distinguishable.
- Measure the sensor noise floor before choosing a velocity deadband.
- Rate damping must be faster than attitude correction; attitude correction must be faster than optional position hold.
- Integral action must be bounded, conditional, and protected against saturation and stale data.
- Load adaptation must be slow, bounded, and disabled when measurements are unsafe or uninformative.

## Resume checklist

Before any new actuator test:

1. Confirm the craft is grounded, restrained if appropriate, and disarmed.
2. Confirm all four pods and FCS-DEV are connected to the intended wired network.
3. Confirm pod startup loads the current mailbox and apply modules.
4. Confirm FCS-DEV sees `control_ready` or fresh acknowledgements from FL, FR, RL, and RR.
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
