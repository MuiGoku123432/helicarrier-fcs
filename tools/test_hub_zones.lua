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
-- Fixture provenance
--
-- The zones are asserted against fixtures.frame(). If that is a hand-written
-- literal, these 2000-odd assertions only prove the zones agree with the
-- literal -- which is how prop.tilt, a field with no producer, survived
-- thirteen reviews. fixtures.frame() must be snapshot.build's own output from
-- a producer-shaped input.
-- ---------------------------------------------------------------------------

local snapshot = require("fcs.snapshot")

test("the frame the zones are tested against is built by snapshot.build", function()
    local context = fixtures.context()
    check(type(context) == "table", "fixtures.context exists")
    -- Producer-side names, not frame-side ones.
    check(context.state.linearVelocityBody ~= nil, "context uses linearVelocityBody")
    check(context.peripheralState.props.FL.perBearing ~= nil, "context uses perBearing")
    check(context.peripheralState.props.FL.tiltAngle ~= nil, "context uses tiltAngle")
    check(context.podStates.FL.receivedAt ~= nil, "context uses receivedAt")

    local built = snapshot.build(context)
    local frame = fixtures.frame()
    equal(frame.v, built.v, "same schema version")
    equal(frame.utc_ms, built.utc_ms, "same timestamp")
    equal(frame.craft.bodyVel.x, built.craft.bodyVel.x, "same body velocity")
    equal(frame.corners.RR.bearings[2].thrust, built.corners.RR.bearings[2].thrust,
        "same RR bearing 2 thrust")
    equal(frame.pods.FL.ageMs, built.pods.FL.ageMs, "same pod age")
end)

