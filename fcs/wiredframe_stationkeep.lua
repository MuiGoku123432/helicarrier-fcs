-- ComputerCraft resolves package paths relative to the running program's
-- directory. When invoked as /fcs/wiredframe_stationkeep.lua, an unadjusted
-- require("fcs.x") incorrectly becomes /fcs/fcs/x.lua. Add the parent of the
-- script directory so the existing fcs.* dependency tree resolves from root.
local source = debug.getinfo(1, "S").source
local scriptDirectory = source:match("^@(.+)/[^/]+$")
if scriptDirectory and package and type(package.path) == "string" then
    local moduleRoot = scriptDirectory:match("^(.*)/[^/]+$")
    if moduleRoot == nil then moduleRoot = "." end
    if moduleRoot == "" then moduleRoot = "/" end
    package.path = moduleRoot .. "/?.lua;" .. moduleRoot .. "/?/init.lua;"
        .. package.path
end

local stationkeep = require("fcs.stationkeep_control")
local protocol = require("fcs.wired_stationkeep_protocol")

local args = { ... }
local RESULT_PATH = "/fcs/wiredframe_stationkeep_result.txt"
local SEND_INTERVAL_SECONDS = 0.25
local PRECHECK_SECONDS = 2
local LIFT_TIMEOUT_SECONDS = 2
local BRAKE_MIN_SECONDS = 1
local BRAKE_TIMEOUT_SECONDS = 2.25
local SHUTDOWN_SECONDS = 3
local TELEMETRY_MAX_AGE_MS = 1250
local POD_MAX_AGE_MS = 1750
local LIFT_TRIGGER_RISE = 0.15
local LIFT_TRIGGER_SPEED = 0.35
local BRAKE_COMPLETE_SPEED = 0.12

-- Broad creative-world runtime envelope. These are genuine loss-of-control
-- stops, not proof-test pass/fail thresholds.
local MAX_RISE = 10
local MAX_FALL = 3
local MAX_VERTICAL_SPEED = 4
local MAX_HORIZONTAL_SPEED = 10
local MAX_TOTAL_SPEED = 12
local MAX_HULL_TILT = 12
local MAX_ANGULAR_SPEED = 1.5

local function finite(value)
    return type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
end

local function vector3(value)
    if type(value) ~= "table" then return nil end
    local x = tonumber(value.x or value[1])
    local y = tonumber(value.y or value[2])
    local z = tonumber(value.z or value[3])
    if not finite(x) or not finite(y) or not finite(z) then return nil end
    return { x = x, y = y, z = z }
end

local function quaternion(pose)
    if type(pose) ~= "table" then return nil end
    local candidate = pose.orientation or pose.rotation or pose.quaternion or pose
    if type(candidate) ~= "table" then return nil end
    local vector = candidate.v or candidate.vector or candidate
    local x = tonumber(vector.x or vector[1])
    local y = tonumber(vector.y or vector[2])
    local z = tonumber(vector.z or vector[3])
    local w = tonumber(candidate.a or candidate.w or candidate[4])
    if not finite(w) or not finite(x) or not finite(y) or not finite(z) then
        return nil
    end
    local length = math.sqrt(w * w + x * x + y * y + z * z)
    if length <= 1e-12 then return nil end
    return { w = w / length, x = x / length, y = y / length, z = z / length }
end

local function positionFromPose(pose)
    if type(pose) ~= "table" then return nil end
    for _, field in ipairs({ "position", "pos", "translation", "location" }) do
        local position = vector3(pose[field])
        if position then return position end
    end
    return nil
end

local function safeCall(api, method)
    local fn = api and api[method]
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn)
    if not ok then return nil end
    return value
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
    local linear = vector3(safeCall(api, "getLinearVelocity"))
    local angular = vector3(safeCall(api, "getAngularVelocity"))
    local position = positionFromPose(pose)
    if not position then
        for _, method in ipairs(POSITION_METHODS) do
            position = vector3(safeCall(api, method))
            if position then break end
        end
    end
    local finishedAt = os.epoch("utc")
    return {
        finishedAt = finishedAt,
        elapsedMs = finishedAt - startedAt,
        quaternion = quaternion(pose),
        position = position,
        linearVelocity = linear,
        angularVelocity = angular,
    }
end

local function sampleValid(sample)
    return type(sample) == "table"
        and finite(sample.finishedAt)
        and finite(sample.elapsedMs) and sample.elapsedMs <= TELEMETRY_MAX_AGE_MS
        and sample.quaternion and sample.position
        and sample.linearVelocity and sample.angularVelocity
