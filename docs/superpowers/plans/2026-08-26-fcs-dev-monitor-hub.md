# fcs-dev Monitor Hub Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `fcs-dev`, a read-only ComputerCraft program that renders live helicarrier telemetry to a 4x3 Advanced Monitor wall on FCS-DEV.

**Architecture:** The existing telemetry loop (`fcs/main.lua`) stays the only thing on the computer that talks to CC:Sable or to the pods. After each sample it publishes a versioned snapshot table — via `os.queueEvent` every sample, and to `/fcs/snapshot.dat` every 2 s for cold start. `fcs-dev` is a separate program in its own multishell tab that consumes snapshots and draws them. Rendering is split into a double-buffered `canvas`, a `layout` that turns a screen size into zone rectangles, and four pure `zone` modules that draw into a rectangle from a frame.

**Tech Stack:** Lua 5.1 (ComputerCraft / CC:Tweaked), `luajit` for off-server tests, no external libraries.

**Spec:** `docs/superpowers/specs/2026-08-25-fcs-dev-monitor-hub-design.md`

## Global Constraints

- **The one-talker invariant.** `fcs/main.lua` is the only program on FCS-DEV that calls `sensors.read`, `banks.*`, or `rednet.*`. No hub module may `require("fcs.banks")`, `require("fcs.sensors")`, or `require("fcs.network")`. A reviewer should reject any task that breaks this.
- **Publishing must never stop logging.** Every `snapshot.publish` call site is `pcall`-wrapped. A hub-side failure increments a counter; it never propagates.
- **This repository is not under version control.** There are no `git commit` steps. Each task ends with a **Checkpoint**: run the full off-server suite and confirm every test file passes. The "Files" block of each task is the rollback record — revert by hand if a task goes wrong.
- **Zones are pure.** A zone module's `draw` reads only its `rect` and the `frame` passed to it. No peripheral access, no clock reads, no network, no globals from ComputerCraft.
- **No ComputerCraft globals in testable modules.** `canvas.lua`, `layout.lua`, `theme.lua`, `widgets.lua`, the zone modules, and `snapshot.build` must run under plain `luajit` with no `term`, `colours`, `peripheral`, `os.epoch`, or `fs`. Colour values are plain numbers defined in `theme.lua`. Only `fcs-dev.lua`, `fcs/hub/run.lua`, and `snapshot.publish` may touch CC globals, and `publish` guards them.
- **Two bearings per corner.** Matches `BEARINGS_PER_CORNER = 2` in `fcs/main.lua:24`. A corner missing a bearing leaves an empty cell; it never shortens a row.
- **Lua 5.1 only.** No integer division `//`, no goto, no `table.unpack` (use `unpack`), no bitwise operators. CC:Tweaked is 5.1 with some 5.2 additions; stay on 5.1.
- **Test runner:** `luajit tools/test_<name>.lua` from the repository root, exiting non-zero on failure, following the scaffolding in `tools/test_mixer.lua:20-55`.
- **Snapshot schema version:** `1`. Declared once as `snapshot.VERSION`.

## File Structure

Create:

| File | Responsibility |
|---|---|
| `fcs/hub/theme.lua` | Colour constants, status→colour, dimming, freshness thresholds. No drawing. |
| `fcs/hub/canvas.lua` | Double-buffered cell grid over a term-like target. Clipping, dirty-run flush, dim mode. Knows nothing about telemetry. |
| `fcs/hub/layout.lua` | Screen size → header/footer/zone rectangles + degraded flags. Pure arithmetic. |
| `fcs/hub/widgets.lua` | Reusable drawing above canvas: title bar, degraded placeholder, key/value row, bar gauge, column grid. |
| `fcs/hub/zones/attitude.lua` | Roll/pitch/yaw ladder, altitude, velocities. |
| `fcs/hub/zones/engines.lua` | Four-corner strip: RPM, thrust, per-bearing thrust and delta, tilt, flags. |
| `fcs/hub/zones/pods.lua` | Per-pod link/armed/power/thrusters, plus the fault list. |
| `fcs/hub/zones/power.lua` | Energy bar, grid W/V/A, per-pod ion average power. |
| `fcs/snapshot.lua` | `build` (pure) and `publish` (CC-side, pcall-guarded). |
| `fcs/hub/run.lua` | Target resolution, event loop, staleness, redraw scheduling, header/footer. |
| `fcs-dev.lua` | Entry point and argument parsing. |
| `tools/test_hub_canvas.lua` | Canvas tests. |
| `tools/test_hub_layout.lua` | Layout tests. |
| `tools/test_snapshot.lua` | Snapshot build tests. |
| `tools/test_hub_zones.lua` | Zone rendering tests, including hostile frames. |
| `tools/hub_fixtures.lua` | Shared fake canvas target and fabricated frames for the test files. |

Modify:

| File | Change |
|---|---|
| `fcs/main.lua` | Require `fcs.snapshot`; publish at the end of `sample()`; add publish-failure counter to `heartbeat.txt`. |
| `fcs/config.lua` | Add the `hub` block. |
| `startup.lua` | Open a third tab for `fcs-dev` when `hub.autoStart` and a monitor is present. |

---

## Task 1: Verify cross-tab event delivery

The entire IPC design assumes CC delivers `os.queueEvent` events to every multishell process, not only the one that queued them. This is the cheapest thing to be wrong about and the most expensive to discover late. Verify before building anything on it.

**Files:**
- Create: `tools/probe_event.lua` (throwaway — deleted in Step 5)

**Interfaces:**
- Consumes: nothing.
- Produces: a yes/no answer that decides whether `fcs/hub/run.lua` (Task 11) waits on `fcs_snapshot` events or polls `/fcs/snapshot.dat`.

- [ ] **Step 1: Write the probe**

Create `tools/probe_event.lua`:

```lua
-- THROWAWAY. Answers one question: does os.queueEvent from one multishell
-- tab reach a program running in another tab?
--
-- Run in tab A:  probe_event listen
-- Run in tab B:  probe_event send
-- Then switch back to tab A.

local mode = ({ ... })[1]

if mode == "send" then
    for i = 1, 20 do
        os.queueEvent("fcs_probe", { n = i, at = os.epoch("utc") })
        print("sent " .. i)
        sleep(0.5)
    end
    return
end

if mode == "listen" then
    local seen = 0
    print("listening for fcs_probe (Ctrl+T to stop)")
    while true do
        local _, payload = os.pullEvent("fcs_probe")
        seen = seen + 1
        print(string.format("got %d: n=%s table=%s",
            seen, tostring(payload and payload.n), tostring(type(payload))))
    end
end

print("usage: probe_event listen | probe_event send")
```

- [ ] **Step 2: Copy the probe to FCS-DEV and run it**

Copy `tools/probe_event.lua` to `/probe_event.lua` on FCS-DEV. Open two multishell tabs.

- Tab A: `probe_event listen`
- Tab B: `probe_event send`

Return to tab A.

Expected: tab A prints `got 1..20` with `n=1..20` and `table=table`.

- [ ] **Step 3: Record the outcome**

Two possible results:

- **Events arrive, payload is a table** → proceed as specified. Note it in `HANDOFF.md` under a new `## fcs-dev hub` heading: "Cross-tab `os.queueEvent` verified <date>: events and table payloads reach other multishell tabs."

- **Events do not arrive, or the table payload arrives as `nil`/a copy that loses nested tables** → the fallback applies. Record which failure it was, then change two things in this plan before continuing: in Task 6, `snapshot.publish` writes `/fcs/snapshot.dat` **every sample** instead of every 2 s; in Task 11, `run.lua` replaces the `fcs_snapshot` branch with a timer that re-reads the file at `maxRedrawHz`. Nothing else in the plan changes — every other module is downstream of the frame table, not of how it arrived.

- [ ] **Step 4: Verify the disk fallback is viable either way**

On FCS-DEV, with the logger running, run:

```
lua
> local f = fs.open("/fcs/probe.dat", "w") f.write(("x"):rep(4096)) f.close()
> fs.getFreeSpace("/")
```

Expected: the write succeeds and free space is comfortably above 1 MB. Delete `/fcs/probe.dat`.

This matters because the snapshot file is written into the same quota the CSV budget (`maxLogBytes = 600000`, `maxLogFiles = 10`) is already tuned against.

- [ ] **Step 5: Delete the probe**

```bash
rm ~/repos/fcs-wireless-pods-v2/tools/probe_event.lua
```

Delete `/probe_event.lua` from FCS-DEV as well.

- [ ] **Step 6: Checkpoint**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit tools/test_mixer.lua
```

Expected: `101 passed, 0 failed`. This is the baseline — nothing has changed yet.

---

## Task 2: Canvas

A double-buffered cell grid over a term-like target. Everything else draws through it. It has no telemetry knowledge and no ComputerCraft dependency, which is what makes it testable under plain `luajit`.

**Files:**
- Create: `fcs/hub/canvas.lua`
- Create: `tools/hub_fixtures.lua`
- Test: `tools/test_hub_canvas.lua`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `canvas.new(target) -> Canvas` where `target` implements `getSize() -> w, h`, `setCursorPos(x, y)`, `blit(text, fgHex, bgHex)`, and optionally `isColour() -> boolean`.
  - `Canvas:clear(bg)`
  - `Canvas:text(x, y, str, fg, bg)` — clipped, returns nothing
  - `Canvas:fill(x, y, w, h, bg, char)`
  - `Canvas:bar(x, y, w, fraction, bgFilled, bgEmpty)`
  - `Canvas:setDim(flag)` / `Canvas:isDim()`
  - `Canvas:flush() -> cellsWritten, runsWritten`
  - `Canvas:invalidate()`
  - `Canvas:resize() -> w, h`
  - `Canvas.width`, `Canvas.height`
  - Colours passed in are plain numbers (powers of two, `1` through `32768`).

- [ ] **Step 1: Write the shared test fixtures**

Create `tools/hub_fixtures.lua`:

```lua
-- Shared scaffolding for the hub test files: a fake canvas target that
-- records every blit, and fabricated telemetry frames.
--
-- Exists so test_hub_canvas, test_hub_zones and test_snapshot agree on what a
-- frame looks like. A zone test that invents its own frame shape tests the
-- test, not the zone.

local fixtures = {}

-- --- fake render target ----------------------------------------------------
-- Implements the subset of the CC term API that canvas uses, and records what
-- was written so a test can assert on the pixels rather than on the calls.

function fixtures.target(width, height, isColour)
    local self = {
        width = width,
        height = height,
        cursorX = 1,
        cursorY = 1,
        calls = {},           -- every blit, in order
        cells = {},           -- [y][x] = {char=, fg=, bg=}
    }

    for y = 1, height do
        self.cells[y] = {}
        for x = 1, width do
            self.cells[y][x] = { char = " ", fg = "0", bg = "f" }
        end
    end

    function self.getSize()
        return self.width, self.height
    end

    function self.setCursorPos(x, y)
        self.cursorX, self.cursorY = x, y
    end

    function self.isColour()
        return isColour ~= false
    end
    self.isColor = self.isColour

    function self.blit(text, fg, bg)
        self.calls[#self.calls + 1] = {
            x = self.cursorX, y = self.cursorY, text = text, fg = fg, bg = bg,
        }
        local row = self.cells[self.cursorY]
        if row then
            for i = 1, #text do
                local x = self.cursorX + i - 1
                if row[x] then
                    row[x] = {
                        char = text:sub(i, i),
                        fg = fg:sub(i, i),
                        bg = bg:sub(i, i),
                    }
                end
            end
        end
        self.cursorX = self.cursorX + #text
    end

    -- Total characters written across every blit since the last reset.
    function self.written()
        local total = 0
        for _, call in ipairs(self.calls) do
            total = total + #call.text
        end
        return total
    end

    function self.reset()
        self.calls = {}
    end

    -- Monitors change size when blocks are added; the canvas must cope.
    function self.resizeTo(newWidth, newHeight)
        self.width, self.height = newWidth, newHeight
        self.cells = {}
        for y = 1, newHeight do
            self.cells[y] = {}
            for x = 1, newWidth do
                self.cells[y][x] = { char = " ", fg = "0", bg = "f" }
            end
        end
        self.calls = {}
    end

    -- The visible screen as an array of strings, for readable assertions.
    function self.rows()
        local out = {}
        for y = 1, self.height do
            local chars = {}
            for x = 1, self.width do
                chars[x] = self.cells[y][x].char
            end
            out[y] = table.concat(chars)
        end
        return out
    end

    function self.rowText(y)
        return self.rows()[y]
    end

    return self
end

return fixtures
```

- [ ] **Step 2: Write the failing test**

Create `tools/test_hub_canvas.lua`:

```lua
-- Offline tests for fcs/hub/canvas.lua.
--
--     luajit tools/test_hub_canvas.lua      (from the repo root)

package.path = "./?.lua;" .. package.path

local canvas = require("fcs.hub.canvas")
local theme = require("fcs.hub.theme")
local fixtures = require("tools.hub_fixtures")

local passed, failed = 0, 0
local currentTest = "<none>"

local function fail(message)
    failed = failed + 1
    print(string.format("  FAIL  %s: %s", currentTest, message))
end

local function ok() passed = passed + 1 end

local function check(condition, message)
    if condition then ok() else fail(message) end
end

local function equal(actual, expected, message)
    if actual ~= expected then
        fail(string.format("%s: expected %s, got %s",
            message, tostring(expected), tostring(actual)))
        return
    end
    ok()
end

local function test(name, body)
    currentTest = name
    local succeeded, err = pcall(body)
    if not succeeded then fail("threw: " .. tostring(err)) end
end

local WHITE, BLACK = theme.colours.white, theme.colours.black
local RED, GREEN = theme.colours.red, theme.colours.green

-- ---------------------------------------------------------------------------

test("reports the target size", function()
    local surface = canvas.new(fixtures.target(20, 5))
    equal(surface.width, 20, "width")
    equal(surface.height, 5, "height")
end)

test("writes text into the buffer and flushes it to the target", function()
    local target = fixtures.target(20, 3)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:text(3, 2, "HELLO", WHITE, BLACK)
    surface:flush()
    equal(target.rowText(2):sub(3, 7), "HELLO", "row 2")
end)

test("clips writes that run past the right edge", function()
    local target = fixtures.target(10, 2)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:text(8, 1, "ABCDEFG", WHITE, BLACK)
    surface:flush()
    equal(target.rowText(1), "       ABC", "clipped row")
end)

test("clips writes that start off-screen to the left", function()
    local target = fixtures.target(10, 2)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:text(-2, 1, "ABCDEFG", WHITE, BLACK)
    surface:flush()
    equal(target.rowText(1), "DEFG      ", "left-clipped row")
end)

test("drops writes entirely outside the surface", function()
    local target = fixtures.target(10, 2)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:text(1, 9, "NOPE", WHITE, BLACK)
    surface:text(1, -1, "NOPE", WHITE, BLACK)
    surface:flush()
    equal(target.rowText(1), "          ", "row 1 untouched")
end)