test("the fixture carries a tilt the zones can actually render", function()
    -- Fails if snapshot.build ever stops mapping the producer's tiltAngle:
    -- the ENGINES tilt row would go back to "--" on every real craft.
    local frame = fixtures.frame()
    for _, corner in ipairs({ "FL", "FR", "RL", "RR" }) do
        check(type(frame.corners[corner].tilt) == "number",
            corner .. " tilt reaches the frame")
    end
end)

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

    test(name .. ": actually renders content", function()
        -- The other battery checks are all satisfied by a zone that draws
        -- nothing at all -- bounds, no-nil, no-throw and determinism are each
        -- trivially true for an empty draw. This is the one that isn't.
        local surface, target = paintedSurface(width, height)
        target.reset()
        zone.draw(surface, rect, fixtures.frame())
        surface:flush()
        check(target.written() > 0, name .. " drew nothing into its rect")
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

-- Regression: attitude drew at fixed row indices 1..9 and needed h >= 10, but
-- layout.MINIMUMS.ATTITUDE.h is 8. Rows past the rect were dropped silently by
-- the old row() helper -- at 45x8 both MASS and XYZ vanished with nothing said.
test("attitude states its hidden row count at the layout minimum", function()
    local minimum = layout.MINIMUMS.ATTITUDE
    local rect = { x = 1, y = 1, w = minimum.w, h = minimum.h }
    local target = drawInto(attitude, fixtures.frame(), rect,
        minimum.w + 2, minimum.h + 2)
    local text = textOf(target)

    check(text:find("ATTITUDE") ~= nil, "title present at the minimum")
    check(text:find("%d hidden") ~= nil, "hidden count stated at the minimum")
    -- The ladder rows are the reason the zone exists: they survive.
    check(text:find("ROLL") ~= nil, "roll survives at the minimum")
    check(text:find("PITCH") ~= nil, "pitch survives at the minimum")
    check(text:find("YAW") ~= nil, "yaw survives at the minimum")
end)

test("attitude's hidden count is computed from what was actually dropped", function()
    local minimum = layout.MINIMUMS.ATTITUDE
    local function hiddenAt(h)
        local rect = { x = 1, y = 1, w = minimum.w, h = h }
        local target = drawInto(attitude, fixtures.frame(), rect, minimum.w + 2, h + 2)
        return tonumber(textOf(target):match("(%d+) hidden"))
    end
    -- Eight content rows, one title row: h - 1 of them fit.
    equal(hiddenAt(minimum.h), 8 - (minimum.h - 1), "hidden at the minimum height")
    equal(hiddenAt(5), 4, "hidden at h=5")
    equal(hiddenAt(7), 2, "hidden at h=7")
end)

test("attitude renders every row with no hidden note on a comfortable rect", function()
    local rect = { x = 1, y = 1, w = 45, h = 14 }
    local target = drawInto(attitude, fixtures.frame(), rect, 47, 16)
    local text = textOf(target)
    check(text:find("hidden") == nil, "no hidden note when everything fits")
    for _, label in ipairs({ "ROLL", "PITCH", "YAW",
        "BODY V", "WORLD V", "ANG V", "MASS", "XYZ" }) do
        check(text:find(label, 1, true) ~= nil, label .. " row rendered")
    end
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

-- Regression tests for Critical 1: link states distinguishability at minimum rect
test("pods at minimum rect: offline-with-age and never-reported are distinguishable", function()
    local minimum = layout.MINIMUMS["PODS"]
    local rect = { x = 1, y = 1, w = minimum.w, h = minimum.h }
    local width = rect.x + rect.w + 2
    local height = rect.y + rect.h + 2

    -- Frame with offline pod that has an age
    local frame1 = fixtures.frame()
    frame1.pods.FL.online = false
    frame1.pods.FL.ageMs = 6200
    frame1.pods.FR.online = true
    frame1.pods.RL.online = true
    frame1.pods.RR.online = true
    local target1 = drawInto(pods, frame1, rect, width, height)
    local text1 = textOf(target1)

    -- Frame with offline pod that has never reported
    local frame2 = fixtures.frame()
    frame2.pods.FL.online = false
    frame2.pods.FL.ageMs = nil
    frame2.pods.FR.online = true
    frame2.pods.RL.online = true
    frame2.pods.RR.online = true
    local target2 = drawInto(pods, frame2, rect, width, height)
    local text2 = textOf(target2)

    check(text1 ~= text2, "offline-with-age and never-reported render different text at minimum rect")
    check(text1:find("6%.2s") ~= nil or text1:find("6s") ~= nil, "frame with age shows the age value")
    check(text2:find("%-%-") ~= nil, "frame without age shows missing indicator")
end)

-- Regression tests for Critical 2: fault section always renders at minimum rect
test("pods at minimum rect: renders fault header and content", function()
    local minimum = layout.MINIMUMS["PODS"]
    local rect = { x = 1, y = 1, w = minimum.w, h = minimum.h }
    local width = rect.x + rect.w + 2
    local height = rect.y + rect.h + 2

    local frame = fixtures.frame()
    frame.pods.RR.faults = { "thruster_7 unresponsive" }
    local target = drawInto(pods, frame, rect, width, height)
    local text = textOf(target)

    check(text:find("FAULTS") ~= nil, "FAULTS header present at minimum rect")
    check(text:find("thruster") ~= nil or text:find("more") ~= nil,
        "fault text or truncation notice present at minimum rect")
end)

-- Regression tests for Important 3: hidden row count shown at minimum rect
test("pods at minimum rect: shows hidden row count in title", function()
    local minimum = layout.MINIMUMS["PODS"]
    local rect = { x = 1, y = 1, w = minimum.w, h = minimum.h }
    local width = rect.x + rect.w + 2
    local height = rect.y + rect.h + 2

    local frame = fixtures.frame()
    local target = drawInto(pods, frame, rect, width, height)
    local text = textOf(target)

    check(text:find("hidden") ~= nil, "hidden row count shown at minimum rect")
end)

-- Verify existing wide-rect behaviour still works without regression
test("pods at full size: all rows present, no hidden count", function()
    local frame = fixtures.frame()
    local rect = { x = 1, y = 1, w = 79, h = 12 }
    local target = drawInto(pods, frame, rect, 79, 14)
    local text = textOf(target)

    check(text:find("hidden") == nil, "no hidden count at full size rect")
    check(text:find("cmd") ~= nil, "cmd row present at full size")
end)

test("engines shows its flags row at the layout minimum height", function()
    -- The title takes rect.y and the content rows take rect.y+1.., so the zone
    -- needs one more line than its content-row count. Reading the minimum from
    -- layout keeps this honest if the minimum is ever retuned.
    local minimum = layout.MINIMUMS.ENGINES
    local frame = fixtures.frame()
    frame.corners.RL.overstressed = true
    local rect = { x = 1, y = 1, w = minimum.w, h = minimum.h }
    local target = drawInto(engines, frame, rect, minimum.w + 2, minimum.h + 3)
    local text = textOf(target)
    check(text:find("flags") ~= nil, "the flags row must render at the minimum height")
    check(text:find("OS") ~= nil, "the overstressed flag must be visible at the minimum height")
end)

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
    frame.pods.FL.averagePower = 0.99
    local rect = { x = 1, y = 1, w = 34, h = 14 }
    local target = drawInto(power, frame, rect, 36, 16)
    local text = textOf(target)
    check(text:find("ION") ~= nil, "ion section")
    check(text:find("0%.99") ~= nil, "per-pod value for FL corner")
end)

-- Regression tests for Important 1: row budget at minimum rect
test("power at minimum rect: shows hidden row count in title", function()
    local minimum = layout.MINIMUMS.POWER
    local rect = { x = 1, y = 1, w = minimum.w, h = minimum.h }
    local width = rect.x + rect.w + 2
    local height = rect.y + rect.h + 2

    local frame = fixtures.frame()
    local target = drawInto(power, frame, rect, width, height)
    local text = textOf(target)

    check(text:find("hidden") ~= nil, "hidden row count shown at minimum rect")
    check(text:find("1%.24M") ~= nil, "FE storage line present at minimum rect")
    check(text:find("grid W") ~= nil, "grid W reading present at minimum rect")
end)

-- Verify existing large-rect behaviour: no hidden count, ION section visible
test("power at full size: all rows present, no hidden count", function()
    local frame = fixtures.frame()
    local rect = { x = 1, y = 1, w = 34, h = 14 }
    local target = drawInto(power, frame, rect, 36, 16)
    local text = textOf(target)

    check(text:find("hidden") == nil, "no hidden count at full size rect")
    check(text:find("ION") ~= nil, "ION section present at full size")
    check(text:find("FL") ~= nil, "pod list present at full size")
end)

-- ---------------------------------------------------------------------------

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
