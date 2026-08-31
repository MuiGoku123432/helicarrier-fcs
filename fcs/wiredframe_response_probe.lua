-- Zero-actuation CC:Sable telemetry probe for the wired-frame response mapper.
--
--     /fcs/wiredframe_response_probe.lua [seconds] [sample_hz]
--     /fcs/wiredframe_response_probe.lua --self-test
--
-- This program NEVER opens a modem and NEVER commands an actuator. It records
-- the live CC:Sable data shape and stationary noise floor needed to build the
-- bounded low-power response test without guessing pose fields or axis signs.

local args = { ... }
local DURATION_SECONDS = tonumber(args[1]) or 10
local SAMPLE_HZ = tonumber(args[2]) or 5
local RESULT_PATH = "/fcs/wiredframe_response_probe_result.txt"

local function finiteNumber(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function component(value, index, key)
    if type(value) ~= "table" then return nil end
    local result = value[index]
    if result == nil then result = value[key] end
    return finiteNumber(result) and result or nil
end

local function vector3(value)
    local x = component(value, 1, "x")
    local y = component(value, 2, "y")
    local z = component(value, 3, "z")
    if x == nil or y == nil or z == nil then return nil end
    return { x = x, y = y, z = z }
end

local function safeSerialize(value)
    if textutils and type(textutils.serialize) == "function" then
        local ok, rendered = pcall(textutils.serialize, value, { compact = true })
        if ok then return rendered end
    end
    return tostring(value)
end

local function safeCall(api, method)
    local fn = api and api[method]
    if type(fn) ~= "function" then
        return nil, "missing method " .. tostring(method)
    end
    local ok, value = pcall(fn)
    if not ok then return nil, tostring(value) end
    return value, nil
end

local function loadSublevel()
    if type(_G.sublevel) == "table" then return _G.sublevel, "global" end
    if type(require) == "function" then
        local ok, api = pcall(require, "sublevel")
        if ok and type(api) == "table" then return api, "require" end
    end
    return nil, "unavailable"
end

local function apiMethods(api)
    local methods = {}
    for name, value in pairs(api or {}) do
        if type(value) == "function" then methods[#methods + 1] = tostring(name) end
    end
    table.sort(methods)
    return methods
end

local function readSample(api, startedAt)
    local logicalPose, logicalError = safeCall(api, "getLogicalPose")
    local lastPose, lastError = safeCall(api, "getLastPose")
    local velocity, velocityError = safeCall(api, "getVelocity")
    local linearVelocity, linearError = safeCall(api, "getLinearVelocity")
    local angularVelocity, angularError = safeCall(api, "getAngularVelocity")
    local centerOfMass, centerError = safeCall(api, "getCenterOfMass")
    local mass, massError = safeCall(api, "getMass")
    local inertia, inertiaError = safeCall(api, "getInertiaTensor")

    return {
        t = (os.epoch("utc") - startedAt) / 1000,
        logicalPose = logicalPose,
        lastPose = lastPose,
        velocity = vector3(velocity),
        linearVelocity = vector3(linearVelocity),
        angularVelocity = vector3(angularVelocity),
        centerOfMass = vector3(centerOfMass),
        mass = finiteNumber(mass) and mass or nil,
        inertia = inertia,
        errors = {
            logicalPose = logicalError,
            lastPose = lastError,
            velocity = velocityError,
            linearVelocity = linearError,
            angularVelocity = angularError,
            centerOfMass = centerError,
            mass = massError,
            inertia = inertiaError,
        },
    }
end

local function sampleValid(sample)
    return sample
        and sample.logicalPose ~= nil
        and sample.lastPose ~= nil
        and sample.velocity ~= nil
        and sample.linearVelocity ~= nil
        and sample.angularVelocity ~= nil
        and sample.centerOfMass ~= nil
        and finiteNumber(sample.mass)
        and sample.mass > 0
        and sample.inertia ~= nil
end

local function newVectorStats()
    return {
        x = { min = math.huge, max = -math.huge, sum = 0 },
        y = { min = math.huge, max = -math.huge, sum = 0 },
        z = { min = math.huge, max = -math.huge, sum = 0 },
        count = 0,
    }
end

local function addVector(stats, value)
    if not value then return end
    stats.count = stats.count + 1
    for _, axis in ipairs({ "x", "y", "z" }) do
        local number = value[axis]
        local entry = stats[axis]
        if number < entry.min then entry.min = number end
        if number > entry.max then entry.max = number end
        entry.sum = entry.sum + number
    end
end

local function formatVector(prefix, value)
    if not value then return prefix .. "=nil" end
    return string.format("%s=%.9f,%.9f,%.9f", prefix, value.x, value.y, value.z)
end

local function formatStats(name, stats)
    if stats.count == 0 then return name .. "=unavailable" end
    local parts = {}
    for _, axis in ipairs({ "x", "y", "z" }) do
        local entry = stats[axis]
        parts[#parts + 1] = string.format("%s[min=%.9f max=%.9f mean=%.9f]",
            axis, entry.min, entry.max, entry.sum / stats.count)
    end
    return name .. " " .. table.concat(parts, " ")
end

local function selfTest()
    assert(finiteNumber(0) and finiteNumber(-1.25))
    assert(not finiteNumber(0 / 0))
    local value = vector3({ x = 1, y = 2, z = 3 })
    assert(value and value.x == 1 and value.y == 2 and value.z == 3)
    local indexed = vector3({ 4, 5, 6 })
    assert(indexed and indexed.x == 4 and indexed.y == 5 and indexed.z == 6)
    local stats = newVectorStats()
    addVector(stats, value)
    addVector(stats, indexed)
    assert(stats.count == 2)
    assert(stats.x.min == 1 and stats.x.max == 4 and stats.x.sum == 5)
    local mock = {
        getLogicalPose = function() return { orientation = { 0, 0, 0, 1 } } end,
        getLastPose = function() return { orientation = { 0, 0, 0, 1 } } end,
        getVelocity = function() return { 1, 2, 3 } end,
        getLinearVelocity = function() return { x = 4, y = 5, z = 6 } end,
        getAngularVelocity = function() return { x = 0.1, y = 0.2, z = 0.3 } end,
        getCenterOfMass = function() return { 7, 8, 9 } end,
        getMass = function() return 10 end,
        getInertiaTensor = function() return { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } } end,
    }
    local oldEpoch = os.epoch
    os.epoch = function() return 1000 end
    local sample = readSample(mock, 0)
    os.epoch = oldEpoch
    assert(sampleValid(sample))
    assert(sample.t == 1 and sample.mass == 10)
    print("wired response probe self-test: PASS")
end

if args[1] == "--self-test" then
    selfTest()
    return
end

if not finiteNumber(DURATION_SECONDS) or DURATION_SECONDS < 2 or DURATION_SECONDS > 60 then
    error("duration must be between 2 and 60 seconds", 0)
end
if not finiteNumber(SAMPLE_HZ) or SAMPLE_HZ < 1 or SAMPLE_HZ > 20 then
    error("sample_hz must be between 1 and 20", 0)
end

local api, source = loadSublevel()
if not api then
    error("CC:Sable sublevel API unavailable; no actuator commands were sent", 0)
end

local inPlotGrid, plotError = safeCall(api, "isInPlotGrid")
if plotError or inPlotGrid ~= true then
    error("FCS-DEV is not attached to a Sable Sub-Level; no actuator commands were sent", 0)
end

local startedAt = os.epoch("utc")
local first = readSample(api, startedAt)
if not sampleValid(first) then
    local errors = {}
    for name, message in pairs(first.errors or {}) do
        if message then errors[#errors + 1] = name .. ":" .. message end
    end
    table.sort(errors)
    error("CC:Sable telemetry preflight failed (" .. table.concat(errors, "; ") .. "); no actuator commands were sent", 0)
end

local samples = { first }
local velocityStats = newVectorStats()
local linearStats = newVectorStats()
local angularStats = newVectorStats()
addVector(velocityStats, first.velocity)
addVector(linearStats, first.linearVelocity)
addVector(angularStats, first.angularVelocity)

local samplePeriod = 1 / SAMPLE_HZ
local nextSampleAt = startedAt + math.floor(samplePeriod * 1000)
local stopAt = startedAt + math.floor(DURATION_SECONDS * 1000)
while os.epoch("utc") < stopAt do
    local now = os.epoch("utc")
    local remaining = nextSampleAt - now
    if remaining > 0 then sleep(remaining / 1000) end
    local sample = readSample(api, startedAt)
    if not sampleValid(sample) then
        error("CC:Sable telemetry became invalid during probe; no actuator commands were sent", 0)
    end
    samples[#samples + 1] = sample
    addVector(velocityStats, sample.velocity)
    addVector(linearStats, sample.linearVelocity)
    addVector(angularStats, sample.angularVelocity)
    nextSampleAt = nextSampleAt + math.floor(samplePeriod * 1000)
end

local lines = {
    "WIRED FRAME RESPONSE SENSOR PROBE",
    "safety=ZERO_ACTUATION",
    "modem_opened=false",
    "control_frames_sent=0",
    "sublevel_source=" .. source,
    "sublevel_methods=" .. table.concat(apiMethods(api), ","),
    "duration_s=" .. tostring(DURATION_SECONDS),
    "requested_sample_hz=" .. tostring(SAMPLE_HZ),
    "sample_count=" .. tostring(#samples),
    "mass=" .. string.format("%.9f", first.mass),
    formatVector("center_of_mass", first.centerOfMass),
    "logical_pose_first=" .. safeSerialize(first.logicalPose),
    "logical_pose_last=" .. safeSerialize(samples[#samples].logicalPose),
    "last_pose_first=" .. safeSerialize(first.lastPose),
    "inertia_tensor=" .. safeSerialize(first.inertia),
    formatStats("velocity_stats", velocityStats),
    formatStats("linear_velocity_stats", linearStats),
    formatStats("angular_velocity_stats", angularStats),
}

for index, sample in ipairs(samples) do
    lines[#lines + 1] = string.format("sample=%d t=%.3f %s %s %s",
        index,
        sample.t,
        formatVector("velocity", sample.velocity),
        formatVector("linear", sample.linearVelocity),
        formatVector("angular", sample.angularVelocity))
end

lines[#lines + 1] = "overall=PASS"

local file = fs.open(RESULT_PATH, "w")
if not file then error("unable to write " .. RESULT_PATH, 0) end
file.write(table.concat(lines, "\n"))
file.close()

print("Response sensor probe PASS")
print("No actuator commands were sent.")
print("Report written to " .. RESULT_PATH)
