<!-- generated-by: gsd-doc-writer -->
# Development

## Local setup

Clone the repository, enter its root, and confirm LuaJIT is available. There is no dependency-install or build step for the Lua sources.

```bash
git clone git@github.com:MuiGoku123432/helicarrier-fcs.git
cd helicarrier-fcs
luajit -v
```

Run the complete test suite before and after controller, protocol, pod, or harness changes:

```bash
for f in tools/test_*.lua; do luajit "$f" || exit 1; done
```

## Development commands

| Command | Description |
|---|---|
| `luajit tools/test_stationkeep.lua` | Stationkeeping controller, direct protocol, pod validation, and pod apply regression |
| `for f in tools/test_*.lua; do luajit "$f" || exit 1; done` | Complete host-side Lua regression suite |
| `luajit -b fcs/stationkeep_control.lua /tmp/stationkeep_control.luac` | Parse/compile-check the controller without running ComputerCraft APIs |
| `git diff --check` | Check changed text for whitespace errors |
| `shasum -a 256 <file>` | Produce the local deployment checksum |

Live ComputerCraft scripts also expose mode-specific `--self-test` options where documented. Run those after deployment when a script supports them.

## Code style

The project uses straightforward Lua modules and standalone ComputerCraft scripts:

- keep runtime dependencies explicit with `require`;
- keep protocol validation separate from actuator application;
- keep command reception free of peripheral writes;
- use finite-number checks at sensor and protocol boundaries;
- use named constants for safety envelopes;
- keep controller state private to an instance and expose bounded outputs;
- preserve exact-zero shutdown as a distinct command state; and
- add a host-side regression for every safety or protocol change.

No standalone formatter or linter configuration is present. The regression suite includes repository-specific structural and undefined-global checks.

## Change boundaries

The frozen operational baseline is run 3. Changes fall into different risk classes:

- Documentation-only: no in-world reload required.
- FCS controller/runner only: copy to computer 1; no pod reboot required.
- Direct protocol: update every producer and consumer together, run protocol tests, and repeat a zero-output regression.
- Pod mailbox/apply/runtime: deploy to pods 2–5 and perform the guarded reboot in a safe craft state.
- Gains, signs, coordinates, safety limits, or fallback: retain the old file, deploy with hashes, and produce a saved live comparison report.

Never overwrite the proven run-3 controller without a rollback copy. The current live rollback is `stationkeep_control.lua.pre-recapture-tune-20260831-v1`.

## Deployment discipline

1. Run the full LuaJIT suite.
2. Compile-check changed standalone Lua files where useful.
3. Compute local SHA-256 hashes.
4. Copy each live target to a uniquely named rollback before overwriting it.
5. Deploy only the files in scope.
6. Compute the remote hashes and compare them with the local values.
7. Reboot only the computers that load changed modules at startup.
8. Run the smallest meaningful live verification.
9. Archive the result before another run overwrites it.
10. Update `HANDOFF.md`, the control contract, and the communication architecture when their contracts change.

## Branch conventions

The default branch is `main`. No project-specific feature-branch naming convention is documented. Keep commits focused and do not include unrelated local artifacts unless the user explicitly requests committing everything.

## Pull-request process

No repository-specific pull-request template or contribution guide is present. A review should nevertheless include:

- the changed control/protocol/safety boundary;
- host-side test results;
- deployment hashes when live files changed;
- saved live-run evidence for behavioral changes; and
- an explicit statement that shutdown/fallback semantics were preserved or intentionally changed.