end

local function hullTiltDegrees(q)
    -- Y component of the ship-local up vector rotated into world space.
    local upY = 1 - 2 * (q.x * q.x + q.z * q.z)
    upY = math.max(-1, math.min(1, upY))
    return math.deg(math.acos(upY))
end

local function metrics(sample, origin, target)
    local velocity = sample.linearVelocity
    local angular = sample.angularVelocity
    local horizontalSpeed = math.sqrt(velocity.x * velocity.x + velocity.z * velocity.z)
    local totalSpeed = math.sqrt(horizontalSpeed * horizontalSpeed + velocity.y * velocity.y)
    local angularSpeed = math.sqrt(angular.x * angular.x + angular.y * angular.y
        + angular.z * angular.z)
    return {
        rise = sample.position.y - origin.position.y,
        verticalVelocity = velocity.y,
        horizontalSpeed = horizontalSpeed,
        totalSpeed = totalSpeed,
        hullTilt = hullTiltDegrees(sample.quaternion),
        angularSpeed = angularSpeed,
        positionErrorX = target and sample.position.x - target.x or 0,
        positionErrorZ = target and sample.position.z - target.z or 0,
        altitudeError = target and sample.position.y - target.y or 0,
    }
end

local function violation(m)
    if m.rise > MAX_RISE then return "rise limit exceeded" end
    if m.rise < -MAX_FALL then return "fall limit exceeded" end
    if math.abs(m.verticalVelocity) > MAX_VERTICAL_SPEED then
        return "vertical speed limit exceeded"
    end
    if m.horizontalSpeed > MAX_HORIZONTAL_SPEED then
        return "horizontal speed limit exceeded"
    end
    if m.totalSpeed > MAX_TOTAL_SPEED then return "total speed limit exceeded" end
    if m.hullTilt > MAX_HULL_TILT then return "hull tilt limit exceeded" end
    if m.angularSpeed > MAX_ANGULAR_SPEED then return "angular speed limit exceeded" end
    return nil
end

