local config = require("pod.config")

local thrusters = {
    devices = {},
    names = {},
    currentPower = config.fallbackPower,
}

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function runSetters(power)
    local jobs = {}
    for index, device in ipairs(thrusters.devices) do
        jobs[index] = function()
            device.setPowerNormalized(power)
        end
    end
    parallel.waitForAll(table.unpack(jobs))
end

function thrusters.load()
    if not config.manifestApproved then
        error("thruster manifest is not approved; run /pod/discover.lua first", 0)
    end
    if not fs.exists(config.manifestPath) then
        error("thruster manifest is missing: " .. config.manifestPath, 0)
    end

    local names = dofile(config.manifestPath)
    if type(names) ~= "table" then
        error("thruster manifest did not return a table", 0)
    end
    if #names ~= config.expectedThrusterCount then
        error("thruster count mismatch: expected " .. config.expectedThrusterCount .. ", found " .. #names, 0)
    end

    local seen = {}
    for _, name in ipairs(names) do
        if type(name) ~= "string" or seen[name] then
            error("invalid or duplicate thruster name in manifest: " .. tostring(name), 0)
        end
        seen[name] = true

        if not peripheral.isPresent(name) then
            error("manifest thruster is missing: " .. name, 0)
        end
        if not peripheral.hasType(name, "ion_thruster") then
            error("manifest device is not an ion_thruster: " .. name, 0)
        end

        local device = peripheral.wrap(name)
        if type(device.setPowerNormalized) ~= "function" then
            error("thruster lacks setPowerNormalized: " .. name, 0)
        end

        thrusters.names[#thrusters.names + 1] = name
        thrusters.devices[#thrusters.devices + 1] = device
    end
end

function thrusters.applyExact(requestedPower)
    local power = clamp(requestedPower, config.minimumPower, config.maximumPower)
    runSetters(power)
    thrusters.currentPower = power
    return power
end

function thrusters.applyCommand(requestedPower)
    local target = clamp(requestedPower, config.minimumPower, config.maximumPower)
    local change = clamp(
        target - thrusters.currentPower,
        -config.maximumChangePerCommand,
        config.maximumChangePerCommand
    )
    return thrusters.applyExact(thrusters.currentPower + change)
end

function thrusters.telemetry()
    local result = {
        healthyThrusters = 0,
        expectedThrusters = config.expectedThrusterCount,
        totalThrustKN = 0,
        averagePower = 0,
        energyFE = 0,
        energyCapacityFE = 0,
        obstructedThrusters = 0,
        minimumClearance = nil,
        faults = {},
    }

    local deviceCount = #thrusters.devices
    local now = os.epoch("utc")

    local function runBatched(jobs, requestedSize)
        local batchSize = math.max(1, math.floor(tonumber(requestedSize) or 1))
        for first = 1, #jobs, batchSize do
            local batch = {}
            local last = math.min(first + batchSize - 1, #jobs)
            for index = first, last do
                batch[#batch + 1] = jobs[index]
            end
            parallel.waitForAll(table.unpack(batch))
        end
    end

    -- Applied power is control-relevant, so keep it fresh for every device.
    -- This is one getter per thruster instead of five, dispatched eight at a
    -- time: 32 events in small bursts rather than a 160-event flood.
    local powerReadings, powerJobs = {}, {}
    for index, device in ipairs(thrusters.devices) do
        local deviceIndex, capturedDevice = index, device
        powerJobs[#powerJobs + 1] = function()
            local ok, value = pcall(capturedDevice.getPower)
            powerReadings[deviceIndex] = { ok = ok, value = value }
        end
    end
    runBatched(powerJobs, tonumber(config.telemetryPowerBatchSize) or 8)

    local powerSum = 0
    for index = 1, deviceCount do
        local entry = powerReadings[index]
        if entry and entry.ok then
            result.healthyThrusters = result.healthyThrusters + 1
            powerSum = powerSum + entry.value
        else
            result.faults[#result.faults + 1] = (thrusters.names[index] or tostring(index))
                .. " power: " .. tostring(entry and entry.value or "no reading returned")
        end
    end
    if result.healthyThrusters > 0 then
        result.averagePower = powerSum / result.healthyThrusters
    end

    -- Thrust, energy, capacity, and obstruction are diagnostics. Refresh only
    -- four devices per sample and aggregate from the rotating cache. A complete
    -- 32-device sweep therefore costs eight samples instead of 128 extra events
    -- every sample. Extra fields make partial/estimated data explicit.
    thrusters._slowTelemetry = thrusters._slowTelemetry or {}
    thrusters._slowTelemetryNext = thrusters._slowTelemetryNext or 1
    local cache = thrusters._slowTelemetry
    local slowBatchSize = math.max(1,
        math.floor(tonumber(config.telemetryBatchSize) or 4))
    local slowCount = math.min(slowBatchSize, deviceCount)
    local slowJobs = {}

    for offset = 0, slowCount - 1 do
        local deviceIndex = ((thrusters._slowTelemetryNext + offset - 1)
            % deviceCount) + 1
        local capturedIndex = deviceIndex
        local capturedDevice = thrusters.devices[deviceIndex]
        slowJobs[#slowJobs + 1] = function()
            local ok, reading = pcall(function()
                return {
                    thrust = capturedDevice.getCurrentThrustKN(),
                    energy = capturedDevice.getEnergyAmountFe(),
                    capacity = capturedDevice.getEnergyCapacityFe(),
                    clearance = capturedDevice.getObstruction(),
                }
            end)
            cache[capturedIndex] = {
                ok = ok,
                value = reading,
                at = os.epoch("utc"),
            }
        end
    end
    runBatched(slowJobs, slowBatchSize)
    if deviceCount > 0 then
        thrusters._slowTelemetryNext =
            ((thrusters._slowTelemetryNext + slowCount - 1) % deviceCount) + 1
    end

    local cachedCount, slowHealthy = 0, 0
    local thrustSum, energySum, capacitySum = 0, 0, 0
    local oldestAt = nil
    for index = 1, deviceCount do
        local entry = cache[index]
        if entry then
            cachedCount = cachedCount + 1
            oldestAt = oldestAt and math.min(oldestAt, entry.at) or entry.at
            if entry.ok then
                local reading = entry.value
                slowHealthy = slowHealthy + 1
                thrustSum = thrustSum + reading.thrust
                energySum = energySum + reading.energy
                capacitySum = capacitySum + reading.capacity
                result.minimumClearance = result.minimumClearance
                    and math.min(result.minimumClearance, reading.clearance)
                    or reading.clearance
                if reading.clearance > 0 then
                    result.obstructedThrusters = result.obstructedThrusters + 1
                end
            else
                result.faults[#result.faults + 1] =
                    (thrusters.names[index] or tostring(index))
                    .. " diagnostics: " .. tostring(entry.value)
            end
        end
    end

    -- Ion thrusters in a pod are identical and receive the same command. Until
    -- the first full rotation completes, extrapolate the sampled aggregate and
    -- label it estimated rather than publishing a misleading partial total.
    if slowHealthy > 0 then
        local scale = deviceCount / slowHealthy
        result.totalThrustKN = thrustSum * scale
        result.energyFE = energySum * scale
        result.energyCapacityFE = capacitySum * scale
    end

    result.telemetryPrimed = cachedCount >= deviceCount
    result.telemetryEstimated = not result.telemetryPrimed
    result.telemetrySlowSampled = cachedCount
    result.telemetrySlowHealthy = slowHealthy
    result.telemetrySlowBatchSize = slowBatchSize
    result.telemetryOldestAt = oldestAt
    result.telemetryOldestAgeMs = oldestAt and (now - oldestAt) or nil

    return result
end

return thrusters
