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

-- snapshot.lua collects log.freeSpace every sample and nothing rendered it.
-- The snapshot file and the CSV log share one disk quota, so this is the
-- number that answers whether the log will keep writing.
test("footer reports free disk space", function()
    local _, right = run.footerText(fixtures.frame())
    check(right:find("free") ~= nil, "free space labelled")
    check(right:find("9%.00M") ~= nil, "free space value")
end)

test("footer omits free space rather than printing dashes for it", function()
    local frame = fixtures.frame()
    frame.log.freeSpace = nil
    local _, right = run.footerText(frame)
    equal(right:find("free"), nil, "no free-space note when the frame lacks it")
    equal(right:lower():find("nil"), nil, "no nils")
end)

test("the footer still fits the target wall's width", function()
    local left, right = run.footerText(fixtures.frame())
    check(#left + #right + 4 <= 79,
        "footer fits 79 columns, is " .. (#left + #right + 4))
end)

-- ---------------------------------------------------------------------------
-- Redraw period
--
-- config.hub is hand-edited on the CC computer. 1/maxRedrawHz used to be
-- unguarded: 0 gave inf and os.startTimer throws at launch, and a negative
-- value spun the hub at tick rate against the sample loop flying the craft.
-- ---------------------------------------------------------------------------

test("a redraw rate of zero cannot produce an infinite timer", function()
    local period = run.redrawPeriod(0)
    check(period == period, "period is not NaN")
    check(period ~= math.huge, "period is finite")
    check(period > 0, "period is positive")
    equal(period, 1 / run.MIN_REDRAW_HZ, "clamped to the floor")
end)

test("a negative redraw rate cannot produce a negative timer", function()
    for _, hz in ipairs({ -1, -0.001, -1000 }) do
        local period = run.redrawPeriod(hz)
        check(period > 0, "period positive for " .. hz)
        equal(period, 1 / run.MIN_REDRAW_HZ, "clamped to the floor for " .. hz)
    end
end)

test("a nonsense redraw rate cannot produce a nonsense timer", function()
    for _, hz in ipairs({ 0 / 0, math.huge, -math.huge }) do
        local period = run.redrawPeriod(hz)
        check(period == period and period > 0 and period ~= math.huge,
            "period usable for " .. tostring(hz))
    end
    equal(run.redrawPeriod("fast"), 1 / run.MIN_REDRAW_HZ, "a non-number clamps too")
end)

test("a sane redraw rate is left alone", function()
    equal(run.redrawPeriod(5), 1 / 5, "5 Hz")
    equal(run.redrawPeriod(1), 1, "1 Hz")
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

-- Regression: a zone whose module is absent (a partial hand-copy onto the CC
-- computer, or a syntax error that fcs/hub/zones/init.lua swallows into the
-- same nil) used to fall into widgets.degraded, which prints "needs 38x7" --
-- a false explanation on a 79x38 wall that sends the operator to rebuild the
-- monitor instead of to redeploy /fcs/hub/zones/.
test("a zone whose module is not deployed says so, not that the screen is small", function()
    local zones = require("fcs.hub.zones")
    local original = zones.get
    -- Stubbed only for the duration of this render, and restored below whether
    -- the render throws or not.
    zones.get = function(name)
        if name == "PODS" then
            return nil
        end
        return original(name)
    end
    local rendered, target, text = pcall(renderTo, 79, 38, fixtures.frame(), "live", 120)
    zones.get = original

    check(rendered, "the render survived a missing zone module: " .. tostring(target))
    if not rendered then
        return
    end
    check(text:find("PODS") ~= nil, "the missing zone is named")
    check(text:lower():find("not deployed") ~= nil, "the real cause is stated")
    equal(text:find("needs %d+x%d+"), nil,
        "a 79x38 wall must not be told it is too small")
    -- The zones that did load still render.
    for _, needle in ipairs({ "ATTITUDE", "POWER", "ENGINES" }) do
        check(text:find(needle) ~= nil, needle .. " still rendered")
    end
end)

test("the registry stub left nothing behind", function()
    local zones = require("fcs.hub.zones")
    check(zones.get("PODS") ~= nil, "PODS resolves again")
    local _, text = renderTo(79, 38, fixtures.frame(), "live", 120)
    equal(text:lower():find("not deployed"), nil, "no lingering placeholder")
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