local function allModems()
    local result = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            result[#result + 1] = { name = name, modem = peripheral.wrap(name) }
        end
    end
    return result
end

local function findWiredModem()
    for _, entry in ipairs(allModems()) do
        local ok, wireless = pcall(entry.modem.isWireless)
        if ok and wireless == false then return entry.modem, entry.name end
    end
    return nil, nil
end

local function closeChannels()
    for _, entry in ipairs(allModems()) do
        pcall(entry.modem.close, protocol.CONTROL_CHANNEL)
        pcall(entry.modem.close, protocol.STATUS_CHANNEL)
    end
end

local function rawSleep(seconds, doneEvent, onTerminate)
    local timer = os.startTimer(math.max(0, seconds or 0))
    while true do
        local event, value = os.pullEventRaw()
        if event == "terminate" then
            if onTerminate then onTerminate() end
            return false
        end
        if event == doneEvent then return false end
        if event == "timer" and value == timer then return true end
    end
end

if args[1] == "--self-test" then
    protocol.selfTest()
    local parsed = assert(quaternion({ orientation = { v = { 1, 2, 3 }, a = 4 } }))
    assert(math.abs(parsed.x - 1 / math.sqrt(30)) < 1e-9)
    assert(math.abs(parsed.w - 4 / math.sqrt(30)) < 1e-9)
    local controller = stationkeep.new()
    local output = controller.update({
        velocityX = 3,
        velocityZ = 0,
        positionErrorX = 0,
        positionErrorZ = 0,
        quaternion = { w = 1, x = 0, y = 0, z = 0 },
    }, 0.25)
    assert(output.valid and output.tiltDegrees > 0)
    print("wired stationkeep self-test: PASS")
    return
end

if args[1] ~= "--stationkeep" then
    error("use --stationkeep; this is the continuous direct-wired flight controller", 0)
end

print("DIRECT-WIRED STATIONKEEP")
print("Holds current X/Z and altitude until stopped.")
print("Bearing vector limit: 6 degrees; broad hull stop: 12 degrees.")
print("Stop the normal FCS first, then type STATIONKEEP to arm.")
write("> ")
if read() ~= "STATIONKEEP" then
    print("Not armed.")
    return
end

local modem, modemName = findWiredModem()
if not modem then error("wired modem unavailable", 0) end
local sublevel, sublevelSource = loadSublevel()
if not sublevel then error("CC:Sable sublevel API unavailable", 0) end
closeChannels()
modem.open(protocol.STATUS_CHANNEL)

local session = tostring(os.getComputerID()) .. "-stationkeep-" .. tostring(os.epoch("utc"))
local controller = stationkeep.new()
local active = true
local stopRequested = false
local abortReason
local runError
local shutdownError
local phase = "idle"
local phaseStartedAt = os.epoch("utc")
local sequence = 0
local finalSequence
local latestSample
local latestMetrics
local latestTelemetryAt
local origin
local target
local lastControllerAt
local statuses = {}
local statusAt = {}
local lastAppliedSequence = {}
local samples = 0
local framesSent = 0
local startedAt = os.epoch("utc")
local maxHorizontalSpeed = 0
local maxTiltCommand = 0
local maxPositionError = 0
local flightTrace = {}
local finalOutput = { tiltDegrees = 0, azimuthDegrees = 0 }
local CORNER_SET = { FL = true, FR = true, RL = true, RR = true }
local DONE_EVENT = "wired_stationkeep_done"

local function abort(reason)
    if not abortReason then
        abortReason = tostring(reason)
        print("ABORT: " .. abortReason)
    end
end

local function requestStop()
    if not stopRequested then print("Operator stop requested; shutting down.") end
    stopRequested = true
end

local function transmit(kind, actuation)
    sequence = sequence + 1
    local now = os.epoch("utc")
    modem.transmit(protocol.CONTROL_CHANNEL, protocol.STATUS_CHANNEL,
        protocol.frame(session, sequence, now, kind, actuation))
    framesSent = framesSent + 1
    return sequence
end

local function statusSequence(status)
    return tonumber(status and (status.appliedSequence or status.lastAppliedSequence))
end

local function recordStatus(status)
    local corner = status.corner
    local appliedSequence = statusSequence(status)
    if appliedSequence and lastAppliedSequence[corner]
        and appliedSequence < lastAppliedSequence[corner] then
        abort("pod " .. corner .. " applied sequence regressed")
        return
    end
    if appliedSequence then lastAppliedSequence[corner] = appliedSequence end
    statuses[corner] = status
    statusAt[corner] = os.epoch("utc")
    if phase ~= "shutdown" and not protocol.cleanStatus(status) then
        abort("pod " .. corner .. " reported transport/apply faults")
    end
    if phase ~= "shutdown" and ((tonumber(status.fallbackCount) or 0) > 0
        or (tonumber(status.fallbackStops) or 0) > 0) then
        abort("pod " .. corner .. " entered stale fallback")
    end
end

local function podsFresh(expected, expectedSequence)
    local now = os.epoch("utc")
    for _, corner in ipairs(protocol.CORNERS) do
        local status = statuses[corner]
        if not status or not statusAt[corner] or now - statusAt[corner] > POD_MAX_AGE_MS then
            return false, corner
        end
        if not protocol.cleanStatus(status) then return false, corner end
        if expected and not protocol.applied(status, expected, expectedSequence) then
            return false, corner
        end
    end
    return true
end

local function receiveLoop()
    while active do
        local event, _, channel, _, message = os.pullEventRaw()
        if event == "terminate" then requestStop() end
        if event == DONE_EVENT then return end
        if event == "modem_message" and channel == protocol.STATUS_CHANNEL
            and type(message) == "table"
            and message.protocol == protocol.PROTOCOL
            and message.session == session
            and CORNER_SET[message.corner] then
            recordStatus(message)
        end
    end
end

local function telemetryLoop()
    while active do
        if phase ~= "shutdown" then
            local sample = readSample(sublevel)
            if sampleValid(sample) then
                latestSample = sample
                latestTelemetryAt = sample.finishedAt
                origin = origin or sample
                latestMetrics = metrics(sample, origin, target)
                samples = samples + 1
                maxHorizontalSpeed = math.max(maxHorizontalSpeed,
                    latestMetrics.horizontalSpeed)
                local positionError = math.sqrt(latestMetrics.positionErrorX ^ 2
                    + latestMetrics.positionErrorZ ^ 2)
                maxPositionError = math.max(maxPositionError, positionError)
                local problem = phase ~= "idle" and violation(latestMetrics) or nil
                if problem then abort(problem) end
            end

            if phase ~= "idle" and os.epoch("utc") - phaseStartedAt > POD_MAX_AGE_MS then
                local fresh, corner = podsFresh()
                if not fresh then abort("pod " .. tostring(corner) .. " status stale") end
            end
        end
        rawSleep(0.05, DONE_EVENT, requestStop)
    end
end

local function runTimed(seconds, kind, actuation, stopPredicate)
    phase = kind
    phaseStartedAt = os.epoch("utc")
    local stopAt = phaseStartedAt + math.floor(seconds * 1000)
    while os.epoch("utc") < stopAt do
        if stopRequested or abortReason then return false end
        transmit(kind, actuation)
        if stopPredicate and stopPredicate() then return true end
        if not rawSleep(SEND_INTERVAL_SECONDS, DONE_EVENT, requestStop) then return false end
    end
    return stopPredicate == nil
end

local function waitForTelemetry()
    local stopAt = os.epoch("utc") + 4000
    while not latestSample and os.epoch("utc") < stopAt do
        if stopRequested or abortReason then return false end
        rawSleep(0.05, DONE_EVENT, requestStop)
    end
    return latestSample ~= nil
end

local function shutdownBurst()
    phase = "shutdown"
    phaseStartedAt = os.epoch("utc")
    controller.reset()
    local stopAt = os.epoch("utc") + SHUTDOWN_SECONDS * 1000
    while os.epoch("utc") < stopAt do
        finalSequence = transmit("shutdown")
        rawSleep(0.1, DONE_EVENT, requestStop)
    end
    rawSleep(1, DONE_EVENT, requestStop)
    local expected = protocol.command("shutdown")
    local ready, corner = podsFresh(expected, finalSequence)
    if not ready then
        shutdownError = "fresh exact-zero shutdown not confirmed for " .. tostring(corner)
    end
end

local function senderLoop()
    if not waitForTelemetry() then
        runError = abortReason or "initial telemetry unavailable"
    end

    if not runError then
        print("Precheck: direct stationkeep session, RPM64, zero ion/tilt.")
        runTimed(PRECHECK_SECONDS, "precheck", { tiltDegrees = 0, azimuthDegrees = 0 })
        local ready, corner = podsFresh(protocol.command("precheck"))
        if not ready then runError = "precheck not acknowledged by " .. tostring(corner) end
    end

    if not runError and not stopRequested and not abortReason then
        print("Lifting into stationkeeping authority.")
        local lifted = runTimed(LIFT_TIMEOUT_SECONDS, "high",
            { tiltDegrees = 0, azimuthDegrees = 0 }, function()
                return latestMetrics and (latestMetrics.rise >= LIFT_TRIGGER_RISE
                    or latestMetrics.verticalVelocity >= LIFT_TRIGGER_SPEED)
            end)
        if not lifted then runError = abortReason or "lift trigger not observed" end
    end

    if not runError and not stopRequested and not abortReason then
        print("Braking vertical motion.")
        local brakeStartedAt = os.epoch("utc")
        local braked = runTimed(BRAKE_TIMEOUT_SECONDS, "low",
            { tiltDegrees = 0, azimuthDegrees = 0 }, function()
                return latestMetrics
                    and os.epoch("utc") - brakeStartedAt >= BRAKE_MIN_SECONDS * 1000
                    and latestMetrics.verticalVelocity <= BRAKE_COMPLETE_SPEED
            end)
        if not braked then runError = abortReason or "vertical brake did not settle" end
    end

    if not runError and not stopRequested and not abortReason then
        target = {
            x = latestSample.position.x,
            y = latestSample.position.y,
            z = latestSample.position.z,
        }
        controller.reset()
        phase = "stationkeep"
        phaseStartedAt = os.epoch("utc")
        lastControllerAt = phaseStartedAt
        local slot = 0
        local nextPrintAt = phaseStartedAt
        print(string.format("STATIONKEEP ACTIVE at x=%.2f y=%.2f z=%.2f",
            target.x, target.y, target.z))
        print("Press Ctrl+T to stop and command exact-zero shutdown.")

        while not stopRequested and not abortReason do
            local now = os.epoch("utc")
            if not latestSample or not latestTelemetryAt
                or now - latestTelemetryAt > TELEMETRY_MAX_AGE_MS then
                abort("controller telemetry stale")
                break
            end

            slot = slot + 1
            local dt = (now - lastControllerAt) / 1000
            lastControllerAt = now
            finalOutput = controller.update({
                velocityX = latestSample.linearVelocity.x,
                velocityZ = latestSample.linearVelocity.z,
                positionErrorX = latestSample.position.x - target.x,
                positionErrorZ = latestSample.position.z - target.z,
                quaternion = latestSample.quaternion,
            }, dt)
            if not finalOutput.valid then
                abort("stationkeeping controller input invalid")
                break
            end
            maxTiltCommand = math.max(maxTiltCommand, finalOutput.tiltDegrees)
            local verticalKind, verticalReason = controller.vertical({
                rise = latestMetrics.rise,
                verticalVelocity = latestMetrics.verticalVelocity,
                altitudeError = latestSample.position.y - target.y,
            }, slot)
            transmit(verticalKind, finalOutput)

            if now >= nextPrintAt then
                local errorX = latestSample.position.x - target.x
                local errorZ = latestSample.position.z - target.z
                local velocityX = latestSample.linearVelocity.x
                local velocityZ = latestSample.linearVelocity.z
                local traceEntry = string.format(
                    "t=%.1f,ex=%+.2f,ez=%+.2f,vx=%+.2f,vz=%+.2f,tilt=%.2f,az=%.0f",
                    (now - phaseStartedAt) / 1000,
                    errorX, errorZ, velocityX, velocityZ,
                    finalOutput.tiltDegrees, finalOutput.azimuthDegrees)
                flightTrace[#flightTrace + 1] = traceEntry
                print(string.format(
                    "hold ex=%+.2f ez=%+.2f vx=%+.2f vz=%+.2f speed=%.2f vy=%+.2f tilt=%.2f az=%.0f vertical=%s/%s",
                    errorX, errorZ, velocityX, velocityZ,
                    latestMetrics.horizontalSpeed, latestMetrics.verticalVelocity,
                    finalOutput.tiltDegrees, finalOutput.azimuthDegrees,
                    verticalKind, verticalReason))
                nextPrintAt = now + 5000
            end
            rawSleep(SEND_INTERVAL_SECONDS, DONE_EVENT, requestStop)
        end
    end

    if runError then print("RUN ERROR: " .. tostring(runError)) end
    shutdownBurst()
    active = false
    os.queueEvent(DONE_EVENT)
end

local ok, err = pcall(parallel.waitForAll, senderLoop, receiveLoop, telemetryLoop)
if not ok then
    runError = runError or tostring(err)
    pcall(function()
        local stopAt = os.epoch("utc") + 2000
        while os.epoch("utc") < stopAt do
            transmit("shutdown")
            sleep(0.1)
        end
    end)
end

local endedAt = os.epoch("utc")
local overall = not runError and not abortReason and not shutdownError
local lines = {
    "WIRED STATIONKEEP RESULT",
    "session=" .. session,
    "termination=" .. (stopRequested and "operator" or (abortReason and "abort" or "complete")),
    "trace_count=" .. tostring(#flightTrace),
    "trace=" .. table.concat(flightTrace, ";"),
    "overall=" .. (overall and "PASS" or "FAIL"),
    "run_error=" .. tostring(runError),
    "abort_reason=" .. tostring(abortReason),
    "shutdown_error=" .. tostring(shutdownError),
    "duration_seconds=" .. string.format("%.3f", (endedAt - startedAt) / 1000),
    "frames_sent=" .. tostring(framesSent),
    "samples=" .. tostring(samples),
    "max_horizontal_speed=" .. string.format("%.6f", maxHorizontalSpeed),
    "max_position_error=" .. string.format("%.6f", maxPositionError),
    "max_tilt_command=" .. string.format("%.6f", maxTiltCommand),
    "final_sequence=" .. tostring(finalSequence),
    "modem=" .. tostring(modemName),
    "sublevel=" .. tostring(sublevelSource),
}
for _, corner in ipairs(protocol.CORNERS) do
    local status = statuses[corner]
    lines[#lines + 1] = string.format(
        "%s applied=%s missing=%s duplicate=%s order=%s invalid=%s expired=%s errors=%s fallback=%s stops=%s",
        corner, tostring(statusSequence(status)), tostring(status and status.missing),
        tostring(status and status.duplicates), tostring(status and status.outOfOrder),
        tostring(status and status.invalid), tostring(status and status.expiredBeforeApply),
        tostring(status and status.applyErrors), tostring(status and status.fallbackCount),
        tostring(status and status.fallbackStops))
end

local file = fs.open(RESULT_PATH, "w")
if file then
    for _, line in ipairs(lines) do file.writeLine(line) end
    file.close()
end
for _, line in ipairs(lines) do print(line) end
print("Saved to " .. RESULT_PATH)
closeChannels()
