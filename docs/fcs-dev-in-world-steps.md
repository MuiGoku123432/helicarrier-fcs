# fcs-dev: what still needs you, in Minecraft

Everything below needs a live FCS-DEV computer. A subagent cannot do any of it.
Nothing here is optional before you trust the wall in flight.

## 0. Deploy

Copy into the FCS-DEV computer directory:

    fcs-dev.lua           -> /fcs-dev.lua
    startup.lua           -> /startup.lua
    fcs/config.lua        -> /fcs/config.lua      *** see warning ***
    fcs/main.lua          -> /fcs/main.lua        *** see warning ***
    fcs/snapshot.lua      -> /fcs/snapshot.lua
    fcs/hub/              -> /fcs/hub/            (7 files + zones/)

**WARNING on config.lua:** HANDOFF.md's first operational gotcha is that the
server's copy carries `podIds` and peripheral names the repo template does not.
Do NOT overwrite it wholesale. Add only the new `hub = { ... }` block.

**WARNING on main.lua:** this file now contains changes from TWO authors -- my
three hub hunks, and someone else's `inertia_*` CSV columns. Copying the repo
copy across carries both. That is probably what you want, but know that it is
what you are doing.

## 1. Verify the one assumption the whole design rests on  (Plan Task 1)

The hub receives frames via `os.queueEvent`, which assumes CC delivers non-input
events to every multishell tab. Verified by reasoning, never in-world.

Open two tabs. In tab A run a listener on `fcs_probe`; in tab B queue 20
`fcs_probe` events with a table payload. Switch back to A.
The probe program is in the plan at Task 1, Step 1.

- **Events arrive with table payloads intact** -> proceed, and note it in HANDOFF.md.
- **They do not** -> the fallback is specified in Task 1 Step 3: `snapshot.publish`
  writes the disk file every sample instead of every 2 s, and `run.lua` polls the
  file instead of waiting on the event. Two localized edits; nothing else changes.
  Note this multiplies the disk write rate by 8 -- re-check free space after.

**Check this FIRST, before item 2**, because it is cheaper to discover here:
the frame carries ARRAY-indexed data (`bearings[1]`, `bearings[2]`, and the
fault lists walked with `ipairs`). Event arguments cross the Lua/Java boundary.
If integer keys do not survive that round trip, `b1 thrust`, `b2 thrust` and the
`b1-b2 delta` all read `--` -- the exact numbers the wall exists to show --
while every offline test stays green. The tell: the disk-seeded cold-start frame
renders those fields but live frames do not.

## 2. Acceptance  (Plan Task 13)

1. **All four zones populate.** Header reads `LIVE`, a sequence number, ~3.9 Hz.
   ENGINES shows b1/b2 at FIVE DIGITS (`13961`), not `14.0k`.
2. **Staleness is visible.** Ctrl+T the telemetry tab. Within ~1 s the header goes
   `STALE` with a rising age and colours dim; by 5 s it reads `NO TELEMETRY` and
   the footer says to start `/fcs/main.lua`. Last numbers stay on screen.
   *If the numbers keep looking live after the logger stops, stop and fix that
   before flying anything.*
3. **Recovery.** Restart the logger; the header returns to `LIVE` on its own,
   without restarting the hub.
4. **Pod loss differs from logger loss.** Power down one pod: the header stays
   `LIVE`, that corner's link row reads `DOWN` with a rising age and turns red,
   the PODS title reads `3/4 up`. The other three corners are untouched.
5. **Logging is not slowed.** Read `sequence` in `/fcs/heartbeat.txt`, wait 60 s,
   read again: expect ~230-240 samples, and `snapshot_failures=0`.
   If the rate dropped, set `hub.maxRedrawHz = 2` and measure again.
6. **Terminal fallback.** `fcs-dev --term` renders at 51x19 showing ENGINES and
   PODS, with the footer listing the hidden zones.

## 3. The one fix with no automated test

A monitor detach mid-flight (chunk boundary, broken block, re-assembled wall)
used to kill the hub tab permanently. It is now handled -- flush is guarded and
the hub re-resolves the monitor on re-attach -- but that path needs CC's event
scheduler, so it has never actually run. **Watch for:** the hub tab showing an
error, or going permanently blank, after you touch a monitor block or cross a
chunk boundary. Everything else on this list has offline test coverage; this
does not.

## 4. Things to watch on first run, ranked

1. Array keys surviving `queueEvent` (see item 1) -- would blank b1/b2/delta.
2. Cross-tab delivery -- signature is a stuck `NO TELEMETRY` with the logger
   demonstrably running.
3. CPU steal from the sample loop. `actualHz` is on the wall; compare it with the
   hub tab killed. Budget is roughly 3-10 ms per frame on CC's interpreter.
4. The startup line `fcs-dev: rendering to monitor_N (WxH)`. Read it. If the
   height is under 30 or width under 70, zones will drop rows -- they SAY so in
   their titles, so check the titles for a "N hidden" note.
5. `peripheral.hasType` needs CC:Tweaked 1.99+. If the server is older, both the
   hub and boot-time monitor detection throw.
6. Disk: a serialized frame is ~6 KB, negligible against the 6 MB CSV budget.
   `snapshot_failures` in heartbeat.txt reports trouble; free space is now on the
   footer.
