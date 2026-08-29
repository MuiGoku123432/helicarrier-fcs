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

The current stage invokes the real ion-thruster API with exact zero. Bearing, propeller, azimuth, and non-zero ion application remain future extensions.

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
  mode = "shadow" or "ground_apply",
  armed = false,
  session = "non-empty-run-identifier",
  sequence = 1,
  sentAt = 0,
  validForMs = 500,
  corners = {
    FL = { ionPower = 0, propRpm = 0, tiltDegrees = 0, azimuthDegrees = 0 },
    FR = { ionPower = 0, propRpm = 0, tiltDegrees = 0, azimuthDegrees = 0 },
    RL = { ionPower = 0, propRpm = 0, tiltDegrees = 0, azimuthDegrees = 0 },
    RR = { ionPower = 0, propRpm = 0, tiltDegrees = 0, azimuthDegrees = 0 },
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

Future modes must be introduced as separate, explicitly named safety envelopes. Do not silently widen `ground_apply` to accept flight commands.

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
- stagger pod transmissions;
- send only measurements needed by control, safety, diagnosis, or the operator;
- separate fast control-critical state from slow device-health detail;
- include source timestamp and age;
- never let telemetry sampling or serialization block command reception;
- do not mirror the same high-rate payload through multiple open modems.

## Extension path to flight control

The protocol should grow by capability, not by bypassing validation:

1. keep `shadow` for non-actuating regression tests;
2. keep `ground_apply` permanently exact-zero;
3. add a named, disarmed bearing-test mode with very small bounded tilt/azimuth;
4. add a named, restrained propeller-test mode with bounded RPM and slew;
5. add a named low-power ion-test mode with bounded power and slew;
6. add an armed flight mode only after local limits, freshness, acknowledgement, mixer bounds, and abort behavior are verified together.

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

The last run measured maximum application times of 114 ms FL, 109 ms FR, 106 ms RL, and 110 ms RR. One fallback per pod after the sender stopped was expected and passed.

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
