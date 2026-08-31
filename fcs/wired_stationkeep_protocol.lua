local protocol = {}

protocol.PROTOCOL = "helicarrier.control-frame.v1"
protocol.MODE = "stationkeep"
protocol.CONTROL_CHANNEL = 42042
protocol.STATUS_CHANNEL = 42043
protocol.CORNERS = { "FL", "FR", "RL", "RR" }
protocol.PROP_RPM = 64
protocol.HIGH_POWER = 0.20
protocol.LOW_POWER = 0.14
protocol.FALLBACK_POWER = 0.07
protocol.FALLBACK_STOP_AFTER_MS = 5000
protocol.VALID_FOR_MS = 750
protocol.SHUTDOWN_VALID_FOR_MS = 5000
protocol.MAX_TILT_DEGREES = 6

local function finite(value)
    return type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
end

local function nearly(a, b, tolerance)
    return finite(a) and finite(b) and math.abs(a - b) <= (tolerance or 1e-6)
end

function protocol.command(kind, actuation)
    actuation = actuation or {}
    if kind == "shutdown" then
        return {
            ionPower = 0,
            fallbackIonPower = 0,
            propRpm = 0,
            tiltDegrees = 0,
            azimuthDegrees = 0,
            shutdown = true,
        }
    end

    local ionPower = 0
    local fallbackIonPower = 0
    if kind == "high" then
        ionPower, fallbackIonPower = protocol.HIGH_POWER, protocol.FALLBACK_POWER
    elseif kind == "low" then
        ionPower, fallbackIonPower = protocol.LOW_POWER, protocol.FALLBACK_POWER
    elseif kind ~= "precheck" then
        error("unknown stationkeep command kind " .. tostring(kind), 2)
    end

    local tilt = tonumber(actuation.tiltDegrees) or 0
    local azimuth = tonumber(actuation.azimuthDegrees) or 0
    if not finite(tilt) or math.abs(tilt) > protocol.MAX_TILT_DEGREES then
        error("stationkeep tilt outside protocol envelope", 2)
    end
    if not finite(azimuth) or azimuth < 0 or azimuth >= 360 then
        error("stationkeep azimuth outside protocol envelope", 2)
    end

    return {
        ionPower = ionPower,
        fallbackIonPower = fallbackIonPower,
        fallbackStopAfterMs = protocol.FALLBACK_STOP_AFTER_MS,
        propRpm = protocol.PROP_RPM,
        tiltDegrees = tilt,
        azimuthDegrees = azimuth,
        shutdown = false,
    }
end

function protocol.frame(session, sequence, sentAt, kind, actuation)
    local corners = {}
    for _, corner in ipairs(protocol.CORNERS) do
        corners[corner] = protocol.command(kind, actuation)
    end
    return {
        protocol = protocol.PROTOCOL,
        kind = "control_frame",
        mode = protocol.MODE,
        armed = true,
        session = session,
        sequence = sequence,
        sentAt = sentAt,
        validForMs = kind == "shutdown"
            and protocol.SHUTDOWN_VALID_FOR_MS or protocol.VALID_FOR_MS,
        corners = corners,
    }
end

local function statusNumber(status, ...)
    for index = 1, select("#", ...) do
        local value = status and status[select(index, ...)]
        if finite(value) then return value end
    end
    return nil
end

function protocol.cleanStatus(status)
    if type(status) ~= "table" then return false end
    for _, field in ipairs({
        "missing", "duplicates", "outOfOrder", "invalid",
        "expiredBeforeApply", "applyErrors",
    }) do
        if (tonumber(status[field]) or 0) ~= 0 then return false end
    end
    return true
end

function protocol.applied(status, expected, expectedSequence)
    if type(status) ~= "table" or type(expected) ~= "table" then return false end
    local sequence = statusNumber(status, "appliedSequence", "lastAppliedSequence")
    if expectedSequence and (not sequence or sequence < expectedSequence) then
        return false
    end
    local ion = statusNumber(status, "appliedIonPower", "ionPower")
    local rpm = statusNumber(status, "appliedPropRpm", "propRpm")
    local tilt = statusNumber(status, "appliedTiltDegrees", "tiltDegrees")
    local azimuth = statusNumber(status, "appliedAzimuthDegrees", "azimuthDegrees")
    return nearly(ion, expected.ionPower)
        and nearly(rpm, expected.propRpm)
        and nearly(tilt, expected.tiltDegrees, 0.02)
        and nearly(azimuth, expected.azimuthDegrees, 0.02)
end

function protocol.selfTest()
    local frame = protocol.frame("self", 7, 1234, "high", {
        tiltDegrees = 2.5,
        azimuthDegrees = 90,
    })
    assert(frame.protocol == protocol.PROTOCOL)
    assert(frame.mode == protocol.MODE and frame.armed == true)
    assert(frame.corners.FL.tiltDegrees == 2.5)
    assert(frame.corners.RR.azimuthDegrees == 90)
    assert(frame.corners.FL.propRpm == 64)
    local shutdown = protocol.frame("self", 8, 1235, "shutdown")
    assert(shutdown.corners.FL.shutdown == true)
    assert(shutdown.corners.FL.ionPower == 0)
    assert(shutdown.corners.FL.propRpm == 0)
    return true
end

return protocol
