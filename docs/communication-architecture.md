<!-- generated-by: gsd-doc-writer -->
# Direct-Wired Control Communication Architecture

## Overview

The helicarrier uses one central flight-control computer and four local pod computers. The central FCS computes the desired state for every corner, serializes all four corner commands into one frame, and transmits that frame directly over a shared wired modem network. Each pod validates the frame, extracts only its own corner, stores the newest valid command, and applies it in a separate worker.

This architecture is optimized for control freshness and bounded failure behavior. It does not try to deliver every intermediate command. If the actuator worker is temporarily slower than the sender, the next safe action is to skip superseded commands and apply the newest still-valid state.

## Design goals

- One physical command transmission represents the complete four-corner control state.
- Control reception remains responsive while peripherals are busy.
- Each pod can reject unsafe or stale commands without consulting FCS-DEV.
- Transport receipt and actuator application are observable separately.
- Loss of the sender produces a local safe fallback.
- Adding telemetry must not recreate high-volume request/reply traffic.
- The command protocol can grow from exact-zero tests to bounded flight control without changing its core delivery model.

## Topology

<!-- VERIFY: The in-world cable network still physically connects FCS-DEV and all four pods after any server/world maintenance. -->

```text
                         Computer 1
                          FCS-DEV
           sensing -> control -> mixing -> frame builder
                              |
                              | one direct modem transmission
                              | channel 42042
                              v
                 shared wired modem/cable network
             +----------------+----------------+
             |                |                |
             v                v                v                v
       Computer 2       Computer 3       Computer 4       Computer 5
           FL               FR               RL               RR
             |                |                |                |
       validate         validate         validate         validate
             |                |                |                |
      latest mailbox   latest mailbox   latest mailbox   latest mailbox
             |                |                |                |
       apply worker     apply worker     apply worker     apply worker
             |                |                |                |
       local devices    local devices    local devices    local devices
             +----------------+----------------+----------------+
                              |
                              | cumulative control acknowledgements
                              | channel 42043, staggered by corner
                              v
                          FCS-DEV
```

The wired network is a transport, not a peripheral-ownership change. FCS-DEV does not directly control every pod peripheral. The pod computer remains the local actuator authority and safety boundary.

## Component responsibilities

### FCS-DEV

FCS-DEV owns:

- sensor acquisition and time alignment;
- coordinate transforms and state estimation;
- rate, attitude, velocity, and later position control laws;
- adaptation and actuator-authority estimates;
- allocation/mixing into FL, FR, RL, and RR commands;
- session and sequence generation;
- frame timing and validity duration;
- monitoring acknowledgements and deciding whether the system may remain armed;
- operator-visible logging and test reports.

FCS-DEV must send one complete state frame per interval. It must not return to separate per-corner or per-actuator Rednet command floods.

### Pod mailbox receiver

`pod-template/pod/control_mailbox.lua` owns:

- finding the local wired modem;
- opening control channel 42042;
- accepting only protocol `helicarrier.control-frame.v1` control frames;
- validating mode, armed state, session, sequence, timestamp, validity, and corner command fields;
- rejecting duplicates and older sequences;
- detecting sequence gaps;
- extracting only the configured FL, FR, RL, or RR command;
- replacing an older pending command with the newest valid command;
- publishing cumulative control status on channel 42043.

The receive loop performs no actuator peripheral calls.

### Pod apply worker

`pod-template/pod/control_apply.lua` owns:

- reading the newest mailbox entry;
- refusing entries outside the current safe application contract;
- refusing expired entries;
- applying an entry at most once;
- calling the permitted local actuator API;
- recording the applied sequence, duration, errors, and coalesced sequences;
- issuing a local safe fallback after the command becomes stale.

The apply worker now supports exact-zero ion writes, bounded ground bearing tests at RPM 8, and the `response_map_test` envelope used for RPM 64 spool-up and future bounded response pulses. It applies propeller RPM, bearing tilt/azimuth, ion power, explicit shutdown, and a mode-specific stale fallback only after the mailbox has validated the complete command. Local write-elision skips a stage only when its requested value equals the last successfully written value; a session change or either stale-fallback stage invalidates the cache so the next command rewrites every field. Cached tilt results exclude diagnostic readback so an elided write cannot make an old sample look fresh. The FCS sender still locks flight pulses; pod-side capability is not by itself permission to actuate in flight.

