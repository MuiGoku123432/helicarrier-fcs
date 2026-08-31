<!-- generated-by: gsd-doc-writer -->
# Testing

## Test framework and setup

Tests are plain Lua programs executed with LuaJIT. They use assertions and repository-local test helpers rather than an external framework. `lua` is not assumed to exist on the development host.

Run commands from the repository root so `require` resolves `fcs.*`, `pod-template.*`, and shared modules correctly.

## Running tests

Run the entire suite:

```bash
for f in tools/test_*.lua; do luajit "$f" || exit 1; done
```

Run the stationkeeping stack alone:

```bash
luajit tools/test_stationkeep.lua
```

Compile-check ComputerCraft scripts without executing their peripheral calls:

```bash
luajit -b fcs/stationkeep_control.lua /tmp/stationkeep_control.luac
luajit -b fcs/wiredframe_stationkeep.lua /tmp/wiredframe_stationkeep.luac
```

The full suite currently covers controller math, protocol validation, pod mailbox/apply behavior, write-elision and cache invalidation, startup behavior, static structural checks, undefined globals, wired harness self-tests, finalization, telemetry budgets, axis/mixer calculations, and historical compatibility paths.

## Writing new tests

Host-side test files use the `tools/test_*.lua` naming convention. A new safety or protocol behavior should include both its accepted case and nearby rejected cases.

For controller changes, cover:

- command direction in the measured body/world convention;
- output bounds and slew limits;
- deadband behavior;
- saturation and anti-windup;
- stale/invalid input reset;
- representative biased-plant convergence; and
- exact expected behavior at the wired plant boundary.

For protocol or pod changes, cover:

- every accepted mode and boundary value;
- values immediately outside each bound;
- session and sequence changes;
- expiry and stale fallback;
- exact-zero shutdown;
- receive/application separation; and
- write-elision cache invalidation after fallback and session changes.

## Live verification layers

Host tests cannot prove the Minecraft plant. Use a graduated live verification:

1. Hash-check the deployed files.
2. Run zero-output/self-test gates.
3. Confirm all four fresh clean pod acknowledgements.
4. Run the bounded operational mode.
5. Stop through the supported operator path.
6. Verify exact-zero shutdown and per-pod final counters.
7. Archive the result under a new `flight-logs/` name.
8. Compare the signed trace and maxima against the frozen baseline.

For stationkeeping, run 3 is the comparison baseline:

| Metric | Baseline |
|---|---:|
| Per-pod frames applied | 521/521 |
| Maximum horizontal speed | 0.750938 blocks/s |
| Maximum position error | 18.832382 blocks |
| Maximum tilt | 1.327737 degrees |
| Fault counters | all zero |
| Finalization | operator stop, overall PASS, exact-zero shutdown |

A future run need not have the same duration or frame count. Compare fault counters, speed, position recapture timing, tilt, oscillation, and finalization rather than expecting identical samples.

## Coverage requirements

No numeric code-coverage threshold is configured. Behavioral acceptance is stricter at the system boundary: a healthy live direct-wired run requires zero missing, invalid, expired, and apply-error events on every pod, plus verified safe finalization.

## Continuous integration

No CI workflow is documented for this repository. The local full-suite command is the required pre-commit gate. Live Minecraft evidence remains a manual hardware-in-the-loop step and must be archived when it supports an operational claim.
