<!-- generated-by: gsd-doc-writer -->
# Getting started

## Prerequisites

- A Minecraft instance with ComputerCraft/CC:Tweaked, CC:Sable, Create, and the carrier's propulsion peripherals.
- Five Advanced Computers: FCS-DEV plus FL, FR, RL, and RR pods.
- One shared wired modem network connecting the operational FCS command path to all four pods.
- LuaJIT on the development host for regression tests.
- Filesystem or SSH access to the server world when deploying directly.

## Installation steps

1. Clone the repository and enter it:

   ```bash
   git clone git@github.com:MuiGoku123432/helicarrier-fcs.git
   cd helicarrier-fcs
   ```

2. Run the host-side regression suite:

   ```bash
   for f in tools/test_*.lua; do luajit "$f" || exit 1; done
   ```

3. Copy the FCS package to computer 1:

   ```text
   fcs-cc/startup.lua -> /startup.lua
   fcs-cc/fcs/        -> /fcs/
   ```

4. Copy `pod-template/startup.lua` and `pod-template/pod/` to each pod, then configure `corner`, `hostname`, FCS computer ID, local peripheral names, and the approved thruster manifest.

5. Reboot pods only after pod-module changes. FCS-only standalone script changes can be loaded without rebooting the pods.

## First run

Before powered operation, verify that all four pods report fresh clean status and that the direct protocol files match the deployed hashes.

For the operational stationkeeping run on FCS-DEV, invoke `/fcs/wiredframe_stationkeep.lua` with the `--stationkeep` flag. The runner performs zero-output precheck, lift, vertical braking, target capture, and active stationkeeping. Press Ctrl+T for an operator stop; it sends the exact-zero shutdown burst and saves `/fcs/wiredframe_stationkeep_result.txt`.

The run-3 baseline should report:

- `overall=PASS`;
- `termination=operator` after Ctrl+T;
- nil run, abort, and shutdown errors;
- equal sent/applied sequences on all four pods; and
- zero missing, duplicate, reordered, invalid, expired, apply-error, fallback, and fallback-stop counters.

## Common setup issues

### Module not found from `/fcs`

ComputerCraft resolves modules relative to the launched script. Use the current `wiredframe_stationkeep.lua`, which derives its own directory and extends `package.path`. Deploy the controller, runner, and protocol at the same `/fcs/` level.

### `lua` is unavailable on the host

Use `luajit`; the repository's full suite is designed to run as `for f in tools/test_*.lua; do luajit "$f"; done`.

### Pod source changed but behavior did not

Pod mailbox or apply-module changes require the pods to reload those modules. Perform the guarded reboot only while the craft is in an appropriate state. FCS-only controller changes do not require a pod reboot.

### A live report was overwritten

Each stationkeeping run writes the same in-world result path. Copy the result into `flight-logs/` before starting the next run.

## Next steps

- Read `docs/architecture/overview.md` for the component and data-flow model.
- Read `docs/configuration/overview.md` before changing axes, gains, safety bounds, or pod configuration.
- Read `docs/testing/overview.md` before deploying.
- Read `HANDOFF.md` for current hashes, rollback names, and the frozen operational baseline.