### Pod runtime

`pod-template/pod/main.lua` composes independent loops for:

- direct control reception;
- cumulative direct control status;
- actuator application;
- sensor sampling;
- regular telemetry/status;
- local display.

No loop may take exclusive ownership of control progress by waiting on a slow peripheral operation.

## Channels and protocol

| Purpose | Channel | Direction | Payload |
|---|---:|---|---|
| Control | 42042 | FCS-DEV to all pods | One batched four-corner control frame |
| Control status | 42043 | Each pod to FCS-DEV | Cumulative ready/ack snapshot |

The modem reply channel on status transmissions is the control channel. The protocol identifier is `helicarrier.control-frame.v1`.

## Control frame contract

A control frame is a Lua table with this conceptual shape:

```lua
{
  protocol = "helicarrier.control-frame.v1",
  kind = "control_frame",
  mode = "shadow", "ground_apply", "ground_bearing_test", or "response_map_test",
  armed = false, -- true only for the bounded response_map_test envelope
  session = "non-empty-run-identifier",
  sequence = 1,
  sentAt = 0,
  validForMs = 500,
  corners = {
    FL = { ionPower = 0, fallbackIonPower = 0, propRpm = 0, tiltDegrees = 0, azimuthDegrees = 0, shutdown = true },
    FR = { ionPower = 0, fallbackIonPower = 0, propRpm = 0, tiltDegrees = 0, azimuthDegrees = 0, shutdown = true },
    RL = { ionPower = 0, fallbackIonPower = 0, propRpm = 0, tiltDegrees = 0, azimuthDegrees = 0, shutdown = true },
    RR = { ionPower = 0, fallbackIonPower = 0, propRpm = 0, tiltDegrees = 0, azimuthDegrees = 0, shutdown = true },
  },
}
```

The sample describes the current safe envelope, not the eventual flight envelope.

### Field rules

| Field | Rule |
|---|---|
| `protocol` | Must exactly match the supported protocol identifier |
| `kind` | Must be `control_frame` |
| `mode` | Must be a mode explicitly supported by the pod runtime |
| `armed` | Must agree with the selected mode and safety contract |
| `session` | Non-empty string; a newer session resets sequence accounting |
| `sequence` | Positive integer, monotonically increasing within a session |
| `sentAt` | Finite timestamp used for session ordering and freshness accounting |
| `validForMs` | Finite duration from 50 through 5000 ms |
| `corners` | Contains the complete four-corner state |
| actuator fields | Finite numbers inside mode-specific safety bounds |

A pod rejects a new session whose timestamp predates the session it has already accepted. Within a session, equal sequences are duplicates and smaller sequences are out of order.

## Mailbox semantics

The mailbox stores at most one pending state for the corner.

```text
receive seq 100 -> mailbox 100
receive seq 101 -> mailbox 101, replacement count +1
apply worker wakes -> applies 101
```

Sequence 100 was not lost by the network. It was intentionally superseded before application. This is reported as coalescing/replacement so it cannot be confused with transport loss.

These distinctions matter:

| Observation | Meaning |
|---|---|
| `missing` increases | A sequence never reached this pod's accepted stream |
| `duplicates` increases | The same sequence arrived again |
| `outOfOrder` increases | An older sequence or older session arrived |
| `invalid` increases | The frame failed protocol or safety validation |
| `replacements` increases | A newer received state replaced a pending mailbox state |
| `coalesced` increases | The apply worker advanced over superseded sequences |
| `expiredBeforeApply` increases | A received entry became stale before application |
| `applyErrors` increases | The local actuator operation failed |
| `fallbackCount` increases | The local stale-command fallback ran |

A healthy high-rate controller may show replacements or coalescing if the apply rate is slower than the send rate. It should not show missing, invalid, expired, or apply-error growth under normal operation.

## Acknowledgement contract

Each pod sends a staggered cumulative status approximately once per second. Corner offsets spread the four replies across the interval instead of producing a simultaneous burst.

The status includes:

- corner and transport;
- session and first/last received sequence;
- received, missing, duplicate, out-of-order, and invalid counts;
- current mailbox sequence and age;
- applied sequence and successful application count;
- apply errors and last error;
- actuator call count;
- replacement, coalescing, and expiration counts;
- fallback count;
- last and maximum apply duration;
- whether the current mode is mailbox-only.

