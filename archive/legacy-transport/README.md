# Legacy transport archive

This directory records the retired ComputerCraft transport design and the evidence that replaced it.

## Retired active behavior

The pod runtime no longer schedules the legacy Rednet command receiver or its command-timeout watchdog. The old path sent separate `arm`, `set_power`, `set_rpm`, and `set_tilt` messages per corner. Rednet repeated those messages across open modems and the aggregate event load produced substantial loss before `rednet.receive`.

The exact pre-removal pod runtime remains recoverable from:

- Git history.
- Each live pod's `/pod/main.lua.pre-ground-apply-20260829-v1` deployment backup.
- The earlier `/pod/main.lua.pre-shadow-mailbox-20260829-v1` backup.

## Reference-only diagnostics

These tools established the failure mode and are no longer part of the active control architecture:

- `fcs/linkwatch.lua`
- `tools/run_linkwatch_harness.lua`
- `tools/test_pod_command_receipt.lua`
- `fcs/wiredframe_test.lua`
- `pod-template/pod/wiredframe_test.lua`
- `fcs/wiredframe_shadow.lua`

Server deployment copies are stored beneath `/archive/legacy-transport/` rather than left in the active FCS or pod command directories. Repository history preserves their source and development sequence.

## Replacement

The active path is one direct wired `helicarrier.control-frame.v1` frame containing all four corners. Each pod extracts its own corner into a latest-wins mailbox. A separate worker applies the newest valid command, allowing reception to continue while peripheral calls yield.

Evidence:

- `flight-logs/wiredframe_test_run1.txt`: 301/301 frames received by every pod at 10 Hz with no loss.
- `flight-logs/wiredframe_shadow_run1.txt`: 601/601 frames received by every pod under the normal production telemetry/peripheral workload with no loss.
