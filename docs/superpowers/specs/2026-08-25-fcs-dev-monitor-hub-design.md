# fcs-dev: monitor hub — design

Date: 2026-08-25
Status: approved for planning
Scope: read-only monitor dashboard on FCS-DEV, with an explicit seam for
control functions in a later phase.

---

## Problem

FCS-DEV logs a 130-column CSV at 4 Hz and draws roughly ten lines of terminal
text. Everything a person actually needs while the carrier is running —
per-bearing thrust deficit, which pod went silent, whether the logger is still
alive — is either buried in the CSV or absent. `HANDOFF.md` records that there
is no pilot-facing surface at all.

There is a 4x3 Advanced Monitor wall on FCS-DEV and nothing in the repository
touches a `monitor` peripheral.

## What this delivers

A program, `fcs-dev`, that renders live telemetry to the monitor wall. It reads
and draws. It commands nothing.

## Non-goals

- No commanding of pods, propellers, or tilt. Not in this phase.
- No new sensor reads, no new rednet traffic.
- No changes to the CSV schema, the wire protocol, or pod firmware.
- No host-side tooling.

---

## Architecture

### The invariant

**The telemetry loop (`fcs/main.lua`) is the only thing on this computer that
talks to CC:Sable or to the pods.**

The hub is a renderer downstream of it. This is not a stylistic preference:

- `sensors.read` costs roughly 50 ms of Sable calls per sample and the loop
  already cannot hold its declared 0.25 s period. A second reader makes a
  measured problem worse.
- A second `banks` instance would issue its own `status_request` volley every
  2 s and put a second `session` on the wire. `banks.lua` guards on
  `senderMismatch` and `hostnameMismatch`, and `HANDOFF.md` documents a whole
  class of ack-clobbering confusion that a second talker can only amplify.

A later session adding buttons must route commands *through* the logger rather
than opening a second channel. See "Control seam" below.

### Data flow

```
Sable + rednet ──> fcs/main.lua ──> snapshot.build() ──> snapshot.publish()
                        │                                    │
                        └──> csv writer                       ├─ os.queueEvent("fcs_snapshot", frame)   every sample
                                                              └─ /fcs/snapshot.dat                      every 2 s

                                    fcs-dev ──> hub/run ──> layout ──> zones ──> canvas ──> monitor
```

CC delivers non-input events to every multishell process, so `os.queueEvent` is
free IPC between the logger tab and the hub tab. The disk file exists only so a
hub started cold has something to draw before the next event arrives, and so it
can show a last-known frame with an honest age when the logger is not running.

### Files

New:

```
/fcs-dev.lua                 entry point (so the shell command is `fcs-dev`)
/fcs/snapshot.lua            build + publish
/fcs/hub/run.lua             event loop, staleness, redraw scheduling
/fcs/hub/canvas.lua          double-buffered draw surface
/fcs/hub/layout.lua          screen measurement -> zone rects
/fcs/hub/theme.lua           value -> colour, in one place
/fcs/hub/zones/attitude.lua
/fcs/hub/zones/engines.lua
/fcs/hub/zones/pods.lua
/fcs/hub/zones/power.lua
```

Modified (the complete list; the repository has no version control, so this
list is the rollback plan):

- `fcs/main.lua` — require `fcs.snapshot`; one `snapshot.publish(...)` call at
  the end of `sample()`; publish-failure counter added to the `heartbeat.txt`
  report.
- `fcs/config.lua` — new `hub` block.
- `startup.lua` — open a third tab for `fcs-dev` when `hub.autoStart` is true
  and a monitor peripheral is present.

`fcs-dev.lua` must open with the same `package.path` / `cc/require.lua`
bootstrap preamble as `fcs/main.lua`. `shell.run` and `shell.openTab` inject
`require`; `multishell.launch` does not, and a top-level program that assumes
otherwise throws on a nil global.

---

## The snapshot contract

`snapshot.build(sequence, timestamp, dt, state, peripheralState, podStates,
logInfo)` returns:

