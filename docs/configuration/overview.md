<!-- generated-by: gsd-doc-writer -->
# Configuration

## Environment variables

This project does not use host environment variables for the ComputerCraft runtime. Configuration is stored in Lua tables copied into each in-world computer. Server paths and SSH aliases are operator environment details, not runtime configuration.

## FCS-DEV configuration

Edit `/fcs/config.lua` on computer 1 from the repository source `fcs/config.lua`.

| Setting | Default | Purpose |
|---|---:|---|
| `schemaVersion` | `1` | Configuration schema identifier |
| `samplePeriodSeconds` | `0.25` | Legacy telemetry loop period |
| `flushEveryRows` | `10` | CSV flush cadence |
| `logDirectory` | `/fcs/logs` | In-world log directory |
| `maxLogBytes` | `600000` | Per-file rollover size |
| `maxLogFiles` | `10` | Retained log file count |
| `axes.bowAxis` | `z` | Measured body axis pointing toward the bow |
| `axes.portAxis` | `x` | Measured body axis pointing to port |
| `wireless.enabled` | `true` | Enables legacy telemetry/manual wireless services |
| `wireless.protocol` | `helicarrier.fcs.v1` | Legacy telemetry protocol identifier |
| `hub.textScale` | `0.5` | Monitor text scale |
| `hub.maxRedrawHz` | `5` | Monitor repaint ceiling |
| `hub.staleAfterMs` | `1000` | Age at which the display reports stale data |
| `hub.deadAfterMs` | `5000` | Age at which the display reports no telemetry |

The measured body convention is `+Z` bow, `+X` port, and `+Y` up. Do not change these axis fields without repeating the axis calibration.

## Pod configuration

Each pod receives its own `/pod/config.lua` copied from `pod-template/pod/config.lua`.

Required per-pod edits:

| Setting | Required value |
|---|---|
| `corner` | Exactly one of `FL`, `FR`, `RL`, or `RR` |
| `hostname` | Matching `ENG-FL`, `ENG-FR`, `ENG-RL`, or `ENG-RR` |
| `mainComputerId` | Numeric ComputerCraft ID for FCS-DEV |
| `propController` | Exact local Rotation Speed Controller peripheral name |
| `propBearing` | Exact local bearing name or list of bearing names |
| `manifestApproved` | `true` only after local thruster discovery is physically verified |
| `expectedThrusterCount` | Actual thruster count for that pod; template default is `32` |

Important defaults:

| Setting | Default | Contract |
|---|---:|---|
| `fallbackPower` | `0.0` | Boot, disarm, error, and exit mean all ions off |
| `commsLossPower` | `0.195` | Legacy wireless-flight fallback calibrated for propeller RPM 64 |
| `minimumPower` / `maximumPower` | `0.0` / `1.0` | Accepted normalized ion range |
| `maximumChangePerCommand` | `0.05` | Legacy command-step limit |
| `commandTimeoutMs` | `750` | Legacy wireless watchdog timeout |
| `telemetryPeriodSeconds` | `0.20` | Pod telemetry publication period |

The operational direct-wired `stationkeep` mode has additional bounds in `fcs/wired_stationkeep_protocol.lua` and `pod-template/pod/control_mailbox.lua`. Do not widen those bounds by changing the legacy configuration table.

## Operational controller defaults

`fcs/stationkeep_control.lua` defines the run-3 baseline:

| Setting | Value |
|---|---:|
| `velocityGain` | `0.80` |
| `positionGain` | `0.0225` |
| `integralGain` | `0.010` |
| `deadbandSpeed` | `0.08` blocks/s |
| `positionDeadband` | `0.50` blocks |
| `maxTiltDegrees` | `6.0` |
| `slewDegreesPerSecond` | `0.15` |
| `maxDtSeconds` | `1.0` |
| `highCooldownSlots` | `3` |

These are source-controlled safety and control constants, not routine operator settings. Treat any change as a new flight configuration requiring tests, a live comparison report, and a rollback.

## Protocol constants

| Constant | Value |
|---|---:|
| Direct protocol | `helicarrier.control-frame.v1` |
| Control channel | `42042` |
| Status channel | `42043` |
| Operational propeller RPM | `64` |
| Stationkeep tilt bound | `+/-6` degrees |

## Per-environment overrides

There is no environment-profile loader. Development changes are made in repository Lua files, tested with LuaJIT, copied to the relevant ComputerCraft directory, and verified by SHA-256. Pod-module changes require a guarded pod reboot; FCS-only standalone controller/runner changes do not.

<!-- VERIFY: The live world remains at /home/cfanch06/server/creative-test-superflat/world and computer IDs 1 through 5 retain their current roles. -->
