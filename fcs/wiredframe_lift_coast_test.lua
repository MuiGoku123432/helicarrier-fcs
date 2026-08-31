-- Bounded zero-tilt lift-and-coast authority bracket for the direct wired frame.
--
-- Run only on FCS-DEV with the normal FCS stopped and the flight area clear:
--     /fcs/wiredframe_lift_coast_test.lua --lift-coast-check
--
-- This is a measurement, not a hover controller. It uses 3/15 only until an
-- early rise/velocity trigger, immediately steps down to 2/15 while airborne,
-- records the vertical response, and verifies exact-zero shutdown on all pods.

local args = { ... }
local CONTROL_CHANNEL, STATUS_CHANNEL = 42042, 42043
local PROTOCOL, MODE = "helicarrier.control-frame.v1", "response_map_test"
local CORNERS = { "FL", "FR", "RL", "RR" }
local CORNER_SET = { FL = true, FR = true, RL = true, RR = true }
local RESULT_PATH = "/fcs/wiredframe_lift_coast_result.txt"
local RATE_HZ, VALID_FOR_MS, SHUTDOWN_VALID_FOR_MS = 10, 750, 5000
local PRECHECK_SECONDS, MAX_LIFT_SECONDS, COAST_SECONDS, SHUTDOWN_SECONDS = 5, 2, 2, 3
local RESPONSE_PROP_RPM = 64
local LIFT_POWER, COAST_POWER, FALLBACK_POWER = 0.200, 0.14, 0.07
local FALLBACK_STOP_AFTER_MS = 5000
local LIFT_TRIGGER_RISE, LIFT_TRIGGER_UP_SPEED = 0.15, 0.35
local REQUIRED_COAST_SAMPLES, REQUIRED_VELOCITY_DROP = 5, 0.10
local CONFIRMATION = "LIFT-COAST"

-- Outer abort limits are intentionally wider than the early transition trigger,
-- but still bound the test to a small, recoverable creative-world excursion.
local MAX_SAMPLE_MS, POD_STATUS_MAX_AGE_MS = 1000, 1500
local MAX_RISE, MAX_FALL, MAX_HORIZONTAL_DISPLACEMENT = 1.5, 1.0, 1.5
local MAX_VERTICAL_SPEED, MAX_HORIZONTAL_SPEED, MAX_TOTAL_SPEED = 2.0, 1.5, 2.25
local MAX_TILT_DEGREES, MAX_ANGULAR_SPEED = 3.0, 0.35

local function finite(value)
    return type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
end

local function nearly(a, b)
    return finite(a) and finite(b) and math.abs(a - b) <= 1e-9
end

local function component(value, index, key)
    if type(value) ~= "table" then return nil end
    local result = value[index]
    if result == nil then result = value[key] end
    return finite(result) and result or nil
end

local function vector3(value)
    local x = component(value, 1, "x")
    local y = component(value, 2, "y")
    local z = component(value, 3, "z")
    if x == nil or y == nil or z == nil then return nil end
    return { x = x, y = y, z = z }
end

local function magnitude(value)
    return math.sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
end

local function quaternion(pose)
    if type(pose) ~= "table" then return nil end
    local candidate = pose.orientation or pose.rotation or pose.quaternion or pose
    if type(candidate) ~= "table" then return nil end
    local vector = candidate.v or candidate.vector or candidate
    local x = component(vector, 1, "x")
    local y = component(vector, 2, "y")
    local z = component(vector, 3, "z")
    local w = candidate.a
    if not finite(w) then w = candidate.w end
    if not finite(w) then w = candidate[4] end
    if x == nil or y == nil or z == nil or not finite(w) then return nil end
    local norm = math.sqrt(x * x + y * y + z * z + w * w)
    if norm <= 1e-12 then return nil end
    return { x = x / norm, y = y / norm, z = z / norm, w = w / norm }
end

local function upVector(q)
    return {
        x = 2 * (q.x * q.y - q.w * q.z),
        y = 1 - 2 * (q.x * q.x + q.z * q.z),
        z = 2 * (q.y * q.z + q.w * q.x),
    }
end

local function tiltDegrees(baseline, current)
    local a, b = upVector(baseline), upVector(current)
    local dot = a.x * b.x + a.y * b.y + a.z * b.z
    return math.deg(math.acos(math.max(-1, math.min(1, dot))))
end

