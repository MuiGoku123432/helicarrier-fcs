-- Regression guard for pod telemetry queue pressure.
-- Runs under LuaJIT with fake peripherals; no Minecraft server is required.

local passed = 0
local function check(condition, message)
    if not condition then error(message, 0) end
    passed = passed + 1
end

local originalConfig = package.loaded["pod.config"]
local originalParallel = _G.parallel
local originalUnpack = table.unpack
local originalEpoch = os.epoch

table.unpack = table.unpack or unpack
package.loaded["pod.config"] = {
    fallbackPower = 0,
    minimumPower = 0,
    maximumPower = 1,
    expectedThrusterCount = 32,
    telemetryPowerBatchSize = 8,
    telemetryBatchSize = 4,
}

local now = 100000
os.epoch = function()
    now = now + 1
    return now
end

local batchSizes = {}
_G.parallel = {
    waitForAll = function(...)
        local jobs = { ... }
        batchSizes[#batchSizes + 1] = #jobs
        for _, job in ipairs(jobs) do job() end
    end,
}

local thrusters = assert(loadfile("pod-template/pod/thrusters.lua"))()
local getterCalls = 0
local powerCalls, slowCalls = {}, {}
local function getter(index, kind, value)
    return function()
        getterCalls = getterCalls + 1
        if kind == "power" then
            powerCalls[index] = (powerCalls[index] or 0) + 1
        else
            slowCalls[index] = (slowCalls[index] or 0) + 1
        end
        return value
    end
end

for index = 1, 32 do
    thrusters.names[index] = "ion_thruster_" .. index
    thrusters.devices[index] = {
        getPower = getter(index, "power", index / 100),
        getCurrentThrustKN = getter(index, "slow", 100),
        getEnergyAmountFe = getter(index, "slow", 100),
        getEnergyCapacityFe = getter(index, "slow", 200),
        getObstruction = getter(index, "slow", 0),
    }
end

local first = thrusters.telemetry()
check(getterCalls == 48,
    "one snapshot must use 32 fresh power reads plus 16 rotating diagnostic reads")
check(#batchSizes == 5, "one snapshot must dispatch four power batches and one slow batch")
check(first.telemetrySlowSampled == 4, "first snapshot must cache four slow devices")
check(first.telemetryEstimated == true and first.telemetryPrimed == false,
    "partial diagnostic rotation must be labelled estimated")
check(first.totalThrustKN == 3200, "estimated thrust must represent all 32 identical ions")
check(first.energyFE == 3200, "estimated energy must represent all 32 identical ions")
check(first.energyCapacityFE == 6400,
    "estimated capacity must represent all 32 identical ions")
check(first.healthyThrusters == 32, "fresh power confirmation lost healthy devices")
check(math.abs(first.averagePower - 0.165) < 0.000001,
    "fresh power average changed")

local result = first
for _ = 2, 8 do result = thrusters.telemetry() end
check(getterCalls == 384, "eight snapshots must cost 384 getters, not the old 1280")
check(#batchSizes == 40, "eight snapshots must preserve five bounded batches each")
for index, size in ipairs(batchSizes) do
    check(size <= 8, "telemetry batch " .. index .. " exceeded eight devices")
end
for index = 1, 32 do
    check(powerCalls[index] == 8,
        "device " .. index .. " power was not refreshed every snapshot")
    check(slowCalls[index] == 4,
        "device " .. index .. " did not receive exactly one four-getter diagnostic refresh")
end
check(result.telemetrySlowSampled == 32, "full rotation did not cache every ion")
check(result.telemetryPrimed == true and result.telemetryEstimated == false,
    "completed diagnostic rotation must be labelled primed")
check(result.totalThrustKN == 3200, "rotating cache changed aggregate thrust")
check(result.obstructedThrusters == 0, "rotating cache changed obstruction semantics")
check(result.telemetryOldestAgeMs ~= nil, "rotating cache must expose diagnostic age")

local mainHandle = assert(io.open("pod-template/pod/main.lua", "r"))
local mainSource = mainHandle:read("*a")
mainHandle:close()
local samplerAt = assert(mainSource:find("local function samplerLoop()", 1, true),
    "sampler loop missing")
local statusAt = assert(mainSource:find("local function statusLoop()", samplerAt, true),
    "independent cached status loop missing")
local samplerSource = mainSource:sub(samplerAt, statusAt - 1)
check(samplerSource:find("refreshSample(includeDetail)", 1, true) ~= nil,
    "sampler must request bounded fast/detail snapshots")
check(samplerSource:find("rednet.send", 1, true) == nil,
    "sampler must not own periodic status transmission")
check(mainSource:find("refreshSample()", 1, true) == nil,
    "pod must not block on a synchronous startup sample")
check(mainSource:find(
    "parallel.waitForAll(controlMailbox.receiveLoop, controlMailbox.statusLoop, controlApply.loop, samplerLoop, statusLoop, displayLoop)",
    1, true) ~= nil, "status loop must run beside the receiver and sampler")
check(mainSource:find("os.queueEvent(\"pod_sample_request\")", 1, true) ~= nil,
    "status requests must wake the sampler for one fresh bounded snapshot")

local propsHandle = assert(io.open("pod-template/pod/props.lua", "r"))
local propsSource = propsHandle:read("*a")
propsHandle:close()
check(propsSource:find("function props.telemetry(controlOnly)", 1, true) ~= nil,
    "props telemetry must expose the fast control-only path")
check(propsSource:find("if controlOnly then", 1, true) ~= nil,
    "props telemetry must skip slow diagnostics on fast samples")

package.loaded["pod.config"] = originalConfig
_G.parallel = originalParallel
table.unpack = originalUnpack
os.epoch = originalEpoch

print(string.format("pod telemetry budget: %d passed, 0 failed", passed))
