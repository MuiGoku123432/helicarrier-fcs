---
status: awaiting_human_verify
trigger: "Implement the pod-side code updates and bug fixes for command loss and COMMAND_TIMEOUT events; leave server configuration unchanged."
created: 2026-08-28
updated: 2026-08-28
---

# Pod Command Loss and Timeouts

## Symptoms

- expected: Four pods continuously accept valid FCS commands, apply the newest setpoint, and remain armed while traffic is healthy.
- actual: Ground LinkWatch tests report approximately 19–26% apparent command loss and repeated COMMAND_TIMEOUT events at roughly 3.35 Hz.
- errors: COMMAND_TIMEOUT; no command rejects were observed.
- timeline: Reproduced in the current creative-test setup; quiet display/log mode did not improve it.
- reproduction: Run the existing four-pod ground LinkWatch workload with mixed wired and wireless links. All corners show equal counts and similar failures.

## Constraints

- Do not modify server configuration in this work.
- Keep computer_threads unchanged.
- Preserve fail-safe disarming when valid power commands genuinely stop.
- Treat receipt acknowledgement and hardware application confirmation as distinct states.

## Current Focus

- hypothesis: The pod receive loop performs yielding peripheral work inline and updates lastCommandAt only after set_power application, delaying command reception and causing false watchdog timeouts; telemetry peripheral pressure may amplify the delay.
- test: After reloading the deployed pods, run unchanged four-pod ground LinkWatch and a genuine command-blackout safety check.
- expecting: The receipt-before-apply fix is sufficient if all four pods accept healthy LinkWatch traffic without new COMMAND_TIMEOUTs; stopping commands must still disarm each pod after the existing watchdog interval.
- next_action: While grounded and disarmed, run `/fcs/reboot.lua all`, then run the unchanged four-pod LinkWatch workload and report accepted-command rate, COMMAND_TIMEOUT rate, and whether a deliberate command blackout disarms every pod.
- bug_class: concurrency (a yielding actuator application and network/watchdog coroutines share receipt state without an atomic hand-off).
- reasoning_checkpoint:
  hypothesis: "Inline thrusters.applyCommand causes command loss and false COMMAND_TIMEOUT because its peripheral operation can yield before networkLoop records a valid command receipt, so the receive and watchdog coroutines observe stale receipt state during healthy traffic."
  confirming_evidence:
    - "The indexed networkLoop calls thrusters.applyCommand before acceptCommand, state.lastCommandAt, and ack for every valid armed set_power."
    - "The same file documents that inline peripheral sampling made the pod deaf for approximately 250 ms per poll and therefore defers status_request to a sampler."
    - "Quiet display/log mode worsened the failure, and wired/wireless corners failed equally with no command rejects, ruling out the two leading non-code alternatives."
  falsification_test: "If receipt is recorded and acknowledged before a deliberately yielding apply, but healthy receipt traffic still produces COMMAND_TIMEOUT or measured loss, the receive/application coupling is not the root cause."
  fix_rationale: "A separate worker lets networkLoop continue consuming valid commands and refresh the watchdog before any actuator I/O; currentPower and lastAppliedAt remain application-side state, and real receipt blackouts still leave lastCommandAt stale so watchdogLoop disarms."
  blind_spots: "The four-pod workload must still establish that the workload's observed loss and timeout rate collapse without server changes; graph impact traversal was truncated."
  candidate_causes:
    - "code: networkLoop performs thrusters.applyCommand before recording command receipt, coupling rednet reception to peripheral latency."
    - "environment: modem link quality could independently lose traffic, but wired/wireless parity makes it unlikely as the primary cause."
    - "data: malformed or replayed commands could be rejected, but no rejects were observed."
  and_gate: "no — the inline-yield/stale-receipt race alone is sufficient. Link quality may amplify frequency but is not needed to create it."
- tdd_checkpoint: pending

## Evidence

- timestamp: 2026-08-28T17:21:34Z
  observation: Quiet mode increased measured loss from 19.2% to 26.0–26.3% and COMMAND_TIMEOUT frequency from 0.122/s to 0.227/s at the same achieved command rate.
- timestamp: 2026-08-28T17:21:34Z
  observation: networkLoop applies set_power through thrusters.applyCommand inline, and lastCommandAt is updated only after that call returns.
- timestamp: 2026-08-28T17:21:34Z
  observation: Server logs showed no multi-second keep-up warning during the exact quiet A/B window.
- timestamp: 2026-08-28T18:05:00Z
  checked: pod-template/pod/main.lua::networkLoop
  found: For a valid, armed set_power, networkLoop calls thrusters.applyCommand inside pcall, then accepts the command, updates currentPower and lastCommandAt, and finally sends ack. In contrast, status_request is already deferred because inline peripheral work previously made the pod deaf for about 250 ms per poll.
  implication: set_power retains precisely the known blocking pattern the status path intentionally avoids; watchdog freshness measures application completion rather than receipt.