local function positionFromPose(pose)
    if type(pose) ~= "table" then return nil end
    for _, field in ipairs({ "position", "pos", "translation", "location" }) do
        local value = vector3(pose[field])
        if value then return value, "logical_pose." .. field end
    end
    return nil
end

local function safeCall(api, method)
    local fn = api and api[method]
    if type(fn) ~= "function" then return nil, "missing method " .. tostring(method) end
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

local POSITION_METHODS = {
    "getPosition", "getLogicalPosition", "getContraptionPosition", "getWorldPosition",
}

local function readSample(api)
    local startedAt = os.epoch("utc")
    local pose = safeCall(api, "getLogicalPose")
    local linear = safeCall(api, "getLinearVelocity")
    local angular = safeCall(api, "getAngularVelocity")
    local position, positionSource = positionFromPose(pose)
    if not position then
        for _, method in ipairs(POSITION_METHODS) do
            if type(api[method]) == "function" then
                position = vector3(safeCall(api, method))
                if position then positionSource = method break end
            end
        end
    end
    local finishedAt = os.epoch("utc")
    return {
        finishedAt = finishedAt,
        elapsedMs = finishedAt - startedAt,
        quaternion = quaternion(pose),
        position = position,
        positionSource = positionSource,
        linearVelocity = vector3(linear),
        angularVelocity = vector3(angular),
    }
end

local function sampleValid(sample)
    return sample and sample.quaternion and sample.linearVelocity and sample.angularVelocity
        and finite(sample.elapsedMs) and sample.elapsedMs >= 0 and sample.elapsedMs <= MAX_SAMPLE_MS
end

local function command(kind)
    if kind == "shutdown" then
        return {
            ionPower = 0, fallbackIonPower = 0, propRpm = 0,
            tiltDegrees = 0, azimuthDegrees = 0, shutdown = true,
        }
    end
    local power = 0
    if kind == "lift" then power = LIFT_POWER end
    if kind == "coast" then power = COAST_POWER end
    return {
        ionPower = power,
        fallbackIonPower = power > 0 and FALLBACK_POWER or 0,
        fallbackStopAfterMs = FALLBACK_STOP_AFTER_MS,
        propRpm = RESPONSE_PROP_RPM,
        tiltDegrees = 0, azimuthDegrees = 0, shutdown = false,
    }
end

local function frame(session, sequence, sentAt, kind)
    local commands = {}
    for _, corner in ipairs(CORNERS) do commands[corner] = command(kind) end
    return {
        protocol = PROTOCOL, kind = "control_frame", mode = MODE, armed = true,
        session = session, sequence = sequence, sentAt = sentAt,
        validForMs = kind == "shutdown" and SHUTDOWN_VALID_FOR_MS or VALID_FOR_MS,
        corners = commands,
    }
end

local function countersClean(status)
    return type(status) == "table"
        and (tonumber(status.missing) or 0) == 0
        and (tonumber(status.duplicates) or 0) == 0
        and (tonumber(status.outOfOrder) or 0) == 0
        and (tonumber(status.invalid) or 0) == 0
        and (tonumber(status.expiredBeforeApply) or 0) == 0
        and (tonumber(status.applyErrors) or 0) == 0
        and (tonumber(status.fallbackCount) or 0) == 0
        and (tonumber(status.fallbackStops) or 0) == 0
end

local function applied(message, power, rpm)
    return type(message) == "table" and message.appliedMode == MODE
        and nearly(message.appliedIonPower, power)
        and message.appliedPropRpm == rpm
        and message.appliedTiltDegrees == 0 and message.appliedAzimuthDegrees == 0
end

local function shutdownStatusAccepted(status, seen, ageMs, expectedSequence)
    return seen == true and finite(ageMs) and ageMs <= POD_STATUS_MAX_AGE_MS
        and applied(status, 0, 0)
        and (tonumber(status.appliedSequence) or -1) == expectedSequence
end