Acknowledgements are diagnostic and supervisory. They are not permission for the pod to apply an otherwise invalid command.

## Timing model

The successful tests used a requested 10 Hz sender. That is the current demonstrated command rate, not a requirement that every actuator must physically update at exactly 10 Hz.

The sender rate is not the binding constraint. Two measurements now bound the loop from opposite ends:

- **Sensing (FCS-DEV).** Every CC:Sable global-API call costs one server tick, ~50 ms, whatever the call does. Five different methods each measured a 49.1-49.9 ms mean over 60 calls. A three-read control cycle therefore runs at 6.67 Hz, and a fixed 10 Hz cadence missed every deadline by exactly one tick. See `flight-logs/sensor_rate_hub_on.txt` and `sensor_rate_hub_off.txt`, and the control-rate budget in `HANDOFF.md`.
- **Applying (pods).** Run 8 measured full-write `apply_mean_ms` near 200 ms: ion roughly 55 ms, RPM roughly 45 ms, and the two-bearing tilt write roughly 100 ms. The twelve-call diagnostic readback was already on its slow lane and cost only about 0.2 ms. With the apply-loop sleep, a changing-state iteration is about 250 ms, so the current actuator ceiling is roughly 4-5 Hz. Local write-elision is intended to remove unchanged stages, but its live rate improvement is not yet measured.

Coalescing at these ratios is the latest-wins mailbox behaving correctly, not loss. Do not raise the send rate to compensate for either bound; a faster sender cannot make a tick-quantized sensor or a slow actuator call finish sooner, and the halved-send-rate experiment already showed send rate is not what governs delivery.

A future production controller should choose its rate and validity window from measured values:

1. sensor update interval and jitter;
2. controller computation time;
3. frame send interval;
4. pod receive-to-apply latency;
5. slowest actuator call;
6. required fallback reaction time.

The validity window must be long enough for expected jitter but short enough that an obsolete command cannot remain dangerous. The fallback timeout must remain local to each pod.

## Current safety modes

### `shadow`

- Requires `armed == false`.
- Validates and stores the per-corner command.
- Does not permit actuator application.
- Used to prove reception and mailbox behavior under normal runtime load.

### `ground_apply`

- Requires `armed == false`.
- Requires ion power, propeller RPM, tilt, and azimuth all to be exactly zero.
- Permits a real exact-zero ion-thruster write.
- Rejects any non-zero actuator field.

### `ground_bearing_test`

- Requires `armed == false` and ion power 0.
- Requires propeller RPM 8 and azimuth 0.
- Permits bearing tilt only within `+/-5` degrees.
- Uses zero RPM, zero tilt, and zero ion power as the local fallback.

### `response_map_test`

- Requires `armed == true`.
- Bounds ion power to 0 through 1 and requires fallback ion power to be no greater than the requested value.
- Requires propeller RPM exactly 64, tilt within `+/-1` degree, and azimuth in the supported 0-through-360 range.
- Defines an explicit shutdown frame with every actuator field exactly zero.
- Uses zero tilt/azimuth while retaining the validated propeller baseline before applying the bounded fallback ion value if a live command becomes stale.
- Accepts an optional `fallbackStopAfterMs` in the range 1000-60000, which declares how long the descent state above may run before the pod writes exact zero. Absent, the descent holds indefinitely. It must not appear on a shutdown frame, which is already the zero state.

`fallbackStopAfterMs` is sender policy: a pod cannot tell from local state whether it is still airborne, so it must not invent a descent duration. The pod owns only enforcement, and both stages are counted separately in the acknowledgement (`fallbackCount`, `fallbackStops`).

The ground gate passed formally and repeatedly in `flight-logs/wiredframe_response_map_ground_run5.txt` through `wiredframe_response_map_ground_run8.txt`. This proves communications and grounded actuation, not nonzero-ion flight. Before any tilt pulse, verify write-elision with another ground gate, choose fallback policy, run a grounded nonzero-ion test, and prove neutral hover. Future production flight modes must remain separate named safety envelopes; do not silently widen `ground_apply` or a diagnostic mode.

### Do not add a sensor computer to buy control rate

