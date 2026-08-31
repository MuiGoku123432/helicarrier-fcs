<!-- generated-by: gsd-doc-writer -->
# Architecture

## System overview

Helicarrier FCS is a distributed ComputerCraft flight-control system. Computer 1 (FCS-DEV) reads CC:Sable whole-craft state, computes bounded control commands, and broadcasts one complete four-corner frame over a wired modem network. Computers 2–5 are FL, FR, RL, and RR actuator pods. Each pod validates the shared frame, keeps only its newest fresh corner command, applies local peripherals independently of reception, and reports cumulative status.

The live operational baseline is direct-wired `stationkeep`: bounded vertical duty plus X/Z velocity and captured-position control. Legacy wireless telemetry and manual tools remain present, but they are not the operational actuator command path.

## Component diagram

```text
CC:Sable state
      |
      v
FCS-DEV (computer 1)
  stationkeep_control -> frame builder -> wired channel 42042
                                     |
                    +----------------+----------------+
                    |                |                |
                   FL               FR               RL               RR
              computer 2       computer 3       computer 4       computer 5
                    |                |                |                |
              validate -> latest-wins mailbox -> independent apply worker
                    |                |                |                |
                    +------- cumulative status on channel 42043 ------+
                                     |
                                     v
                                  FCS-DEV
```

## Data flow

1. `fcs/wiredframe_stationkeep.lua` samples pose and velocity, establishes a captured X/Z/Y target, and supervises the run.
2. `fcs/stationkeep_control.lua` combines world X/Z velocity, captured-position error, bounded integral bias, deadband, anti-windup, and command-vector slew limiting.
3. `fcs/wired_stationkeep_protocol.lua` builds one `helicarrier.control-frame.v1` frame containing FL, FR, RL, and RR commands.
4. Every pod receives the same frame in `pod-template/pod/control_mailbox.lua`, rejects invalid/stale/out-of-order input, and extracts only its configured corner.
5. `pod-template/pod/control_apply.lua` applies the newest still-valid command, elides unchanged writes, records latency/errors, and enforces stale fallback.
6. Pods publish cumulative acknowledgements; the FCS runner monitors freshness and writes a signed flight trace and final report.
7. Operator stop or fault finalization sends repeated exact-zero shutdown frames and verifies pod application.

## Key abstractions

| Abstraction | Location | Responsibility |
|---|---|---|
| Stationkeeping controller | `fcs/stationkeep_control.lua` | Bounded X/Z velocity and captured-position control plus vertical duty selection |
| Wired stationkeep protocol | `fcs/wired_stationkeep_protocol.lua` | Frame construction, mode bounds, and acknowledgement helpers |
| Operational runner | `fcs/wiredframe_stationkeep.lua` | Sensor acquisition, phase sequencing, safety supervision, tracing, reporting, and shutdown |
| Pod mailbox | `pod-template/pod/control_mailbox.lua` | Validation, session/sequence accounting, latest-wins corner extraction, and status |
| Pod apply worker | `pod-template/pod/control_apply.lua` | Local actuator writes, write-elision, latency/error accounting, and fallback |
| Pod runtime | `pod-template/pod/main.lua` | Independent receive, status, apply, sensor, telemetry, and display loops |
| FCS configuration | `fcs/config.lua` | Axes, telemetry, logging, wireless compatibility, and monitor settings |
| Pod configuration | `pod-template/pod/config.lua` | Corner identity, peripheral names, manifests, power limits, and legacy telemetry settings |

## Operational baseline

`flight-logs/wiredframe_stationkeep_run3.txt` is the frozen baseline. It records 521/521 applications on every pod, zero transport/application faults, maximum horizontal speed 0.750938 blocks/s, maximum position error 18.832382 blocks, maximum tilt 1.327737 degrees, and clean exact-zero shutdown after operator termination.

The baseline preserves protocol version `helicarrier.control-frame.v1`, control channel 42042, status channel 42043, propeller RPM 64, a 6 degree tilt cap, and controller gains documented in `docs/stationkeeping-control-contract.md`.

## Directory structure rationale

```text
fcs/                  FCS-DEV runtime, controllers, diagnostics, and live harnesses
fcs-cc/               ComputerCraft packaging/startup layout for FCS-DEV
pod-template/         Per-corner pod runtime template and configuration
shared/               Code shared by runtime components
tools/                Host-side LuaJIT regression tests and harness tests
flight-logs/          Archived immutable live-run evidence
docs/                 Architecture, control contracts, setup, and operating guidance
archive/              Recoverable retired transport implementations
```

The transport, controller, pod validation, application, and documentation boundaries are intentionally separate so each can be tested and rolled back without replacing the others.