local function evaluate(sample, baselineQuaternion, relative)
    local linear, angular = sample.linearVelocity, sample.angularVelocity
    local horizontalSpeed = math.sqrt(linear.x * linear.x + linear.z * linear.z)
    local metrics = {
        rise = relative.y,
        verticalVelocity = linear.y,
        verticalSpeed = math.abs(linear.y),
        horizontalDisplacement = math.sqrt(relative.x * relative.x + relative.z * relative.z),
        horizontalSpeed = horizontalSpeed,
        totalSpeed = magnitude(linear),
        angularSpeed = magnitude(angular),
        tiltDegrees = tiltDegrees(baselineQuaternion, sample.quaternion),
    }
    if metrics.rise > MAX_RISE then return metrics, "rise limit exceeded" end
    if metrics.rise < -MAX_FALL then return metrics, "fall limit exceeded" end
    if metrics.horizontalDisplacement > MAX_HORIZONTAL_DISPLACEMENT then
        return metrics, "horizontal displacement limit exceeded"
    end
    if metrics.verticalSpeed > MAX_VERTICAL_SPEED then return metrics, "vertical speed limit exceeded" end
    if metrics.horizontalSpeed > MAX_HORIZONTAL_SPEED then return metrics, "horizontal speed limit exceeded" end
    if metrics.totalSpeed > MAX_TOTAL_SPEED then return metrics, "total speed limit exceeded" end
    if metrics.tiltDegrees > MAX_TILT_DEGREES then return metrics, "attitude limit exceeded" end
    if metrics.angularSpeed > MAX_ANGULAR_SPEED then return metrics, "angular-rate limit exceeded" end
    return metrics, nil
end

local function liftTrigger(metrics)
    if metrics.rise >= LIFT_TRIGGER_RISE then return "rise" end
    if metrics.verticalVelocity >= LIFT_TRIGGER_UP_SPEED then return "upward_velocity" end
    return nil
end

local function coastDropEnough(peakVelocity, finalVelocity, samples)
    return samples >= REQUIRED_COAST_SAMPLES
        and finite(peakVelocity) and finite(finalVelocity)
        and peakVelocity - finalVelocity >= REQUIRED_VELOCITY_DROP
end

local function selfTest()
    assert(math.floor(LIFT_POWER * 15) == 3)
    assert(math.floor(COAST_POWER * 15) == 2)
    assert(math.floor(FALLBACK_POWER * 15) == 1)
    local lift = frame("self", 1, 1000, "lift")
    local coast = frame("self", 2, 1100, "coast")
    local stop = frame("self", 3, 1200, "shutdown")
    for _, corner in ipairs(CORNERS) do
        assert(lift.corners[corner].ionPower == LIFT_POWER)
        assert(coast.corners[corner].ionPower == COAST_POWER)
        assert(lift.corners[corner].fallbackIonPower == FALLBACK_POWER)
        assert(coast.corners[corner].fallbackIonPower == FALLBACK_POWER)
        assert(lift.corners[corner].propRpm == RESPONSE_PROP_RPM)
        assert(lift.corners[corner].tiltDegrees == 0)
        assert(stop.corners[corner].ionPower == 0 and stop.corners[corner].propRpm == 0)
        assert(stop.corners[corner].shutdown == true)
    end
    assert(liftTrigger({ rise = 0.16, verticalVelocity = 0 }) == "rise")
    assert(liftTrigger({ rise = 0, verticalVelocity = 0.36 }) == "upward_velocity")
    assert(liftTrigger({ rise = 0.1, verticalVelocity = 0.2 }) == nil)
    assert(coastDropEnough(0.8, 0.6, REQUIRED_COAST_SAMPLES))
    assert(not coastDropEnough(0.8, 0.75, REQUIRED_COAST_SAMPLES))
    local zeroStatus = {
        appliedMode = MODE, appliedIonPower = 0, appliedPropRpm = 0,
        appliedTiltDegrees = 0, appliedAzimuthDegrees = 0, appliedSequence = 7,
    }
    assert(shutdownStatusAccepted(zeroStatus, true, POD_STATUS_MAX_AGE_MS, 7))
    assert(not shutdownStatusAccepted(zeroStatus, false, 0, 7))
    local identity = { a = 1, v = { x = 0, y = 0, z = 0 } }
    local tilted = {
        a = math.cos(math.rad(1) / 2),
        v = { x = math.sin(math.rad(1) / 2), y = 0, z = 0 },
    }
    local q0, q1 = assert(quaternion(identity)), assert(quaternion(tilted))
    local sample = {
        quaternion = q1,
        linearVelocity = { x = 0.1, y = 0.3, z = 0.1 },
        angularVelocity = { x = 0.01, y = 0.01, z = 0.01 },
    }
    assert(select(2, evaluate(sample, q0, { x = 0.1, y = 0.2, z = 0.1 })) == nil)
    assert(select(2, evaluate(sample, q0,
        { x = 0, y = MAX_RISE + 0.01, z = 0 })) == "rise limit exceeded")
    local mock = {
        getLogicalPose = function() return identity end,
        getLinearVelocity = function() return { x = 0, y = 0, z = 0 } end,
        getAngularVelocity = function() return { x = 0, y = 0, z = 0 } end,
        getPosition = function() return { x = 1, y = 2, z = 3 } end,
    }
    local oldEpoch = os.epoch
    os.epoch = function() return 1000 end
    local mockSample = readSample(mock)
    os.epoch = oldEpoch
    assert(sampleValid(mockSample) and mockSample.position.y == 2)
    assert(countersClean({}) and not countersClean({ missing = 1 }))
    print("wired lift-and-coast sender self-test: PASS")
