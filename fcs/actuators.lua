local config = require("fcs.config")
local banks = require("fcs.banks")

local actuators = {}
local CORNERS = { FL = true, FR = true, RL = true, RR = true }

-- How long to wait for the pod that owns a propeller to answer.
local REPLY_TIMEOUT_MS = 1000

local function normalizeCorner(corner)
    corner = string.upper(corner or "")
    if not CORNERS[corner] then
        error("Unknown corner " .. tostring(corner) .. "; use FL, FR, RL, or RR", 0)
    end
    return corner
end

local function roundedInteger(value)
    if value >= 0 then
        return math.floor(value + 0.5)
    end
    return math.ceil(value - 0.5)
end

local function lastReceivedAt(corner)
    local pod = banks.getState()[corner]
    return (pod and pod.receivedAt) or 0
end

-- Wait for a reply strictly newer than the one already on file. Keying off the
-- previous receipt rather than the send time matters: a reply landing in the
-- same millisecond as the send would otherwise pass a `>= sentAt` test, and a
-- stale fault from an earlier command would be read as this command's answer.
--
-- The pod also broadcasts unprompted telemetry every telemetryPeriodSeconds,
-- and one of those can arrive between our send and the pod applying the
-- command -- so when a specific reply type is wanted, a plain status broadcast
-- is not good enough to return.
local function waitForReply(corner, after, wantReply)
    local deadline = os.epoch("utc") + REPLY_TIMEOUT_MS

    repeat
        banks.poll()
        local pod = banks.getState()[corner]
        if pod then
            if wantReply then
                -- Read the dedicated ack/fault stamps, NOT pod.type. pod.type
                -- is simply the most recent message, and unprompted telemetry
                -- arrives every 200 ms, so an ack observed a moment late looks
                -- like no ack at all. See the note in fcs/banks.lua.
                if pod.lastFaultAt and pod.lastFaultAt > after then
                    return pod, "fault"
                end
                if pod.lastAckAt and pod.lastAckAt > after then
                    return pod, "ack"
                end
            elseif pod.receivedAt and pod.receivedAt > after then
                return pod, pod.type
            end
        end
        sleep(0.05)
    until os.epoch("utc") > deadline

    return nil
end

local function describe(corner, pod, requestedRpm)
    local prop = pod.prop or {}
    return {
        corner = corner,
        podId = pod.podId,
        name = prop.controllerName,
        requestedRpm = requestedRpm,
        targetRpm = prop.targetRpm,
        actualRpm = prop.controllerRpm,
        hasSource = prop.hasSource,
        overstressed = prop.overstressed,
        controllerPresent = prop.controllerPresent,
        bearingPresent = prop.bearingPresent,
        faults = prop.faults,
    }
end

function actuators.setPropellerRpm(corner, requestedRpm)
    corner = normalizeCorner(corner)

    local rpm = tonumber(requestedRpm)
    if not rpm then
        error("RPM must be a number", 0)
    end
    rpm = roundedInteger(math.max(config.propeller.minimumRpm,
        math.min(config.propeller.maximumRpm, rpm)))

    local seenAt = lastReceivedAt(corner)
    local sent, reason = banks.send(corner, "set_rpm", { rpm = rpm })
    if not sent then
        error(reason, 0)
    end

    local pod, replyType = waitForReply(corner, seenAt, true)
    if not pod then
        error("no reply from the " .. corner .. " pod within "
            .. REPLY_TIMEOUT_MS .. " ms; RPM may or may not have been applied", 0)
    end
    if replyType == "fault" then
        local prop = pod.prop or {}
        error(corner .. " pod reported a fault: "
            .. table.concat(prop.faults or pod.faults or { "unknown" }, " | "), 0)
    end

    return describe(corner, pod, rpm)
end

-- ---------------------------------------------------------------------------
-- Thrust vectoring
--
-- Confirmed from a tilt IN TELEMETRY, never from the ack: the pod's reported
-- tiltAngle is the only proof the bearings actually moved. An ack says the
-- message was accepted, and at 0 RPM the bearings accept a target and ignore
-- it completely -- isActive is false, and nothing moves.
-- ---------------------------------------------------------------------------

function actuators.setTilt(corner, angleDegrees, azimuthDegrees, bearingIndex, mirror)
    corner = normalizeCorner(corner)

    local angle = tonumber(angleDegrees)
    if not angle then
        error("tilt angle must be a number", 0)
    end

    local seenAt = lastReceivedAt(corner)
    local sent, reason = banks.send(corner, "set_tilt", {
        angle = angle,
        azimuth = tonumber(azimuthDegrees) or 0,
        bearing = bearingIndex,
        -- Mirrors the down-facing bearing of each counter-rotating pair so the
        -- two lateral forces ADD instead of cancelling. Measured: unmirrored
        -- is exactly zero lateral force. Defaults true pod-side; passed
        -- explicitly only when a caller wants the old behaviour to compare.
        mirror = mirror,
    })
    if not sent then
        error(reason, 0)
    end

    local pod, replyType = waitForReply(corner, seenAt, true)
    if not pod then
        error("no reply from the " .. corner .. " pod within "
            .. REPLY_TIMEOUT_MS .. " ms; tilt may or may not have been applied", 0)
    end
    if replyType == "fault" then
        local prop = pod.prop or {}
        error(corner .. " pod reported a fault: "
            .. table.concat(prop.faults or pod.faults or { "unknown" }, " | "), 0)
    end

    return {
        corner = corner,
        requested = angle,
        azimuth = tonumber(azimuthDegrees) or 0,
        commandedTilt = pod.commandedTilt,
        reportedTilt = (pod.prop or {}).tiltAngle,
    }
end

function actuators.clearTilt(corner, bearingIndex)
    corner = normalizeCorner(corner)

    local seenAt = lastReceivedAt(corner)
    local sent, reason = banks.send(corner, "clear_tilt", { bearing = bearingIndex })
    if not sent then
        error(reason, 0)
    end

    local pod, replyType = waitForReply(corner, seenAt, true)
    if not pod then
        error("no reply from the " .. corner .. " pod within "
            .. REPLY_TIMEOUT_MS .. " ms", 0)
    end
    if replyType == "fault" then
        error(corner .. " pod reported a fault clearing tilt", 0)
    end
    return { corner = corner, cleared = true }
end

function actuators.getPropellerStatus(corner)
    corner = normalizeCorner(corner)

    local seenAt = lastReceivedAt(corner)
    local sent, reason = banks.send(corner, "status_request")
    if not sent then
        error(reason, 0)
    end

    local pod = waitForReply(corner, seenAt)
    if not pod then
        error("no reply from the " .. corner .. " pod within "
            .. REPLY_TIMEOUT_MS .. " ms", 0)
    end

    return describe(corner, pod, nil)
end

return actuators
