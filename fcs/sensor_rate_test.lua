-- CC:Sable sensor read-rate measurement for FCS-DEV.
--
--     /fcs/sensor_rate_test.lua <label>
--     /fcs/sensor_rate_test.lua --self-test
--
-- Answers one question: how fast can the flight control loop actually read the
-- three quantities it needs -- pose, linear velocity, angular velocity -- on
-- this computer, with whatever else is currently running on it.
--
-- This program opens no modem, sends no frame, and touches no actuator. It is
-- safe to run at any time, grounded or not. Nothing here commands anything.
--
-- Run it twice with different labels -- once with the monitor hub tab running
-- and once with it stopped -- to measure whether the hub competes for this
-- computer's main-thread budget. If the achieved rate is the same both ways,
-- moving the hub to its own computer buys nothing.

local args = { ... }
local RESULT_PATH = "/fcs/sensor_rate_result.txt"
local PER_CALL_SAMPLES = 60
local FREE_RUN_SECONDS = 10
local FIXED_RATE_HZ = 10
local FIXED_RUN_SECONDS = 10

-- The three reads a rate-damping / velocity-hold loop actually needs. Mass,
-- centre of mass and the inertia tensor are deliberately absent: they change
-- slowly and belong on a slow lane, and the exploratory probe that read all
-- fourteen methods managed only 2.5 Hz.
local CONTROL_METHODS = { "getLogicalPose", "getVelocity", "getAngularVelocity" }
-- Measured alongside, not in the control cycle: the response probe recorded
-- getLinearVelocity as exactly zero in every sample while getVelocity showed
-- float noise. On a grounded ship both are consistent with working correctly,
-- so this records the values rather than judging them.
local EXTRA_METHODS = { "getLinearVelocity", "getMass" }

local function finiteNumber(value)
    return type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
end

local function summarize(samples)
    local count = #samples
    if count == 0 then
        return { count = 0, min = nil, mean = nil, max = nil, p95 = nil }
    end
    local ordered = {}
    local total = 0
    for index = 1, count do
        ordered[index] = samples[index]
        total = total + samples[index]
    end
    table.sort(ordered)
    local p95Index = math.ceil(count * 0.95)
    if p95Index < 1 then p95Index = 1 end
    if p95Index > count then p95Index = count end
    return {
        count = count,
        min = ordered[1],
        mean = total / count,
        max = ordered[count],
        p95 = ordered[p95Index],
    }
end

local function formatSummary(label, summary)
    if summary.count == 0 then
        return string.format("%s count=0 (no samples)", label)
    end
    return string.format(
        "%s count=%d min=%.1f mean=%.1f p95=%.1f max=%.1f",
        label, summary.count, summary.min, summary.mean, summary.p95, summary.max)
end

-- Intervals between cycle starts -> achieved rate. Guarded because a run that
-- produced a single cycle has no interval to divide by.
local function achievedHz(intervals)
    local summary = summarize(intervals)
    if summary.count == 0 or not summary.mean or summary.mean <= 0 then
        return nil
    end
    return 1000 / summary.mean
end