- timestamp: 2026-08-28T18:05:00Z
  checked: impact analysis of networkLoop
  found: The indexed graph reports medium change risk with no direct dependents, but traversal was lower-bound/truncated.
  implication: Keep the fix local to pod/main.lua and validate through the pod payload harness plus the actual four-pod LinkWatch workload.
- timestamp: 2026-08-28T18:18:00Z
  checked: local validation of the pod-only change
  found: `git diff --check`, LuaJIT syntax loading, `tools/test_pod_payload.lua` (48 passed), and the agent-authored receipt regression (10 passed) all passed. The graph-backed review returned APPROVE and the changed symbols have no indexed test coverage or configured guards.
  implication: The local code change is syntactically sound and preserves existing payload behavior, but the new test is a derived structural contract rather than the four-pod statistical workload.
- timestamp: 2026-08-28T18:20:00Z
  checked: revert-and-reconfirm guardrail
  found: Temporarily stashing only `pod-template/pod/main.lua` made `tools/test_pod_command_receipt.lua` fail because `applyPowerLoop` was absent; restoring the stash made it pass again (10 passed, 0 failed).
  implication: The regression guard is causally tied to this change. The remaining validation is the original LinkWatch reproduction in its creative-test environment.
- timestamp: 2026-08-28T18:30:00Z
  checked: final local validation and revert-and-reconfirm
  found: `git diff --check`, LuaJIT syntax loading, payload tests (48 passed), and the arm-session receipt regression (13 passed) passed. Temporarily stashing only final pod/main.lua made the regression fail; restoring exactly that file made it pass again.
  implication: The final pod-only implementation passes all locally available checks and is causally required by the regression. The unchanged four-pod LinkWatch workload remains the necessary end-to-end test.
- timestamp: 2026-08-28T18:45:00Z
  checked: live creative-test pod payload deployment
  found: `pod/main.lua` was backed up on computers 2–5 as `main.lua.pre-command-mailbox-20260828`, then deployed to all four; each deployed copy has SHA-256 `fa1813ad365a75745ad8e330935ead92409879f06cfc7b1732cd207e8cf3fc04`. No server configuration was modified. The server has neither a tmux/screen session nor enabled RCON, so the running ComputerCraft programs still hold the old module.
  implication: Rollback is preserved and the payload is staged identically on every pod, but a grounded/disarmed human must run `/fcs/reboot.lua all` before the workload can test the new implementation.

## Eliminated

- hypothesis: Pod display and filesystem heartbeat activity is the primary cause.
  reason: Quiet mode did not reduce loss or timeouts.
- hypothesis: Wireless transport alone is the primary cause.
  reason: Wired and wireless corners had identical command counts and failures.

## Resolution

- root_cause: `networkLoop` performed `thrusters.applyCommand` inline and only then recorded `lastCommandAt` and acknowledged the command. A yielding actuator operation therefore delayed receive progress and made watchdog freshness track peripheral completion rather than valid receipt.
- fix: Added a pod-local `applyPowerLoop` and newest-setpoint hand-off. `receiveLoop` now validates, sequence-accepts, timestamps, queues, and acknowledges `set_power` before actuator I/O; the worker alone updates application state. Queued work carries an armed-session token, so application after a watchdog disarm/re-arm is discarded. Disarm drops pending power, and worker faults retain fallback disarming.
- oracle_type: derived (the regression verifies the required receipt-before-apply ordering and disarm cancellation contract; the original LinkWatch rate is a statistical end-to-end oracle still awaiting the target environment).
- verification:
  - target_test: pass (`luajit tools/test_pod_command_receipt.lua`: 13 passed, 0 failed)
  - mutation_check: skipped (no Lua mutation runner/Stryker configuration was found)
  - no_op_deletion: pass (the graph-backed unstaged review approved the added worker/hand-off behavior with no deletion finding)
  - adjacent_tests: pass (`LUA_PATH='pod-template/?.lua;pod-template/?/init.lua;;' luajit tools/test_pod_payload.lua`: 48 passed, 0 failed; syntax load and `git diff --check` also passed)
  - revert_and_reconfirm: pass (the final regression failed without `applyPowerLoop` and passed after restoring exactly `pod-template/pod/main.lua`)
  - end_to_end_linkwatch: pending human reload and unchanged live workload (payload is staged on all four pods with verified matching hashes; existing server configuration remains unchanged)
  - guardrail_verdict: accepted
- files_changed:
  - pod-template/pod/main.lua
  - tools/test_pod_command_receipt.lua