end

if args[1] == "--self-test" then selfTest() return end
if args[1] ~= "--lift-coast-check" then
    error("use --lift-coast-check; this is a bounded live flight test", 0)
end

print("ZERO-TILT LIFT-AND-COAST AUTHORITY BRACKET")
print("Required: FCS-DEV only, normal FCS stopped, flight area clear.")
print("Keep an operator at the computer; terminate is an emergency abort.")
print(string.format("Lift 3/15 until rise %.2f or upward speed %.2f; then coast 2/15 for %ds.",
    LIFT_TRIGGER_RISE, LIFT_TRIGGER_UP_SPEED, COAST_SECONDS))
print(string.format("Outer abort: rise %.1f, vertical speed %.1f, tilt %.1f degrees.",
    MAX_RISE, MAX_VERTICAL_SPEED, MAX_TILT_DEGREES))
write("Type " .. CONFIRMATION .. " to continue: ")
if read() ~= CONFIRMATION then error("operator confirmation not received", 0) end

local sublevel, sublevelSource = loadSublevel()
if not sublevel then error("CC:Sable sublevel API unavailable; no commands sent", 0) end
local inPlotGrid, plotError = safeCall(sublevel, "isInPlotGrid")
if plotError or inPlotGrid ~= true then
    error("FCS-DEV is not attached to a Sable Sub-Level; no commands sent", 0)
end
local baselineSample = readSample(sublevel)
if not sampleValid(baselineSample) then
    error("CC:Sable telemetry preflight failed; no commands sent", 0)
end
local baselineQuaternion, baselinePosition = baselineSample.quaternion, baselineSample.position
local testStartedAt = baselineSample.finishedAt