local function selfTest()
    local empty = summarize({})
    assert(empty.count == 0 and empty.mean == nil)

    local one = summarize({ 50 })
    assert(one.count == 1 and one.min == 50 and one.mean == 50
        and one.max == 50 and one.p95 == 50)

    local many = summarize({ 30, 10, 20, 40 })
    assert(many.count == 4 and many.min == 10 and many.max == 40)
    assert(math.abs(many.mean - 25) < 1e-9)
    assert(many.p95 == 40)

    -- 100 ms mean interval is 10 Hz, and no interval at all is not 0 Hz.
    assert(math.abs(achievedHz({ 100, 100, 100 }) - 10) < 1e-9)
    assert(achievedHz({}) == nil)
    assert(achievedHz({ 0 }) == nil)

    assert(finiteNumber(1) and not finiteNumber("1"))
    assert(not finiteNumber(0 / 0) and not finiteNumber(math.huge))

    assert(#CONTROL_METHODS == 3, "control cycle must stay at three reads")
    for _, name in ipairs(CONTROL_METHODS) do
        assert(name ~= "getInertiaTensor", "tensor must not enter the control cycle")
    end

    print("sensor rate test self-test: PASS")
end

if args[1] == "--self-test" then selfTest() return end

local label = args[1]
if not label or label == "" then
    error("usage: /fcs/sensor_rate_test.lua <label>   (e.g. hub-on, hub-off)", 0)
end

local function loadSublevel()
    if type(_G.sublevel) == "table" then return _G.sublevel, "global" end
    if type(require) == "function" then
        local ok, api = pcall(require, "sublevel")
        if ok and type(api) == "table" then return api, "require" end
    end
    return nil, "unavailable"
end

local api, source = loadSublevel()
if not api then
    error("CC:Sable sublevel API unavailable; nothing was measured", 0)
end

-- A tight read loop can trip "too long without yielding" if the Sable calls
-- turn out to be direct rather than main-thread tasks. queueEvent/pullEvent
-- yields and resumes within the same tick, so it does not distort the timing
-- the way sleep(0) would -- sleep rounds up to a whole 50 ms tick.
local function yieldNow()
    os.queueEvent("sensor_rate_yield")
    os.pullEvent("sensor_rate_yield")
end

local function callOnce(name)
    local method = api[name]
    if type(method) ~= "function" then
        return nil, "absent", 0
    end
    local startedAt = os.epoch("utc")
    local ok, value = pcall(method)
    local elapsed = os.epoch("utc") - startedAt
    if not ok then
        return nil, tostring(value), elapsed
    end
    return value, nil, elapsed
end

----------------------------------------------------------------------
-- Phase 1: per-call latency, one method at a time.
----------------------------------------------------------------------

local perCall = {}
local perCallError = {}
local measuredMethods = {}
for _, name in ipairs(CONTROL_METHODS) do measuredMethods[#measuredMethods + 1] = name end
for _, name in ipairs(EXTRA_METHODS) do measuredMethods[#measuredMethods + 1] = name end

print("Phase 1: per-call latency, " .. PER_CALL_SAMPLES .. " calls per method")
for _, name in ipairs(measuredMethods) do
    local timings = {}
    for _ = 1, PER_CALL_SAMPLES do
        local _, err, elapsed = callOnce(name)
        timings[#timings + 1] = elapsed
        if err then perCallError[name] = perCallError[name] or err end
        yieldNow()
    end
    perCall[name] = summarize(timings)
end

----------------------------------------------------------------------
-- Phase 2: the real control cycle, free-running as fast as it will go.
----------------------------------------------------------------------

print("Phase 2: free-run control cycle for " .. FREE_RUN_SECONDS .. "s")
local freeIntervals = {}
local freeCycleMs = {}
local freeCycles = 0
local freeStart = os.epoch("utc")
local previousCycleAt
while (os.epoch("utc") - freeStart) < (FREE_RUN_SECONDS * 1000) do
    local cycleAt = os.epoch("utc")
    for _, name in ipairs(CONTROL_METHODS) do callOnce(name) end
    local cycleEnd = os.epoch("utc")
    freeCycles = freeCycles + 1
    freeCycleMs[#freeCycleMs + 1] = cycleEnd - cycleAt
    if previousCycleAt then
        freeIntervals[#freeIntervals + 1] = cycleAt - previousCycleAt
    end
    previousCycleAt = cycleAt
    yieldNow()
end
local freeElapsed = (os.epoch("utc") - freeStart) / 1000

----------------------------------------------------------------------
-- Phase 3: can it hold a fixed cadence, and how late is it when it misses?
----------------------------------------------------------------------

print("Phase 3: fixed " .. FIXED_RATE_HZ .. " Hz cadence for " .. FIXED_RUN_SECONDS .. "s")
local periodMs = 1000 / FIXED_RATE_HZ
local deadlinesMade, deadlinesMissed = 0, 0
local lateness = {}
local fixedStart = os.epoch("utc")
local slot = 0
while (os.epoch("utc") - fixedStart) < (FIXED_RUN_SECONDS * 1000) do
    local due = fixedStart + (slot * periodMs)
    -- Wait out the remainder of the slot. sleep(0) costs a whole 50 ms tick, so
    -- it is only used while more than a tick remains; the last stretch is spun
    -- on a same-tick yield to keep the slot boundary accurate.
    while true do
        local remaining = due - os.epoch("utc")
        if remaining <= 0 then break end
        if remaining > 50 then sleep(0) else yieldNow() end
    end
    for _, name in ipairs(CONTROL_METHODS) do callOnce(name) end
    local finishedAt = os.epoch("utc")
    -- Overrun is measured against this cycle's own slot, not against a clock
    -- that has been drifting since phase start: slot is re-derived from real
    -- elapsed time below, so a slow cycle reports its own lateness once rather
    -- than reporting an ever-growing cumulative backlog.
    local overrun = finishedAt - (due + periodMs)
    if overrun > 0 then
        deadlinesMissed = deadlinesMissed + 1
        lateness[#lateness + 1] = overrun
    else
        deadlinesMade = deadlinesMade + 1
    end
    slot = math.floor((os.epoch("utc") - fixedStart) / periodMs) + 1
    yieldNow()
end
local fixedSlotsExpected = FIXED_RUN_SECONDS * FIXED_RATE_HZ

----------------------------------------------------------------------
-- Phase 4: value sanity, so the numbers above can be trusted.
----------------------------------------------------------------------

local function vectorText(value)
    if type(value) ~= "table" then return "nil" end
    local x, y, z = value.x, value.y, value.z
    if not finiteNumber(x) or not finiteNumber(y) or not finiteNumber(z) then
        return "non-numeric"
    end
    return string.format("%.9f,%.9f,%.9f", x, y, z)
end

local function nonZeroVector(value)
    if type(value) ~= "table" then return false end
    for _, key in ipairs({ "x", "y", "z" }) do
        local component = value[key]
        if finiteNumber(component) and component ~= 0 then return true end
    end
    return false
end

local velocityNonZero, linearNonZero, angularNonZero = false, false, false
local lastVelocity, lastLinear, lastAngular
for _ = 1, 20 do
    lastVelocity = callOnce("getVelocity")
    lastLinear = callOnce("getLinearVelocity")
    lastAngular = callOnce("getAngularVelocity")
    velocityNonZero = velocityNonZero or nonZeroVector(lastVelocity)
    linearNonZero = linearNonZero or nonZeroVector(lastLinear)
    angularNonZero = angularNonZero or nonZeroVector(lastAngular)
    yieldNow()
end

----------------------------------------------------------------------
-- Report
----------------------------------------------------------------------

local freeSummary = summarize(freeIntervals)
local freeHz = achievedHz(freeIntervals)
local cycleSummary = summarize(freeCycleMs)
local latenessSummary = summarize(lateness)

local lines = {
    "CC:SABLE SENSOR READ-RATE MEASUREMENT",
    "label=" .. tostring(label),
    "computer=" .. tostring(os.getComputerID()),
    "sublevel_source=" .. tostring(source),
    "safety=ZERO_ACTUATION_NO_MODEM",
    "control_methods=" .. table.concat(CONTROL_METHODS, ","),
    "",
    "-- phase 1: per-call latency (ms) --",
}
for _, name in ipairs(measuredMethods) do
    lines[#lines + 1] = formatSummary(name, perCall[name])
    if perCallError[name] then
        lines[#lines + 1] = name .. " first_error=" .. perCallError[name]
    end
end

lines[#lines + 1] = ""
lines[#lines + 1] = "-- phase 2: free-run control cycle --"
lines[#lines + 1] = string.format("elapsed_s=%.2f cycles=%d", freeElapsed, freeCycles)
lines[#lines + 1] = formatSummary("cycle_duration_ms", cycleSummary)
lines[#lines + 1] = formatSummary("cycle_interval_ms", freeSummary)
lines[#lines + 1] = "achieved_hz=" .. (freeHz and string.format("%.2f", freeHz) or "nil")

lines[#lines + 1] = ""
lines[#lines + 1] = string.format("-- phase 3: fixed %d Hz cadence --", FIXED_RATE_HZ)
lines[#lines + 1] = string.format("slots_expected=%d slots_run=%d made=%d missed=%d",
    fixedSlotsExpected, deadlinesMade + deadlinesMissed, deadlinesMade, deadlinesMissed)
lines[#lines + 1] = formatSummary("overrun_ms", latenessSummary)

lines[#lines + 1] = ""
lines[#lines + 1] = "-- phase 4: value sanity --"
lines[#lines + 1] = "getVelocity_last=" .. vectorText(lastVelocity)
lines[#lines + 1] = "getLinearVelocity_last=" .. vectorText(lastLinear)
lines[#lines + 1] = "getAngularVelocity_last=" .. vectorText(lastAngular)
lines[#lines + 1] = string.format(
    "any_nonzero velocity=%s linear=%s angular=%s",
    tostring(velocityNonZero), tostring(linearNonZero), tostring(angularNonZero))
lines[#lines + 1] = "note=a resting physics body reads exact zero; a grounded run"
    .. " cannot establish a flight noise floor"

local file = fs.open(RESULT_PATH, "w")
if not file then error("unable to write " .. RESULT_PATH, 0) end
file.write(table.concat(lines, "\n"))
file.close()

print("")
print(formatSummary("cycle_duration_ms", cycleSummary))
print("achieved_hz=" .. (freeHz and string.format("%.2f", freeHz) or "nil"))
print(string.format("fixed %d Hz: made=%d missed=%d",
    FIXED_RATE_HZ, deadlinesMade, deadlinesMissed))
print("Report written to " .. RESULT_PATH)
