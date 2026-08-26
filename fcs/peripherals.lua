local devices = {}

local CORNERS = { "FL", "FR", "RL", "RR" }

local function attempt(errors, label, callback)
    local ok, value = pcall(callback)
    if not ok then
        errors[#errors + 1] = label .. ": " .. tostring(value)
        return nil
    end
    return value
end

local function wrapConfigured(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    if not peripheral.isPresent(name) then
        return nil
    end
    return peripheral.wrap(name)
end

-- Propellers are owned by the pod on their corner, so their telemetry arrives
-- over the wireless link rather than from a local peripheral.wrap. podStates is
-- banks.getState(); each entry carries the prop sub-table the pod reports.
function devices.read(config, podStates)
    local result = { valid = true, errors = {}, props = {} }
    podStates = podStates or {}

    for _, corner in ipairs(CORNERS) do
        local pod = podStates[corner] or {}
        local prop = pod.prop or {}
        result.props[corner] = prop

        if config.wireless.enabled and not pod.online then
            result.valid = false
            result.errors[#result.errors + 1] = corner .. " pod offline: no propeller telemetry"
        elseif prop.controllerName and not prop.controllerPresent then
            result.valid = false
            result.errors[#result.errors + 1] =
                corner .. " controller missing: " .. prop.controllerName
        elseif prop.bearingName and not prop.bearingPresent then
            result.valid = false
            result.errors[#result.errors + 1] =
                corner .. " bearing missing: " .. prop.bearingName
        end

        for _, fault in ipairs(prop.faults or {}) do
            result.errors[#result.errors + 1] = corner .. " prop: " .. tostring(fault)
        end
    end

    local energy = wrapConfigured(config.peripherals.energyStorage)
    if energy then
        result.energy = attempt(result.errors, "stored FE", energy.getEnergy)
        result.energyCapacity = attempt(result.errors, "FE capacity", energy.getEnergyCapacity)
    end

    local powerMeter = wrapConfigured(config.peripherals.powerMeter)
    if powerMeter then
        result.gridPower = attempt(result.errors, "grid power", powerMeter.getPower)
    end

    local voltmeter = wrapConfigured(config.peripherals.voltmeter)
    if voltmeter then
        result.gridVoltage = attempt(result.errors, "grid voltage", voltmeter.getVoltage)
    end

    local ammeter = wrapConfigured(config.peripherals.ammeter)
    if ammeter then
        result.gridAmperage = attempt(result.errors, "grid amperage", ammeter.getAmperage)
    end

    return result
end

return devices
