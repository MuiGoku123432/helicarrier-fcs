-- Flight session internals: the stable-hold window gate, and the cheap read.
--
--     luajit tools/test_flight_window.lua
--
-- This exists because the first version of the gate was a divisibility
-- lottery: it could only ever pass when the loop period divided the window
-- length exactly. It shipped, and it failed in flight as "no full window
-- sampled" -- but only on runs whose loop period happened to be unfriendly,
-- which is why earlier runs looked fine.
--
-- Deliberately calls flight.trimWindow rather than reimplementing it. A test
-- that copied the logic would have copied the bug and agreed with it.
package.path = "./?.lua;./?/init.lua;" .. package.path

require("tools.cc_harness").install(_G)
_G.package = package
package.path = "./?.lua;./?/init.lua;" .. package.path
local flight = require("fcs.flight")

local passed, failed = 0, 0
local function check(label, ok)
    if ok then passed = passed + 1
    else failed = failed + 1; print("FAIL " .. label) end
end

local WINDOW = flight.STABLE_WINDOW_SECONDS * 1000

-- Every plausible loop period must eventually satisfy the gate. The periods
-- that do NOT divide the window are the whole point: 950, 1600 and 3000 all
-- scored exactly zero under the old trim.
for _, period in ipairs({ 250, 500, 800, 950, 1000, 1250, 1600, 2000, 2500, 3000, 4100 }) do
    local window, passes, worstSpan = {}, 0, nil
    for tick = 1, 400 do
        local now = tick * period
        window[#window + 1] = { t = now }
        local span = flight.trimWindow(window, now, WINDOW)
        if span >= WINDOW and #window >= flight.STABLE_MIN_SAMPLES then
            passes = passes + 1
            if not worstSpan or span > worstSpan then worstSpan = span end
        end
    end
    check(string.format("period %4d ms satisfies the gate (%d passes)", period, passes),
        passes > 0)
    -- And it must not drag in a huge stale tail: the span should stay close to
    -- the window, not grow without bound.
    if worstSpan then
        check(string.format("period %4d ms span %d ms stays near the %d ms window",
            period, worstSpan, WINDOW), worstSpan <= WINDOW + period + 1)
    end
end

-- A long gap must not leave a single stale sample masquerading as a window.
local window = { { t = 0 } }
local span = flight.trimWindow(window, 100000, WINDOW)
check("a lone stale sample is not a valid window",
    not (span >= WINDOW and #window >= flight.STABLE_MIN_SAMPLES))

-- ---------------------------------------------------------------------------
-- The cheap attitude-only read must AGREE with the full read.
--
-- It exists to get more samples inside the axis-response pulse, which was
-- collecting two in 3.3 seconds and producing authority numbers that
-- disagreed by 27% between runs. A faster read that quietly reports a
-- different attitude would be far worse than a slow one.
-- ---------------------------------------------------------------------------
local config = require("fcs.config")
local session = flight.new({ config = config })

local harness = require("tools.cc_harness")
local function near(a, b, tolerance)
    return a and b and math.abs(a - b) <= (tolerance or 1e-6)
end

for _, case in ipairs({ { 0, 0 }, { 8, -5 }, { -12, 9 }, { 3, 17 } }) do
    harness.craft.roll, harness.craft.pitch = case[1], case[2]
    local full = session:read()
    local cheap = session:readCheap()

    check(string.format("cheap read is valid at %+.0f/%+.0f", case[1], case[2]),
        cheap.valid == true)
    check(string.format("cheap roll matches full at %+.0f/%+.0f", case[1], case[2]),
        near(cheap.roll, full.roll))
    check(string.format("cheap pitch matches full at %+.0f/%+.0f", case[1], case[2]),
        near(cheap.pitch, full.pitch))
    check(string.format("cheap altitude matches full at %+.0f/%+.0f", case[1], case[2]),
        near(session:craftY(cheap), session:craftY(full)))
    check(string.format("cheap vy matches full at %+.0f/%+.0f", case[1], case[2]),
        near(cheap.linearVelocityWorld and cheap.linearVelocityWorld.y,
             full.linearVelocityWorld and full.linearVelocityWorld.y))
    -- And it must be usable by the abort path, which is the whole safety case.
    check(string.format("checkLimits accepts the cheap sample at %+.0f/%+.0f", case[1], case[2]),
        session:checkLimits(cheap) == nil)
end
harness.craft.roll, harness.craft.pitch = 0, 0

-- An unusable sample must not be marked valid, or checkLimits would wave
-- through a craft it cannot see.
check("cheap read marks itself invalid without a pose",
    (function()
        local saved = _G.sublevel.getLogicalPose
        _G.sublevel.getLogicalPose = function() return nil end
        local bad = session:readCheap()
        _G.sublevel.getLogicalPose = saved
        return bad.valid == false
    end)())

-- A tilt beyond the limit must still abort on a cheap sample.
harness.craft.roll = 45
check("checkLimits still aborts on an over-tilt cheap sample",
    session:checkLimits(session:readCheap()) ~= nil)
harness.craft.roll = 0

print("")
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