test("a second identical frame writes nothing", function()
    local target = fixtures.target(30, 4)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:text(1, 1, "STATIC", WHITE, BLACK)
    surface:flush()
    target.reset()

    surface:clear(BLACK)
    surface:text(1, 1, "STATIC", WHITE, BLACK)
    local cells = surface:flush()
    equal(cells, 0, "cells written on unchanged frame")
    equal(#target.calls, 0, "blit calls on unchanged frame")
end)

test("only the changed cells are written", function()
    local target = fixtures.target(40, 3)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:text(1, 1, "value: 100", WHITE, BLACK)
    surface:flush()
    target.reset()

    surface:clear(BLACK)
    surface:text(1, 1, "value: 200", WHITE, BLACK)
    local cells = surface:flush()
    equal(cells, 1, "only the changed digit is written")
    equal(target.calls[1].text, "2", "written character")
    equal(target.calls[1].x, 8, "written column")
end)

test("adjacent changed cells coalesce into one blit", function()
    local target = fixtures.target(40, 3)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:text(1, 1, "AAAA", WHITE, BLACK)
    surface:flush()
    target.reset()

    surface:clear(BLACK)
    surface:text(1, 1, "BBBB", WHITE, BLACK)
    local cells, runs = surface:flush()
    equal(cells, 4, "cells written")
    equal(runs, 1, "runs written")
end)

test("a colour-only change is still a change", function()
    local target = fixtures.target(20, 2)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:text(1, 1, "OK", GREEN, BLACK)
    surface:flush()
    target.reset()

    surface:clear(BLACK)
    surface:text(1, 1, "OK", RED, BLACK)
    local cells = surface:flush()
    equal(cells, 2, "cells written on colour change")
end)

test("invalidate forces a full repaint", function()
    local target = fixtures.target(20, 2)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:text(1, 1, "HI", WHITE, BLACK)
    surface:flush()
    target.reset()

    surface:invalidate()
    surface:clear(BLACK)
    surface:text(1, 1, "HI", WHITE, BLACK)
    local cells = surface:flush()
    equal(cells, 40, "every cell repainted")
end)

test("resize rebuilds the buffers and forces a full repaint", function()
    local target = fixtures.target(20, 2)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:flush()

    target.resizeTo(30, 4)

    local w, h = surface:resize()
    equal(w, 30, "new width")
    equal(h, 4, "new height")
    surface:clear(BLACK)
    local cells = surface:flush()
    equal(cells, 120, "every cell of the new size repainted")
end)

test("dim mode rewrites foreground colours through the theme", function()
    local target = fixtures.target(10, 2)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:setDim(true)
    -- lime, not green: theme.dim maps lime -> green, whereas green is already
    -- its own dim form, so asserting on green would prove nothing.
    surface:text(1, 1, "X", theme.colours.lime, BLACK)
    surface:flush()
    equal(target.cells[1][1].fg, "d", "lime must dim to green")
    equal(surface:isDim(), true, "dim flag")
end)

test("dim mode is off by default", function()
    local target = fixtures.target(10, 2)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:text(1, 1, "X", theme.colours.lime, BLACK)
    surface:flush()
    equal(target.cells[1][1].fg, "5", "lime renders as lime when not dimmed")
    equal(surface:isDim(), false, "dim flag defaults to false")
end)

test("a monochrome target receives only white on black", function()
    local target = fixtures.target(12, 2, false)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:text(1, 1, "RED", RED, GREEN)
    surface:flush()
    equal(target.cells[1][1].fg, "0", "foreground forced to white")
    equal(target.cells[1][1].bg, "f", "background forced to black")
end)

test("bar fills the correct number of cells", function()
    local target = fixtures.target(20, 2)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:bar(1, 1, 10, 0.5, GREEN, theme.colours.gray)
    surface:flush()
    local filled = 0
    for x = 1, 10 do
        if target.cells[1][x].bg ~= "7" then filled = filled + 1 end
    end
    equal(filled, 5, "filled cells at 50%")
end)

test("bar clamps fractions outside 0..1 instead of overflowing", function()
    local target = fixtures.target(20, 2)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:bar(1, 1, 8, 5.0, GREEN, theme.colours.gray)
    surface:bar(1, 2, 8, -3.0, GREEN, theme.colours.gray)
    surface:flush()
    equal(#target.rowText(1), 20, "row 1 length unchanged")
    equal(#target.rowText(2), 20, "row 2 length unchanged")
end)

test("a nil or non-string text write is ignored rather than thrown", function()
    local target = fixtures.target(10, 2)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:text(1, 1, nil, WHITE, BLACK)
    surface:text(1, 1, 42, WHITE, BLACK)
    surface:flush()
    ok()
end)

-- ---------------------------------------------------------------------------

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit tools/test_hub_canvas.lua
```

Expected: an error loading `fcs.hub.theme` (module not found). Both `theme.lua` and `canvas.lua` are written in the next step.

- [ ] **Step 4: Write `fcs/hub/theme.lua`**

Create `fcs/hub/theme.lua`:

```lua
-- Colour constants and value-to-colour rules for the hub.
--
-- The numbers are ComputerCraft's colour palette, redeclared here rather than
-- read from the `colours` global: every module below run.lua must load under
-- plain luajit, where that global does not exist.

local theme = {}

theme.colours = {
    white = 1, orange = 2, magenta = 4, lightBlue = 8,
    yellow = 16, lime = 32, pink = 64, gray = 128,
    lightGray = 256, cyan = 512, purple = 1024, blue = 2048,
    brown = 4096, green = 8192, red = 16384, black = 32768,
}

local c = theme.colours

theme.background = c.black
theme.foreground = c.white
theme.titleForeground = c.black
theme.titleBackground = c.lightGray
theme.label = c.lightGray
theme.rule = c.gray

local LEVEL_COLOUR = {
    idle = c.gray,
    ok = c.lime,
    warn = c.yellow,
    bad = c.red,
}

function theme.status(level)
    return LEVEL_COLOUR[level] or c.white
end

-- Dim mode is how a stale frame stays readable while announcing that it is no
-- longer true. Everything collapses toward gray; nothing stays saturated,
-- because a saturated green on a frozen frame is exactly the lie to avoid.
local DIM = {
    [c.white] = c.lightGray,
    [c.lightGray] = c.gray,
    [c.gray] = c.gray,
    [c.lime] = c.green,
    [c.green] = c.green,
    [c.yellow] = c.brown,
    [c.orange] = c.brown,
    [c.red] = c.brown,
    [c.cyan] = c.blue,
    [c.lightBlue] = c.blue,
    [c.blue] = c.blue,
    [c.magenta] = c.purple,
    [c.pink] = c.purple,
    [c.purple] = c.purple,
    [c.brown] = c.brown,
    [c.black] = c.black,
}

function theme.dim(colour)
    return DIM[colour] or c.gray
end

-- Frame freshness. Thresholds come from config.hub; the defaults here are the
-- spec's and are used when a caller passes none.
theme.defaultStaleAfterMs = 1000
theme.defaultDeadAfterMs = 5000

function theme.freshness(ageMs, staleAfterMs, deadAfterMs)
    if type(ageMs) ~= "number" then
        return "dead"
    end
    staleAfterMs = staleAfterMs or theme.defaultStaleAfterMs
    deadAfterMs = deadAfterMs or theme.defaultDeadAfterMs
    if ageMs < staleAfterMs then
        return "live"
    elseif ageMs < deadAfterMs then
        return "stale"
    end
    return "dead"
end

local FRESHNESS_COLOUR = { live = c.lime, stale = c.yellow, dead = c.red }

function theme.freshnessColour(freshness)
    return FRESHNESS_COLOUR[freshness] or c.red
end

return theme
```

- [ ] **Step 5: Write `fcs/hub/canvas.lua`**

Create `fcs/hub/canvas.lua`:

```lua
-- A double-buffered character grid over a term-like target.
--
-- Why buffer at all: the 4x3 wall is roughly 3000 cells, and repainting all of
-- it four times a second both flickers and burns server tick. Draw into a back
-- buffer, compare against what the screen already shows, and emit only the
-- runs that changed -- a typical frame changes a few hundred cells.
--
-- Deliberately knows nothing about telemetry, and touches no ComputerCraft
-- global, so it runs under plain luajit in tools/test_hub_canvas.lua.

local theme = require("fcs.hub.theme")

local canvas = {}

local Canvas = {}
Canvas.__index = Canvas

local HEX = "0123456789abcdef"

-- Colour numbers are powers of two; blit wants the exponent as a hex digit.
local HEX_OF = {}
do
    local value = 1
    for i = 0, 15 do
        HEX_OF[value] = HEX:sub(i + 1, i + 1)
        value = value * 2
    end
end

local WHITE_HEX = HEX_OF[theme.colours.white]
local BLACK_HEX = HEX_OF[theme.colours.black]

local function hexOf(colour, fallback)
    return HEX_OF[colour] or fallback
end

function canvas.new(target)
    local self = setmetatable({}, Canvas)
    self.target = target
    self.dim = false
    -- Monochrome monitors accept only white on black; asking for anything else
    -- is not an error, it just silently renders wrong.
    local isColour = target.isColour or target.isColor
    self.colour = isColour and isColour() or false
    self:resize()
    return self
end

local function blankRow(width)
    local row = { char = {}, fg = {}, bg = {} }
    for x = 1, width do
        row.char[x] = " "
        row.fg[x] = WHITE_HEX
        row.bg[x] = BLACK_HEX
    end
    return row
end

function Canvas:resize()
    local width, height = self.target.getSize()
    self.width, self.height = width, height
    self.back = {}
    self.front = {}
    for y = 1, height do
        self.back[y] = blankRow(width)
        self.front[y] = blankRow(width)
    end
    self:invalidate()
    return width, height
end

-- Poison the front buffer so every cell compares unequal on the next flush.
function Canvas:invalidate()
    for y = 1, self.height do
        local row = self.front[y]
        for x = 1, self.width do
            row.char[x] = "\0"
        end
    end
end

function Canvas:setDim(flag)
    self.dim = flag and true or false
end

function Canvas:isDim()
    return self.dim
end

function Canvas:resolveForeground(colour)
    if not self.colour then
        return WHITE_HEX
    end
    if self.dim then
        colour = theme.dim(colour)
    end
    return hexOf(colour, WHITE_HEX)
end

function Canvas:resolveBackground(colour)
    if not self.colour then
        return BLACK_HEX
    end
    return hexOf(colour, BLACK_HEX)
end

function Canvas:clear(bg)
    local fgHex = self:resolveForeground(theme.foreground)
    local bgHex = self:resolveBackground(bg or theme.background)
    for y = 1, self.height do
        local row = self.back[y]
        for x = 1, self.width do
            row.char[x] = " "
            row.fg[x] = fgHex
            row.bg[x] = bgHex
        end
    end
end

-- Clipped single-cell write. Every other drawing method funnels through here,
-- so bounds checking lives in exactly one place.
function Canvas:set(x, y, char, fgHex, bgHex)
    if y < 1 or y > self.height or x < 1 or x > self.width then
        return
    end
    local row = self.back[y]
    row.char[x] = char
    row.fg[x] = fgHex
    row.bg[x] = bgHex
end

function Canvas:text(x, y, str, fg, bg)
    if type(str) ~= "string" then
        return
    end
    local fgHex = self:resolveForeground(fg or theme.foreground)
    local bgHex = self:resolveBackground(bg or theme.background)
    for i = 1, #str do
        self:set(x + i - 1, y, str:sub(i, i), fgHex, bgHex)
    end
end

function Canvas:fill(x, y, w, h, bg, char)
    char = char or " "
    local fgHex = self:resolveForeground(theme.foreground)
    local bgHex = self:resolveBackground(bg or theme.background)
    for dy = 0, h - 1 do
        for dx = 0, w - 1 do
            self:set(x + dx, y + dy, char, fgHex, bgHex)
        end
    end
end

-- A gauge drawn as coloured background cells rather than glyphs: it reads at a
-- glance on a wall and costs nothing extra to flush.
function Canvas:bar(x, y, w, fraction, bgFilled, bgEmpty)
    if type(fraction) ~= "number" or fraction ~= fraction then
        fraction = 0
    end
    if fraction < 0 then fraction = 0 end
    if fraction > 1 then fraction = 1 end
    w = math.max(0, math.floor(w))
    local filled = math.floor(w * fraction + 0.5)
    for i = 1, w do
        self:fill(x + i - 1, y, 1, 1, i <= filled and bgFilled or bgEmpty)
    end
end

-- Emit only what changed, coalescing adjacent changed cells into one blit.
-- Returns cells written and runs written, which is what the tests assert on
-- and what run.lua can log when a frame is unexpectedly expensive.
function Canvas:flush()
    local cells, runs = 0, 0
    for y = 1, self.height do
        local back, front = self.back[y], self.front[y]
        local x = 1
        while x <= self.width do
            if back.char[x] ~= front.char[x]
                or back.fg[x] ~= front.fg[x]
                or back.bg[x] ~= front.bg[x] then
                local startX = x
                local chars, fgs, bgs = {}, {}, {}
                while x <= self.width
                    and (back.char[x] ~= front.char[x]
                        or back.fg[x] ~= front.fg[x]
                        or back.bg[x] ~= front.bg[x]) do
                    local i = x - startX + 1
                    chars[i], fgs[i], bgs[i] = back.char[x], back.fg[x], back.bg[x]
                    front.char[x], front.fg[x], front.bg[x] =
                        back.char[x], back.fg[x], back.bg[x]
                    x = x + 1
                end
                self.target.setCursorPos(startX, y)
                self.target.blit(
                    table.concat(chars), table.concat(fgs), table.concat(bgs))
                cells = cells + #chars
                runs = runs + 1
            else
                x = x + 1
            end
        end
    end
    return cells, runs
end

return canvas
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit tools/test_hub_canvas.lua
```

Expected: `N passed, 0 failed`.

- [ ] **Step 7: Checkpoint**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit tools/test_mixer.lua && luajit tools/test_hub_canvas.lua
```

Expected: both suites report `0 failed`.

---

## Task 3: Layout

Turns a screen size into zone rectangles. Pure arithmetic — no drawing, no CC globals. This is where the reflow rules from the spec become code.

**Files:**
- Create: `fcs/hub/layout.lua`
- Test: `tools/test_hub_layout.lua`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `layout.compute(width, height) -> plan`, where `plan` is:
    ```lua
    {
      width = number, height = number,
      header = {x=, y=, w=, h=} or nil,
      footer = {x=, y=, w=, h=} or nil,
      zones  = { {name="ENGINES", rect={x=,y=,w=,h=}, degraded=boolean}, … },
      hidden = { "POWER", … },     -- names dropped for lack of room
      message = string or nil,     -- set only when nothing at all fits
    }
    ```
  - `layout.MINIMUMS` — `{ ATTITUDE={w=,h=}, POWER=…, ENGINES=…, PODS=… }`
  - `layout.PRIORITY` — `{ "ENGINES", "PODS", "ATTITUDE", "POWER" }`, most important first
  - `layout.SIDE_BY_SIDE_WIDTH = 70`
- Zone names are exactly `ATTITUDE`, `POWER`, `ENGINES`, `PODS` and match the module names in Tasks 7–10.

- [ ] **Step 1: Write the failing test**

Create `tools/test_hub_layout.lua`:

```lua
-- Offline tests for fcs/hub/layout.lua.
--
-- Layout is pure arithmetic on a screen size, so this is plain Lua rather than
-- tools/cc_harness.lua -- there is no event scheduling to reproduce.
--
--     luajit tools/test_hub_layout.lua      (from the repo root)

package.path = "./?.lua;" .. package.path

local layout = require("fcs.hub.layout")

local passed, failed = 0, 0
local currentTest = "<none>"

local function fail(message)
    failed = failed + 1
    print(string.format("  FAIL  %s: %s", currentTest, message))
end

local function ok() passed = passed + 1 end

local function check(condition, message)
    if condition then ok() else fail(message) end
end

local function equal(actual, expected, message)
    if actual ~= expected then
        fail(string.format("%s: expected %s, got %s",
            message, tostring(expected), tostring(actual)))
        return
    end
    ok()
end

local function test(name, body)
    currentTest = name
    local succeeded, err = pcall(body)
    if not succeeded then fail("threw: " .. tostring(err)) end
end

-- The sizes that matter: the 4x3 wall at scale 0.5, an Advanced Computer
-- terminal, a wall one block bigger, and something far too small.
local SIZES = {
    { name = "wall 79x38", w = 79, h = 38 },
    { name = "terminal 51x19", w = 51, h = 19 },
    { name = "large 120x50", w = 120, h = 50 },
    { name = "tiny 29x12", w = 29, h = 12 },
    { name = "degenerate 5x3", w = 5, h = 3 },
}

local function byName(plan, name)
    for _, zone in ipairs(plan.zones) do
        if zone.name == name then return zone end
    end
    return nil
end

local function overlaps(a, b)
    return a.x < b.x + b.w and b.x < a.x + a.w
        and a.y < b.y + b.h and b.y < a.y + a.h
end

-- ---------------------------------------------------------------------------
-- Invariants that must hold at EVERY size
-- ---------------------------------------------------------------------------

for _, size in ipairs(SIZES) do
    test(size.name .. ": every zone rect is inside the body region", function()
        local plan = layout.compute(size.w, size.h)
        for _, zone in ipairs(plan.zones) do
            local r = zone.rect
            check(r.x >= 1, zone.name .. " x >= 1")
            check(r.y >= 2, zone.name .. " y >= 2 (below the header)")
            check(r.w >= 1, zone.name .. " w >= 1")
            check(r.h >= 1, zone.name .. " h >= 1")
            check(r.x + r.w - 1 <= size.w, zone.name .. " fits horizontally")
            check(r.y + r.h - 1 <= size.h - 1, zone.name .. " stays above the footer")
        end
    end)

    test(size.name .. ": no two zones overlap", function()
        local plan = layout.compute(size.w, size.h)
        for i = 1, #plan.zones do
            for j = i + 1, #plan.zones do
                check(not overlaps(plan.zones[i].rect, plan.zones[j].rect),
                    plan.zones[i].name .. " overlaps " .. plan.zones[j].name)
            end
        end
    end)

    test(size.name .. ": no zone is listed both visible and hidden", function()
        local plan = layout.compute(size.w, size.h)
        for _, name in ipairs(plan.hidden) do
            check(byName(plan, name) == nil, name .. " is both visible and hidden")
        end
    end)

    test(size.name .. ": every known zone is either placed or hidden", function()
        local plan = layout.compute(size.w, size.h)
        for _, name in ipairs(layout.PRIORITY) do
            local placed = byName(plan, name) ~= nil
            local hidden = false
            for _, hiddenName in ipairs(plan.hidden) do
                if hiddenName == name then hidden = true end
            end
            check(placed or hidden, name .. " is unaccounted for")
        end
    end)
end

-- ---------------------------------------------------------------------------
-- The design target
-- ---------------------------------------------------------------------------

test("the 4x3 wall shows all four zones", function()
    local plan = layout.compute(79, 38)
    equal(#plan.zones, 4, "zone count")
    equal(#plan.hidden, 0, "hidden count")
    equal(plan.message, nil, "no too-small message")
    for _, zone in ipairs(plan.zones) do
        equal(zone.degraded, false, zone.name .. " degraded")
    end
end)

test("the wall places attitude and power side by side", function()
    local plan = layout.compute(79, 38)
    local attitude = byName(plan, "ATTITUDE")
    local power = byName(plan, "POWER")
    equal(attitude.rect.y, power.rect.y, "same top edge")
    check(attitude.rect.x < power.rect.x, "attitude sits left of power")
    equal(attitude.rect.w + power.rect.w, 79, "the pair spans the full width")
end)

test("engines and pods span the full width and sit below the top band", function()
    local plan = layout.compute(79, 38)
    local engines = byName(plan, "ENGINES")
    local pods = byName(plan, "PODS")
    local attitude = byName(plan, "ATTITUDE")
    equal(engines.rect.x, 1, "engines x")
    equal(engines.rect.w, 79, "engines width")
    equal(pods.rect.w, 79, "pods width")
    check(engines.rect.y > attitude.rect.y, "engines below the top band")
    check(pods.rect.y > engines.rect.y, "pods below engines")
end)

test("the body exactly fills the space between header and footer", function()
    local plan = layout.compute(79, 38)
    local lowest = 0
    for _, zone in ipairs(plan.zones) do
        lowest = math.max(lowest, zone.rect.y + zone.rect.h - 1)
    end
    equal(plan.header.y, 1, "header row")
    equal(plan.footer.y, 38, "footer row")
    equal(lowest, 37, "body reaches the row above the footer")
end)

-- ---------------------------------------------------------------------------
-- Degradation
-- ---------------------------------------------------------------------------

test("a narrow screen stacks attitude and power instead of pairing them", function()
    -- 60 is below SIDE_BY_SIDE_WIDTH but tall enough to keep both.
    local plan = layout.compute(60, 44)
    local attitude = byName(plan, "ATTITUDE")
    local power = byName(plan, "POWER")
    check(attitude and power, "both zones present at 60x44")
    if attitude and power then
        check(attitude.rect.y ~= power.rect.y, "stacked, not side by side")
        equal(attitude.rect.w, 60, "attitude spans full width when stacked")
        equal(power.rect.w, 60, "power spans full width when stacked")
    end
end)

test("the terminal keeps the highest-priority zones and hides the rest", function()
    local plan = layout.compute(51, 19)
    check(byName(plan, "ENGINES") ~= nil, "engines survives")
    check(byName(plan, "PODS") ~= nil, "pods survives")
    check(#plan.hidden > 0, "something was hidden")
    equal(plan.message, nil, "not a too-small screen")
end)

test("zones are dropped in reverse priority order", function()
    -- Tall enough for engines + pods only.
    local plan = layout.compute(79, 20)
    for _, name in ipairs(plan.hidden) do
        check(name == "POWER" or name == "ATTITUDE",
            "engines and pods must never be the first dropped, got " .. name)
    end
end)

test("a tiny screen keeps only what fits and hides the rest", function()
    -- 29 columns cannot hold engines (48) or pods (38), but attitude (28) fits.
    -- Dropping whole zones is the point: one readable zone beats four garbled.
    local plan = layout.compute(29, 12)
    check(byName(plan, "ENGINES") == nil, "engines cannot fit 29 columns")
    check(byName(plan, "PODS") == nil, "pods cannot fit 29 columns")
    check(#plan.zones >= 1, "something still renders")
    check(#plan.hidden >= 2, "the zones that cannot fit are listed as hidden")
    equal(plan.message, nil, "not a too-small screen -- something rendered")
end)

test("a screen too small for anything reports a message and places nothing", function()
    local plan = layout.compute(20, 6)
    equal(#plan.zones, 0, "zone count")
    check(type(plan.message) == "string", "message is a string")
    check(plan.message:find("20") ~= nil, "message names the actual width")
end)

test("a degenerate screen does not throw", function()
    local plan = layout.compute(5, 3)
    equal(#plan.zones, 0, "zone count")
    check(type(plan.message) == "string", "message present")
end)

test("a zone narrower than its minimum is marked degraded, not garbled", function()
    -- Wide enough to place engines, narrow enough to squeeze it.
    local plan = layout.compute(layout.MINIMUMS.ENGINES.w - 2, 40)
    local engines = byName(plan, "ENGINES")
    if engines then
        equal(engines.degraded, true, "engines degraded flag")
    else
        ok()
    end
end)

test("compute is deterministic", function()
    local first = layout.compute(79, 38)
    local second = layout.compute(79, 38)
    equal(#first.zones, #second.zones, "zone count")
    for i = 1, #first.zones do
        equal(first.zones[i].name, second.zones[i].name, "zone " .. i .. " name")
        equal(first.zones[i].rect.x, second.zones[i].rect.x, "zone " .. i .. " x")
        equal(first.zones[i].rect.y, second.zones[i].rect.y, "zone " .. i .. " y")
        equal(first.zones[i].rect.w, second.zones[i].rect.w, "zone " .. i .. " w")
        equal(first.zones[i].rect.h, second.zones[i].rect.h, "zone " .. i .. " h")
    end
end)

-- ---------------------------------------------------------------------------

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit tools/test_hub_layout.lua
```

Expected: `module 'fcs.hub.layout' not found`.

- [ ] **Step 3: Write `fcs/hub/layout.lua`**

Create `fcs/hub/layout.lua`:

```lua
-- Screen size in, zone rectangles out. No drawing, no state, no CC globals.
--
-- The reflow rule that matters: rather than shrinking every zone until they
-- are all illegible, drop whole zones in reverse priority order until the
-- survivors fit at their minimum size. A missing zone is honest; four
-- unreadable ones are not.

local layout = {}

-- Minimum size at which a zone can render truthfully. Below this it draws its
-- name and the size it wants -- never a partial render.
layout.MINIMUMS = {
    ENGINES = { w = 48, h = 9 },
    PODS = { w = 38, h = 7 },
    ATTITUDE = { w = 28, h = 8 },
    POWER = { w = 22, h = 6 },
}

-- Most important first. ENGINES leads because the per-bearing thrust delta is
-- the reason the wall exists: corner aggregates sum magnitudes and cannot show
-- one bearing of a counter-rotating pair underperforming its twin.
layout.PRIORITY = { "ENGINES", "PODS", "ATTITUDE", "POWER" }

-- Below this width, attitude and power stack instead of pairing.
layout.SIDE_BY_SIDE_WIDTH = 70

-- Extra rows beyond the minimum, handed out in this order while surplus lasts.
local EXTRA_BUDGET = { ENGINES = 3, TOP = 6 }

-- Attitude takes the larger share of a shared top band: it carries a ladder
-- and six numeric rows, where power carries a bar and three.
local ATTITUDE_SHARE = 0.58

local function contains(list, value)
    for _, item in ipairs(list) do
        if item == value then return true end
    end
    return false
end

-- Height the present set needs at minimum size, given how the top band packs.
local function requiredHeight(present, sideBySide)
    local total = 0
    if contains(present, "ENGINES") then
        total = total + layout.MINIMUMS.ENGINES.h
    end
    if contains(present, "PODS") then
        total = total + layout.MINIMUMS.PODS.h
    end

    local attitude = contains(present, "ATTITUDE")
    local power = contains(present, "POWER")
    if attitude and power then
        if sideBySide then
            total = total + math.max(layout.MINIMUMS.ATTITUDE.h, layout.MINIMUMS.POWER.h)
        else
            total = total + layout.MINIMUMS.ATTITUDE.h + layout.MINIMUMS.POWER.h
        end
    elseif attitude then
        total = total + layout.MINIMUMS.ATTITUDE.h
    elseif power then
        total = total + layout.MINIMUMS.POWER.h
    end

    return total
end

local function topBandMinimum(present, sideBySide)
    local attitude = contains(present, "ATTITUDE")
    local power = contains(present, "POWER")
    if not attitude and not power then
        return 0
    end
    if attitude and power then
        if sideBySide then
            return math.max(layout.MINIMUMS.ATTITUDE.h, layout.MINIMUMS.POWER.h)
        end
        return layout.MINIMUMS.ATTITUDE.h + layout.MINIMUMS.POWER.h
    end
    return attitude and layout.MINIMUMS.ATTITUDE.h or layout.MINIMUMS.POWER.h
end

function layout.compute(width, height)
    local plan = {
        width = width,
        height = height,
        zones = {},
        hidden = {},
        message = nil,
    }

    -- One header row, one footer row, and at least the smallest zone between.
    local minimumHeight = 2 + layout.MINIMUMS.POWER.h
    local minimumWidth = layout.MINIMUMS.POWER.w
    if type(width) ~= "number" or type(height) ~= "number"
        or width < minimumWidth or height < minimumHeight then
        plan.message = string.format("screen too small: need %dx%d, have %sx%s",
            minimumWidth, minimumHeight, tostring(width), tostring(height))
        for _, name in ipairs(layout.PRIORITY) do
            plan.hidden[#plan.hidden + 1] = name
        end
        return plan
    end

    plan.header = { x = 1, y = 1, w = width, h = 1 }
    plan.footer = { x = 1, y = height, w = width, h = 1 }

    local bodyTop = 2
    local bodyHeight = height - 2
    local sideBySide = width >= layout.SIDE_BY_SIDE_WIDTH

    -- Start with everything, then drop the least important until it fits both
    -- ways: horizontally at minimum width, and vertically as a set.
    local present = {}
    for _, name in ipairs(layout.PRIORITY) do
        present[#present + 1] = name
    end

    local function drop(name)
        for index, item in ipairs(present) do
            if item == name then
                table.remove(present, index)
                break
            end
        end
        if not contains(plan.hidden, name) then
            plan.hidden[#plan.hidden + 1] = name
        end
    end

    -- Horizontal fit. In a side-by-side band each of the pair gets a share of
    -- the width, so check that share rather than the whole screen.
    for index = #layout.PRIORITY, 1, -1 do
        local name = layout.PRIORITY[index]
        local available = width
        if sideBySide and (name == "ATTITUDE" or name == "POWER") then
            available = name == "ATTITUDE"
                and math.floor(width * ATTITUDE_SHARE)
                or width - math.floor(width * ATTITUDE_SHARE)
        end
        if available < layout.MINIMUMS[name].w then
            drop(name)
        end
    end

    -- Vertical fit, dropping from the end of the priority list.
    for index = #layout.PRIORITY, 1, -1 do
        if requiredHeight(present, sideBySide) <= bodyHeight then
            break
        end
        drop(layout.PRIORITY[index])
    end

    if #present == 0 then
        plan.message = string.format("screen too small: need %dx%d, have %dx%d",
            minimumWidth, minimumHeight, width, height)
        return plan
    end

    -- Hand out the surplus: engines first (more corners' worth of rows), then
    -- the top band, and whatever is left to pods, whose fault list is the one
    -- thing that genuinely grows without bound.
    local surplus = bodyHeight - requiredHeight(present, sideBySide)
    local enginesExtra = 0
    if contains(present, "ENGINES") then
        enginesExtra = math.min(surplus, EXTRA_BUDGET.ENGINES)
        surplus = surplus - enginesExtra
    end
    local topExtra = 0
    if topBandMinimum(present, sideBySide) > 0 then
        topExtra = math.min(surplus, EXTRA_BUDGET.TOP)
        surplus = surplus - topExtra
    end
    local podsExtra = contains(present, "PODS") and surplus or 0

    local topHeight = topBandMinimum(present, sideBySide) + topExtra
    local enginesHeight = contains(present, "ENGINES")
        and layout.MINIMUMS.ENGINES.h + enginesExtra or 0
    local podsHeight = contains(present, "PODS")
        and layout.MINIMUMS.PODS.h + podsExtra or 0

    -- Anything unclaimed (no pods present) goes to whatever is left, so the
    -- body always reaches the row above the footer.
    local claimed = topHeight + enginesHeight + podsHeight
    local leftover = bodyHeight - claimed
    if leftover > 0 then
        if podsHeight > 0 then
            podsHeight = podsHeight + leftover
        elseif enginesHeight > 0 then
            enginesHeight = enginesHeight + leftover
        else
            topHeight = topHeight + leftover
        end
    end

    local function add(name, rect)
        local minimum = layout.MINIMUMS[name]
        plan.zones[#plan.zones + 1] = {
            name = name,
            rect = rect,
            degraded = rect.w < minimum.w or rect.h < minimum.h,
        }
    end

    local y = bodyTop

    if topHeight > 0 then
        local attitude = contains(present, "ATTITUDE")
        local power = contains(present, "POWER")
        if attitude and power and sideBySide then
            local attitudeWidth = math.floor(width * ATTITUDE_SHARE)
            add("ATTITUDE", { x = 1, y = y, w = attitudeWidth, h = topHeight })
            add("POWER", {
                x = attitudeWidth + 1, y = y,
                w = width - attitudeWidth, h = topHeight,
            })
        elseif attitude and power then
            -- Stacked: attitude keeps its share of the band's height.
            local attitudeHeight = math.max(
                layout.MINIMUMS.ATTITUDE.h,
                math.floor(topHeight * ATTITUDE_SHARE))
            attitudeHeight = math.min(attitudeHeight, topHeight - layout.MINIMUMS.POWER.h)
            add("ATTITUDE", { x = 1, y = y, w = width, h = attitudeHeight })
            add("POWER", {
                x = 1, y = y + attitudeHeight,
                w = width, h = topHeight - attitudeHeight,
            })
        elseif attitude then
            add("ATTITUDE", { x = 1, y = y, w = width, h = topHeight })
        elseif power then
            add("POWER", { x = 1, y = y, w = width, h = topHeight })
        end
        y = y + topHeight
    end

    if enginesHeight > 0 then
        add("ENGINES", { x = 1, y = y, w = width, h = enginesHeight })
        y = y + enginesHeight
    end

    if podsHeight > 0 then
        add("PODS", { x = 1, y = y, w = width, h = podsHeight })
        y = y + podsHeight
    end

    return plan
end

return layout
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit tools/test_hub_layout.lua
```

Expected: `N passed, 0 failed`.

- [ ] **Step 5: Checkpoint**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit tools/test_mixer.lua \
  && luajit tools/test_hub_canvas.lua && luajit tools/test_hub_layout.lua
```

Expected: all three report `0 failed`.

---

## Task 4: Widgets

Reusable drawing above `canvas`: title bars, degraded placeholders, nil-safe number formatting, and the four-column grid every corner zone uses. Extracted because all four zones need the same primitives, and a `nil` telemetry field must render as `--` in exactly one place rather than four.

**Files:**
- Create: `fcs/hub/widgets.lua`
- Test: `tools/test_hub_widgets.lua`

**Interfaces:**
- Consumes: `fcs.hub.canvas` (as a passed-in object), `fcs.hub.theme`.
- Produces:
  - `widgets.title(canvas, rect, text, rightText, background)` — draws the zone title bar on `rect.y`; `background` defaults to `theme.titleBackground`
  - `widgets.degraded(canvas, rect, name, minimum)` — draws `NAME needs WxH`
  - `widgets.number(value, format, fallback) -> string` — nil/NaN-safe
  - `widgets.compact(value) -> string` — `1.24M`, `18.4k`, `412`
  - `widgets.duration(ms) -> string` — `120ms`, `6.2s`, `--`
  - `widgets.clip(text, width) -> string`
  - `widgets.columns(rect, labelWidth, count) -> xs, columnWidth`
  - `widgets.row(canvas, rect, y, label, cells, labelWidth)` where `cells` is an array of `{text=, colour=}`
  - `widgets.CORNERS = { "FL", "FR", "RL", "RR" }`

- [ ] **Step 1: Write the failing test**

Create `tools/test_hub_widgets.lua`:

```lua
-- Offline tests for fcs/hub/widgets.lua.
--
--     luajit tools/test_hub_widgets.lua      (from the repo root)

package.path = "./?.lua;" .. package.path

local canvas = require("fcs.hub.canvas")
local widgets = require("fcs.hub.widgets")
local theme = require("fcs.hub.theme")
local fixtures = require("tools.hub_fixtures")

local passed, failed = 0, 0
local currentTest = "<none>"

local function fail(message)
    failed = failed + 1
    print(string.format("  FAIL  %s: %s", currentTest, message))
end

local function ok() passed = passed + 1 end

local function check(condition, message)
    if condition then ok() else fail(message) end
end

local function equal(actual, expected, message)
    if actual ~= expected then
        fail(string.format("%s: expected %s, got %s",
            message, tostring(expected), tostring(actual)))
        return
    end
    ok()
end

local function test(name, body)
    currentTest = name
    local succeeded, err = pcall(body)
    if not succeeded then fail("threw: " .. tostring(err)) end
end

local function surfaceOf(w, h)
    local target = fixtures.target(w, h)
    local surface = canvas.new(target)
    surface:clear(theme.background)
    return surface, target
end

-- ---------------------------------------------------------------------------
-- Nil-safe formatting. Telemetry fields are nil constantly: a pod that is
-- offline reports nothing, and a corner with no bearing reports no thrust.
-- ---------------------------------------------------------------------------

test("number formats a value", function()
    equal(widgets.number(12.345, "%.2f"), "12.35", "formatted")
end)

test("number falls back for nil", function()
    equal(widgets.number(nil, "%.2f"), "--", "nil")
    equal(widgets.number(nil, "%.2f", "n/a"), "n/a", "custom fallback")
end)

test("number falls back for NaN and infinity", function()
    equal(widgets.number(0 / 0, "%.2f"), "--", "NaN")
    equal(widgets.number(1 / 0, "%.2f"), "--", "infinity")
    equal(widgets.number(-1 / 0, "%.2f"), "--", "negative infinity")
end)

test("number falls back for a non-number", function()
    equal(widgets.number("64", "%.1f"), "--", "string")
    equal(widgets.number(true, "%.1f"), "--", "boolean")
    equal(widgets.number({}, "%.1f"), "--", "table")
end)

test("compact scales large values", function()
    equal(widgets.compact(412), "412", "hundreds")
    equal(widgets.compact(18400), "18.4k", "thousands")
    equal(widgets.compact(1240000), "1.24M", "millions")
    equal(widgets.compact(nil), "--", "nil")
end)

test("compact handles negatives and zero", function()
    equal(widgets.compact(0), "0", "zero")
    equal(widgets.compact(-18400), "-18.4k", "negative thousands")
end)

test("duration reads in the unit that fits", function()
    equal(widgets.duration(120), "120ms", "milliseconds")
    equal(widgets.duration(6200), "6.2s", "seconds")
    equal(widgets.duration(nil), "--", "nil")
end)

test("clip truncates rather than overflowing", function()
    equal(widgets.clip("ABCDEFGH", 4), "ABCD", "truncated")
    equal(widgets.clip("AB", 4), "AB", "short text untouched")
    equal(widgets.clip(nil, 4), "", "nil")
end)

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------

test("title draws on the first row of the rect", function()
    local surface, target = surfaceOf(40, 6)
    widgets.title(surface, { x = 1, y = 2, w = 40, h = 5 }, "ENGINES")
    surface:flush()
    check(target.rowText(2):find("ENGINES") ~= nil, "title text present")
    equal(target.rowText(1):find("ENGINES"), nil, "nothing drawn above the rect")
end)

test("title right-aligns its second string", function()
    local surface, target = surfaceOf(40, 6)
    widgets.title(surface, { x = 1, y = 1, w = 40, h = 5 }, "PODS", "4 UP")
    surface:flush()
    local row = target.rowText(1)
    check(row:find("PODS") ~= nil, "left text")
    check(row:find("4 UP") ~= nil, "right text")
    check(row:find("4 UP") > row:find("PODS"), "right text is to the right")
end)

test("title honours a background override", function()
    local surface, target = surfaceOf(40, 4)
    widgets.title(surface, { x = 1, y = 1, w = 40, h = 3 }, "FCS-DEV", "LIVE",
        theme.colours.red)
    surface:flush()
    equal(target.cells[1][1].bg, "e", "header bar painted red")
end)

test("title never writes outside the rect", function()
    local surface, target = surfaceOf(20, 4)
    widgets.title(surface, { x = 5, y = 2, w = 10, h = 2 },
        "AVERYLONGTITLETHATOVERFLOWS", "ALSOLONG")
    surface:flush()
    equal(target.rowText(2):sub(1, 4), "    ", "left of the rect untouched")
    equal(target.rowText(2):sub(15, 20), "      ", "right of the rect untouched")
end)

test("degraded states the zone and the size it needs", function()
    local surface, target = surfaceOf(30, 6)
    widgets.degraded(surface, { x = 1, y = 1, w = 30, h = 4 },
        "ENGINES", { w = 48, h = 9 })
    surface:flush()
    local joined = table.concat(target.rows(), "\n")
    check(joined:find("ENGINES") ~= nil, "zone name")
    check(joined:find("48") ~= nil, "needed width")
    check(joined:find("9") ~= nil, "needed height")
end)

test("degraded fits inside a one-row rect without throwing", function()
    local surface = surfaceOf(30, 3)
    widgets.degraded(surface, { x = 1, y = 1, w = 30, h = 1 },
        "POWER", { w = 22, h = 6 })
    surface:flush()
    ok()
end)

test("columns divide the rect evenly after the label gutter", function()
    local xs, columnWidth = widgets.columns({ x = 1, y = 1, w = 79, h = 10 }, 15, 4)
    equal(#xs, 4, "column count")
    equal(xs[1], 16, "first column starts after the label gutter")
    check(columnWidth >= 15, "columns are wide enough to be useful")
    check(xs[4] + columnWidth - 1 <= 79, "last column stays inside the rect")
    for i = 2, 4 do
        equal(xs[i] - xs[i - 1], columnWidth, "even spacing at column " .. i)
    end
end)

test("columns degrade rather than going negative on a narrow rect", function()
    local xs, columnWidth = widgets.columns({ x = 1, y = 1, w = 20, h = 4 }, 15, 4)
    equal(#xs, 4, "column count")
    check(columnWidth >= 1, "column width stays positive")
end)

test("row draws a label and one cell per column", function()
    local surface, target = surfaceOf(60, 5)
    local rect = { x = 1, y = 1, w = 60, h = 5 }
    widgets.row(surface, rect, 2, "target rpm", {
        { text = "64" }, { text = "64" }, { text = "64" }, { text = "64" },
    }, 14)
    surface:flush()
    local row = target.rowText(2)
    check(row:find("target rpm") ~= nil, "label present")
    local count = 0
    for _ in row:gmatch("64") do count = count + 1 end
    equal(count, 4, "one value per corner")
end)

test("row clips cell text to the column width", function()
    local surface, target = surfaceOf(40, 4)
    local rect = { x = 1, y = 1, w = 40, h = 4 }
    widgets.row(surface, rect, 1, "label", {
        { text = "AAAAAAAAAAAAAAAAAAAA" }, { text = "B" },
        { text = "C" }, { text = "D" },
    }, 10)
    surface:flush()
    equal(#target.rowText(1), 40, "row length unchanged")
    check(target.rowText(1):find("B") ~= nil, "later columns are not overwritten")
end)

test("row tolerates missing cells", function()
    local surface = surfaceOf(60, 4)
    widgets.row(surface, { x = 1, y = 1, w = 60, h = 4 }, 1, "label",
        { { text = "1" }, nil, { text = "3" } }, 12)
    surface:flush()
    ok()
end)

test("row outside the rect is dropped", function()
    local surface, target = surfaceOf(40, 6)
    widgets.row(surface, { x = 1, y = 2, w = 40, h = 2 }, 9, "label",
        { { text = "X" } }, 10)
    surface:flush()
    for y = 1, 6 do
        equal(target.rowText(y):find("label"), nil, "nothing drawn at row " .. y)
    end
end)

-- ---------------------------------------------------------------------------

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit tools/test_hub_widgets.lua
```

Expected: `module 'fcs.hub.widgets' not found`.

- [ ] **Step 3: Write `fcs/hub/widgets.lua`**

Create `fcs/hub/widgets.lua`:

```lua
-- Drawing primitives shared by the zone modules, one layer above canvas.
--
-- The formatting helpers matter more than the drawing ones. Telemetry fields
-- are nil constantly -- an offline pod reports nothing, a corner with no
-- bearing reports no thrust -- and string.format("%.1f", nil) throws. Every
-- number reaching the screen goes through widgets.number so that a missing
-- value renders as "--" in one place instead of four.

local theme = require("fcs.hub.theme")

local widgets = {}

widgets.CORNERS = { "FL", "FR", "RL", "RR" }

widgets.MISSING = "--"

local function isFinite(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

widgets.isFinite = isFinite

function widgets.number(value, format, fallback)
    if not isFinite(value) then
        return fallback or widgets.MISSING
    end
    return string.format(format or "%.2f", value)
end

function widgets.compact(value)
    if not isFinite(value) then
        return widgets.MISSING
    end
    local sign = value < 0 and "-" or ""
    local magnitude = math.abs(value)
    if magnitude >= 1000000 then
        return string.format("%s%.2fM", sign, magnitude / 1000000)
    elseif magnitude >= 1000 then
        return string.format("%s%.1fk", sign, magnitude / 1000)
    end
    return string.format("%s%d", sign, math.floor(magnitude + 0.5))
end

function widgets.duration(ms)
    if not isFinite(ms) then
        return widgets.MISSING
    end
    if ms < 1000 then
        return string.format("%dms", math.floor(ms + 0.5))
    end
    return string.format("%.1fs", ms / 1000)
end

function widgets.clip(text, width)
    if type(text) ~= "string" then
        return ""
    end
    if width == nil or #text <= width then
        return text
    end
    if width <= 0 then
        return ""
    end
    return text:sub(1, width)
end

-- A zone header: name on the left, an optional summary on the right, drawn as
-- an inverted bar so the eye can find zone boundaries on a wall without box
-- glyphs (CC's font has no reliable line-drawing characters).
-- background overrides the default bar colour. run.lua uses it to paint the
-- header by freshness, so a dead feed is a red band across the top of the wall
-- rather than a word someone has to be close enough to read.
function widgets.title(canvas, rect, text, rightText, background)
    local bar = background or theme.titleBackground
    canvas:fill(rect.x, rect.y, rect.w, 1, bar)
    canvas:text(rect.x + 1, rect.y,
        widgets.clip(text, rect.w - 2), theme.titleForeground, bar)

    if type(rightText) == "string" and rightText ~= "" then
        local clipped = widgets.clip(rightText, math.max(0, rect.w - #text - 4))
        if #clipped > 0 then
            canvas:text(rect.x + rect.w - #clipped - 1, rect.y,
                clipped, theme.titleForeground, bar)
        end
    end
end

-- What a zone draws when its rect is below its minimum: the name and the size
-- it wants. Never a partial render -- a half-drawn engine strip is worse than
-- an absent one, because it looks like data.
function widgets.degraded(canvas, rect, name, minimum)
    canvas:fill(rect.x, rect.y, rect.w, rect.h, theme.background)
    canvas:text(rect.x, rect.y,
        widgets.clip(name, rect.w), theme.status("warn"), theme.background)
    if rect.h >= 2 then
        canvas:text(rect.x, rect.y + 1,
            widgets.clip(string.format("needs %dx%d", minimum.w, minimum.h), rect.w),
            theme.label, theme.background)
    end
end

-- Column geometry for the four-corner zones. Returns the x of each column and
-- the width each one may use.
function widgets.columns(rect, labelWidth, count)
    local available = rect.w - labelWidth
    local columnWidth = math.floor(available / count)
    if columnWidth < 1 then
        columnWidth = 1
    end
    local xs = {}
    for i = 1, count do
        xs[i] = rect.x + labelWidth + (i - 1) * columnWidth
    end
    return xs, columnWidth
end

-- One labelled row of per-column values. cells is an array of {text=, colour=};
-- a nil entry leaves its column blank rather than shifting the others.
function widgets.row(canvas, rect, y, label, cells, labelWidth)
    if y < rect.y or y > rect.y + rect.h - 1 then
        return
    end

    canvas:text(rect.x, y,
        widgets.clip(label, labelWidth - 1), theme.label, theme.background)

    local count = #widgets.CORNERS
    local xs, columnWidth = widgets.columns(rect, labelWidth, count)
    for i = 1, count do
        local cell = cells[i]
        if cell and type(cell.text) == "string" then
            canvas:text(xs[i], y,
                widgets.clip(cell.text, columnWidth - 1),
                cell.colour or theme.foreground, theme.background)
        end
    end
end

return widgets
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit tools/test_hub_widgets.lua
```

Expected: `N passed, 0 failed`.

- [ ] **Step 5: Checkpoint**

```bash
cd ~/repos/fcs-wireless-pods-v2 && for t in mixer hub_canvas hub_layout hub_widgets; do \
  echo "== $t"; luajit tools/test_$t.lua || exit 1; done
```

Expected: every suite reports `0 failed`.

---

## Task 5: Snapshot build

The interface between the logger and the hub. `build` is pure — it takes the three tables `sample()` already holds and returns a fresh frame. It performs no reads and touches no ComputerCraft global, so it is testable under `luajit`.

Note a refinement on the spec: `build` takes a single **context table** rather than eight positional arguments. Eight positionals of which four are tables is an argument-order bug waiting to happen, and the caller in Task 6 reads better this way.

**Files:**
- Create: `fcs/snapshot.lua` (build half only — `publish` lands in Task 6)
- Test: `tools/test_snapshot.lua`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `snapshot.VERSION = 1`
  - `snapshot.build(context) -> frame`, where `context` is
    ```lua
    { sequence=, timestamp=, dt=, state=, peripheralState=, podStates=,
      netStats=, log= }
    ```
    and `frame` matches the schema in the spec's "Snapshot contract".
  - `snapshot.CORNERS = { "FL", "FR", "RL", "RR" }`
  - `snapshot.BEARINGS_PER_CORNER = 2`
- **Critical:** `build` must copy scalars into fresh tables and never retain a reference to `podStates`. `banks.acceptStatus` mutates its pod tables in place every time a message lands, so a frame holding references would tear halfway through a render.

- [ ] **Step 1: Write the failing test**

Create `tools/test_snapshot.lua`:

```lua
-- Offline tests for fcs/snapshot.lua (the build half).
--
--     luajit tools/test_snapshot.lua      (from the repo root)

package.path = "./?.lua;" .. package.path

local snapshot = require("fcs.snapshot")

local passed, failed = 0, 0
local currentTest = "<none>"

local function fail(message)
    failed = failed + 1
    print(string.format("  FAIL  %s: %s", currentTest, message))
end

local function ok() passed = passed + 1 end

local function check(condition, message)
    if condition then ok() else fail(message) end
end

local function equal(actual, expected, message)
    if actual ~= expected then
        fail(string.format("%s: expected %s, got %s",
            message, tostring(expected), tostring(actual)))
        return
    end
    ok()
end

local function test(name, body)
    currentTest = name
    local succeeded, err = pcall(body)
    if not succeeded then fail("threw: " .. tostring(err)) end
end

-- ---------------------------------------------------------------------------
-- Fabricated inputs, shaped exactly like what fcs/main.lua holds at the point
-- it will call publish: sensors.read, devices.read, banks.getState.
-- ---------------------------------------------------------------------------

local function sampleState()
    return {
        valid = true,
        errors = {},
        uuid = "abc-123",
        name = "Helicarrier",
        position = { x = 10.5, y = 82.0, z = -3.25 },
        linearVelocityBody = { x = 0.1, y = -0.02, z = 0.0 },
        linearVelocityWorld = { x = 0.1, y = -0.02, z = 0.0 },
        angularVelocityBody = { x = 0.0, y = 0.01, z = 0.0 },
        roll = 1.23, pitch = -0.4, yaw = 271.5,
        mass = 41250.0,
        airPressure = 0.86,
    }
end

local function samplePeripheralState()
    return {
        valid = true,
        errors = { "RR pod: thruster_7 unresponsive" },
        energy = 1240000, energyCapacity = 2000000,
        gridPower = 18400, gridVoltage = 240, gridAmperage = 76,
        props = {
            FL = { controllerPresent = true, bearingPresent = true,
                targetRpm = 64, controllerRpm = 63.8, bearingRpm = 4.8,
                thrust = 27921.9, thrustImbalance = 0.4, airflow = 12.0,
                sailPower = 267, hasSource = true, overstressed = false,
                active = true,
                perBearing = {
                    { thrust = 13960.98, assembled = true },
                    { thrust = 13960.92, assembled = true },
                },
                tilt = 0.0, tiltAzimuth = 0.0 },
            FR = { controllerPresent = true, bearingPresent = true,
                targetRpm = 64, controllerRpm = 64.0, thrust = 27921.9,
                perBearing = { { thrust = 13960.98 }, { thrust = 13960.92 } } },
            RL = { controllerPresent = true, bearingPresent = true,
                targetRpm = 64, controllerRpm = 63.9, thrust = 27921.9,
                perBearing = { { thrust = 13960.98 }, { thrust = 13960.92 } } },
            RR = { controllerPresent = true, bearingPresent = true,
                targetRpm = 64, controllerRpm = 64.0, thrust = 27765.4,
                perBearing = { { thrust = 13960.98 }, { thrust = 13804.41 } } },
        },
    }
end

local function samplePodStates()
    local pods = {}
    for _, corner in ipairs({ "FL", "FR", "RL", "RR" }) do
        pods[corner] = {
            corner = corner,
            hostname = "ENG-" .. corner,
            online = true,
            podId = 20,
            armed = true,
            currentPower = 0.45,
            fallbackPower = 0.0,
            healthyThrusters = 20,
            expectedThrusters = 20,
            obstructedThrusters = 0,
            totalThrustKN = 900.0,
            averagePower = 0.45,
            energyFE = 400000,
            energyCapacityFE = 500000,
            receivedAt = 1787670000000 - 120,
            faults = {},
            commandsSeen = 412, commandsApplied = 412, commandsRejected = 0,
            bootedAt = 1787660000000,
        }
    end
    pods.RR.faults = { "thruster_7 unresponsive" }
    pods.RL.online = false
    pods.RL.receivedAt = 1787670000000 - 6200
    return pods
end

local function sampleContext()
    return {
        sequence = 12481,
        timestamp = 1787670000000,
        dt = 0.26,
        state = sampleState(),
        peripheralState = samplePeripheralState(),
        podStates = samplePodStates(),
        netStats = {
            seen = 5000, accepted = 4980, badProtocol = 2, wrongType = 0,
            unknownCorner = 0, hostnameMismatch = 0, senderMismatch = 18,
            perCorner = { FL = 1250, FR = 1250, RL = 1230, RR = 1250 },
        },
        log = {
            path = "/fcs/logs/flight_1787670000000.csv",
            bytes = 412000, samples = 12481,
            targetHz = 4.0, actualHz = 3.85, freeSpace = 9000000,
        },
    }
end

-- ---------------------------------------------------------------------------

test("stamps the schema version", function()
    equal(snapshot.build(sampleContext()).v, snapshot.VERSION, "v")
    equal(snapshot.VERSION, 1, "VERSION constant")
end)

test("carries the sample identity", function()
    local frame = snapshot.build(sampleContext())
    equal(frame.sequence, 12481, "sequence")
    equal(frame.utc_ms, 1787670000000, "utc_ms")
    equal(frame.dt_s, 0.26, "dt_s")
    equal(frame.valid, true, "valid")
end)

test("valid is false when either half is invalid", function()
    local context = sampleContext()
    context.state.valid = false
    equal(snapshot.build(context).valid, false, "state invalid")

    context = sampleContext()
    context.peripheralState.valid = false
    equal(snapshot.build(context).valid, false, "peripheral invalid")
end)

test("merges errors from both halves", function()
    local context = sampleContext()
    context.state.errors = { "sable timeout" }
    local frame = snapshot.build(context)
    equal(#frame.errors, 2, "error count")
    check(frame.errors[1]:find("sable") or frame.errors[2]:find("sable"),
        "state error carried")
end)

test("copies craft state", function()
    local frame = snapshot.build(sampleContext())
    equal(frame.craft.roll, 1.23, "roll")
    equal(frame.craft.pitch, -0.4, "pitch")
    equal(frame.craft.yaw, 271.5, "yaw")
    equal(frame.craft.position.y, 82.0, "altitude")
    equal(frame.craft.bodyVel.x, 0.1, "body velocity x")
    equal(frame.craft.mass, 41250.0, "mass")
end)

test("copies every corner with both bearings", function()
    local frame = snapshot.build(sampleContext())
    for _, corner in ipairs(snapshot.CORNERS) do
        local entry = frame.corners[corner]
        check(entry ~= nil, corner .. " present")
        equal(#entry.bearings, snapshot.BEARINGS_PER_CORNER, corner .. " bearing count")
    end
    equal(frame.corners.RR.bearings[2].thrust, 13804.41, "RR bearing 2 thrust")
    equal(frame.corners.FL.targetRpm, 64, "FL target rpm")
end)

test("a corner missing a bearing leaves an empty slot, not a short row", function()
    local context = sampleContext()
    context.peripheralState.props.FR.perBearing = { { thrust = 13960.98 } }
    local frame = snapshot.build(context)
    equal(#frame.corners.FR.bearings, snapshot.BEARINGS_PER_CORNER, "slot count")
    equal(frame.corners.FR.bearings[2].thrust, nil, "empty slot has no thrust")
end)

test("copies pod state including age", function()
    local frame = snapshot.build(sampleContext())
    equal(frame.pods.FL.online, true, "FL online")
    equal(frame.pods.FL.ageMs, 120, "FL age")
    equal(frame.pods.RL.online, false, "RL offline")
    equal(frame.pods.RL.ageMs, 6200, "RL age")
    equal(frame.pods.FL.healthyThrusters, 20, "healthy thrusters")
    equal(frame.pods.RR.faults[1], "thruster_7 unresponsive", "fault text")
end)

test("a pod that has never reported has a nil age rather than a wrong one", function()
    local context = sampleContext()
    context.podStates.FR.receivedAt = nil
    local frame = snapshot.build(context)
    equal(frame.pods.FR.ageMs, nil, "age")
end)

test("copies power and network and log blocks", function()
    local frame = snapshot.build(sampleContext())
    equal(frame.power.storedFE, 1240000, "stored FE")
    equal(frame.power.gridVoltage, 240, "voltage")
    equal(frame.net.accepted, 4980, "accepted")
    equal(frame.net.senderMismatch, 18, "sender mismatch")
    equal(frame.net.perCorner.RL, 1230, "per corner")
    equal(frame.log.samples, 12481, "log samples")
    equal(frame.log.actualHz, 3.85, "actual Hz")
end)

-- ---------------------------------------------------------------------------
-- Isolation. banks.acceptStatus writes into its pod tables in place on every
-- message, so a frame holding references would tear mid-render.
-- ---------------------------------------------------------------------------

test("the frame does not alias the pod state tables", function()
    local context = sampleContext()
    local frame = snapshot.build(context)
    check(frame.pods.FL ~= context.podStates.FL, "pod table is a copy")
    context.podStates.FL.currentPower = 0.99
    equal(frame.pods.FL.currentPower, 0.45, "frame value unchanged by later mutation")
end)

test("the frame does not alias the fault arrays", function()
    local context = sampleContext()
    local frame = snapshot.build(context)
    check(frame.pods.RR.faults ~= context.podStates.RR.faults, "faults is a copy")
    table.insert(context.podStates.RR.faults, "new fault")
    equal(#frame.pods.RR.faults, 1, "frame fault count unchanged")
end)

test("the frame does not alias corner or vector tables", function()
    local context = sampleContext()
    local frame = snapshot.build(context)
    check(frame.corners.FL ~= context.peripheralState.props.FL, "corner is a copy")
    context.state.position.y = 999
    equal(frame.craft.position.y, 82.0, "position is a copy")
end)

-- ---------------------------------------------------------------------------
-- Hostile inputs. A frame must be buildable from whatever the loop is holding
-- during a bad tick, because a bad tick is exactly when the wall is read.
-- ---------------------------------------------------------------------------

test("builds from an empty context without throwing", function()
    local frame = snapshot.build({})
    equal(frame.v, snapshot.VERSION, "version")
    for _, corner in ipairs(snapshot.CORNERS) do
        check(frame.corners[corner] ~= nil, corner .. " corner present")
        check(frame.pods[corner] ~= nil, corner .. " pod present")
    end
    equal(frame.pods.FL.online, false, "unknown pod defaults to offline")
end)

test("builds when sensors returned nothing", function()
    local context = sampleContext()
    context.state = { valid = false, errors = { "no craft" } }
    local frame = snapshot.build(context)
    equal(frame.craft.roll, nil, "roll")
    equal(frame.craft.position, nil, "position")
    equal(frame.valid, false, "valid")
end)

test("builds when a pod reports a fault string instead of an array", function()
    local context = sampleContext()
    context.podStates.FL.faults = "single fault"
    local frame = snapshot.build(context)
    equal(frame.pods.FL.faults[1], "single fault", "coerced to an array")
end)

test("builds when props are missing entirely", function()
    local context = sampleContext()
    context.peripheralState.props = nil
    local frame = snapshot.build(context)
    for _, corner in ipairs(snapshot.CORNERS) do
        check(frame.corners[corner] ~= nil, corner .. " present")
        equal(frame.corners[corner].targetRpm, nil, corner .. " target rpm")
    end
end)

test("builds when netStats and log are absent", function()
    local context = sampleContext()
    context.netStats = nil
    context.log = nil
    local frame = snapshot.build(context)
    check(type(frame.net) == "table", "net is a table")
    check(type(frame.log) == "table", "log is a table")
    equal(frame.net.accepted, nil, "absent counter is nil, not zero")
end)

-- ---------------------------------------------------------------------------

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit tools/test_snapshot.lua
```

Expected: `module 'fcs.snapshot' not found`.

- [ ] **Step 3: Write `fcs/snapshot.lua`**

Create `fcs/snapshot.lua`:

```lua
-- The interface between the telemetry loop and the monitor hub.
--
-- build() takes the three tables fcs/main.lua already holds each sample and
-- returns a fresh frame. It reads nothing itself: there is exactly one place
-- on this computer that talks to CC:Sable and to the pods, and it is the
-- sample loop. A second reader would duplicate ~50 ms of Sable calls on a loop
-- that already cannot hold its declared period.
--
-- Everything is COPIED. banks.acceptStatus writes into its pod tables in place
-- on every message that lands, so a frame that held references would tear
-- halfway through a render -- roll from one tick, thrust from the next.
--
-- publish() is added in the next task; this half stays free of ComputerCraft
-- globals so tools/test_snapshot.lua can run it under plain luajit.

local snapshot = {}

snapshot.VERSION = 1

snapshot.CORNERS = { "FL", "FR", "RL", "RR" }

-- Fixed at 2, matching BEARINGS_PER_CORNER in fcs/main.lua: a corner that
-- loses a bearing must leave an empty slot, not silently shorten the row.
snapshot.BEARINGS_PER_CORNER = 2

local function copyVector(vector)
    if type(vector) ~= "table" then
        return nil
    end
    return { x = vector.x, y = vector.y, z = vector.z }
end

local function copyList(list)
    local out = {}
    if type(list) == "table" then
        for index, value in ipairs(list) do
            out[index] = value
        end
    elseif type(list) == "string" and list ~= "" then
        -- A pod that reports a single fault as a bare string still belongs on
        -- the wall.
        out[1] = list
    end
    return out
end

local function buildCraft(state)
    state = state or {}
    return {
        uuid = state.uuid,
        name = state.name,
        position = copyVector(state.position),
        roll = state.roll,
        pitch = state.pitch,
        yaw = state.yaw,
        bodyVel = copyVector(state.linearVelocityBody),
        worldVel = copyVector(state.linearVelocityWorld),
        angVel = copyVector(state.angularVelocityBody),
        mass = state.mass,
        airPressure = state.airPressure,
    }
end

local function buildCorner(prop)
    prop = prop or {}
    local bearings = {}
    local source = type(prop.perBearing) == "table" and prop.perBearing or {}
    for index = 1, snapshot.BEARINGS_PER_CORNER do
        local bearing = source[index] or {}
        bearings[index] = {
            thrust = bearing.thrust,
            assembled = bearing.assembled,
        }
    end

    return {
        controllerPresent = prop.controllerPresent,
        bearingPresent = prop.bearingPresent,
        controllerName = prop.controllerName,
        bearingName = prop.bearingName,
        targetRpm = prop.targetRpm,
        controllerRpm = prop.controllerRpm,
        bearingRpm = prop.bearingRpm,
        thrust = prop.thrust,
        thrustImbalance = prop.thrustImbalance,
        airflow = prop.airflow,
        sailPower = prop.sailPower,
        hasSource = prop.hasSource,
        overstressed = prop.overstressed,
        active = prop.active,
        bearings = bearings,
        tilt = prop.tilt,
        tiltAzimuth = prop.tiltAzimuth,
    }
end

local function buildPod(pod, timestamp)
    pod = pod or {}
    local ageMs = nil
    if type(pod.receivedAt) == "number" and type(timestamp) == "number" then
        ageMs = timestamp - pod.receivedAt
    end

    return {
        corner = pod.corner,
        hostname = pod.hostname,
        online = pod.online == true,
        podId = pod.podId,
        armed = pod.armed,
        currentPower = pod.currentPower,
        fallbackPower = pod.fallbackPower,
        commandedTilt = pod.commandedTilt,
        commandedTiltAzimuth = pod.commandedTiltAzimuth,
        healthyThrusters = pod.healthyThrusters,
        expectedThrusters = pod.expectedThrusters,
        obstructedThrusters = pod.obstructedThrusters,
        totalThrustKN = pod.totalThrustKN,
        averagePower = pod.averagePower,
        energyFE = pod.energyFE,
        energyCapacityFE = pod.energyCapacityFE,
        ageMs = ageMs,
        faults = copyList(pod.faults),
        commandsSeen = pod.commandsSeen,
        commandsApplied = pod.commandsApplied,
        commandsRejected = pod.commandsRejected,
        lastReject = pod.lastReject,
        bootedAt = pod.bootedAt,
    }
end

function snapshot.build(context)
    context = context or {}
    local state = context.state or {}
    local peripheralState = context.peripheralState or {}
    local podStates = context.podStates or {}
    local props = peripheralState.props or {}
    local netStats = context.netStats or {}
    local log = context.log or {}

    local errors = {}
    for _, message in ipairs(state.errors or {}) do
        errors[#errors + 1] = message
    end
    for _, message in ipairs(peripheralState.errors or {}) do
        errors[#errors + 1] = message
    end

    local frame = {
        v = snapshot.VERSION,
        utc_ms = context.timestamp,
        sequence = context.sequence,
        dt_s = context.dt,
        valid = (state.valid == true) and (peripheralState.valid == true),
        errors = errors,
        craft = buildCraft(state),
        corners = {},
        pods = {},
        power = {
            storedFE = peripheralState.energy,
            capacityFE = peripheralState.energyCapacity,
            gridPower = peripheralState.gridPower,
            gridVoltage = peripheralState.gridVoltage,
            gridAmperage = peripheralState.gridAmperage,
        },
        net = {
            seen = netStats.seen,
            accepted = netStats.accepted,
            badProtocol = netStats.badProtocol,
            wrongType = netStats.wrongType,
            unknownCorner = netStats.unknownCorner,
            hostnameMismatch = netStats.hostnameMismatch,
            senderMismatch = netStats.senderMismatch,
            perCorner = {
                FL = (netStats.perCorner or {}).FL,
                FR = (netStats.perCorner or {}).FR,
                RL = (netStats.perCorner or {}).RL,
                RR = (netStats.perCorner or {}).RR,
            },
        },
        log = {
            path = log.path,
            bytes = log.bytes,
            samples = log.samples,
            targetHz = log.targetHz,
            actualHz = log.actualHz,
            freeSpace = log.freeSpace,
        },
    }

    for _, corner in ipairs(snapshot.CORNERS) do
        frame.corners[corner] = buildCorner(props[corner])
        frame.pods[corner] = buildPod(podStates[corner], context.timestamp)
    end

    return frame
end

return snapshot
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit tools/test_snapshot.lua
```

Expected: `N passed, 0 failed`.

- [ ] **Step 5: Checkpoint**

```bash
cd ~/repos/fcs-wireless-pods-v2 && for t in mixer hub_canvas hub_layout hub_widgets snapshot; do \
  echo "== $t"; luajit tools/test_$t.lua || exit 1; done
```

Expected: every suite reports `0 failed`.

---

## Task 6: Snapshot publish and logger integration

Adds the ComputerCraft-facing half of `fcs/snapshot.lua` and wires it into the sample loop. This is the only task that touches the hot path, so the guard rails matter more than the feature.

**Files:**
- Modify: `fcs/snapshot.lua` (append `publish`, `read`, and their state)
- Modify: `fcs/main.lua:18` (require), `fcs/main.lua:304` (publish call), `fcs/main.lua:314-330` (heartbeat counter)
- Test: `tools/test_snapshot.lua` (append a publish section)

**Interfaces:**
- Consumes: `snapshot.build` from Task 5.
- Produces:
  - `snapshot.publish(frame) -> ok, err` — queues `fcs_snapshot`, throttled disk write
  - `snapshot.read() -> frame|nil, err` — hub-side cold-start read, used by Task 11
  - `snapshot.PATH = "/fcs/snapshot.dat"`
  - `snapshot.DISK_PERIOD_MS = 2000`
  - `snapshot.failures`, `snapshot.publishes`, `snapshot.lastError`

- [ ] **Step 1: Write the failing publish tests**

Append to `tools/test_snapshot.lua`, immediately **before** the final `print(...)` / `os.exit(...)` lines:

```lua
-- ---------------------------------------------------------------------------
-- publish(). Exercised with fake fs/textutils globals, because the guarantee
-- under test is "a publish failure never reaches the caller" -- and the only
-- way to prove that is to make it fail.
-- ---------------------------------------------------------------------------

local function fakeFilesystem()
    local disk = { files = {}, opens = 0, failNextOpen = false }

    local fs = {}
    function fs.open(path, mode)
        disk.opens = disk.opens + 1
        if disk.failNextOpen then
            disk.failNextOpen = false
            return nil
        end
        if mode == "r" then
            local content = disk.files[path]
            if not content then return nil end
            return {
                readAll = function() return content end,
                close = function() end,
            }
        end
        local buffer = {}
        return {
            -- CC file handles are called with a dot, not a colon: the code
            -- under test does file.write(text), so text is the FIRST argument.
            -- Getting this wrong makes the handle silently write nothing and
            -- every "file written" assertion pass against an empty string.
            write = function(text)
                buffer[#buffer + 1] = tostring(text)
            end,
            close = function()
                disk.files[path] = table.concat(buffer)
            end,
        }
    end
    function fs.exists(path) return disk.files[path] ~= nil end
    function fs.delete(path) disk.files[path] = nil end
    function fs.move(from, to)
        disk.files[to] = disk.files[from]
        disk.files[from] = nil
    end
    function fs.getFreeSpace() return 9000000 end

    return fs, disk
end

local function withFakeCC(body)
    local savedFs, savedTextutils, savedQueue = _G.fs, _G.textutils, os.queueEvent
    local fs, disk = fakeFilesystem()
    local queued = {}

    _G.fs = fs
    _G.textutils = {
        serialize = function(value) return "SERIALIZED:" .. tostring(value.sequence) end,
        unserialize = function(text) return { v = 1, marker = text } end,
    }
    os.queueEvent = function(name, payload)
        queued[#queued + 1] = { name = name, payload = payload }
    end

    local succeeded, err = pcall(body, disk, queued)

    _G.fs, _G.textutils, os.queueEvent = savedFs, savedTextutils, savedQueue
    if not succeeded then error(err, 0) end
end

local function resetPublishState()
    snapshot.failures = 0
    snapshot.publishes = 0
    snapshot.lastDiskWriteAt = nil
    snapshot.lastError = nil
end

test("publish queues an fcs_snapshot event carrying the frame", function()
    withFakeCC(function(disk, queued)
        resetPublishState()
        local frame = snapshot.build(sampleContext())
        snapshot.publish(frame)
        equal(#queued, 1, "events queued")
        equal(queued[1].name, "fcs_snapshot", "event name")
        equal(queued[1].payload.sequence, 12481, "payload carries the frame")
    end)
end)

test("publish writes the snapshot file on the first call", function()
    withFakeCC(function(disk)
        resetPublishState()
        snapshot.publish(snapshot.build(sampleContext()))
        check(disk.files[snapshot.PATH] ~= nil, "snapshot file written")
        equal(disk.files[snapshot.PATH], "SERIALIZED:12481",
            "the serialized frame actually reached the file")
    end)
end)

test("publish throttles the disk write but never the event", function()
    withFakeCC(function(disk, queued)
        resetPublishState()
        local context = sampleContext()
        snapshot.publish(snapshot.build(context))
        local opensAfterFirst = disk.opens

        -- 250 ms later: same second, well inside DISK_PERIOD_MS.
        context.timestamp = context.timestamp + 250
        context.sequence = context.sequence + 1
        snapshot.publish(snapshot.build(context))

        equal(disk.opens, opensAfterFirst, "no second disk write inside the window")
        equal(#queued, 2, "both events still queued")

        -- Past the window.
        context.timestamp = context.timestamp + snapshot.DISK_PERIOD_MS
        snapshot.publish(snapshot.build(context))
        check(disk.opens > opensAfterFirst, "disk write resumes after the window")
    end)
end)

test("publish writes via a temporary file so a reader never sees half a frame", function()
    withFakeCC(function(disk)
        resetPublishState()
        snapshot.publish(snapshot.build(sampleContext()))
        equal(disk.files[snapshot.PATH .. ".tmp"], nil, "temporary file was moved, not left")
        check(disk.files[snapshot.PATH] ~= nil, "final file present")
    end)
end)

test("a disk failure is counted and swallowed, never raised", function()
    withFakeCC(function(disk)
        resetPublishState()
        disk.failNextOpen = true
        local ok = snapshot.publish(snapshot.build(sampleContext()))
        equal(ok, false, "publish reports failure")
        equal(snapshot.failures, 1, "failure counted")
        check(type(snapshot.lastError) == "string", "error recorded")
    end)
end)

test("publish tolerates a frame with no timestamp", function()
    withFakeCC(function(_, queued)
        resetPublishState()
        snapshot.publish({ v = 1 })
        equal(#queued, 1, "event still queued")
        equal(snapshot.failures, 0, "no failure counted")
    end)
end)

test("publish does nothing harmful with no ComputerCraft globals at all", function()
    resetPublishState()
    local ok = snapshot.publish(snapshot.build(sampleContext()))
    equal(ok, true, "publish succeeds as a no-op off-server")
    equal(snapshot.failures, 0, "no failure counted")
end)

test("read returns nil when there is no snapshot file", function()
    withFakeCC(function()
        resetPublishState()
        local frame, reason = snapshot.read()
        equal(frame, nil, "frame")
        check(type(reason) == "string", "reason given")
    end)
end)

test("read returns the deserialized frame when the file exists", function()
    withFakeCC(function()
        resetPublishState()
        snapshot.publish(snapshot.build(sampleContext()))
        local frame = snapshot.read()
        check(type(frame) == "table", "frame is a table")
        equal(frame.v, 1, "version")
    end)
end)
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit tools/test_snapshot.lua
```

Expected: failures reporting `attempt to call field 'publish' (a nil value)`.

- [ ] **Step 3: Append the publish half to `fcs/snapshot.lua`**

Add to `fcs/snapshot.lua`, immediately **before** the final `return snapshot`:

```lua
-- ---------------------------------------------------------------------------
-- ComputerCraft side. Everything below guards its globals so the module still
-- loads under plain luajit for the tests above.
-- ---------------------------------------------------------------------------

snapshot.PATH = "/fcs/snapshot.dat"

-- The event fires every sample; the file is a cold-start seed, not a channel.
-- Writing it at 4 Hz would put roughly 8 KB/s of churn against the same disk
-- quota the CSV budget (maxLogBytes x maxLogFiles) is already tuned against.
snapshot.DISK_PERIOD_MS = 2000

snapshot.publishes = 0
snapshot.failures = 0
snapshot.lastDiskWriteAt = nil
snapshot.lastError = nil

local function haveFilesystem()
    return type(_G.fs) == "table" and type(_G.textutils) == "table"
end

function snapshot.publish(frame)
    snapshot.publishes = snapshot.publishes + 1

    -- CC delivers non-input events to every multishell process, which is what
    -- lets the hub tab hear the logger tab without a second rednet listener.
    if type(os) == "table" and type(os.queueEvent) == "function" then
        os.queueEvent("fcs_snapshot", frame)
    end

    local timestamp = type(frame) == "table" and frame.utc_ms or nil
    if type(timestamp) ~= "number" then
        return true
    end
    if snapshot.lastDiskWriteAt
        and timestamp - snapshot.lastDiskWriteAt < snapshot.DISK_PERIOD_MS then
        return true
    end
    if not haveFilesystem() then
        return true
    end
    snapshot.lastDiskWriteAt = timestamp

    -- Write to a temporary path and move it into place, so a hub reading the
    -- file mid-write gets the previous whole frame rather than half of this one.
    local temporary = snapshot.PATH .. ".tmp"
    local ok, err = pcall(function()
        local file = fs.open(temporary, "w")
        if not file then
            error("cannot open " .. temporary, 0)
        end
        file.write(textutils.serialize(frame))
        file.close()
        if fs.exists(snapshot.PATH) then
            fs.delete(snapshot.PATH)
        end
        fs.move(temporary, snapshot.PATH)
    end)

    if not ok then
        snapshot.failures = snapshot.failures + 1
        snapshot.lastError = tostring(err)
        pcall(fs.delete, temporary)
        return false, err
    end

    return true
end

-- Hub-side cold start: something to draw before the first event arrives, and
-- the last known frame when the logger is not running at all.
function snapshot.read()
    if not haveFilesystem() then
        return nil, "no filesystem"
    end
    if not fs.exists(snapshot.PATH) then
        return nil, "no snapshot file"
    end

    local ok, result = pcall(function()
        local file = fs.open(snapshot.PATH, "r")
        if not file then
            error("cannot open " .. snapshot.PATH, 0)
        end
        local text = file.readAll()
        file.close()
        return textutils.unserialize(text)
    end)

    if not ok then
        return nil, tostring(result)
    end
    if type(result) ~= "table" then
        return nil, "snapshot file is not a table"
    end
    return result
end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit tools/test_snapshot.lua
```

Expected: `N passed, 0 failed`.

- [ ] **Step 5: Require the module in `fcs/main.lua`**

In `fcs/main.lua`, after line 18 (`local atmosphere = require("fcs.atmosphere")`), add:

```lua
local snapshot = require("fcs.snapshot")
```

- [ ] **Step 6: Publish at the end of each sample**

In `fcs/main.lua`, in `sample()`, immediately after the existing line 304:

```lua
    draw(state, peripheralState, podStates, path, sequence)
```

insert:

```lua
    -- Hand the monitor hub a frame. Wrapped, because a rendering-side bug must
    -- never be able to stop logging: this loop is the only thing on the
    -- computer that talks to Sable and to the pods, and it keeps running even
    -- if nothing is watching.
    local published = pcall(function()
        snapshot.publish(snapshot.build({
            sequence = sequence,
            timestamp = timestamp,
            dt = dt,
            state = state,
            peripheralState = peripheralState,
            podStates = podStates,
            netStats = banks.stats,
            log = {
                path = path,
                bytes = writer.bytes(),
                samples = sequence,
                targetHz = config.samplePeriodSeconds > 0
                    and 1 / config.samplePeriodSeconds or nil,
                actualHz = dt > 0 and 1 / dt or nil,
                freeSpace = fs.getFreeSpace("/"),
            },
        }))
    end)
    if not published then
        snapshot.failures = snapshot.failures + 1
    end
```

- [ ] **Step 7: Report publish health in the heartbeat**

In `fcs/main.lua`, inside the `writeReport("/fcs/heartbeat.txt", { … })` table (lines 314-330), add immediately after the `"sequence=" .. tostring(sequence),` line:

```lua
            "snapshot_publishes=" .. tostring(snapshot.publishes),
            "snapshot_failures=" .. tostring(snapshot.failures),
            "snapshot_last_error=" .. tostring(snapshot.lastError),
```

This matters because the hub runs in a background tab where a failure is invisible unless someone happens to switch to it — the same reason `heartbeat.txt` exists at all.

- [ ] **Step 8: Syntax-check the modified logger**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit -b fcs/main.lua /dev/null && echo "main.lua compiles"
```

Expected: `main.lua compiles`. This only proves the file parses — it cannot run off-server, since it opens Sable peripherals on load.

- [ ] **Step 9: Deploy and verify logging is unaffected**

Copy `fcs/snapshot.lua` and `fcs/main.lua` to FCS-DEV. Reboot it. In the telemetry tab, confirm the sample counter still advances. Then in the shell:

```
edit /fcs/heartbeat.txt
```

Expected: `snapshot_publishes` climbs, `snapshot_failures=0`, `snapshot_last_error=nil`.

Then confirm the seed file exists and is a table:

```
lua
> local s = dofile("/fcs/snapshot.lua") local f = s.read() print(f and f.v, f and f.sequence)
```

Expected: `1` and a sequence number close to the one on screen.

**If `snapshot_failures` climbs:** read `snapshot_last_error`. An `Out of space` there means the log budget needs lowering, not the snapshot removed — reduce `maxLogFiles` in `fcs/config.lua`.

- [ ] **Step 10: Checkpoint**

```bash
cd ~/repos/fcs-wireless-pods-v2 && for t in mixer hub_canvas hub_layout hub_widgets snapshot; do \
  echo "== $t"; luajit tools/test_$t.lua || exit 1; done
```

Expected: every suite reports `0 failed`.

---

## Task 7: Zone registry, shared test battery, and the attitude zone

Establishes the zone contract and a battery of tests that every zone must pass. Tasks 8–10 add modules; the battery picks them up automatically, so each later zone inherits the same safety checks without copied test code.

**Files:**
- Create: `fcs/hub/zones/init.lua`
- Create: `fcs/hub/zones/attitude.lua`
- Test: `tools/test_hub_zones.lua`
- Modify: `tools/hub_fixtures.lua` (add `fixtures.frame` and `fixtures.hostileFrames`)

**Interfaces:**
- Consumes: `fcs.hub.canvas`, `fcs.hub.widgets`, `fcs.hub.theme`, `fcs.hub.layout`.
- Produces:
  - `zones.NAMES = { "ATTITUDE", "ENGINES", "PODS", "POWER" }`
  - `zones.get(name) -> module|nil` — lazy, tolerant of modules not yet written
  - `zones.available() -> { name, … }`
  - Zone module contract: `{ name = "ATTITUDE", draw = function(canvas, rect, frame) end }`
  - `fixtures.frame() -> frame` — a healthy frame matching `snapshot.build`'s output
  - `fixtures.hostileFrames() -> { {label=, frame=}, … }`
- **Contract:** a zone draws strictly inside `rect`, never reads a global, and never renders the literal string `nil`. Minimum sizes live in `layout.MINIMUMS`, not in the zone — `run.lua` (Task 11) draws the degraded placeholder itself, so zones never have to handle a rect below their minimum (though they must not crash on one).

- [ ] **Step 1: Add frame fixtures**

Append to `tools/hub_fixtures.lua`, immediately **before** the final `return fixtures`:

```lua
-- --- telemetry frames ------------------------------------------------------
-- Shaped exactly like snapshot.build's output. Zones are tested against these
-- rather than against invented tables, so a change to the snapshot contract
-- breaks the zone tests instead of silently diverging from them.

local CORNERS = { "FL", "FR", "RL", "RR" }

function fixtures.frame()
    local frame = {
        v = 1,
        utc_ms = 1787670000000,
        sequence = 12481,
        dt_s = 0.26,
        valid = true,
        errors = {},
        craft = {
            uuid = "abc-123", name = "Helicarrier",
            position = { x = 10.5, y = 82.0, z = -3.25 },
            roll = 1.23, pitch = -0.4, yaw = 271.5,
            bodyVel = { x = 0.1, y = -0.02, z = 0.0 },
            worldVel = { x = 0.1, y = -0.02, z = 0.0 },
            angVel = { x = 0.0, y = 0.01, z = 0.0 },
            mass = 41250.0, airPressure = 0.86,
        },
        corners = {},
        pods = {},
        power = {
            storedFE = 1240000, capacityFE = 2000000,
            gridPower = 18400, gridVoltage = 240, gridAmperage = 76,
        },
        net = {
            seen = 5000, accepted = 4980, badProtocol = 2, wrongType = 0,
            unknownCorner = 0, hostnameMismatch = 0, senderMismatch = 18,
            perCorner = { FL = 1250, FR = 1250, RL = 1230, RR = 1250 },
        },
        log = {
            path = "/fcs/logs/flight_1787670000000.csv",
            bytes = 412000, samples = 12481,
            targetHz = 4.0, actualHz = 3.85, freeSpace = 9000000,
        },
    }

    for _, corner in ipairs(CORNERS) do
        frame.corners[corner] = {
            controllerPresent = true, bearingPresent = true,
            targetRpm = 64, controllerRpm = 63.9, bearingRpm = 4.8,
            thrust = 27921.9, thrustImbalance = 0.4, airflow = 12.0,
            sailPower = 267, hasSource = true, overstressed = false,
            active = true,
            bearings = {
                { thrust = 13960.98, assembled = true },
                { thrust = 13960.92, assembled = true },
            },
            tilt = 0.0, tiltAzimuth = 0.0,
        }
        frame.pods[corner] = {
            corner = corner, hostname = "ENG-" .. corner,
            online = true, podId = 20, armed = true,
            currentPower = 0.45, fallbackPower = 0.0,
            healthyThrusters = 20, expectedThrusters = 20,
            obstructedThrusters = 0, totalThrustKN = 900.0,
            averagePower = 0.45, energyFE = 400000, energyCapacityFE = 500000,
            ageMs = 120, faults = {},
            commandsSeen = 412, commandsApplied = 412, commandsRejected = 0,
            bootedAt = 1787660000000,
        }
    end

    -- The interesting corner: RR's second bearing reading under its twin is
    -- the asymmetry this whole wall exists to make visible.
    frame.corners.RR.bearings[2].thrust = 13804.41
    frame.corners.RR.thrust = 27765.4

    return frame
end

-- Every way a frame can be wrong that the hub must survive. A bad tick is
-- exactly when someone is staring at the wall.
function fixtures.hostileFrames()
    local cases = {}

    cases[#cases + 1] = { label = "empty table", frame = {} }

    local noCraft = fixtures.frame()
    noCraft.craft = {}
    cases[#cases + 1] = { label = "no craft state", frame = noCraft }

    local noCorners = fixtures.frame()
    noCorners.corners = {}
    noCorners.pods = {}
    cases[#cases + 1] = { label = "no corners or pods", frame = noCorners }

    local offline = fixtures.frame()
    for _, corner in ipairs(CORNERS) do
        offline.pods[corner].online = false
        offline.pods[corner].ageMs = 9000
        offline.pods[corner].armed = nil
        offline.pods[corner].currentPower = nil
        offline.pods[corner].healthyThrusters = nil
        offline.corners[corner] = {
            bearings = { {}, {} },
        }
    end
    cases[#cases + 1] = { label = "all pods offline", frame = offline }

    local missingBearings = fixtures.frame()
    for _, corner in ipairs(CORNERS) do
        missingBearings.corners[corner].bearings = { {}, {} }
    end
    cases[#cases + 1] = { label = "no bearing readings", frame = missingBearings }

    local nan = fixtures.frame()
    nan.craft.roll = 0 / 0
    nan.craft.pitch = 1 / 0
    nan.craft.position.y = -1 / 0
    nan.power.storedFE = 0 / 0
    nan.power.capacityFE = 0
    for _, corner in ipairs(CORNERS) do
        nan.corners[corner].thrust = 0 / 0
        nan.corners[corner].controllerRpm = 1 / 0
        nan.corners[corner].bearings[1].thrust = 0 / 0
        nan.pods[corner].currentPower = 0 / 0
    end
    cases[#cases + 1] = { label = "NaN and infinity", frame = nan }

    local faults = fixtures.frame()
    faults.pods.RR.faults = {
        "thruster_7 unresponsive",
        "thruster_11 obstructed by a block that has a very long name indeed",
        "bearing not assembled",
        "rsc lost source",
        "a fifth fault to overflow any fixed list",
    }
    faults.errors = { "RR pod offline: no propeller telemetry" }
    cases[#cases + 1] = { label = "many long faults", frame = faults }

    local negative = fixtures.frame()
    for _, corner in ipairs(CORNERS) do
        negative.corners[corner].thrust = -27921.9
        negative.corners[corner].targetRpm = -256
        negative.corners[corner].bearings[1].thrust = -13960.98
    end
    cases[#cases + 1] = { label = "negative values", frame = negative }

    local huge = fixtures.frame()
    huge.power.storedFE = 2000000
    huge.power.capacityFE = 1
    cases[#cases + 1] = { label = "fraction above one", frame = huge }

    return cases
end
```

- [ ] **Step 2: Write the failing test**

Create `tools/test_hub_zones.lua`:

```lua
-- Offline tests for the hub zone modules.
--
-- The shared battery below runs against every zone that loads, so a zone added
-- in a later task inherits these checks without copying test code.
--
--     luajit tools/test_hub_zones.lua      (from the repo root)

-- ?/init.lua as well as ?.lua: the zone registry is fcs/hub/zones/init.lua,
-- and this mirrors the search path fcs/main.lua installs in game.
package.path = "./?.lua;./?/init.lua;" .. package.path

local canvas = require("fcs.hub.canvas")
local layout = require("fcs.hub.layout")
local theme = require("fcs.hub.theme")
local zones = require("fcs.hub.zones")
local fixtures = require("tools.hub_fixtures")

local passed, failed = 0, 0
local currentTest = "<none>"

local function fail(message)
    failed = failed + 1
    print(string.format("  FAIL  %s: %s", currentTest, message))
end

local function ok() passed = passed + 1 end

local function check(condition, message)
    if condition then ok() else fail(message) end
end

local function equal(actual, expected, message)
    if actual ~= expected then
        fail(string.format("%s: expected %s, got %s",
            message, tostring(expected), tostring(actual)))
        return
    end
    ok()
end

local function test(name, body)
    currentTest = name
    local succeeded, err = pcall(body)
    if not succeeded then fail("threw: " .. tostring(err)) end
end

-- A surface pre-filled with a sentinel, so anything a zone writes outside its
-- rect is visible as a hole in the border.
local SENTINEL = "#"

local function paintedSurface(width, height)
    local target = fixtures.target(width, height)
    local surface = canvas.new(target)
    surface:clear(theme.background)
    for y = 1, height do
        surface:text(1, y, string.rep(SENTINEL, width), theme.colours.white, theme.background)
    end
    surface:flush()
    return surface, target
end

local function drawInto(zone, frame, rect, width, height)
    local surface, target = paintedSurface(width, height)
    zone.draw(surface, rect, frame)
    surface:flush()
    return target
end

local function textOf(target)
    return table.concat(target.rows(), "\n")
end

-- ---------------------------------------------------------------------------
-- Registry
-- ---------------------------------------------------------------------------

test("the registry names exactly the four zones the layout knows", function()
    equal(#zones.NAMES, 4, "zone name count")
    for _, name in ipairs(zones.NAMES) do
        check(layout.MINIMUMS[name] ~= nil, name .. " has a layout minimum")
    end
    for name in pairs(layout.MINIMUMS) do
        local found = false
        for _, known in ipairs(zones.NAMES) do
            if known == name then found = true end
        end
        check(found, name .. " is in layout.MINIMUMS but not in zones.NAMES")
    end
end)

test("get returns nil rather than throwing for an unknown zone", function()
    equal(zones.get("NOPE"), nil, "unknown zone")
end)

test("at least one zone is available", function()
    check(#zones.available() >= 1, "available zones")
end)

test("every available zone declares its name and a draw function", function()
    for _, name in ipairs(zones.available()) do
        local zone = zones.get(name)
        equal(zone.name, name, name .. " declares its own name")
        equal(type(zone.draw), "function", name .. " draw is a function")
    end
end)

-- ---------------------------------------------------------------------------
-- The shared battery: every available zone, every hostile frame
-- ---------------------------------------------------------------------------

for _, name in ipairs(zones.available()) do
    local zone = zones.get(name)
    local minimum = layout.MINIMUMS[name]
    local rect = { x = 3, y = 2, w = minimum.w, h = minimum.h }
    local width = rect.x + rect.w + 2
    local height = rect.y + rect.h + 2

    test(name .. ": draws strictly inside its rect", function()
        local target = drawInto(zone, fixtures.frame(), rect, width, height)
        for y = 1, height do
            for x = 1, width do
                local inside = x >= rect.x and x < rect.x + rect.w
                    and y >= rect.y and y < rect.y + rect.h
                if not inside then
                    equal(target.cells[y][x].char, SENTINEL,
                        string.format("cell %d,%d outside the rect was written", x, y))
                end
            end
        end
    end)

    test(name .. ": never renders the string nil", function()
        local target = drawInto(zone, fixtures.frame(), rect, width, height)
        equal(textOf(target):lower():find("nil"), nil, "the word nil appears on screen")
    end)

    test(name .. ": renders a healthy frame without throwing", function()
        drawInto(zone, fixtures.frame(), rect, width, height)
        ok()
    end)

    for _, case in ipairs(fixtures.hostileFrames()) do
        test(name .. ": survives " .. case.label, function()
            local target = drawInto(zone, case.frame, rect, width, height)
            equal(textOf(target):lower():find("nil"), nil,
                "the word nil appears for " .. case.label)
        end)
    end

    test(name .. ": survives a nil frame", function()
        drawInto(zone, nil, rect, width, height)
        ok()
    end)

    test(name .. ": survives a rect below its minimum", function()
        -- run.lua draws the degraded placeholder instead, but a zone must not
        -- explode if it is ever handed a small rect anyway.
        drawInto(zone, fixtures.frame(),
            { x = 2, y = 2, w = math.max(4, minimum.w - 20), h = math.max(2, minimum.h - 4) },
            width, height)
        ok()
    end)

    test(name .. ": survives a very large rect", function()
        drawInto(zone, fixtures.frame(),
            { x = 1, y = 2, w = 118, h = 40 }, 120, 44)
        ok()
    end)

    test(name .. ": is deterministic", function()
        local first = textOf(drawInto(zone, fixtures.frame(), rect, width, height))
        local second = textOf(drawInto(zone, fixtures.frame(), rect, width, height))
        equal(first, second, "two renders of the same frame differ")
    end)
end

-- ---------------------------------------------------------------------------
-- Attitude specifics
-- ---------------------------------------------------------------------------

local attitude = zones.get("ATTITUDE")

test("attitude titles itself", function()
    local rect = { x = 1, y = 1, w = 44, h = 14 }
    local target = drawInto(attitude, fixtures.frame(), rect, 46, 16)
    check(textOf(target):find("ATTITUDE") ~= nil, "title present")
end)

test("attitude shows roll, pitch and yaw", function()
    local rect = { x = 1, y = 1, w = 44, h = 14 }
    local target = drawInto(attitude, fixtures.frame(), rect, 46, 16)
    local text = textOf(target)
    check(text:find("1%.23") ~= nil, "roll value")
    check(text:find("0%.40") ~= nil, "pitch value")
    check(text:find("271%.5") ~= nil, "yaw value")
end)

test("attitude shows altitude", function()
    local rect = { x = 1, y = 1, w = 44, h = 14 }
    local target = drawInto(attitude, fixtures.frame(), rect, 46, 16)
    check(textOf(target):find("82%.0") ~= nil, "altitude value")
end)

test("attitude shows missing values as dashes rather than omitting the row", function()
    local frame = fixtures.frame()
    frame.craft.roll = nil
    frame.craft.pitch = nil
    local rect = { x = 1, y = 1, w = 44, h = 14 }
    local target = drawInto(attitude, frame, rect, 46, 16)
    local text = textOf(target)
    check(text:find("ROLL") ~= nil, "roll row still labelled")
    check(text:find("%-%-") ~= nil, "missing value shown as dashes")
end)

test("attitude keeps its roll marker inside the rect at extreme values", function()
    for _, roll in ipairs({ -720, -45, 0, 45, 720 }) do
        local frame = fixtures.frame()
        frame.craft.roll = roll
        local rect = { x = 3, y = 2, w = 40, h = 12 }
        local target = drawInto(attitude, frame, rect, 46, 16)
        for y = 1, 16 do
            for x = 1, 46 do
                local inside = x >= rect.x and x < rect.x + rect.w
                    and y >= rect.y and y < rect.y + rect.h
                if not inside then
                    equal(target.cells[y][x].char, SENTINEL,
                        string.format("roll %d wrote outside at %d,%d", roll, x, y))
                end
            end
        end
    end
end)

-- ---------------------------------------------------------------------------

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit tools/test_hub_zones.lua
```

Expected: `module 'fcs.hub.zones' not found`.

- [ ] **Step 4: Write `fcs/hub/zones/init.lua`**

Create `fcs/hub/zones/init.lua`:

```lua
-- Zone registry.
--
-- Lookup is lazy and tolerant: a name whose module does not exist yet returns
-- nil rather than throwing, so the zones can land one task at a time and the
-- shared test battery picks each one up as it arrives.

local zones = {}

zones.NAMES = { "ATTITUDE", "ENGINES", "PODS", "POWER" }

local MODULE = {
    ATTITUDE = "fcs.hub.zones.attitude",
    ENGINES = "fcs.hub.zones.engines",
    PODS = "fcs.hub.zones.pods",
    POWER = "fcs.hub.zones.power",
}

local cache = {}

function zones.get(name)
    if cache[name] ~= nil then
        return cache[name] or nil
    end
    local path = MODULE[name]
    if not path then
        return nil
    end
    local ok, module = pcall(require, path)
    if not ok or type(module) ~= "table" or type(module.draw) ~= "function" then
        cache[name] = false
        return nil
    end
    cache[name] = module
    return module
end

function zones.available()
    local found = {}
    for _, name in ipairs(zones.NAMES) do
        if zones.get(name) then
            found[#found + 1] = name
        end
    end
    return found
end

return zones
```

- [ ] **Step 5: Write `fcs/hub/zones/attitude.lua`**

Create `fcs/hub/zones/attitude.lua`:

```lua
-- Attitude and motion: is the craft level, and is it going anywhere.
--
-- The ladders exist because a number alone does not read at a glance from
-- across a room, and roll in particular is the number this craft has a history
-- of quietly sitting off-centre on.

local theme = require("fcs.hub.theme")
local widgets = require("fcs.hub.widgets")

local attitude = {}

attitude.name = "ATTITUDE"

local LABEL_WIDTH = 7
local LADDER_RANGE = 10

-- Roll and pitch are in degrees and should sit near zero. These thresholds are
-- deliberately tight: the standing offset this craft has carried was 1.23 deg,
-- and a scale that called that "fine" would have hidden it.
local function attitudeLevel(value)
    if not widgets.isFinite(value) then
        return "idle"
    end
    local magnitude = math.abs(value)
    if magnitude < 0.5 then
        return "ok"
    elseif magnitude < 2.0 then
        return "warn"
    end
    return "bad"
end

-- A horizontal scale with a marker. Clamped hard: a roll of 720 must pin the
-- marker to the edge, not write past the rect.
local function ladder(canvas, x, y, width, value, colour)
    if width < 5 then
        return
    end
    local track = string.rep("-", width)
    canvas:text(x, y, track, theme.rule, theme.background)
    canvas:text(x + math.floor((width - 1) / 2), y, "+", theme.label, theme.background)

    if not widgets.isFinite(value) then
        return
    end
    local fraction = (value + LADDER_RANGE) / (2 * LADDER_RANGE)
    if fraction < 0 then fraction = 0 end
    if fraction > 1 then fraction = 1 end
    local offset = math.floor(fraction * (width - 1) + 0.5)
    canvas:text(x + offset, y, "^", colour, theme.background)
end

local function row(canvas, rect, index)
    local y = rect.y + index
    if y > rect.y + rect.h - 1 then
        return nil
    end
    return y
end

function attitude.draw(canvas, rect, frame)
    frame = frame or {}
    local craft = frame.craft or {}

    local altitude = craft.position and craft.position.y or nil
    widgets.title(canvas, rect, "ATTITUDE / MOTION",
        "ALT " .. widgets.number(altitude, "%.1f"))

    -- Room for the label, the numeric value, and a ladder between them.
    local valueWidth = 9
    local ladderX = rect.x + LABEL_WIDTH
    local ladderWidth = rect.w - LABEL_WIDTH - valueWidth - 1

    local axes = {
        { label = "ROLL", value = craft.roll, ladder = true },
        { label = "PITCH", value = craft.pitch, ladder = true },
        { label = "YAW", value = craft.yaw, ladder = false, format = "%.1f" },
    }

    for index, axis in ipairs(axes) do
        local y = row(canvas, rect, index)
        if y then
            local level = axis.ladder and attitudeLevel(axis.value) or "idle"
            local colour = axis.ladder and theme.status(level) or theme.foreground
            canvas:text(rect.x, y, axis.label, theme.label, theme.background)
            if axis.ladder and ladderWidth >= 5 then
                ladder(canvas, ladderX, y, ladderWidth, axis.value, colour)
            end
            -- One column short of the right edge: on the wall this zone sits
            -- directly against POWER, and a value flush to the edge reads as
            -- part of the neighbour.
            local text = widgets.number(axis.value, axis.format or "%+.2f")
            canvas:text(rect.x + rect.w - #text - 1, y, text, colour, theme.background)
        end
    end

    local vectors = {
        { label = "BODY V", value = craft.bodyVel },
        { label = "WORLD V", value = craft.worldVel },
        { label = "ANG V", value = craft.angVel },
    }

    for index, vector in ipairs(vectors) do
        local y = row(canvas, rect, index + 4)
        if y then
            canvas:text(rect.x, y, vector.label, theme.label, theme.background)
            local value = vector.value or {}
            local text = string.format("x %s  y %s  z %s",
                widgets.number(value.x, "%+.3f"),
                widgets.number(value.y, "%+.3f"),
                widgets.number(value.z, "%+.3f"))
            canvas:text(rect.x + LABEL_WIDTH + 1, y,
                widgets.clip(text, rect.w - LABEL_WIDTH - 1),
                theme.foreground, theme.background)
        end
    end

    local y = row(canvas, rect, 8)
    if y then
        canvas:text(rect.x, y, "MASS", theme.label, theme.background)
        canvas:text(rect.x + LABEL_WIDTH + 1, y,
            widgets.compact(craft.mass), theme.foreground, theme.background)
        local air = "AIR " .. widgets.number(craft.airPressure, "%.2f")
        canvas:text(rect.x + rect.w - #air - 1, y, air, theme.foreground, theme.background)
    end

    local position = craft.position or {}
    y = row(canvas, rect, 9)
    if y then
        canvas:text(rect.x, y, "XYZ", theme.label, theme.background)
        local text = string.format("%s  %s  %s",
            widgets.number(position.x, "%.1f"),
            widgets.number(position.y, "%.1f"),
            widgets.number(position.z, "%.1f"))
        canvas:text(rect.x + LABEL_WIDTH + 1, y,
            widgets.clip(text, rect.w - LABEL_WIDTH - 1),
            theme.foreground, theme.background)
    end
end

return attitude
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit tools/test_hub_zones.lua
```

Expected: `N passed, 0 failed`.

- [ ] **Step 7: Checkpoint**

```bash
cd ~/repos/fcs-wireless-pods-v2 && for t in mixer hub_canvas hub_layout hub_widgets snapshot hub_zones; do \
  echo "== $t"; luajit tools/test_$t.lua || exit 1; done
```

Expected: every suite reports `0 failed`.

---

## Task 8: Engines zone

The reason the wall exists. Corner aggregates sum thrust *magnitudes*, so they cannot show one bearing of a counter-rotating pair underperforming its twin — this zone puts `b1`, `b2` and their delta on screen side by side.

**Files:**
- Create: `fcs/hub/zones/engines.lua`
- Test: `tools/test_hub_zones.lua` (append an engines section)

**Interfaces:**
- Consumes: `fcs.hub.widgets`, `fcs.hub.theme`. Registered as `ENGINES` by `zones/init.lua` from Task 7 — no registry change needed.
- Produces: `engines.name = "ENGINES"`, `engines.draw(canvas, rect, frame)`, `engines.deltaPercent(bearings) -> number|nil`, `engines.deltaLevel(delta) -> "ok"|"warn"|"bad"|"idle"`.
- The shared battery in `tools/test_hub_zones.lua` covers this module automatically once it loads.

- [ ] **Step 1: Write the failing test**

Append to `tools/test_hub_zones.lua`, immediately **before** the final `print(...)` / `os.exit(...)` lines:

```lua
-- ---------------------------------------------------------------------------
-- Engines specifics
-- ---------------------------------------------------------------------------

local engines = zones.get("ENGINES")

test("engines computes the per-bearing delta as a percentage", function()
    local delta = engines.deltaPercent({
        { thrust = 13960.98 }, { thrust = 13804.41 },
    })
    check(delta ~= nil, "delta computed")
    if delta then
        check(math.abs(delta - 1.1215) < 0.01,
            string.format("expected about 1.12%%, got %.4f", delta))
    end
end)

test("engines compares bearing magnitudes, not signed values", function()
    -- getThrust is signed by HANDEDNESS: a matched counter-rotating pair reads
    -- +x and -x while physically pushing the same way. Comparing raw values
    -- would call a healthy pair 200% out.
    local delta = engines.deltaPercent({
        { thrust = 13960.98 }, { thrust = -13960.98 },
    })
    check(delta ~= nil and math.abs(delta) < 1e-6,
        "a matched counter-rotating pair reads as zero delta")
end)

test("engines has no delta when a bearing reading is missing", function()
    equal(engines.deltaPercent({ { thrust = 13960.98 }, {} }), nil, "one missing")
    equal(engines.deltaPercent({ {}, {} }), nil, "both missing")
    equal(engines.deltaPercent(nil), nil, "no bearings at all")
end)

test("engines has no delta when both bearings read zero", function()
    equal(engines.deltaPercent({ { thrust = 0 }, { thrust = 0 } }), nil,
        "a stopped pair has no meaningful ratio")
end)

test("engines grades the delta against the thresholds that matter", function()
    equal(engines.deltaLevel(0.05), "ok", "noise")
    equal(engines.deltaLevel(0.5), "warn", "drifting")
    equal(engines.deltaLevel(1.12), "bad", "the known bearing deficit")
    equal(engines.deltaLevel(-1.12), "bad", "sign does not matter")
    equal(engines.deltaLevel(nil), "idle", "unknown")
end)

test("engines labels all four corners", function()
    local rect = { x = 1, y = 1, w = 79, h = 12 }
    local target = drawInto(engines, fixtures.frame(), rect, 79, 14)
    local text = textOf(target)
    for _, corner in ipairs({ "FL", "FR", "RL", "RR" }) do
        check(text:find(corner) ~= nil, corner .. " column header")
    end
end)

test("engines shows the RR deficit on screen", function()
    local rect = { x = 1, y = 1, w = 79, h = 12 }
    local target = drawInto(engines, fixtures.frame(), rect, 79, 14)
    check(textOf(target):find("1%.1") ~= nil,
        "the 1.12% RR bearing delta must be visible")
end)

test("engines shows both bearings per corner", function()
    local rect = { x = 1, y = 1, w = 79, h = 12 }
    local target = drawInto(engines, fixtures.frame(), rect, 79, 14)
    local text = textOf(target)
    check(text:find("b1") ~= nil, "b1 row")
    check(text:find("b2") ~= nil, "b2 row")
end)

test("engines shows target and actual rpm", function()
    local frame = fixtures.frame()
    frame.corners.FL.targetRpm = 64
    frame.corners.FL.controllerRpm = 61.5
    local rect = { x = 1, y = 1, w = 79, h = 12 }
    local target = drawInto(engines, frame, rect, 79, 14)
    local text = textOf(target)
    check(text:find("64") ~= nil, "target rpm")
    check(text:find("61%.5") ~= nil, "actual rpm")
end)

test("engines flags an overstressed corner", function()
    local frame = fixtures.frame()
    frame.corners.RL.overstressed = true
    local rect = { x = 1, y = 1, w = 79, h = 12 }
    local target = drawInto(engines, frame, rect, 79, 14)
    check(textOf(target):find("OS") ~= nil, "overstressed flag")
end)

test("engines flags a missing controller or bearing", function()
    local frame = fixtures.frame()
    frame.corners.FR.controllerPresent = false
    frame.corners.FR.bearingPresent = false
    local rect = { x = 1, y = 1, w = 79, h = 12 }
    local target = drawInto(engines, frame, rect, 79, 14)
    check(textOf(target):find("!") ~= nil, "missing-device flag")
end)
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit tools/test_hub_zones.lua
```

Expected: `attempt to index local 'engines' (a nil value)` — the registry returns nil for a module that does not exist yet.

- [ ] **Step 3: Write `fcs/hub/zones/engines.lua`**

Create `fcs/hub/zones/engines.lua`:

```lua
-- The four-corner engine strip.
--
-- Why per-bearing rows rather than a corner total: getThrust is signed by
-- HANDEDNESS, not by world direction, so a counter-rotating pair reports +x
-- and -x while pushing the same way. The corner aggregate therefore sums
-- MAGNITUDES -- which means it cannot show one bearing of a pair
-- underperforming its twin. That asymmetry is exactly what this craft has a
-- history of hiding, so b1, b2 and their delta get their own rows.

local theme = require("fcs.hub.theme")
local widgets = require("fcs.hub.widgets")

local engines = {}

engines.name = "ENGINES"

local LABEL_WIDTH = 14

-- Thresholds in percent. 1.12% was the real deficit on this craft; a scale
-- that graded that as "warn" would have let it keep hiding.
engines.DELTA_WARN = 0.25
engines.DELTA_BAD = 1.0

-- Magnitudes, deliberately. See the header comment.
function engines.deltaPercent(bearings)
    if type(bearings) ~= "table" then
        return nil
    end
    local first = (bearings[1] or {}).thrust
    local second = (bearings[2] or {}).thrust
    if not widgets.isFinite(first) or not widgets.isFinite(second) then
        return nil
    end
    local a, b = math.abs(first), math.abs(second)
    local largest = math.max(a, b)
    if largest == 0 then
        -- A stopped pair has no meaningful ratio; 0/0 is not "balanced".
        return nil
    end
    return (a - b) / largest * 100
end

function engines.deltaLevel(delta)
    if not widgets.isFinite(delta) then
        return "idle"
    end
    local magnitude = math.abs(delta)
    if magnitude < engines.DELTA_WARN then
        return "ok"
    elseif magnitude < engines.DELTA_BAD then
        return "warn"
    end
    return "bad"
end

local function flagsFor(corner)
    local flags = {}
    local level = "ok"
    if corner.controllerPresent == false then
        flags[#flags + 1] = "!C"
        level = "bad"
    end
    if corner.bearingPresent == false then
        flags[#flags + 1] = "!B"
        level = "bad"
    end
    if corner.overstressed then
        flags[#flags + 1] = "OS"
        level = "bad"
    end
    if corner.hasSource == false then
        flags[#flags + 1] = "!S"
        if level ~= "bad" then level = "warn" end
    end
    if corner.active then
        flags[#flags + 1] = "A"
    elseif corner.active == false then
        flags[#flags + 1] = "--"
        if level == "ok" then level = "idle" end
    end
    return table.concat(flags, " "), level
end

local function cellsFor(frame, build)
    local cells = {}
    for index, corner in ipairs(widgets.CORNERS) do
        cells[index] = build((frame.corners or {})[corner] or {}, corner)
    end
    return cells
end

function engines.draw(canvas, rect, frame)
    frame = frame or {}

    -- Worst delta across the corners, so the title carries the headline even
    -- when someone only glances at the zone header.
    local worst, worstCorner = nil, nil
    for _, corner in ipairs(widgets.CORNERS) do
        local delta = engines.deltaPercent(((frame.corners or {})[corner] or {}).bearings)
        if delta and (not worst or math.abs(delta) > math.abs(worst)) then
            worst, worstCorner = delta, corner
        end
    end
    local headline = worst
        and string.format("max d %s %+.2f%%", worstCorner, worst)
        or "max d --"
    widgets.title(canvas, rect, "ENGINES", headline)

    local rows = {
        {
            label = "",
            build = function(_, corner)
                return { text = corner, colour = theme.foreground }
            end,
        },
        {
            label = "target rpm",
            build = function(corner)
                return { text = widgets.number(corner.targetRpm, "%.0f") }
            end,
        },
        {
            label = "actual rpm",
            build = function(corner)
                return { text = widgets.number(corner.controllerRpm, "%.1f") }
            end,
        },
        {
            label = "thrust",
            build = function(corner)
                return { text = widgets.compact(corner.thrust) }
            end,
        },
        -- Full resolution, NOT widgets.compact: the deficit under
        -- investigation is ~1%, and 13960.98 vs 13804.41 both compact to
        -- "14.0k". Rounding here would erase the one number this zone exists
        -- to show.
        {
            label = "b1 thrust",
            build = function(corner)
                return { text = widgets.number(
                    ((corner.bearings or {})[1] or {}).thrust, "%.0f") }
            end,
        },
        {
            label = "b2 thrust",
            build = function(corner)
                return { text = widgets.number(
                    ((corner.bearings or {})[2] or {}).thrust, "%.0f") }
            end,
        },
        {
            label = "b1-b2 delta",
            build = function(corner)
                local delta = engines.deltaPercent(corner.bearings)
                return {
                    text = delta and string.format("%+.2f%%", delta) or widgets.MISSING,
                    colour = theme.status(engines.deltaLevel(delta)),
                }
            end,
        },
        {
            label = "tilt deg",
            build = function(corner)
                return { text = widgets.number(corner.tilt, "%+.1f") }
            end,
        },
        {
            label = "flags",
            build = function(corner)
                local flags, level = flagsFor(corner)
                return { text = flags, colour = theme.status(level) }
            end,
        },
    }

    for index, row in ipairs(rows) do
        widgets.row(canvas, rect, rect.y + index, row.label,
            cellsFor(frame, row.build), LABEL_WIDTH)
    end
end

return engines
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit tools/test_hub_zones.lua
```

Expected: `N passed, 0 failed`, with the shared battery now running against `ENGINES` as well.

- [ ] **Step 5: Checkpoint**

```bash
cd ~/repos/fcs-wireless-pods-v2 && for t in mixer hub_canvas hub_layout hub_widgets snapshot hub_zones; do \
  echo "== $t"; luajit tools/test_$t.lua || exit 1; done
```

Expected: every suite reports `0 failed`.

---

## Task 9: Pods zone

Pod link health and the fault list. A live logger with a dead FL pod is a completely different situation from a dead logger, and this zone is where that distinction is drawn.

**Files:**
- Create: `fcs/hub/zones/pods.lua`
- Test: `tools/test_hub_zones.lua` (append a pods section)

**Interfaces:**
- Consumes: `fcs.hub.widgets`, `fcs.hub.theme`.
- Produces: `pods.name = "PODS"`, `pods.draw(canvas, rect, frame)`, `pods.faultLines(frame) -> { string, … }`.

- [ ] **Step 1: Write the failing test**

Append to `tools/test_hub_zones.lua`, immediately **before** the final `print(...)` / `os.exit(...)` lines:

```lua
-- ---------------------------------------------------------------------------
-- Pods specifics
-- ---------------------------------------------------------------------------

local pods = zones.get("PODS")

test("pods gathers faults from every corner and from the frame errors", function()
    local frame = fixtures.frame()
    frame.pods.FL.faults = { "fl fault" }
    frame.pods.RR.faults = { "rr fault" }
    frame.errors = { "top level error" }
    local lines = pods.faultLines(frame)
    local joined = table.concat(lines, "\n")
    check(joined:find("fl fault") ~= nil, "FL fault present")
    check(joined:find("rr fault") ~= nil, "RR fault present")
    check(joined:find("top level error") ~= nil, "frame error present")
end)

test("pods prefixes a pod fault with its corner", function()
    local frame = fixtures.frame()
    frame.pods.RR.faults = { "thruster_7 unresponsive" }
    local joined = table.concat(pods.faultLines(frame), "\n")
    check(joined:find("RR") ~= nil, "corner prefix")
end)

test("pods returns an empty list when nothing is wrong", function()
    local frame = fixtures.frame()
    frame.errors = {}
    equal(#pods.faultLines(frame), 0, "fault count")
end)

test("pods tolerates a frame with no pods at all", function()
    equal(#pods.faultLines({}), 0, "fault count")
    equal(#pods.faultLines(nil), 0, "nil frame")
end)

test("pods shows link state and age per corner", function()
    local frame = fixtures.frame()
    frame.pods.RL.online = false
    frame.pods.RL.ageMs = 6200
    local rect = { x = 1, y = 1, w = 79, h = 10 }
    local target = drawInto(pods, frame, rect, 79, 12)
    local text = textOf(target)
    check(text:find("UP") ~= nil, "an online pod reads UP")
    check(text:find("DOWN") ~= nil, "an offline pod reads DOWN")
    check(text:find("6%.2s") ~= nil, "the offline pod's age is shown")
end)

test("pods shows armed state", function()
    local frame = fixtures.frame()
    frame.pods.FL.armed = false
    local rect = { x = 1, y = 1, w = 79, h = 10 }
    local target = drawInto(pods, frame, rect, 79, 12)
    check(textOf(target):find("ARM") ~= nil, "armed marker")
end)

test("pods shows healthy against expected thrusters", function()
    local frame = fixtures.frame()
    frame.pods.RR.healthyThrusters = 19
    frame.pods.RR.expectedThrusters = 20
    local rect = { x = 1, y = 1, w = 79, h = 10 }
    local target = drawInto(pods, frame, rect, 79, 12)
    check(textOf(target):find("19/20") ~= nil, "thruster count")
end)

test("pods renders the fault list when there is room", function()
    local frame = fixtures.frame()
    frame.pods.RR.faults = { "thruster_7 unresponsive" }
    local rect = { x = 1, y = 1, w = 79, h = 12 }
    local target = drawInto(pods, frame, rect, 79, 14)
    check(textOf(target):find("thruster_7") ~= nil, "fault text on screen")
end)

test("pods says how many faults it could not show", function()
    local frame = fixtures.frame()
    frame.pods.RR.faults = {}
    for i = 1, 20 do
        frame.pods.RR.faults[i] = "fault number " .. i
    end
    local rect = { x = 1, y = 1, w = 79, h = 10 }
    local target = drawInto(pods, frame, rect, 79, 12)
    check(textOf(target):find("more") ~= nil,
        "a truncated fault list must say it was truncated")
end)
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit tools/test_hub_zones.lua
```

Expected: `attempt to index local 'pods' (a nil value)`.

- [ ] **Step 3: Write `fcs/hub/zones/pods.lua`**

Create `fcs/hub/zones/pods.lua`:

```lua
-- Pod link health and the fault list.
--
-- Pod freshness is tracked separately from frame freshness on purpose: a live
-- logger with a dead FL pod and a dead logger are different emergencies, and a
-- wall that renders them the same way is worse than no wall.

local theme = require("fcs.hub.theme")
local widgets = require("fcs.hub.widgets")

local pods = {}

pods.name = "PODS"

local LABEL_WIDTH = 12

-- Everything wrong right now, in one list: per-pod faults first, then the
-- frame-level errors from sensors and peripherals.
function pods.faultLines(frame)
    frame = frame or {}
    local lines = {}

    for _, corner in ipairs(widgets.CORNERS) do
        local pod = (frame.pods or {})[corner]
        if pod then
            for _, fault in ipairs(pod.faults or {}) do
                lines[#lines + 1] = corner .. ": " .. tostring(fault)
            end
            if pod.lastReject then
                lines[#lines + 1] = corner .. ": rejected " .. tostring(pod.lastReject)
            end
        end
    end

    for _, message in ipairs(frame.errors or {}) do
        lines[#lines + 1] = tostring(message)
    end

    return lines
end

local function cellsFor(frame, build)
    local cells = {}
    for index, corner in ipairs(widgets.CORNERS) do
        cells[index] = build((frame.pods or {})[corner] or {}, corner)
    end
    return cells
end

function pods.draw(canvas, rect, frame)
    frame = frame or {}

    local up = 0
    for _, corner in ipairs(widgets.CORNERS) do
        if ((frame.pods or {})[corner] or {}).online then
            up = up + 1
        end
    end
    widgets.title(canvas, rect, "PODS",
        string.format("%d/%d up", up, #widgets.CORNERS))

    local rows = {
        {
            label = "",
            build = function(_, corner)
                return { text = corner, colour = theme.foreground }
            end,
        },
        {
            label = "link",
            build = function(pod)
                if pod.online then
                    return {
                        text = "UP " .. widgets.duration(pod.ageMs),
                        colour = theme.status("ok"),
                    }
                end
                local age = widgets.isFinite(pod.ageMs)
                    and widgets.duration(pod.ageMs) or widgets.MISSING
                return { text = "DOWN " .. age, colour = theme.status("bad") }
            end,
        },
        {
            label = "armed",
            build = function(pod)
                if pod.armed == true then
                    return { text = "ARM", colour = theme.status("warn") }
                elseif pod.armed == false then
                    return { text = "safe", colour = theme.status("idle") }
                end
                return { text = widgets.MISSING, colour = theme.status("idle") }
            end,
        },
        {
            label = "power",
            build = function(pod)
                return { text = widgets.number(pod.currentPower, "%.3f") }
            end,
        },
        {
            label = "thrusters",
            build = function(pod)
                local healthy = pod.healthyThrusters
                local expected = pod.expectedThrusters
                if not widgets.isFinite(healthy) or not widgets.isFinite(expected) then
                    return { text = widgets.MISSING, colour = theme.status("idle") }
                end
                local level = "ok"
                if healthy < expected then
                    level = healthy == 0 and "bad" or "warn"
                end
                return {
                    text = string.format("%d/%d", healthy, expected),
                    colour = theme.status(level),
                }
            end,
        },
        {
            label = "obstructed",
            build = function(pod)
                local count = pod.obstructedThrusters
                if not widgets.isFinite(count) then
                    return { text = widgets.MISSING, colour = theme.status("idle") }
                end
                return {
                    text = string.format("%d", count),
                    colour = theme.status(count > 0 and "warn" or "ok"),
                }
            end,
        },
        {
            label = "cmd s/a/r",
            build = function(pod)
                return {
                    text = string.format("%s/%s/%s",
                        widgets.number(pod.commandsSeen, "%d"),
                        widgets.number(pod.commandsApplied, "%d"),
                        widgets.number(pod.commandsRejected, "%d")),
                    colour = widgets.isFinite(pod.commandsRejected)
                        and pod.commandsRejected > 0
                        and theme.status("warn") or theme.foreground,
                }
            end,
        },
    }

    local lastRow = 0
    for index, row in ipairs(rows) do
        local y = rect.y + index
        if y <= rect.y + rect.h - 1 then
            widgets.row(canvas, rect, y, row.label,
                cellsFor(frame, row.build), LABEL_WIDTH)
            lastRow = index
        end
    end

    -- Faults take whatever rows are left. A truncated list always says so:
    -- silently dropping the fault that mattered is the failure mode here.
    local faultTop = rect.y + lastRow + 1
    local available = rect.y + rect.h - faultTop
    if available < 2 then
        return
    end

    local lines = pods.faultLines(frame)
    canvas:text(rect.x, faultTop,
        widgets.clip(#lines > 0 and "FAULTS" or "FAULTS  none", rect.w),
        #lines > 0 and theme.status("bad") or theme.status("ok"),
        theme.background)

    local room = available - 1
    local shown = math.min(#lines, room)
    if #lines > room then
        shown = math.max(0, room - 1)
    end

    for index = 1, shown do
        canvas:text(rect.x + 1, faultTop + index,
            widgets.clip(lines[index], rect.w - 1),
            theme.status("bad"), theme.background)
    end

    if #lines > shown then
        canvas:text(rect.x + 1, faultTop + shown + 1,
            widgets.clip(string.format("... %d more", #lines - shown), rect.w - 1),
            theme.status("warn"), theme.background)
    end
end

return pods
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit tools/test_hub_zones.lua
```

Expected: `N passed, 0 failed`.

- [ ] **Step 5: Checkpoint**

```bash
cd ~/repos/fcs-wireless-pods-v2 && for t in mixer hub_canvas hub_layout hub_widgets snapshot hub_zones; do \
  echo "== $t"; luajit tools/test_$t.lua || exit 1; done
```

Expected: every suite reports `0 failed`.

---

## Task 10: Power zone

Energy reserve, grid readings, and per-pod ion draw.

**Files:**
- Create: `fcs/hub/zones/power.lua`
- Test: `tools/test_hub_zones.lua` (append a power section)

**Interfaces:**
- Consumes: `fcs.hub.widgets`, `fcs.hub.theme`.
- Produces: `power.name = "POWER"`, `power.draw(canvas, rect, frame)`, `power.fraction(stored, capacity) -> number|nil`.

- [ ] **Step 1: Write the failing test**

Append to `tools/test_hub_zones.lua`, immediately **before** the final `print(...)` / `os.exit(...)` lines:

```lua
-- ---------------------------------------------------------------------------
-- Power specifics
-- ---------------------------------------------------------------------------

local power = zones.get("POWER")

test("power computes a charge fraction", function()
    local fraction = power.fraction(1240000, 2000000)
    check(fraction ~= nil and math.abs(fraction - 0.62) < 1e-9,
        "fraction of a normal reading")
end)

test("power has no fraction without a capacity", function()
    equal(power.fraction(1240000, nil), nil, "no capacity")
    equal(power.fraction(1240000, 0), nil, "zero capacity")
    equal(power.fraction(nil, 2000000), nil, "no stored value")
    equal(power.fraction(0 / 0, 2000000), nil, "NaN stored value")
end)

test("power clamps a fraction above one", function()
    local fraction = power.fraction(4000000, 2000000)
    check(fraction ~= nil and fraction <= 1.0, "clamped to one")
end)

test("power shows the charge percentage", function()
    local rect = { x = 1, y = 1, w = 34, h = 14 }
    local target = drawInto(power, fixtures.frame(), rect, 36, 16)
    check(textOf(target):find("62") ~= nil, "percentage on screen")
end)

test("power shows grid readings", function()
    local rect = { x = 1, y = 1, w = 34, h = 14 }
    local target = drawInto(power, fixtures.frame(), rect, 36, 16)
    local text = textOf(target)
    check(text:find("18%.4k") ~= nil, "grid power")
    check(text:find("240") ~= nil, "voltage")
    check(text:find("76") ~= nil, "amperage")
end)

test("power shows dashes when the optional meters are absent", function()
    local frame = fixtures.frame()
    frame.power = {}
    local rect = { x = 1, y = 1, w = 34, h = 14 }
    local target = drawInto(power, frame, rect, 36, 16)
    local text = textOf(target)
    check(text:find("%-%-") ~= nil, "missing readings shown as dashes")
    check(text:lower():find("nil") == nil, "no nils")
end)

test("power lists per-pod ion draw", function()
    local frame = fixtures.frame()
    frame.pods.FL.averagePower = 0.45
    local rect = { x = 1, y = 1, w = 34, h = 14 }
    local target = drawInto(power, frame, rect, 36, 16)
    local text = textOf(target)
    check(text:find("ION") ~= nil, "ion section")
    check(text:find("0%.45") ~= nil, "per-pod value")
end)
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit tools/test_hub_zones.lua
```

Expected: `attempt to index local 'power' (a nil value)`.

- [ ] **Step 3: Write `fcs/hub/zones/power.lua`**

Create `fcs/hub/zones/power.lua`:

```lua
-- Energy reserve, grid readings, and per-pod ion draw.
--
-- Every reading here is optional: energyStorage, powerMeter, voltmeter and
-- ammeter are all nil-by-default in fcs/config.lua. A carrier without meters
-- must render a clean zone full of dashes, not a broken one.

local theme = require("fcs.hub.theme")
local widgets = require("fcs.hub.widgets")

local power = {}

power.name = "POWER"

power.LOW_FRACTION = 0.20
power.WARN_FRACTION = 0.50

function power.fraction(stored, capacity)
    if not widgets.isFinite(stored) or not widgets.isFinite(capacity) then
        return nil
    end
    if capacity <= 0 then
        return nil
    end
    local fraction = stored / capacity
    if fraction < 0 then fraction = 0 end
    if fraction > 1 then fraction = 1 end
    return fraction
end

local function chargeLevel(fraction)
    if not widgets.isFinite(fraction) then
        return "idle"
    end
    if fraction < power.LOW_FRACTION then
        return "bad"
    elseif fraction < power.WARN_FRACTION then
        return "warn"
    end
    return "ok"
end

local function row(rect, index)
    local y = rect.y + index
    if y > rect.y + rect.h - 1 then
        return nil
    end
    return y
end

function power.draw(canvas, rect, frame)
    frame = frame or {}
    local readings = frame.power or {}

    local fraction = power.fraction(readings.storedFE, readings.capacityFE)
    local level = chargeLevel(fraction)
    local percent = fraction and string.format("%d%%", math.floor(fraction * 100 + 0.5))
        or widgets.MISSING
    widgets.title(canvas, rect, "POWER", percent)

    local y = row(rect, 1)
    if y then
        -- The percentage is already right-aligned in the title bar, so the bar
        -- takes the whole width rather than repeating the number beside itself.
        canvas:bar(rect.x, y, rect.w, fraction or 0,
            theme.status(level), theme.colours.gray)
    end

    y = row(rect, 2)
    if y then
        canvas:text(rect.x, y,
            widgets.clip(string.format("%s / %s FE",
                widgets.compact(readings.storedFE),
                widgets.compact(readings.capacityFE)), rect.w),
            theme.foreground, theme.background)
    end

    local grid = {
        { label = "grid W", value = widgets.compact(readings.gridPower) },
        { label = "volts", value = widgets.number(readings.gridVoltage, "%.0f") },
        { label = "amps", value = widgets.number(readings.gridAmperage, "%.0f") },
    }

    for index, entry in ipairs(grid) do
        y = row(rect, index + 3)
        if y then
            canvas:text(rect.x, y,
                widgets.clip(entry.label, 8), theme.label, theme.background)
            canvas:text(rect.x + 9, y,
                widgets.clip(entry.value, rect.w - 9),
                theme.foreground, theme.background)
        end
    end

    y = row(rect, 7)
    if y then
        canvas:text(rect.x, y, widgets.clip("ION AVG POWER", rect.w),
            theme.label, theme.background)
    end

    -- Two corners per line, so the block fits a narrow zone.
    for pairIndex = 1, 2 do
        y = row(rect, 7 + pairIndex)
        if y then
            local parts = {}
            for offset = 1, 2 do
                local corner = widgets.CORNERS[(pairIndex - 1) * 2 + offset]
                local pod = (frame.pods or {})[corner] or {}
                parts[#parts + 1] = string.format("%s %s",
                    corner, widgets.number(pod.averagePower, "%.3f"))
            end
            canvas:text(rect.x + 1, y,
                widgets.clip(table.concat(parts, "  "), rect.w - 1),
                theme.foreground, theme.background)
        end
    end
end

return power
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit tools/test_hub_zones.lua
```

Expected: `N passed, 0 failed`, with the shared battery now covering all four zones.

- [ ] **Step 5: Checkpoint**

```bash
cd ~/repos/fcs-wireless-pods-v2 && for t in mixer hub_canvas hub_layout hub_widgets snapshot hub_zones; do \
  echo "== $t"; luajit tools/test_$t.lua || exit 1; done
```

Expected: every suite reports `0 failed`.

---

## Task 11: Hub loop and entry point

Ties it together: resolve a target, seed from disk, listen for frames, and decide when to repaint. Also where staleness becomes something the viewer can see.

**Files:**
- Create: `fcs/hub/run.lua`
- Create: `fcs-dev.lua`
- Test: `tools/test_hub_run.lua`

**Interfaces:**
- Consumes: `fcs.hub.canvas`, `fcs.hub.layout`, `fcs.hub.zones`, `fcs.hub.theme`, `fcs.hub.widgets`, `fcs.snapshot`.
- Produces:
  - `run.headerText(frame, freshness, ageMs) -> leftText, rightText`
  - `run.footerText(frame) -> leftText, rightText`
  - `run.findMonitor(name) -> monitor, name, reason` (uses the `peripheral` global; injectable for tests via `run._peripheral`)
  - `run.render(surface, frame, freshness, ageMs)` — one full repaint into a canvas
  - `run.start(options)` — the event loop; `options = { monitorName=, term=, textScale=, maxRedrawHz=, staleAfterMs=, deadAfterMs= }`
- **Contract:** `run` never requires `fcs.banks`, `fcs.sensors`, or `fcs.network`. The one-talker invariant is enforced here or nowhere.

- [ ] **Step 1: Write the failing test**

Create `tools/test_hub_run.lua`:

```lua
-- Offline tests for the pure parts of fcs/hub/run.lua: header and footer text,
-- monitor resolution, and a full render into a fake surface.
--
-- The event loop itself is not tested here -- it is CC scheduling, which is
-- what tools/cc_harness.lua exists for, and what the in-world acceptance steps
-- in Task 13 cover.
--
--     luajit tools/test_hub_run.lua      (from the repo root)

package.path = "./?.lua;./?/init.lua;" .. package.path

local canvas = require("fcs.hub.canvas")
local theme = require("fcs.hub.theme")
local run = require("fcs.hub.run")
local fixtures = require("tools.hub_fixtures")

local passed, failed = 0, 0
local currentTest = "<none>"

local function fail(message)
    failed = failed + 1
    print(string.format("  FAIL  %s: %s", currentTest, message))
end

local function ok() passed = passed + 1 end

local function check(condition, message)
    if condition then ok() else fail(message) end
end

local function equal(actual, expected, message)
    if actual ~= expected then
        fail(string.format("%s: expected %s, got %s",
            message, tostring(expected), tostring(actual)))
        return
    end
    ok()
end

local function test(name, body)
    currentTest = name
    local succeeded, err = pcall(body)
    if not succeeded then fail("threw: " .. tostring(err)) end
end

-- ---------------------------------------------------------------------------
-- Header: the single most important thing on the wall, because a frozen
-- dashboard showing plausible numbers is the failure mode to design against.
-- ---------------------------------------------------------------------------

test("a live frame reads LIVE with its sequence and rate", function()
    local left, right = run.headerText(fixtures.frame(), "live", 120)
    check(left:find("FCS%-DEV") ~= nil, "program name")
    check(right:find("LIVE") ~= nil, "live marker")
    check(right:find("12481") ~= nil, "sequence")
    check(right:find("3%.9") ~= nil, "sample rate")
end)

test("a stale frame reads STALE with its age", function()
    local _, right = run.headerText(fixtures.frame(), "stale", 2400)
    check(right:find("STALE") ~= nil, "stale marker")
    check(right:find("2%.4s") ~= nil, "age")
end)

test("a dead frame reads NO TELEMETRY with its age", function()
    local _, right = run.headerText(fixtures.frame(), "dead", 12000)
    check(right:find("NO TELEMETRY") ~= nil, "dead marker")
    check(right:find("12%.0s") ~= nil, "age")
end)

test("having never received a frame is distinct from a stale one", function()
    local _, right = run.headerText(nil, "dead", nil)
    check(right:find("NO TELEMETRY") ~= nil, "dead marker")
    check(right:lower():find("nil") == nil, "no nils")
end)

test("header never renders nil for a frame missing its fields", function()
    local _, right = run.headerText({ v = 1 }, "live", 100)
    equal(right:lower():find("nil"), nil, "no nils")
end)

-- ---------------------------------------------------------------------------
-- Footer
-- ---------------------------------------------------------------------------

test("footer reports the rednet counters and the active log", function()
    local left, right = run.footerText(fixtures.frame())
    check(left:find("4980") ~= nil, "accepted count")
    check(right:find("flight_") ~= nil, "log file name")
end)

test("footer shows the log file basename, not the whole path", function()
    local _, right = run.footerText(fixtures.frame())
    equal(right:find("/fcs/logs"), nil, "directory should be trimmed")
end)

test("footer survives a frame with no log or net block", function()
    local left, right = run.footerText({ v = 1 })
    equal(left:lower():find("nil"), nil, "no nils on the left")
    equal(right:lower():find("nil"), nil, "no nils on the right")
end)

-- ---------------------------------------------------------------------------
-- Monitor resolution
-- ---------------------------------------------------------------------------

local function fakePeripheral(names, types)
    return {
        getNames = function() return names end,
        isPresent = function(name)
            for _, candidate in ipairs(names) do
                if candidate == name then return true end
            end
            return false
        end,
        hasType = function(name, wanted) return types[name] == wanted end,
        wrap = function(name) return { name = name, setTextScale = function() end } end,
    }
end

test("findMonitor picks the first attached monitor", function()
    run._peripheral = fakePeripheral(
        { "modem_0", "monitor_3", "monitor_4" },
        { modem_0 = "modem", monitor_3 = "monitor", monitor_4 = "monitor" })
    local monitor, name = run.findMonitor(nil)
    check(monitor ~= nil, "monitor found")
    equal(name, "monitor_3", "first monitor by peripheral order")
    run._peripheral = nil
end)

test("findMonitor honours a configured name", function()
    run._peripheral = fakePeripheral(
        { "monitor_3", "monitor_4" },
        { monitor_3 = "monitor", monitor_4 = "monitor" })
    local _, name = run.findMonitor("monitor_4")
    equal(name, "monitor_4", "configured monitor")
    run._peripheral = nil
end)

test("findMonitor explains a missing configured monitor", function()
    run._peripheral = fakePeripheral({ "monitor_3" }, { monitor_3 = "monitor" })
    local monitor, _, reason = run.findMonitor("monitor_9")
    equal(monitor, nil, "no monitor")
    check(reason:find("monitor_9") ~= nil, "reason names the missing monitor")
    run._peripheral = nil
end)

test("findMonitor explains having no monitor at all", function()
    run._peripheral = fakePeripheral({ "modem_0" }, { modem_0 = "modem" })
    local monitor, _, reason = run.findMonitor(nil)
    equal(monitor, nil, "no monitor")
    check(type(reason) == "string", "reason given")
    run._peripheral = nil
end)

-- ---------------------------------------------------------------------------
-- Full render
-- ---------------------------------------------------------------------------

local function renderTo(width, height, frame, freshness, ageMs)
    local target = fixtures.target(width, height)
    local surface = canvas.new(target)
    run.render(surface, frame, freshness, ageMs)
    surface:flush()
    return target, table.concat(target.rows(), "\n")
end

test("a full wall render includes every zone", function()
    local _, text = renderTo(79, 38, fixtures.frame(), "live", 120)
    for _, needle in ipairs({ "ATTITUDE", "POWER", "ENGINES", "PODS" }) do
        check(text:find(needle) ~= nil, needle .. " rendered")
    end
end)

test("a full wall render never shows the string nil", function()
    local _, text = renderTo(79, 38, fixtures.frame(), "live", 120)
    equal(text:lower():find("nil"), nil, "no nils")
end)

test("the render fills the surface without writing out of bounds", function()
    local target = renderTo(79, 38, fixtures.frame(), "live", 120)
    for y = 1, 38 do
        equal(#target.rowText(y), 79, "row " .. y .. " width")
    end
end)

test("a dead render dims the surface and states the remedy", function()
    local _, text = renderTo(79, 38, fixtures.frame(), "dead", 30000)
    check(text:find("NO TELEMETRY") ~= nil, "dead marker")
    check(text:find("main%.lua") ~= nil,
        "a dead hub must say how to restart the logger")
end)

test("the header bar is painted by freshness", function()
    local live = renderTo(79, 38, fixtures.frame(), "live", 120)
    local dead = renderTo(79, 38, fixtures.frame(), "dead", 30000)
    check(live.cells[1][1].bg ~= dead.cells[1][1].bg,
        "a dead feed must not look like a live one at a glance")
end)

test("a render with no frame at all does not throw", function()
    local _, text = renderTo(79, 38, nil, "dead", nil)
    equal(text:lower():find("nil"), nil, "no nils")
end)

test("a render on a screen too small says so", function()
    local _, text = renderTo(20, 6, fixtures.frame(), "live", 120)
    check(text:lower():find("too small") ~= nil, "explains the problem")
end)

test("a frame from an unknown schema version is refused, not mis-drawn", function()
    local frame = fixtures.frame()
    frame.v = 99
    local _, text = renderTo(79, 38, frame, "live", 120)
    check(text:lower():find("version") ~= nil, "version mismatch stated")
end)

test("the terminal size renders without throwing", function()
    local _, text = renderTo(51, 19, fixtures.frame(), "live", 120)
    equal(text:lower():find("nil"), nil, "no nils")
end)

-- ---------------------------------------------------------------------------

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit tools/test_hub_run.lua
```

Expected: `module 'fcs.hub.run' not found`.

- [ ] **Step 3: Write `fcs/hub/run.lua`**

Create `fcs/hub/run.lua`:

```lua
-- The hub's event loop.
--
-- It listens and it draws. It does not require fcs.banks, fcs.sensors or
-- fcs.network, and it must never start to: fcs/main.lua is the only program on
-- this computer that talks to CC:Sable or to the pods. A second reader would
-- duplicate ~50 ms of Sable calls per sample on a loop that already cannot
-- hold its period, and a second sender would put another session on the wire
-- for banks.lua's sender guards to trip over.

local canvas = require("fcs.hub.canvas")
local layout = require("fcs.hub.layout")
local theme = require("fcs.hub.theme")
local widgets = require("fcs.hub.widgets")
local zones = require("fcs.hub.zones")
local snapshot = require("fcs.snapshot")

local run = {}

-- Overridable so tools/test_hub_run.lua can resolve monitors without CC.
run._peripheral = nil

local function peripherals()
    return run._peripheral or _G.peripheral
end

function run.findMonitor(name)
    local api = peripherals()
    if type(api) ~= "table" then
        return nil, nil, "no peripheral API"
    end

    if type(name) == "string" and name ~= "" then
        if not api.isPresent(name) then
            return nil, nil, "configured monitor is missing: " .. name
        end
        if not api.hasType(name, "monitor") then
            return nil, nil, "configured peripheral is not a monitor: " .. name
        end
        return api.wrap(name), name
    end

    for _, candidate in ipairs(api.getNames()) do
        if api.hasType(candidate, "monitor") then
            return api.wrap(candidate), candidate
        end
    end

    return nil, nil, "no monitor is attached"
end

local FRESHNESS_LABEL = {
    live = "LIVE",
    stale = "STALE",
    dead = "NO TELEMETRY",
}

function run.headerText(frame, freshness, ageMs)
    local left = "FCS-DEV"
    local parts = { FRESHNESS_LABEL[freshness] or "NO TELEMETRY" }

    if freshness ~= "live" then
        parts[#parts + 1] = widgets.isFinite(ageMs)
            and widgets.duration(ageMs) or "never"
    end

    if type(frame) == "table" then
        if widgets.isFinite(frame.sequence) then
            parts[#parts + 1] = "seq " .. widgets.number(frame.sequence, "%d")
        end
        local log = frame.log or {}
        if widgets.isFinite(log.actualHz) then
            parts[#parts + 1] = widgets.number(log.actualHz, "%.1f") .. " Hz"
        end
    end

    return left, table.concat(parts, "  ")
end

function run.footerText(frame)
    frame = type(frame) == "table" and frame or {}
    local net = frame.net or {}
    local log = frame.log or {}

    local dropped = nil
    if widgets.isFinite(net.seen) and widgets.isFinite(net.accepted) then
        dropped = net.seen - net.accepted
    end

    local left = string.format("rednet %s/%s/%s",
        widgets.number(net.seen, "%d"),
        widgets.number(net.accepted, "%d"),
        widgets.number(dropped, "%d"))

    local name = widgets.MISSING
    if type(log.path) == "string" then
        name = log.path:match("([^/]+)$") or log.path
    end
    local right = string.format("%s  %s", name, widgets.compact(log.bytes))

    return left, right
end

function run.render(surface, frame, freshness, ageMs)
    -- A stale frame keeps its numbers but loses its saturation: a green
    -- reading on a frozen frame is precisely the lie to avoid.
    surface:setDim(freshness ~= "live")
    surface:clear(theme.background)

    local plan = layout.compute(surface.width, surface.height)

    local headerLeft, headerRight = run.headerText(frame, freshness, ageMs)
    if plan.header then
        widgets.title(surface, plan.header, headerLeft, headerRight,
            theme.freshnessColour(freshness))
    end

    if plan.message then
        surface:text(1, math.max(2, math.floor(surface.height / 2)),
            widgets.clip(plan.message, surface.width),
            theme.status("warn"), theme.background)
        surface:setDim(false)
        return plan
    end

    -- A frame from a schema this build does not know is refused rather than
    -- mis-rendered: field names would silently mean something else.
    if type(frame) == "table" and frame.v ~= nil and frame.v ~= snapshot.VERSION then
        surface:text(1, 3, widgets.clip(string.format(
            "snapshot version %s, this hub speaks %s -- redeploy /fcs-dev.lua and /fcs/",
            tostring(frame.v), tostring(snapshot.VERSION)), surface.width),
            theme.status("bad"), theme.background)
        surface:setDim(false)
        return plan
    end

    for _, entry in ipairs(plan.zones) do
        local zone = zones.get(entry.name)
        if not zone then
            widgets.degraded(surface, entry.rect, entry.name,
                layout.MINIMUMS[entry.name])
        elseif entry.degraded then
            widgets.degraded(surface, entry.rect, entry.name,
                layout.MINIMUMS[entry.name])
        else
            -- One zone must not be able to blank the wall.
            local ok, err = pcall(zone.draw, surface, entry.rect, frame)
            if not ok then
                surface:fill(entry.rect.x, entry.rect.y,
                    entry.rect.w, entry.rect.h, theme.background)
                surface:text(entry.rect.x, entry.rect.y,
                    widgets.clip(entry.name .. " render failed", entry.rect.w),
                    theme.status("bad"), theme.background)
                surface:text(entry.rect.x, entry.rect.y + 1,
                    widgets.clip(tostring(err), entry.rect.w),
                    theme.status("warn"), theme.background)
            end
        end
    end

    if plan.footer then
        local footerLeft, footerRight = run.footerText(frame)
        if freshness == "dead" then
            footerLeft = "logger not running -- start /fcs/main.lua"
        elseif #plan.hidden > 0 then
            footerLeft = footerLeft .. "  hidden: " .. table.concat(plan.hidden, " ")
        end
        widgets.title(surface, plan.footer, footerLeft, footerRight)
    end

    surface:setDim(false)
    return plan
end

function run.start(options)
    options = options or {}
    local maxRedrawHz = options.maxRedrawHz or 5
    local staleAfterMs = options.staleAfterMs or theme.defaultStaleAfterMs
    local deadAfterMs = options.deadAfterMs or theme.defaultDeadAfterMs
    local redrawPeriod = 1 / maxRedrawHz

    local target, targetName
    if options.term then
        target = term.current()
        targetName = "terminal"
    else
        local monitor, name, reason = run.findMonitor(options.monitorName)
        if monitor then
            monitor.setTextScale(options.textScale or 0.5)
            target, targetName = monitor, name
        else
            print("fcs-dev: " .. tostring(reason) .. "; using the terminal")
            target = term.current()
            targetName = "terminal"
        end
    end

    local surface = canvas.new(target)
    print("fcs-dev: rendering to " .. tostring(targetName)
        .. " (" .. surface.width .. "x" .. surface.height .. ")")

    -- Seed from disk so a hub started cold has something to draw immediately,
    -- and so a hub started with no logger running shows the last known frame
    -- with an honest age rather than an empty screen.
    local frame = snapshot.read()
    local dirty = true
    local lastFreshness = nil
    local lastDrawAt = 0

    local timer = os.startTimer(redrawPeriod)

    while true do
        local event, first = os.pullEvent()

        if event == "fcs_snapshot" then
            if type(first) == "table" then
                frame = first
                dirty = true
            end
        elseif event == "monitor_resize" or event == "term_resize" then
            surface:resize()
            dirty = true
        elseif event == "timer" and first == timer then
            local now = os.epoch("utc")
            local ageMs = nil
            if type(frame) == "table" and widgets.isFinite(frame.utc_ms) then
                ageMs = now - frame.utc_ms
            end
            local freshness = theme.freshness(ageMs, staleAfterMs, deadAfterMs)

            -- Repaint on new data, on a change of freshness, and at least once
            -- a second so the age counter keeps moving while nothing arrives.
            if dirty or freshness ~= lastFreshness or now - lastDrawAt >= 1000 then
                run.render(surface, frame, freshness, ageMs)
                surface:flush()
                dirty = false
                lastFreshness = freshness
                lastDrawAt = now
            end

            timer = os.startTimer(redrawPeriod)
        end
    end
end

return run
```

- [ ] **Step 4: Write `fcs-dev.lua`**

Create `fcs-dev.lua`:

```lua
-- fcs-dev: the monitor hub for the main FCS computer.
--
-- Reads telemetry frames published by /fcs/main.lua and draws them. It sends
-- nothing, commands nothing, and opens no modem.
--
-- How this program is started decides whether it has require() at all.
-- shell.run and shell.openTab wrap a program in a shell env, which injects
-- require/package. multishell.launch goes straight to os.run() and injects
-- neither, so touching package.path there throws on a nil global. Build them
-- when missing, rooted at "/" so "fcs.x" resolves to /fcs/x.lua.
if package then
    package.path = "/?.lua;/?/init.lua;" .. package.path
else
    require, package = dofile("/rom/modules/main/cc/require.lua").make(_ENV, "/")
end

local config = require("fcs.config")
local run = require("fcs.hub.run")

local USAGE = [[
fcs-dev -- helicarrier monitor hub

  fcs-dev                    render to the configured or first monitor
  fcs-dev --term             render to this terminal instead
  fcs-dev --monitor <name>   render to a named monitor peripheral
  fcs-dev --scale <n>        override the monitor text scale

Reads frames published by /fcs/main.lua. Commands nothing.
]]

local hub = config.hub or {}

local options = {
    monitorName = hub.monitorName,
    textScale = hub.textScale or 0.5,
    maxRedrawHz = hub.maxRedrawHz or 5,
    staleAfterMs = hub.staleAfterMs or 1000,
    deadAfterMs = hub.deadAfterMs or 5000,
    term = false,
}

local arguments = { ... }
local index = 1
while index <= #arguments do
    local argument = arguments[index]
    if argument == "--term" then
        options.term = true
    elseif argument == "--monitor" then
        index = index + 1
        options.monitorName = arguments[index]
        if not options.monitorName then
            printError("--monitor needs a peripheral name")
            print(USAGE)
            return
        end
    elseif argument == "--scale" then
        index = index + 1
        local scale = tonumber(arguments[index])
        if not scale then
            printError("--scale needs a number")
            print(USAGE)
            return
        end
        options.textScale = scale
    elseif argument == "--help" or argument == "-h" then
        print(USAGE)
        return
    else
        printError("unknown option: " .. tostring(argument))
        print(USAGE)
        return
    end
    index = index + 1
end

run.start(options)
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit tools/test_hub_run.lua
```

Expected: `N passed, 0 failed`.

- [ ] **Step 6: Syntax-check the entry point**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit -b fcs-dev.lua /dev/null && echo "fcs-dev.lua compiles"
```

Expected: `fcs-dev.lua compiles`.

- [ ] **Step 7: Confirm the one-talker invariant holds**

```bash
# Matches real require calls and rednet usage, NOT the prose in run.lua's
# header comment that explains why they are absent.
cd ~/repos/fcs-wireless-pods-v2 && \
  grep -rnE "require\(['\"]fcs\.(banks|sensors|network)['\"]\)|rednet\.[a-zA-Z]" \
    fcs/hub fcs-dev.lua \
  && echo "FOUND FORBIDDEN REQUIRE" || echo "clean: the hub talks to nobody"
```

Expected: `clean: the hub talks to nobody`.

- [ ] **Step 8: Checkpoint**

```bash
cd ~/repos/fcs-wireless-pods-v2 && for t in mixer hub_canvas hub_layout hub_widgets snapshot hub_zones hub_run; do \
  echo "== $t"; luajit tools/test_$t.lua || exit 1; done
```

Expected: every suite reports `0 failed`.

---

## Task 12: Configuration and autostart

**Files:**
- Modify: `fcs/config.lua:83-85` (add the `hub` block before the closing brace)
- Modify: `startup.lua` (path preamble, and a third tab guarded on a monitor)

**Interfaces:**
- Consumes: `fcs-dev.lua` reads `config.hub` (Task 11).
- Produces: `config.hub = { monitorName, textScale, autoStart, maxRedrawHz, staleAfterMs, deadAfterMs }`.

- [ ] **Step 1: Add the hub block to `fcs/config.lua`**

In `fcs/config.lua`, after the closing brace of the `wireless = { … }` table (line 84) and before the file's final `}` on line 85, add:

```lua

    -- Monitor hub (/fcs-dev.lua). Read-only: the hub renders frames published
    -- by the telemetry loop and commands nothing.
    hub = {
        -- nil = use the first attached monitor.
        monitorName = nil,

        -- 0.5 gives roughly 79x38 characters on a 4x3 Advanced Monitor, which
        -- is what the zone layout is designed around.
        textScale = 0.5,

        -- Open a hub tab on boot, but only when a monitor is actually present.
        autoStart = true,

        -- Repaint ceiling, independent of how fast frames arrive. The wall is
        -- roughly 3000 cells; repainting all of it on every sample flickers
        -- and wastes server tick for no added information.
        maxRedrawHz = 5,

        -- Frame age at which the header stops saying LIVE, and at which it
        -- stops claiming to have telemetry at all. A dashboard frozen on
        -- plausible numbers is the failure mode these exist to prevent.
        staleAfterMs = 1000,
        deadAfterMs = 5000,
    },
```

- [ ] **Step 2: Verify the config still loads**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit -e 'package.path="./?.lua;"..package.path
local c = require("fcs.config")
assert(type(c.hub) == "table", "hub block missing")
assert(c.hub.textScale == 0.5, "text scale")
assert(c.hub.autoStart == true, "autostart")
assert(c.wireless.offlineAfterMs == 5000, "existing config intact")
print("config ok")'
```

Expected: `config ok`.

- [ ] **Step 3: Add the path preamble to `startup.lua`**

In `startup.lua`, immediately after the opening comment block and before `term.clear()`, add:

```lua
-- Root the module search at "/" so "fcs.config" resolves to /fcs/config.lua
-- regardless of the shell's working directory.
if package then
    package.path = "/?.lua;/?/init.lua;" .. package.path
end
```

- [ ] **Step 4: Open the hub tab**

In `startup.lua`, at the end of the file (after the existing `if multishell and shell and shell.openTab then … else … end` block), add:

```lua

-- Monitor hub, in its own tab. Guarded on a monitor actually being present, so
-- a computer with no wall boots exactly as it did before this existed.
local configLoaded, config = pcall(require, "fcs.config")
local hub = (configLoaded and type(config) == "table" and config.hub) or {}

if hub.autoStart ~= false and multishell and shell and shell.openTab then
    local hasMonitor = false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "monitor") then
            hasMonitor = true
            break
        end
    end

    if hasMonitor then
        local hubTab = shell.openTab("/fcs-dev.lua")
        multishell.setTitle(hubTab, "Monitor Hub")
        print("Monitor hub tab: " .. tostring(hubTab))
    else
        print("No monitor attached; run fcs-dev when one is placed.")
    end
end
```

- [ ] **Step 5: Syntax-check**

```bash
cd ~/repos/fcs-wireless-pods-v2 && luajit -b startup.lua /dev/null \
  && luajit -b fcs/config.lua /dev/null && echo "startup and config compile"
```

Expected: `startup and config compile`.

- [ ] **Step 6: Checkpoint**

```bash
cd ~/repos/fcs-wireless-pods-v2 && for t in mixer hub_canvas hub_layout hub_widgets snapshot hub_zones hub_run; do \
  echo "== $t"; luajit tools/test_$t.lua || exit 1; done
```

Expected: every suite reports `0 failed`.

---

## Task 13: Deploy, in-world acceptance, and documentation

The off-server suite proves the drawing logic. Only the carrier proves the wiring.

**Files:**
- Deploy: `fcs-dev.lua`, `fcs/snapshot.lua`, `fcs/hub/` (7 files), `fcs/config.lua`, `fcs/main.lua`, `startup.lua` → FCS-DEV
- Modify: `README.md` (file listing and a hub section)
- Modify: `HANDOFF.md` (a `## fcs-dev hub` section)

**Interfaces:**
- Consumes: everything from Tasks 2–12.
- Produces: a verified wall, and a written record of what was verified.

- [ ] **Step 1: Copy the package to FCS-DEV**

Copy into the FCS-DEV computer directory:

```text
fcs-dev.lua           -> /fcs-dev.lua
startup.lua           -> /startup.lua
fcs/config.lua        -> /fcs/config.lua
fcs/main.lua          -> /fcs/main.lua
fcs/snapshot.lua      -> /fcs/snapshot.lua
fcs/hub/theme.lua     -> /fcs/hub/theme.lua
fcs/hub/canvas.lua    -> /fcs/hub/canvas.lua
fcs/hub/layout.lua    -> /fcs/hub/layout.lua
fcs/hub/widgets.lua   -> /fcs/hub/widgets.lua
fcs/hub/run.lua       -> /fcs/hub/run.lua
fcs/hub/zones/        -> /fcs/hub/zones/   (init, attitude, engines, pods, power)
```

Keep `fcs/config.lua`'s existing `podIds` values — do not overwrite them with the repository's `nil` placeholders.

- [ ] **Step 2: Place the wall and confirm the hub finds it**

Build the 4x3 Advanced Monitor and attach it to FCS-DEV. Reboot the computer.

Expected: a third tab titled `Monitor Hub` opens, and the wall shows the header, four zone title bars, and live values.

If the hub prints `no monitor is attached` and falls back to the terminal, the monitor is not connected to the computer — check the block adjacency or the wired modem.

- [ ] **Step 3: Acceptance 1 — all four zones populate**

With the logger running, read the wall.

Expected: header reads `LIVE` with a sequence number and a rate near `3.9 Hz`; ENGINES shows four corners of RPM with `b1`/`b2` thrust at full resolution (five digits, e.g. `13961`, **not** `14.0k`); PODS shows `4/4 up`.

- [ ] **Step 4: Acceptance 2 — staleness is visible**

Switch to the telemetry tab and stop it with Ctrl+T. Watch the wall.

Expected: within about a second the header changes to `STALE` with a rising age and the colours dim; by five seconds it reads `NO TELEMETRY` and the footer says `logger not running -- start /fcs/main.lua`. The last frame's numbers stay on screen.

This is the single most important behaviour on the wall. If the numbers keep looking live after the logger stops, stop and fix it before flying anything.

- [ ] **Step 5: Acceptance 3 — recovery without restarting the hub**

Restart the logger: `fg` to the telemetry tab, or `shell.openTab("/fcs/main.lua")`.

Expected: the header returns to `LIVE` on its own. The hub is not restarted.

- [ ] **Step 6: Acceptance 4 — pod loss is distinct from logger loss**

Power down one pod computer (or Ctrl+T its program).

Expected: the header stays `LIVE`; that corner's PODS `link` row reads `DOWN` with a rising age and turns red; `3/4 up` appears in the PODS title; the other three corners are untouched.

- [ ] **Step 7: Acceptance 5 — logging is not slowed by the hub**

In the shell:

```
edit /fcs/heartbeat.txt
```

Record `sequence`. Wait 60 seconds and read it again.

Expected: roughly 230-240 samples in 60 s, matching the ~3.9 Hz the loop achieved before the hub existed, and `snapshot_failures=0`.

If the rate dropped noticeably, raise `hub.maxRedrawHz` scrutiny first: set `maxRedrawHz = 2` in `/fcs/config.lua`, reboot, and measure again. If that recovers the rate, the cost is in rendering, not in publishing.

- [ ] **Step 8: Acceptance 6 — the terminal fallback works**

In the shell: `fcs-dev --term`

Expected: the same hub renders at 51x19 with `ENGINES` and `PODS` visible and the footer listing `hidden: ATTITUDE POWER`. Ctrl+T to exit.

- [ ] **Step 9: Update `README.md`**

In the FCS-DEV filesystem listing, add the new files:

```text
/
├── startup.lua
├── fcs-dev.lua
└── fcs/
    ├── ...
    ├── snapshot.lua
    └── hub/
        ├── canvas.lua
        ├── layout.lua
        ├── run.lua
        ├── theme.lua
        ├── widgets.lua
        └── zones/
            ├── init.lua
            ├── attitude.lua
            ├── engines.lua
            ├── pods.lua
            └── power.lua
```

Then add a section after "Main-computer configuration":

```markdown
## Monitor hub

`fcs-dev` renders live telemetry to an attached monitor. It is read-only: it
draws frames published by the telemetry loop and commands nothing.

Attach a monitor to FCS-DEV -- a 4x3 Advanced Monitor at text scale 0.5 gives
roughly 79x38 characters, which is the size the layout is designed around. On
reboot the hub opens in its own tab automatically when a monitor is present.

    fcs-dev                    render to the configured or first monitor
    fcs-dev --term             render to the terminal instead
    fcs-dev --monitor <name>   render to a named monitor
    fcs-dev --scale <n>        override the text scale

Settings live in the `hub` block of `/fcs/config.lua`. Set `autoStart = false`
to stop it opening on boot.

The header is the thing to read first: `LIVE` means the frame is under a second
old, `STALE` means the telemetry loop has gone quiet, and `NO TELEMETRY` means
it has been quiet for over five seconds -- the numbers on screen are the last
ones received, not current ones.
```

- [ ] **Step 10: Update `HANDOFF.md`**

Add a section recording what a fresh session needs to know:

```markdown
## fcs-dev hub

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

Offline tests, all plain luajit from the repo root:

    luajit tools/test_hub_canvas.lua
    luajit tools/test_hub_layout.lua
    luajit tools/test_hub_widgets.lua
    luajit tools/test_hub_zones.lua
    luajit tools/test_hub_run.lua
    luajit tools/test_snapshot.lua

`test_hub_zones.lua` runs a shared battery over every registered zone against
hostile frames (nils, NaN, offline pods, missing bearings). A new zone added to
`fcs/hub/zones/init.lua` is covered by it automatically.

Per-bearing thrust is printed at full resolution deliberately: the deficit
under investigation is ~1%, and 13960.98 and 13804.41 both round to "14.0k".
```

- [ ] **Step 11: Final checkpoint**

```bash
cd ~/repos/fcs-wireless-pods-v2 && for t in mixer hub_canvas hub_layout hub_widgets snapshot hub_zones hub_run; do \
  echo "== $t"; luajit tools/test_$t.lua || exit 1; done \
  && grep -rnE "require\(['\"]fcs\.(banks|sensors|network)['\"]\)|rednet\.[a-zA-Z]" \
    fcs/hub fcs-dev.lua \
  && echo "FOUND FORBIDDEN REQUIRE" || echo "ALL GREEN"
```

Expected: every suite reports `0 failed`, then `ALL GREEN`.

---

## Deferred to a later phase

Named here so a future session does not have to rediscover the seam:

- **Touch control.** `fcs/hub/input.lua` on `monitor_touch`, emitting
  `os.queueEvent("fcs_command", …)`, dispatched by `fcs/main.lua` through
  `banks.send`. Arm/disarm, set RPM, launch a flight profile, e-stop. The
  read-only zone modules do not change.
- **Paging on small screens.** `layout.compute` already reports `hidden`; a
  page cycle would rotate hidden zones into view on a timer or a key.
- **Historical strips.** A sparkline of the last N frames per corner would make
  a drifting bearing visible before it crosses a threshold. Needs a ring buffer
  in the hub, which is why it is not in this phase.