```lua
{
  v = 1,
  utc_ms, sequence, dt_s, valid,
  errors = { "…" },

  craft = {
    position = {x,y,z}, roll, pitch, yaw,
    bodyVel = {x,y,z}, worldVel = {x,y,z}, angVel = {x,y,z},
    mass, airPressure,
  },

  corners = {                       -- FL FR RL RR
    FL = {
      controllerPresent, bearingPresent,
      targetRpm, controllerRpm, bearingRpm,
      thrust, thrustImbalance, airflow, sailPower,
      hasSource, overstressed, active,
      bearings = { {thrust=, assembled=}, {thrust=, assembled=} },
      tilt, tiltAzimuth,
    }, …
  },

  pods = {
    FL = {
      online, podId, armed, currentPower, fallbackPower, ageMs,
      healthyThrusters, expectedThrusters, obstructedThrusters,
      totalThrustKN, averagePower, energyFE, energyCapacityFE,
      faults = { "…" },
      commandsSeen, commandsApplied, commandsRejected, lastReject, bootedAt,
    }, …
  },

  power = { storedFE, capacityFE, gridPower, gridVoltage, gridAmperage },
  net   = { seen, accepted, badProtocol, wrongType, unknownCorner,
            hostnameMismatch, senderMismatch, perCorner = {FL=,FR=,RL=,RR=} },
  log   = { path, bytes, samples, targetHz, actualHz, freeSpace },
}
```

Rules:

- `v` is checked by the hub. A hub reading a snapshot whose `v` it does not
  know draws a version-mismatch banner rather than mis-rendering fields.
- `build` derives everything from the three tables `sample()` already holds. It
  performs no reads of its own. There is no second source of truth.
- **`publish` is wrapped in `pcall` at the call site in `main.lua`.** A render-
  side or serialisation-side bug must not be able to stop logging. Failures
  increment `snapshot.failures`, reported in `heartbeat.txt`.
- The disk write is throttled to at most once per 2 s and is itself `pcall`-ed.
  The computer has a hard disk quota and the CSV budget is already tuned
  against it; the snapshot file is a single small file, overwritten in place.
- Two bearings per corner, matching the fixed `BEARINGS_PER_CORNER = 2` in
  `main.lua`. A corner missing a bearing leaves an empty cell; it never
  shortens the row.

---

## Layout

Target surface: 4x3 Advanced Monitor at text scale 0.5, approximately 79x38
characters. The hub measures the surface it is actually given and reflows; the
number above is the design target, not an assumption baked into the code.

```
┌ FCS-DEV ────────────────────────── LIVE  seq 12481  3.9 Hz ──┐
│ ATTITUDE / MOTION                │ POWER                      │
│   horizon + roll / pitch ladder  │   FE ▓▓▓▓▓▓░░░░  62%       │
│   R/P/Y   ALT   body V   world V │   grid  W / V / A          │
├──────────────────────────────────┴────────────────────────────┤
│ ENGINES              FL        FR        RL        RR         │
│   target / actual rpm · thrust · b1 · b2 · Δ% · tilt · flags  │
├───────────────────────────────────────────────────────────────┤
│ PODS   online  armed  power  age  thrusters  obstructed       │
│ FAULTS  (most recent first)                                   │
└─ rednet seen/acc/drop ────── flight_1787….csv   412 KB ───────┘
```

Zone priorities and reflow:

- ENGINES is full width with four fixed columns at every size above its
  minimum. The per-bearing `b1`/`b2` values and their Δ% are the reason this
  screen exists: corner aggregates sum magnitudes and cannot show one bearing
  of a counter-rotating pair underperforming its twin.
- ATTITUDE and POWER share the top row above 70 columns; below that they stack.
- PODS and FAULTS occupy the bottom band; FAULTS shrinks first.
- A zone whose rect is below its `minWidth`/`minHeight` draws its name and the
  size it needs — never a partial or wrapped render.
- `fcs-dev --term` renders the same code to the terminal (51x19), which is how
  the layout degradation gets exercised in practice.

Zone module interface:

```lua
return {
  name = "ENGINES",
  minWidth = 60, minHeight = 8,
  draw = function(canvas, rect, frame) … end,
}
```

`draw` is a pure function of `rect` and `frame`. Zones do not read peripherals,
do not touch `banks`, and do not know whether they are on a monitor or a
terminal.

---

## Command line

```
fcs-dev                    render to the configured (or first) monitor
fcs-dev --term             render to the terminal instead
fcs-dev --monitor <name>   render to a named monitor peripheral
fcs-dev --scale <n>        override hub.textScale for this run
```