Reading CC:Sable state on a separate computer and forwarding it to FCS-DEV was measured and rejected. The per-call cost is main-thread scheduling latency, not a per-computer budget: identical runs with the monitor hub running and stopped differ by under a tenth of a millisecond on every method and produce the same 6.67 Hz. There is nothing to offload. Extra computers could only read different quantities during the same tick, and collecting those results costs at least one more tick over the modem plus the event-queue exposure this whole transport exists to avoid. Stagger reads by loop rate instead.

## Failure behavior

### Sender stops

The mailbox entry ages beyond its permitted window. The pod refuses further application and writes the local safe fallback once. Status exposes the fallback count.

### Receiver gets behind

The receive loop remains free to accept frames. The mailbox keeps the newest valid state, and the apply worker coalesces superseded states.

### Actuator call is slow

Reception continues independently. Apply duration is recorded. FCS-DEV can compare received and applied sequences and decide whether the system remains safe to arm.

### Malformed or unsafe frame

The pod increments `invalid` and does not place the frame in the mailbox.

### Duplicate or reordered frame

The pod counts and ignores it. It does not rewind the actuator state.

### Pod or cable disappears

FCS-DEV stops receiving fresh acknowledgement from that corner and must leave or enter the appropriate safe state. Other pods must not compensate indefinitely without a separately designed degraded-mode controller.

### Sender stops while the pod is flying

The pod's stale-link response is two-stage and entirely local, requiring nothing from FCS-DEV at the time it fires:

1. **Descent** at `validForMs`: level bearings to zero tilt and azimuth, hold the commanded propeller RPM, apply `fallbackIonPower`. Propeller RPM is *not* cut -- descent comes from the reduced ion value.
2. **Stop** at `fallbackStopAfterMs` after stage 1, only if that field was declared: exact-zero ion, RPM, and tilt, written through the same exact-zero path ground shutdown proves, so no mode's command values can reach the terminal write.

Each stage fires once per command. Without a declared allowance the pod descends and holds, which is the proven ground behavior and the safe default for an unattended pod that may still be airborne.

## Why direct modem frames replaced Rednet commands

The legacy path treated actuator updates as many independent messages. Rednet can transmit one logical send through every open modem and through recipient and repeat channels. Deduplication occurs after modem events have already entered the computer event queue. Under aggregate four-corner traffic, that creates more event pressure than the logical command count suggests.

The event queue is fixed at 256 entries and silently drops new events when full. There is no supported server-side setting to enlarge it. The measured single-corner test was lossless above the former apparent per-pod ceiling, ruling out a one-message-per-tick modem limit. The direct all-corner tests then delivered every frame to every pod.

The architectural fix is therefore structural:

- batch four corners into one frame;
- transmit once on the intended wired modem;
- receive without actuator work;
- keep only the newest valid command;
- apply independently;
- report cumulative counters instead of acknowledging every field separately.

## Telemetry architecture

The control channel is now direct-modem traffic, but regular flight telemetry still uses the existing pod status path. This is transitional.

When telemetry is consolidated, preserve these rules:

- publish cached snapshots rather than answering high-rate polls;
- keep confirmation reads off the actuator write path: bearing readback is twelve peripheral calls and now samples on its own lane at most once per second, with the mailbox latching the last sample and reporting its age, rather than running on every write;
- stagger pod transmissions;
- send only measurements needed by control, safety, diagnosis, or the operator;
- separate fast control-critical state from slow device-health detail;
- include source timestamp and age;
- never let telemetry sampling or serialization block command reception;
- do not mirror the same high-rate payload through multiple open modems.

## Extension path to flight control

The protocol grows by capability, not by bypassing validation:

1. keep `shadow` for non-actuating regression tests;
2. keep `ground_apply` permanently exact-zero;
3. retain the proven `ground_bearing_test` envelope for independent corner/sign regressions;
4. regression-test write-elision against the run 8 RPM 64 ground baseline, using `apply_mean_ms` and per-stage timings;
5. choose the sender-owned fallback policy, run grounded nonzero ion, and prove neutral hover;
6. use `response_map_test` for paired, lowest-authority `+/-1` degree flight pulses with explicit abort and baseline-return phases;
7. use the measured plant map to shadow-test rate damping and mixing;
8. add a production armed flight mode only after local limits, freshness, acknowledgement, mixer bounds, state quality, and abort behavior are verified together.

