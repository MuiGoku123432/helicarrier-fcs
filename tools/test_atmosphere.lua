-- Offline tests for fcs/atmosphere.lua.
--
--     luajit tools/test_atmosphere.lua      (from the repo root)
--
-- The expected values here are not invented: every one was MEASURED in game by
-- /fcs/pressureprobe.lua, where aero.getAirPressure and
-- pressureFunction.evaluateFunction agreed to eight decimal places at each
-- altitude (flight-logs/pressureprobe.txt). So this suite asserts that the
-- local model reproduces the mod's own curve, not that it matches some
-- formula I liked.

package.path = "./?.lua;" .. package.path

local atmosphere = require("fcs.atmosphere")

-- The exact control points returned by getPoints() on the creative superflat
-- test server, 2026-08-25.
local POINTS = {
    { altitude = -38.36627703, value = 1.50000000, slope = -0.00600000 },
    { altitude =  63.00000000, value = 1.00000000, slope = -0.00400000 },
    { altitude = 263.00000000, value = 0.44932896, slope = -0.00179732 },
    { altitude = 280.00000000, value = 0.41979029, slope = -0.00167916 },
    { altitude = 320.00000000, value = 0.00000000, slope = -0.02098951 },
}

-- Measured pressures, straight out of the probe report.
local MEASURED = {
    { y = -64, pressure = 1.50000000 },
    { y =   0, pressure = 1.28651875 },
    { y =  32, pressure = 1.13195451 },
    { y =  64, pressure = 0.99600768 },
    { y =  96, pressure = 0.87610924 },
    { y = 128, pressure = 0.77047922 },
    { y = 192, pressure = 0.59631092 },
    { y = 256, pressure = 0.46207570 },
    { y = 320, pressure = 0.00000000 },
}

local passed, failed = 0, 0
local currentTest = "<none>"

local function fail(message)
    failed = failed + 1
    print(string.format("  FAIL  %s: %s", currentTest, message))
end

local function check(condition, message)
    if condition then passed = passed + 1 else fail(message) end
end

local function near(actual, expected, tolerance, message)
    if type(actual) ~= "number" then
        fail(message .. ": expected a number, got " .. tostring(actual))
        return
    end
    if math.abs(actual - expected) > tolerance then
        fail(string.format("%s: expected %.8f, got %.8f (off by %.2e)",
            message, expected, actual, math.abs(actual - expected)))
        return
    end
    passed = passed + 1
end

local function test(name, body)
    currentTest = name
    local ok, err = pcall(body)
    if not ok then fail("threw: " .. tostring(err)) end
end

-- ---------------------------------------------------------------------------

test("reproduces every measured in-game pressure", function()
    local model = atmosphere.fromPoints(POINTS)
    -- 1e-5 is loose enough for the control points being reported to 8 figures
    -- and tight enough that a wrong interpolation scheme fails: a pure
    -- exponential is off by 6e-5 at y=32, six times this bound.
    for _, sample in ipairs(MEASURED) do
        near(model.pressureAt(sample.y), sample.pressure, 1e-5,
            string.format("y=%d", sample.y))
    end
end)

test("an exponential model would NOT pass the previous test", function()
    -- Guards the guard. If someone swaps the Hermite evaluation for the
    -- exponential that the scale height suggests, the tolerance above must
    -- catch it -- so prove the two really are distinguishable at 1e-5.
    local anchor, rate = 1.0, -0.004        -- value at y=63, H = 250 blocks
    local exponential = anchor * math.exp(rate * (32 - 63))
    local model = atmosphere.fromPoints(POINTS)
    local hermite = model.pressureAt(32)

    check(math.abs(exponential - hermite) > 1e-5,
        string.format("exponential %.8f and Hermite %.8f are indistinguishable",
            exponential, hermite))
end)

test("passes exactly through its own control points", function()
    local model = atmosphere.fromPoints(POINTS)
    for _, point in ipairs(POINTS) do
        near(model.pressureAt(point.altitude), point.value, 1e-9,
            string.format("knot at y=%.5f", point.altitude))
    end
end)

test("clamps below the lowest control point", function()
    local model = atmosphere.fromPoints(POINTS)
    -- Measured: y=-64 reads exactly 1.5, the same as the first knot's value,
    -- so the curve is flat below it rather than continuing to rise.
    near(model.pressureAt(-64), 1.5, 1e-9, "y=-64")
    near(model.pressureAt(-1000), 1.5, 1e-9, "y=-1000")
end)

test("the ceiling is hard: zero at 320 and above", function()
    local model = atmosphere.fromPoints(POINTS)
    near(model.pressureAt(320), 0.0, 1e-9, "y=320")
    near(model.pressureAt(400), 0.0, 1e-9, "y=400")
    near(model.pressureAt(100000), 0.0, 1e-9, "y=100000")

    check(model.ceiling == 320, "ceiling should be 320, got " .. tostring(model.ceiling))
end)

test("pressure falls monotonically with altitude", function()
    -- The property the whole altitude-self-stabilising argument rests on: rise
    -- -> less pressure -> less prop thrust -> sink. A non-monotonic patch
    -- anywhere in the curve would be a local instability.
    local model = atmosphere.fromPoints(POINTS)
    local previous = model.pressureAt(-50)
    local violations = 0
    for y = -49, 330 do
        local pressure = model.pressureAt(y)
        if pressure > previous + 1e-12 then
            violations = violations + 1
        end
        previous = pressure
    end
    check(violations == 0, violations .. " altitudes where pressure rose with height")
end)

test("costs no Sable calls", function()
    -- The entire point of step 4. fromPoints must not reach for the aero API,
    -- so a controller can evaluate pressure inside its loop for free.
    local model = atmosphere.fromPoints(POINTS)
    local calls = 0
    local previousAero = _G.aero
    _G.aero = setmetatable({}, { __index = function()
        calls = calls + 1
        return function() return 0 end
    end })

    for y = 0, 300, 10 do model.pressureAt(y) end

    _G.aero = previousAero
    check(calls == 0, "pressureAt reached for the aero API " .. calls .. " times")
end)

test("reports the exponential region and its scale height", function()
    -- Useful, and it records the finding that corrects HANDOFF.md: below the
    -- 280 knot every segment has slope/value = -0.004, i.e. a clean
    -- exponential with H = 250 blocks. The r2 = 0.976 fit that called the
    -- atmosphere "not a clean exponential" was fitting across the collapse
    -- above 280.
    local model = atmosphere.fromPoints(POINTS)
    near(model.scaleHeight, 250, 0.5, "scale height")
    near(model.exponentialTo, 280, 1e-9, "top of the exponential region")
end)

test("rejects a malformed point list rather than interpolating nonsense", function()
    check(not pcall(atmosphere.fromPoints, nil), "nil should be rejected")
    check(not pcall(atmosphere.fromPoints, {}), "an empty list should be rejected")
    check(not pcall(atmosphere.fromPoints, { { altitude = 0 } }),
        "a point missing value/slope should be rejected")
end)

test("survives unsorted control points", function()
    -- getPoints() came back sorted, but nothing promises that it always will,
    -- and a silently mis-ordered curve would be wrong everywhere rather than
    -- obviously broken.
    local shuffled = { POINTS[3], POINTS[1], POINTS[5], POINTS[2], POINTS[4] }
    local model = atmosphere.fromPoints(shuffled)
    for _, sample in ipairs(MEASURED) do
        near(model.pressureAt(sample.y), sample.pressure, 1e-5,
            string.format("y=%d (shuffled)", sample.y))
    end
end)

-- ---------------------------------------------------------------------------

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
