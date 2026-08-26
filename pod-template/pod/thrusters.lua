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

    -- 32 devices x 5 getters is 160 peripheral calls. Run sequentially each one
    -- is a main-thread task costing a server tick, so a single sample took
    -- ~6 seconds and starved telemetryLoop down to one send per six seconds.
    -- Dispatch per device concurrently -- the same trick runSetters already
    -- uses for writes -- so the cost is the 5 getters deep, not 160 wide.
    local readings, jobs = {}, {}
    for index, device in ipairs(thrusters.devices) do
        jobs[index] = function()
            local ok, reading = pcall(function()
                return {
                    power = device.getPower(),
                    thrust = device.getCurrentThrustKN(),
                    energy = device.getEnergyAmountFe(),
                    capacity = device.getEnergyCapacityFe(),
                    clearance = device.getObstruction(),
                }
            end)
            readings[index] = { ok = ok, value = reading }
        end
    end

    if #jobs > 0 then
        parallel.waitForAll(table.unpack(jobs))
    end

    local powerSum = 0
    for index = 1, #thrusters.devices do
        local name = thrusters.names[index]
        local entry = readings[index] or { ok = false, value = "no reading returned" }

        if entry.ok then
            local reading = entry.value
            result.healthyThrusters = result.healthyThrusters + 1
            powerSum = powerSum + reading.power
            result.totalThrustKN = result.totalThrustKN + reading.thrust
            result.energyFE = result.energyFE + reading.energy
            result.energyCapacityFE = result.energyCapacityFE + reading.capacity
            result.minimumClearance = result.minimumClearance
                and math.min(result.minimumClearance, reading.clearance) or reading.clearance
            -- `> 0`, not `<= 0`. The old test flagged all 128 thrusters
            -- obstructed on every run, including runs that produced 516,096 kN
            -- and lifted the carrier (ionsweep_1787677298924.csv: 146 rows of
            -- obstructed=128 at full thrust). A thruster cannot be blocked and
            -- lifting at once.
            --
            -- Measured: getObstruction returns exactly 0.000000 on all 32
            -- thrusters of a pod, idle AND under full thrust. An ion thruster
            -- exposes no other obstruction method -- no isObstructed -- so this
            -- getter is all there is.
            --
            -- Two readings of that constant survive the evidence, and they
            -- agree on this predicate, which is why it is safe:
            --   a) 0 means "no obstruction found", and this craft flies in open
            --      superflat sky where nothing ever obstructs -- then `> 0` is
            --      correct and reports the truth: none obstructed.
            --   b) the getter is uninformative here -- then no predicate is
            --      meaningful, and `> 0` at least never fires spuriously.
            --
            -- To settle which: put a block hard against one thruster in
            -- creative and re-run /pod/obstructionprobe.lua. If that thruster's
            -- value moves off 0, reading (a) is confirmed and the scale is
            -- whatever it moved to. Until then, treat obstructedThrusters as
            -- "nothing detected" rather than as proof of clearance, and keep
            -- reading minimumClearance raw.
            if reading.clearance > 0 then
                result.obstructedThrusters = result.obstructedThrusters + 1
            end
        else
            result.faults[#result.faults + 1] = name .. ": " .. tostring(entry.value)
        end
    end

    if result.healthyThrusters > 0 then
        result.averagePower = powerSum / result.healthyThrusters
    end

    return result
end

return thrusters
