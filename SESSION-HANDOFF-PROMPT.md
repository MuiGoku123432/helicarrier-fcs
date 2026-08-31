# Session handoff prompt

Continue work on the helicarrier FCS in `/Users/cfanch06/repos/mine/luaScripts/helicarrier-fcs`.

Read `AGENTS.md`, `HANDOFF.md`, `docs/communication-architecture.md`, and `docs/stationkeeping-control-contract.md`. Use Gortex for indexed source. Preserve the operational stationkeeping baseline below unless the user explicitly requests a measured change.

## Proven operational baseline

Direct-wired stationkeeping is operational on the current carrier. The command path is one `helicarrier.control-frame.v1` frame for all four corners over wired channel 42042, with cumulative pod status on 42043. Pods validate locally, use latest-wins mailboxes, apply in independent workers, and retain exact-zero shutdown and stale fallback.

Run 3 is the frozen baseline:

- report: `flight-logs/wiredframe_stationkeep_run3.txt`;
- session: `1-stationkeep-1788203667879`;
- result: `overall=PASS`, operator termination, nil run/abort/shutdown errors;
- duration: 126.082 seconds;
- 521 frames and 614 samples;
- FL, FR, RL, and RR each applied 521/521 frames;
- zero missing, duplicate, out-of-order, invalid, expired, apply-error, fallback, and fallback-stop events;
- maximum horizontal speed 0.750938 blocks/s;
- maximum captured-position error 18.832382 blocks;
- maximum commanded tilt 1.327737 degrees; and
- report SHA-256 `489f22a80d936127595eda3bb8c105951c9ae26ce6e773b4acbfb9373cc09567`.

The trace proves the controller arrests the prior persistent rightward drift, holds near-zero X/Z velocity, and returns toward the captured position.

## Controller baseline

`fcs/stationkeep_control.lua`:

- `velocityGain=0.80`;
- `positionGain=0.0225`;
- `integralGain=0.010`;
- `deadbandSpeed=0.08`;
- `positionDeadband=0.50`;
- `slewDegreesPerSecond=0.15`;
- `maxTiltDegrees=6.0`;
- verified inverted synthetic-vector convention at the direct wired plant boundary; and
- deployed SHA-256 `836e7d315286877be5a408a7c1d0a18d19b85a74417f1f640208d5d3231efed2`.

Related deployed hashes:

- `fcs/wiredframe_stationkeep.lua`: `2106005d9a246ca29a147bd7e0c9de1b31f08a7b475f9104c25536222ed83abd`;
- `fcs/wired_stationkeep_protocol.lua`: `3243666f92ce9cd997713f0d2451ea99d6f69336dfd5e8c54c8a8f77b2a38861`.

The protocol hash did not change during sign correction or gain tuning. The run-2 controller rollback is `/fcs/stationkeep_control.lua.pre-recapture-tune-20260831-v1` on FCS computer 1.

## Verification and deployment

Run the complete suite with:

```bash
for f in tools/test_*.lua; do luajit "$f" || exit 1; done
```

Server access is `ssh mcserver`. The world computer directories are under `/home/cfanch06/server/creative-test-superflat/world/computercraft/computer`; FCS-DEV is 1 and pods are 2–5. Back up live files and verify local/remote SHA-256 hashes after deployment.

FCS-only controller or runner changes do not require a pod reboot. Pod mailbox/apply/runtime changes require a guarded reboot in a safe craft state.

## Next work

Do not keep increasing gains by default. Run 3 is stable and operational. The next useful work is:

1. repeat stationkeeping after a meaningful load/geometry change;
2. add a bounded pilot X/Z velocity request with bumpless return to captured-position hold;
3. validate stale-sensor, stale-pod, and actuator-fault behavior in the integrated controller;
4. improve roll/pitch damping from measured disturbance data; and
5. preserve the direct protocol, pod validation, plant sign, shutdown, and rollback unless comparison evidence justifies a change.