Each new mode needs:

- explicit field bounds;
- slew/rate limits where applicable;
- a defined stale fallback;
- a defined disarm transition;
- unit tests for accepted and rejected frames;
- a live zero-output test;
- a smallest-measurable-output test;
- received-versus-applied reporting;
- rollback instructions.

## Proven evidence

| Report | Frames sent | Per-pod result | Scope |
|---|---:|---|---|
| `flight-logs/wiredframe_test_run1.txt` | 301 | 301 received, zero errors | Standalone direct transport |
| `flight-logs/wiredframe_shadow_run1.txt` | 601 | 601 received, zero errors | Production pod workload, no actuation |
| `flight-logs/wiredframe_actuator_run1.txt` | 301 | 301 received and applied, zero errors | Production workload plus real exact-zero ion calls |
| `flight-logs/wiredframe_bearing_rpm8_run1.txt` | 152 | 152 received per pod; all `0,+5,0,-5,0` physical phases observed | Bounded bearing application and local physical readback |
| `flight-logs/wiredframe_corner_map_run1.txt` | 551 | 551 received per pod; every active corner moved while inactive corners stayed at zero | Independent four-corner addressing and sign map |
| `flight-logs/wiredframe_response_map_ground_run3.txt` | 351 | 351 received per pod; active stabilized bearings settled near rotation magnitude 19.2 | RPM 64 spool-up, physical bearing state, shutdown, and fallback; printed FAIL was the corrected nil-zero-angle reporter predicate |
| `flight-logs/wiredframe_response_map_ground_run4.txt` | 350 | 350 received per pod, zero faults; printed FAIL on `1:tilt` | The corrected predicate had never reached FCS-DEV; a deploy was recorded that did not happen |
| `flight-logs/wiredframe_response_map_ground_run5.txt` | 352 | 352 received per pod; `overall=PASS`, every corner PASS, 1408/1408 aggregate | Formal ground-gate pass with physical readback on every sample |
| `flight-logs/wiredframe_response_map_ground_run6.txt` | 351 | 351 received per pod; `overall=PASS`, zero faults, 1404/1404 aggregate | Repeatability after moving readback off the write path |
| `flight-logs/wiredframe_response_map_ground_run7.txt` | 350 | 350 received per pod; `overall=PASS`, zero faults, 1400/1400 aggregate | Second repeatability pass on the current pod runtime |
| `flight-logs/wiredframe_response_map_ground_run8.txt` | 350 | 350 received per pod; `overall=PASS`, zero faults, 1400/1400 aggregate | Pre-write-elision timing baseline with `apply_mean_ms` and per-stage timings |

Run 3 had zero transport or application faults and maximum application times from 228 through 245 ms. CC:Sable returned `tiltAngle=nil` at exact zero deflection while thrust vectors were vertical. The ground-gate verifier therefore accepts missing angle only when the applied target is exactly zero and the physical thrust vector lies within 0.005 of the vertical unit vector; nonzero-tilt checks still require numeric angle readback.

Runs 5-8 closed and repeated the gate: zero missing, duplicate, out-of-order, invalid, expired, or apply-error events on any corner; physical readback passing on every sample; shutdown seen on all four corners; and every pod finishing at ion 0, RPM 0, tilt 0 with one fallback.

Received counts across runs 3-8 varied from 350 through 352 while `missing` stayed 0 throughout. That count tracks `frames_sent`, which moves with sender loop timing. A received count below a round number is not evidence of loss when `missing` is zero.

## Architectural invariants

The following are design contracts, not tuning suggestions:

1. FCS-DEV is the only component that computes whole-craft control and mixing.
2. Pods are the only components that directly apply their local actuator state.
3. Every control interval is represented by one complete four-corner frame.
4. A pod applies only its own corner.
5. Reception and application remain separate execution paths.
6. The newest valid state wins; old states are never replayed to catch up.
7. Session, sequence, freshness, mode, arming, and numeric bounds are validated locally.
8. A stale or invalid command cannot disable the pod's local fallback.
9. Transport receipt and actuator application remain separately observable.
10. Telemetry cannot be allowed to recreate the event amplification that the direct protocol removed.
