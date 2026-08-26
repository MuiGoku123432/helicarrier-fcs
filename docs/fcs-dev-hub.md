# fcs-dev hub

A read-only monitor dashboard on FCS-DEV. `/fcs-dev.lua` renders frames that
`/fcs/main.lua` publishes; it opens automatically in its own tab on boot when a
monitor is attached.

**The invariant, and it matters:** `fcs/main.lua` is the ONLY program on this
computer that talks to CC:Sable or to the pods. The hub requires none of
`fcs.banks`, `fcs.sensors`, `fcs.network`, and must not start to. A second
reader duplicates ~50 ms of Sable calls per sample on a loop that already
cannot hold its 0.25 s period; a second sender puts another session on the wire
for `banks.lua`'s sender guards to trip over.

When control functions are added, they route through the logger: the hub queues
`fcs_command`, and `main.lua` dispatches it via `banks.send`. One talker.

Transport is `os.queueEvent("fcs_snapshot", frame)` every sample, plus
`/fcs/snapshot.dat` every 2 s as a cold-start seed. Publishing is pcall-wrapped
at the call site; `snapshot_publishes` / `snapshot_failures` appear in
`/fcs/heartbeat.txt`.

**Per-bearing thrust is printed at full resolution deliberately** — the deficit
under investigation is ~1%, and 13960.98 and 13804.41 both round to "14.0k".

**The producer-side tilt field is `tiltAngle`, not `tilt`.** `snapshot.lua`
maps it to the frame's `tilt`. `actuators.lua` and `tiltctl.lua` read
`tiltAngle` too. This was shipped wrong once and caught only at final review.

**Zone row budgets.** ATTITUDE, PODS and POWER each compute how many rows fit
from `rect.h` and state a hidden count in their title when they drop rows.
ENGINES instead declares a minimum height of 10 that fits its fixed row list.
Both are deliberate; do not "unify" them without re-reading why.

Offline tests, all plain luajit from the repo root:

    luajit tools/test_hub_canvas.lua      luajit tools/test_hub_zones.lua
    luajit tools/test_hub_layout.lua      luajit tools/test_hub_run.lua
    luajit tools/test_hub_widgets.lua     luajit tools/test_snapshot.lua

`tools/hub_fixtures.lua` builds its frame by calling `snapshot.build` on a
producer-shaped context using REAL field names. Keep it that way: the previous
hand-written literal is exactly why the `tilt` break stayed invisible.

`test_hub_zones.lua` runs a shared battery over every registered zone against
hostile frames (nils, NaN, offline pods, missing bearings) and asserts each zone
draws inside its rect, never renders "nil", and renders something. A zone added
to `fcs/hub/zones/init.lua` is covered automatically.
