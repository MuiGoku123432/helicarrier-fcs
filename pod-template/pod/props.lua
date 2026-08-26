local config = require("pod.config")

local props = {
    controller = nil,
    bearing = nil,
    controllerName = nil,
    bearingName = nil,
    faults = {},
}

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function roundedInteger(value)
    if value >= 0 then
        return math.floor(value + 0.5)
    end
    return math.ceil(value - 0.5)
end

local function optional(device, method)
    return type(device[method]) == "function" and device[method] or nil
end

local function attempt(faults, label, callback)
    local ok, value = pcall(callback)
    if not ok then
        faults[#faults + 1] = label .. ": " .. tostring(value)
        return nil
    end
    return value
end

-- A nil name means "this pod has no prop", which is not a fault. A configured
-- name that cannot be used is a fault the pod reports and then keeps running.
-- required may be one method name or a list of alternatives, since the same
-- role is spelled differently across mods: a Create Aeronautics propeller
-- bearing reports RPM as getRotationSpeed, while
-- simulated_addition:directional_propeller_bearing calls it getSpeed. Accept
-- either rather than locking the pod to one mod's vocabulary.
local function wrapConfigured(name, required, label)
    if type(name) ~= "string" or name == "" then
        return nil, nil
    end
    if not peripheral.isPresent(name) then
        return nil, label .. " missing: " .. name
    end

    local device = peripheral.wrap(name)
    local alternatives = type(required) == "table" and required or { required }
    for _, method in ipairs(alternatives) do
        if type(device[method]) ~= "function" then
            -- keep looking
        else
            return device, nil
        end
    end

    return nil, label .. " lacks " .. table.concat(alternatives, "/") .. ": " .. name
end

-- propBearing accepts one name or a list of them, because a corner can carry
-- more than one propeller. Returns a plain list either way.
local function bearingNames()
    local configured = config.propBearing
    if type(configured) == "string" and configured ~= "" then
        return { configured }
    end
    if type(configured) == "table" then
        local names = {}
        for _, name in ipairs(configured) do
            if type(name) == "string" and name ~= "" then
                names[#names + 1] = name
            end
        end
        return names
    end
    return {}
end

-- Deliberately never errors, unlike thrusters.load(). A dead Rotation Speed
-- Controller must not ground this corner's ion bank -- the bank is the failsafe
-- layer, and it has to come up even when the propeller side is broken.
function props.load()
    props.faults = {}
    props.controllerName = config.propController
    props.bearings = {}
    props.bearingNames = bearingNames()
    props.bearingName = #props.bearingNames > 0
        and table.concat(props.bearingNames, ", ") or nil

    local controller, controllerFault =
        wrapConfigured(config.propController, "setTargetSpeed", "prop controller")
    props.controller = controller
    if controllerFault then
        props.faults[#props.faults + 1] = controllerFault
    end

    for _, name in ipairs(props.bearingNames) do
        -- getSpeed, not getThrust: prop bearings vary by mod. Create Aeronautics
        -- bearings report thrust/airflow/sail power, but
        -- simulated_addition:directional_propeller_bearing exposes only the
        -- rotation side. getSpeed is the one reading every bearing has, so it
        -- is what the pod requires; richer readings are used when present.
        local bearing, bearingFault =
            wrapConfigured(name, { "getRotationSpeed", "getSpeed" }, "prop bearing")
        if bearing then
            props.bearings[#props.bearings + 1] = bearing
        else
            props.faults[#props.faults + 1] = bearingFault
        end
    end

    -- Kept so single-bearing callers and the display still read naturally.
    props.bearing = props.bearings[1]

    return props
end

function props.telemetry()
    local faults = {}
    for _, fault in ipairs(props.faults) do
        faults[#faults + 1] = fault
    end

    local result = {
        controllerPresent = props.controller ~= nil,
        bearingPresent = #props.bearings > 0,
        bearingCount = #props.bearings,
        bearingExpected = #props.bearingNames,
        controllerName = props.controllerName,
        bearingName = props.bearingName,
    }

    if props.controller then
        result.targetRpm = attempt(faults, "target RPM", props.controller.getTargetSpeed)
        result.controllerRpm = attempt(faults, "controller RPM", props.controller.getSpeed)
        result.hasSource = attempt(faults, "has source", props.controller.hasSource)
        result.overstressed = attempt(faults, "overstressed", props.controller.isOverstressed)
    end

    -- Aggregated across every bearing on this corner.
    --
    -- getThrust is signed by HANDEDNESS, not by world direction: a
    -- counter-rotating pair reports +x and -x while physically pushing the same
    -- way. Summing the raw values annihilates them to exactly zero, which is
    -- what made three corners look dead. Sum magnitudes for the corner total,
    -- and keep the signed sum as `thrustImbalance` -- for a matched pair it is
    -- ~0, and any drift from that is one bearing underperforming its twin.
    if #props.bearings > 0 then
        local thrust, airflow, sailPower, rpm = 0, 0, 0, 0
        local thrustSigned = 0
        local rpmSamples, active = 0, false

        local sawThrust, sawAirflow, sawSail, sawActive = false, false, false, false
        local overstressed = false
        local assembled, sawAssembled = 0, false
        -- Per-bearing rows: an aggregate cannot show two bearings cancelling.
        result.perBearing = {}
        local tiltSum, tiltSamples = 0, 0
        local angular, angularSamples = 0, 0
        local kinetic, kineticSamples = 0, 0

        for index, bearing in ipairs(props.bearings) do
            local label = "bearing " .. index

            local getThrust = optional(bearing, "getThrust")
            if getThrust then
                sawThrust = true
                local reading = attempt(faults, label .. " thrust", getThrust) or 0
                thrust = thrust + math.abs(reading)
                thrustSigned = thrustSigned + reading
            end

            -- Vectoring feedback. getTiltAngle is the tilt in degrees;
            -- getThrustVector is the bearing's axis as an ARRAY {1,2,3}, NOT
            -- {x,y,z} -- reading .x/.y/.z off it yields three nils, which is
            -- how it came to be recorded as "returns nil".
            local getTiltAngle = optional(bearing, "getTiltAngle")
            if getTiltAngle then
                local reading = attempt(faults, label .. " tilt", getTiltAngle)
                if reading then
                    result.perBearingTilt = result.perBearingTilt or {}
                    result.perBearingTilt[index] = reading
                    tiltSum = tiltSum + reading
                    tiltSamples = tiltSamples + 1
                end
            end

            local getManualTarget = optional(bearing, "getManualTarget")
            if getManualTarget then
                local reading = attempt(faults, label .. " manual target", getManualTarget)
                if type(reading) == "table" then
                    result.perBearingTarget = result.perBearingTarget or {}
                    result.perBearingTarget[index] =
                        { reading[1], reading[2], reading[3] }
                end
            end

            local getAirflow = optional(bearing, "getAirflow")
            if getAirflow then
                sawAirflow = true
                airflow = airflow + (attempt(faults, label .. " airflow", getAirflow) or 0)
            end

            local getSailPower = optional(bearing, "getSailPower")
            if getSailPower then
                sawSail = true
                sailPower = sailPower + (attempt(faults, label .. " sail power", getSailPower) or 0)
            end

            -- getRotationSpeed where a bearing has it, getSpeed otherwise.
            local getRpm = optional(bearing, "getRotationSpeed") or optional(bearing, "getSpeed")
            local reading = getRpm and attempt(faults, label .. " RPM", getRpm)
            if reading then
                rpm = rpm + reading
                rpmSamples = rpmSamples + 1
            end

            local isActive = optional(bearing, "isActive")
            if isActive then
                sawActive = true
                if attempt(faults, label .. " active", isActive) then
                    active = true
                end
            end

            local isOverstressed = optional(bearing, "isOverstressed")
            if isOverstressed and attempt(faults, label .. " overstressed", isOverstressed) then
                overstressed = true
            end

            -- Diagnostics: a Create Aeronautics bearing only makes thrust once
            -- it has formed its contraption, and getRotationSpeed reads 0 even
            -- on a bearing that is plainly working -- so record what each of
            -- the three speed sources actually says.
            local isAssembled = optional(bearing, "isAssembled")
            if isAssembled then
                sawAssembled = true
                if attempt(faults, label .. " assembled", isAssembled) then
                    assembled = assembled + 1
                end
            end

            local getAngular = optional(bearing, "getAngularSpeed")
            if getAngular then
                local v = attempt(faults, label .. " angular", getAngular)
                if v then angular = angular + v; angularSamples = angularSamples + 1 end
            end

            local getKinetic = optional(bearing, "getSpeed")
            if getKinetic then
                local v = attempt(faults, label .. " kinetic", getKinetic)
                if v then kinetic = kinetic + v; kineticSamples = kineticSamples + 1 end
            end

            local getVector = optional(bearing, "getThrustVector")
            local vec = getVector and attempt(faults, label .. " thrustVector", getVector)
            local getHand = optional(bearing, "getThrustHandedness")
            result.perBearing[index] = {
                name = props.bearingNames[index],
                thrust = getThrust and attempt(faults, label .. " thrust2", getThrust) or nil,
                assembled = isAssembled and attempt(faults, label .. " asm2", isAssembled) or nil,
                handedness = getHand and attempt(faults, label .. " hand", getHand) or nil,
                -- ARRAY-indexed {1,2,3}, not {x,y,z}. The comment above said
                -- so; this line still read .x/.y/.z and put three nils in every
                -- heartbeat. Accept either shape rather than swapping one
                -- assumption for another.
                vx = vec and (vec[1] or vec.x),
                vy = vec and (vec[2] or vec.y),
                vz = vec and (vec[3] or vec.z),
            }
        end

        -- Left nil rather than 0 when no bearing can report it: an empty column
        -- says "unavailable", a zero would read as "measured no thrust".
        result.thrust = sawThrust and thrust or nil
        result.thrustImbalance = sawThrust and thrustSigned or nil
        result.airflow = sawAirflow and airflow or nil
        result.sailPower = sawSail and sailPower or nil
        result.active = sawActive and active or nil
        result.bearingRpm = rpmSamples > 0 and (rpm / rpmSamples) or nil
        result.bearingOverstressed = overstressed
        result.bearingsAssembled = sawAssembled and assembled or nil
        result.bearingAngularSpeed = angularSamples > 0 and (angular / angularSamples) or nil
        -- Mean tilt across this corner's bearings, in degrees. The FCS
        -- confirms a tilt command from THIS, not from an ack -- the same rule
        -- the RPM path learned the hard way.
        result.tiltAngle = tiltSamples > 0 and (tiltSum / tiltSamples) or nil
        result.bearingKineticSpeed = kineticSamples > 0 and (kinetic / kineticSamples) or nil
    end

    result.faults = faults
    return result
end

-- Set and hold. There is no watchdog revert here on purpose: the propellers are
-- the lift source, so dropping them to a fallback RPM on a wireless hiccup would
-- drop the carrier. Clamping happens pod-side, where the hardware is, rather
-- than trusting whatever the sender asked for.
-- ---------------------------------------------------------------------------
-- Thrust vectoring
--
-- setManualTarget takes an ARRAY vector, {x, y, z}, and the mod NORMALISES it
-- for you -- commanding {0.174, 0.985, 0} reads back as {0.173956, 0.984753,
-- 0}, the input over its own length. Confirmed on FL bearing_1.
--
-- It only takes effect while the bearing is ACTIVE. At 0 RPM the target is
-- stored and completely ignored: getTiltAngle stays 0 and getThrustVector does
-- not move. With props turning, getThrustVector tracks the target exactly and
-- getTiltAngle reports the angle in degrees.
--
-- Each bearing's neutral is its OWN getBlockNormal, not world up: a
-- counter-rotating pair reads {0,1,0} and {0,-1,0}. So a tilt is applied
-- relative to that normal, otherwise commanding "5 degrees" would flip the
-- second bearing of every pair.
--
-- WHAT IS NOT YET KNOWN: which way the resulting FORCE points. getThrust is
-- signed by handedness rather than world direction, and getThrustVector
-- reports the bearing's own axis -- the pair reads {0,1,0} and {0,-1,0} while
-- physically pushing the craft the same way. So the mapping from a commanded
-- tilt to a lateral force direction is UNVERIFIED. Command it, read it back,
-- and measure the craft's response before trusting a sign.
-- ---------------------------------------------------------------------------

local MAX_TILT_DEGREES = 15

-- A tilt of `angle` degrees away from the bearing's own normal, rotated
-- `azimuth` degrees around it. Azimuth 0 is toward +X (bow), 90 toward +Z
-- (starboard), matching fcs/config.lua's body convention.
local function tiltTarget(bearing, angle, azimuth)
    local normal = { 0, 1, 0 }
    local getBlockNormal = optional(bearing, "getBlockNormal")
    if getBlockNormal then
        local ok, value = pcall(getBlockNormal)
        if ok and type(value) == "table" and type(value[2]) == "number" then
            normal = { value[1] or 0, value[2], value[3] or 0 }
        end
    end

    local sign = (normal[2] >= 0) and 1 or -1
    local tilt = math.rad(angle)
    local swing = math.rad(azimuth or 0)

    return {
        math.sin(tilt) * math.cos(swing),
        sign * math.cos(tilt),
        math.sin(tilt) * math.sin(swing),
    }
end

-- Apply a tilt to every bearing on this corner, or to one of them by index.
-- Returns a per-bearing report so the caller can see what actually took.
function props.setTilt(angle, azimuth, index)
    local requested = tonumber(angle)
    if not requested then
        error("tilt angle must be a number", 0)
    end
    requested = clamp(requested, -MAX_TILT_DEGREES, MAX_TILT_DEGREES)
    azimuth = tonumber(azimuth) or 0

    if #props.bearings == 0 then
        error("no bearings on " .. tostring(config.corner), 0)
    end

    local applied = {}
    for bearingIndex, bearing in ipairs(props.bearings) do
        if not index or index == bearingIndex then
            local setManualTarget = optional(bearing, "setManualTarget")
            if not setManualTarget then
                applied[bearingIndex] = { error = "setManualTarget absent" }
            else
                local target = tiltTarget(bearing, requested, azimuth)
                local ok, err = pcall(setManualTarget, target)
                applied[bearingIndex] = ok
                    and { target = target, requested = requested, azimuth = azimuth }
                    or { error = tostring(err) }
            end
        end
    end

    return { angle = requested, azimuth = azimuth, bearings = applied }
end

function props.clearTilt(index)
    local cleared = {}
    for bearingIndex, bearing in ipairs(props.bearings) do
        if not index or index == bearingIndex then
            local clearManualTarget = optional(bearing, "clearManualTarget")
            if not clearManualTarget then
                cleared[bearingIndex] = { error = "clearManualTarget absent" }
            else
                local ok, err = pcall(clearManualTarget)
                cleared[bearingIndex] = ok and { cleared = true } or { error = tostring(err) }
            end
        end
    end
    return cleared
end

function props.setRpm(requestedRpm)
    local rpm = tonumber(requestedRpm)
    if not rpm then
        error("RPM must be a number", 0)
    end
    if not props.controller then
        error("no prop controller on " .. tostring(config.corner), 0)
    end

    rpm = roundedInteger(clamp(rpm, config.propMinimumRpm, config.propMaximumRpm))
    props.controller.setTargetSpeed(rpm)
    return rpm
end

return props