local function modems()
    local result = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            result[#result + 1] = { name = name, modem = peripheral.wrap(name) }
        end
    end
    return result
end

local function findWiredModem()
    for _, entry in ipairs(modems()) do
        local ok, wireless = pcall(entry.modem.isWireless)
        if ok and wireless == false then return entry.name, entry.modem end
    end
    return nil, nil
end

local modemName, modem = findWiredModem()
if not modem then error("no wired modem attached; no commands sent", 0) end
for _, entry in ipairs(modems()) do pcall(entry.modem.closeAll) end
modem.open(STATUS_CHANNEL)

local session = string.format("%d-response-lift-coast-%d", os.getComputerID(), os.epoch("utc"))
local latest, lastStatusAt, lastAppliedSequence = {}, {}, {}
local precheckSeen, liftSeen, coastSeen, shutdownSeen = {}, {}, {}, {}
local sequence, framesSent, transmitting = 0, 0, true
local currentPhase, runError, abortReason, shutdownError = "idle", nil, nil, nil
local telemetry = {
    count = 0, maxSampleMs = baselineSample.elapsedMs,
    minRise = 0, maxRise = 0, maxVerticalSpeed = 0,
    maxHorizontalDisplacement = 0, maxHorizontalSpeed = 0,
    maxTotalSpeed = 0, maxAngularSpeed = 0, maxTiltDegrees = 0,
    positionSource = baselinePosition and (baselineSample.positionSource or "absolute_position")
        or "integrated_linear_velocity",
    triggerReason = nil, triggerAt = nil, triggerRise = nil, triggerVelocity = nil,
    coastSamples = 0, coastInitialVelocity = nil,
    coastPeakVelocity = -math.huge, coastMinimumVelocity = math.huge,
    coastFinalVelocity = nil,
}
local trace = {}
local integrated = { x = 0, y = 0, z = 0 }
local lastTelemetryAt = baselineSample.finishedAt

local function abort(reason)
    if abortReason == nil then abortReason = tostring(reason) end
end

local function recordStatus(message)
    local corner, appliedSequence = message.corner, tonumber(message.appliedSequence)
    if lastAppliedSequence[corner] and appliedSequence
        and appliedSequence < lastAppliedSequence[corner] then
        abort("pod " .. corner .. " applied-sequence regression")
    end
    if appliedSequence then lastAppliedSequence[corner] = appliedSequence end
    latest[corner], lastStatusAt[corner] = message, os.epoch("utc")
    if not countersClean(message) then abort("pod " .. corner .. " reported a transport/apply fault") end
    if currentPhase == "precheck" and applied(message, 0, RESPONSE_PROP_RPM) then
        precheckSeen[corner] = true
    end
    if applied(message, LIFT_POWER, RESPONSE_PROP_RPM) then liftSeen[corner] = true end
    if applied(message, COAST_POWER, RESPONSE_PROP_RPM) then coastSeen[corner] = true end
    if currentPhase == "shutdown" and applied(message, 0, 0) then shutdownSeen[corner] = true end
end

local function receiveLoop()
    while transmitting do
        local event, _, channel, _, message = os.pullEvent()
        if event == "lift_coast_done" then return end
        if event == "modem_message" and channel == STATUS_CHANNEL
            and type(message) == "table"
            and message.protocol == PROTOCOL and message.session == session
            and CORNER_SET[message.corner] then
            recordStatus(message)
        end
    end
end

local function transmit(kind)
    sequence = sequence + 1
    modem.transmit(CONTROL_CHANNEL, STATUS_CHANNEL,
        frame(session, sequence, os.epoch("utc"), kind))
    framesSent = framesSent + 1
end

local function runPhase(seconds, kind, name, stopCondition)
    currentPhase = name
    local periodMs = math.floor(1000 / RATE_HZ)
    local stopAt = os.epoch("utc") + seconds * 1000
    local nextAt = os.epoch("utc")
    while os.epoch("utc") < stopAt do
        if abortReason then return false end
        if stopCondition and stopCondition() then return true end
        transmit(kind)
        nextAt = nextAt + periodMs
        local remaining = nextAt - os.epoch("utc")
        if remaining > 0 then sleep(remaining / 1000) end
    end
    return true
end

local function podsFresh(power, rpm, seen)
    local now = os.epoch("utc")
    for _, corner in ipairs(CORNERS) do
        local status = latest[corner]
        local age = lastStatusAt[corner] and now - lastStatusAt[corner] or math.huge
        if seen[corner] ~= true or age > POD_STATUS_MAX_AGE_MS
            or not countersClean(status) or not applied(status, power, rpm) then
            return false, corner
        end
    end
    return true
end

local function podsSeen(seen)
    for _, corner in ipairs(CORNERS) do
        if seen[corner] ~= true then return false, corner end
    end
    return true
end

local function shutdownAcknowledged()
    local now = os.epoch("utc")
    for _, corner in ipairs(CORNERS) do
        local status = latest[corner]
        local age = lastStatusAt[corner] and now - lastStatusAt[corner] or math.huge
        if not shutdownStatusAccepted(status, shutdownSeen[corner], age, sequence) then
            return false, corner
        end
    end
    return true
end

local function updateTelemetry(sample)
    local intervalMs = sample.finishedAt - lastTelemetryAt
    local dt = math.max(0, intervalMs / 1000)
    lastTelemetryAt = sample.finishedAt
    integrated.x = integrated.x + sample.linearVelocity.x * dt
    integrated.y = integrated.y + sample.linearVelocity.y * dt
    integrated.z = integrated.z + sample.linearVelocity.z * dt
    local relative
    if sample.position and baselinePosition then
        relative = {
            x = sample.position.x - baselinePosition.x,
            y = sample.position.y - baselinePosition.y,
            z = sample.position.z - baselinePosition.z,
        }
    else
        relative = { x = integrated.x, y = integrated.y, z = integrated.z }
    end
    local metrics, violation = evaluate(sample, baselineQuaternion, relative)
    if intervalMs > MAX_SAMPLE_MS + 250 then
        violation = violation or "CC:Sable telemetry interval stale"
    end
    telemetry.count = telemetry.count + 1
    telemetry.maxSampleMs = math.max(telemetry.maxSampleMs, sample.elapsedMs)
    telemetry.minRise = math.min(telemetry.minRise, metrics.rise)
    telemetry.maxRise = math.max(telemetry.maxRise, metrics.rise)
    telemetry.maxVerticalSpeed = math.max(telemetry.maxVerticalSpeed, metrics.verticalSpeed)
    telemetry.maxHorizontalDisplacement = math.max(
        telemetry.maxHorizontalDisplacement, metrics.horizontalDisplacement)
    telemetry.maxHorizontalSpeed = math.max(telemetry.maxHorizontalSpeed, metrics.horizontalSpeed)
    telemetry.maxTotalSpeed = math.max(telemetry.maxTotalSpeed, metrics.totalSpeed)
    telemetry.maxAngularSpeed = math.max(telemetry.maxAngularSpeed, metrics.angularSpeed)
    telemetry.maxTiltDegrees = math.max(telemetry.maxTiltDegrees, metrics.tiltDegrees)

    trace[#trace + 1] = {
        t = (sample.finishedAt - testStartedAt) / 1000,
        phase = currentPhase,
        rise = metrics.rise,
        verticalVelocity = metrics.verticalVelocity,
        horizontalSpeed = metrics.horizontalSpeed,
        totalSpeed = metrics.totalSpeed,
        tiltDegrees = metrics.tiltDegrees,
        angularSpeed = metrics.angularSpeed,
    }

    if currentPhase == "lift" and not telemetry.triggerReason then
        local reason = liftTrigger(metrics)
        if reason then
            telemetry.triggerReason = reason
            telemetry.triggerAt = (sample.finishedAt - testStartedAt) / 1000
            telemetry.triggerRise = metrics.rise
            telemetry.triggerVelocity = metrics.verticalVelocity
        end
    end
    if currentPhase == "coast" then
        telemetry.coastSamples = telemetry.coastSamples + 1
        telemetry.coastInitialVelocity = telemetry.coastInitialVelocity or metrics.verticalVelocity
        telemetry.coastPeakVelocity = math.max(telemetry.coastPeakVelocity, metrics.verticalVelocity)
        telemetry.coastMinimumVelocity = math.min(telemetry.coastMinimumVelocity, metrics.verticalVelocity)
        telemetry.coastFinalVelocity = metrics.verticalVelocity
    end
    return violation
end

local function telemetryLoop()
    while transmitting do
        if currentPhase ~= "shutdown" then
            local sample = readSample(sublevel)
            if not sampleValid(sample) then
                abort("CC:Sable telemetry invalid or stale")
            else
                local violation = updateTelemetry(sample)
                if violation and (currentPhase == "precheck"
                    or currentPhase == "lift" or currentPhase == "coast") then
                    abort(violation)
                end
            end
            if currentPhase == "precheck" or currentPhase == "lift"
                or currentPhase == "coast" then
                local now = os.epoch("utc")
                for _, corner in ipairs(CORNERS) do
                    if lastStatusAt[corner]
                        and now - lastStatusAt[corner] > POD_STATUS_MAX_AGE_MS then
                        abort("pod " .. corner .. " status became stale")
                    end
                end
            end
        end
        sleep(0.05)
    end
end

local function shutdownBurst(seconds)
    currentPhase = "shutdown"
    local stopAt = os.epoch("utc") + seconds * 1000
    while os.epoch("utc") < stopAt do pcall(transmit, "shutdown") sleep(0.1) end
end

local function runSequence()
    print("Precheck: telemetry plus four zero-ion/RPM-64 acknowledgements.")
    if not runPhase(PRECHECK_SECONDS, "spin", "precheck") then
        error(abortReason or "precheck aborted", 0)
    end
    local ready, corner = podsFresh(0, RESPONSE_PROP_RPM, precheckSeen)
    if not ready then error("fresh clean precheck not confirmed for " .. tostring(corner), 0) end

    print("Lift: commanding 3/15 until the early transition trigger.")
    if not runPhase(MAX_LIFT_SECONDS, "lift", "lift",
        function() return telemetry.triggerReason ~= nil end) then
        error(abortReason or "lift phase aborted", 0)
    end
    if not telemetry.triggerReason then
        error("lift trigger not reached within bounded lift phase", 0)
    end

    print("Coast: stepping immediately to 2/15 for response measurement.")
    if not runPhase(COAST_SECONDS, "coast", "coast") then
        error(abortReason or "coast phase aborted", 0)
    end
    local liftReady, liftCorner = podsSeen(liftSeen)
    if not liftReady then error("clean 3/15 application not confirmed for " .. tostring(liftCorner), 0) end
    local coastReady, coastCorner = podsFresh(COAST_POWER, RESPONSE_PROP_RPM, coastSeen)
    if not coastReady then error("clean 2/15 application not confirmed for " .. tostring(coastCorner), 0) end
    if not coastDropEnough(telemetry.coastPeakVelocity,
        telemetry.coastFinalVelocity, telemetry.coastSamples) then
        error("2/15 coast did not show the required upward-velocity decline", 0)
    end
end

local function sendLoop()
    local sequenceOk, sequenceError = pcall(runSequence)
    if not sequenceOk then runError = tostring(sequenceError) end
    print((runError or abortReason) and
        "Proof/safety condition failed; commanding explicit shutdown."
        or "Bracket measurement complete; commanding explicit shutdown.")
    shutdownBurst(SHUTDOWN_SECONDS)
    sleep(1)
    local zeroReady, zeroCorner = shutdownAcknowledged()
    if not zeroReady then
        shutdownError = "fresh zero shutdown not confirmed for " .. tostring(zeroCorner)
    end
    transmitting = false
    os.queueEvent("lift_coast_done")
end

local ok, err = pcall(parallel.waitForAll, sendLoop, receiveLoop, telemetryLoop)
if not ok then
    runError = runError or tostring(err)
    pcall(shutdownBurst, 2)
    transmitting = false
end
pcall(modem.close, STATUS_CHANNEL)

local coastDrop = finite(telemetry.coastPeakVelocity) and finite(telemetry.coastFinalVelocity)
    and telemetry.coastPeakVelocity - telemetry.coastFinalVelocity or nil
local failure = runError or abortReason or shutdownError
local lines = {
    "WIRED FRAME ZERO-TILT LIFT-AND-COAST BRACKET",
    "session=" .. session,
    "modem=" .. tostring(modemName),
    "mode=" .. MODE,
    "armed=true",
    "safety=FCS_DEV_LIVE_SENSOR_ABORT_ZERO_TILT_LIFT_COAST",
    "sublevel_source=" .. tostring(sublevelSource),
    "position_source=" .. tostring(telemetry.positionSource),
    "lift_power=" .. tostring(LIFT_POWER),
    "lift_level=3/15",
    "coast_power=" .. tostring(COAST_POWER),
    "coast_level=2/15",
    "fallback_power=" .. tostring(FALLBACK_POWER),
    "fallback_stop_after_ms=" .. tostring(FALLBACK_STOP_AFTER_MS),
    "response_prop_rpm=" .. tostring(RESPONSE_PROP_RPM),
    "tilt_degrees=0",
    "azimuth_degrees=0",
    "precheck_seconds=" .. tostring(PRECHECK_SECONDS),
    "max_lift_seconds=" .. tostring(MAX_LIFT_SECONDS),
    "coast_seconds=" .. tostring(COAST_SECONDS),
    "shutdown_seconds=" .. tostring(SHUTDOWN_SECONDS),
    "lift_trigger_rise=" .. tostring(LIFT_TRIGGER_RISE),
    "lift_trigger_up_speed=" .. tostring(LIFT_TRIGGER_UP_SPEED),
    "abort_max_rise=" .. tostring(MAX_RISE),
    "abort_max_fall=" .. tostring(MAX_FALL),
    "abort_max_horizontal_displacement=" .. tostring(MAX_HORIZONTAL_DISPLACEMENT),
    "abort_max_vertical_speed=" .. tostring(MAX_VERTICAL_SPEED),
    "abort_max_horizontal_speed=" .. tostring(MAX_HORIZONTAL_SPEED),
    "abort_max_total_speed=" .. tostring(MAX_TOTAL_SPEED),
    "abort_max_tilt_degrees=" .. tostring(MAX_TILT_DEGREES),
    "abort_max_angular_speed=" .. tostring(MAX_ANGULAR_SPEED),
    "frames_sent=" .. tostring(framesSent),
    "final_sequence=" .. tostring(sequence),
    "telemetry_samples=" .. tostring(telemetry.count),
    "telemetry_max_sample_ms=" .. tostring(telemetry.maxSampleMs),
    "telemetry_min_rise=" .. tostring(telemetry.minRise),
    "telemetry_max_rise=" .. tostring(telemetry.maxRise),
    "telemetry_max_vertical_speed=" .. tostring(telemetry.maxVerticalSpeed),
    "telemetry_max_horizontal_displacement=" .. tostring(telemetry.maxHorizontalDisplacement),
    "telemetry_max_horizontal_speed=" .. tostring(telemetry.maxHorizontalSpeed),
    "telemetry_max_total_speed=" .. tostring(telemetry.maxTotalSpeed),
    "telemetry_max_angular_speed=" .. tostring(telemetry.maxAngularSpeed),
    "telemetry_max_tilt_degrees=" .. tostring(telemetry.maxTiltDegrees),
    "lift_trigger_reason=" .. tostring(telemetry.triggerReason),
    "lift_trigger_at=" .. tostring(telemetry.triggerAt),
    "lift_trigger_rise_observed=" .. tostring(telemetry.triggerRise),
    "lift_trigger_velocity_observed=" .. tostring(telemetry.triggerVelocity),
    "coast_samples=" .. tostring(telemetry.coastSamples),
    "coast_initial_vertical_velocity=" .. tostring(telemetry.coastInitialVelocity),
    "coast_peak_vertical_velocity=" .. tostring(telemetry.coastPeakVelocity),
    "coast_minimum_vertical_velocity=" .. tostring(telemetry.coastMinimumVelocity),
    "coast_final_vertical_velocity=" .. tostring(telemetry.coastFinalVelocity),
    "coast_velocity_drop=" .. tostring(coastDrop),
}
if runError or abortReason then
    lines[#lines + 1] = "run_error=" .. tostring(runError or abortReason)
end
if shutdownError then lines[#lines + 1] = "shutdown_error=" .. tostring(shutdownError) end

for index, entry in ipairs(trace) do
    lines[#lines + 1] = string.format(
        "trace=%d t=%.3f phase=%s rise=%.6f vy=%.6f hspeed=%.6f speed=%.6f tilt=%.6f angular=%.6f",
        index, entry.t, entry.phase, entry.rise, entry.verticalVelocity,
        entry.horizontalSpeed, entry.totalSpeed, entry.tiltDegrees, entry.angularSpeed)
end

local overall, aggregate = failure == nil, 0
for _, corner in ipairs(CORNERS) do
    local status = latest[corner]
    local received = status and tonumber(status.received) or 0
    aggregate = aggregate + received
    local cornerPass = status ~= nil and precheckSeen[corner] == true
        and liftSeen[corner] == true and coastSeen[corner] == true
        and shutdownSeen[corner] == true and received == framesSent
        and countersClean(status) and (tonumber(status.appliedSequence) or -1) == sequence
        and applied(status, 0, 0)
    if not cornerPass then overall = false end
    lines[#lines + 1] = string.format(
        "%s recv=%d missing=%s dup=%s order=%s invalid=%s applied=%s applies=%s coalesced=%s expired=%s errors=%s fallbacks=%s fallback_stops=%s precheck_seen=%s lift_seen=%s coast_seen=%s shutdown_seen=%s applied_ion=%s applied_rpm=%s applied_tilt=%s max_apply_ms=%s result=%s",
        corner, received,
        tostring(status and status.missing or "nil"), tostring(status and status.duplicates or "nil"),
        tostring(status and status.outOfOrder or "nil"), tostring(status and status.invalid or "nil"),
        tostring(status and status.appliedSequence or "nil"), tostring(status and status.applyCount or "nil"),
        tostring(status and status.coalesced or "nil"), tostring(status and status.expiredBeforeApply or "nil"),
        tostring(status and status.applyErrors or "nil"), tostring(status and status.fallbackCount or "nil"),
        tostring(status and status.fallbackStops or "nil"), tostring(precheckSeen[corner] == true),
        tostring(liftSeen[corner] == true), tostring(coastSeen[corner] == true),
        tostring(shutdownSeen[corner] == true), tostring(status and status.appliedIonPower or "nil"),
        tostring(status and status.appliedPropRpm or "nil"),
        tostring(status and status.appliedTiltDegrees or "nil"),
        tostring(status and status.maxApplyMs or "nil"), cornerPass and "PASS" or "FAIL")
end
lines[#lines + 1] = "aggregate_verified_deliveries=" .. tostring(aggregate)
lines[#lines + 1] = "overall=" .. (overall and "PASS" or "FAIL")

local file = fs.open(RESULT_PATH, "w")
if not file then error("unable to write " .. RESULT_PATH, 0) end
file.write(table.concat(lines, "\n"))
file.close()
print("Result: " .. (overall and "PASS" or "FAIL"))
print("Report written to " .. RESULT_PATH)
if not overall then error("zero-tilt lift-and-coast bracket failed", 0) end