Unknown flags print usage and exit non-zero. With no monitor attached and no
`--term`, the hub says so and falls back to the terminal rather than erroring.

---

## Staleness

The dangerous failure is a dashboard frozen on plausible numbers. Freshness is
therefore a rendered value, not an implementation detail.

Frame age, measured against `hub.staleAfterMs` / `hub.deadAfterMs`:

| age | header | body |
|---|---|---|
| < 1 s | `LIVE`, green | normal |
| 1–5 s | `STALE 2.4s`, yellow | all values dimmed |
| > 5 s, or none ever received | `NO TELEMETRY`, red | last frame retained, age shown large, plus the literal remedy: start `/fcs/main.lua` |

Pod freshness is separate and per corner, driven by `pods[c].ageMs` against
`config.wireless.offlineAfterMs`. A live logger with a dead FL pod and a dead
logger are different situations and must never look alike.

---

## Render cost

The wall is roughly 3000 cells. A full repaint at 4 Hz flickers and wastes tick
budget.

`canvas` holds a shadow buffer of `{char, fg, bg}` per cell. `flush()` walks
each row and emits only changed runs via `blit`. A typical frame changes a few
hundred cells. Redraw is capped at `hub.maxRedrawHz` (default 5) regardless of
snapshot arrival rate, and a `monitor_resize` forces a full repaint and a
re-layout.

---

## Control seam

Reserved for a later phase, specified here so it is not improvised:

- `fcs/hub/input.lua` handles `monitor_touch` and owns hit-testing.
- Commands are emitted as `os.queueEvent("fcs_command", …)`.
- **`fcs/main.lua` dispatches them via `banks.send`.** The hub never calls
  `banks` directly.

This keeps exactly one rednet talker on FCS-DEV. Read-only zone modules do not
change when control lands.

---

## Configuration

New block in `fcs/config.lua`:

```lua
hub = {
    monitorName = nil,   -- nil = first attached monitor
    textScale = 0.5,
    autoStart = true,    -- startup.lua opens a tab when a monitor is present
    maxRedrawHz = 5,
    staleAfterMs = 1000,
    deadAfterMs = 5000,
},
```

`startup.lua` opens the third tab only when `hub.autoStart` is true *and* a
monitor peripheral is present, so a computer with no wall boots exactly as it
does today.

---

## Testing

Off-server, plain Lua, following `tools/test_mixer.lua`. `tools/cc_harness.lua`
is deliberately not used: it exists to reproduce CC's event scheduling, and
layout, canvas, and zones have no scheduling surface.

- `tools/test_hub_layout.lua` — 79x38, 51x19, 29x12, 120x50: every zone rect
  in bounds, no two zones overlapping, degraded message when below minimum.
- `tools/test_hub_canvas.lua` — flush writes only changed cells; an unchanged
  frame writes nothing; resize forces a full repaint.
- `tools/test_hub_zones.lua` — each zone against hostile frames: all-nil,
  pod offline, missing bearings, NaN, negative thrust. Must not error and must
  not emit the string `nil`.
- `tools/test_snapshot.lua` — `build` from fabricated `state` /
  `peripheralState` / `podStates`; unknown `v` handling; `publish` failure is
  swallowed and counted.

Each test file is runnable as `luajit tools/test_<name>.lua` from the repo root
and exits non-zero on failure.

In-world acceptance, on the grounded carrier:

1. `fcs-dev` with the logger running: all four zones populate, header reads
   LIVE, and the engine strip shows four corners of RPM and per-bearing thrust.
2. Kill the logger tab: header transitions STALE then NO TELEMETRY within 5 s,
   values dim, last frame stays readable.
3. Restart the logger: header returns to LIVE without restarting the hub.
4. Power one pod down: that corner alone goes offline; the header stays LIVE.
5. Confirm the CSV keeps its row rate with the hub running.

---

## Risks

- **Publish in the hot path.** Mitigated by `pcall`, the 2 s disk throttle, and
  acceptance step 5, which measures the row rate rather than assuming it.
- **Event delivery across tabs.** The design assumes CC delivers non-input
  events to every multishell process. If that proves false in this version, the
  hub falls back to polling `/fcs/snapshot.dat`, and the disk write drops from
  every 2 s to every sample. This is the one assumption to verify first.
- **No version control.** The modified-file list above is the rollback plan.
