-- Ion lift profile: step the ion banks through their hardware levels and
-- measure what each one is worth.
--
--     /fcs/wiredframe_ion_lift_profile.lua --ion-lift-profile
--     /fcs/wiredframe_ion_lift_profile.lua --self-test
--
-- WHY THIS EXISTS
--
-- Everything known about ion thrust so far is inferred from three points: the
-- reported quanta in fcs/ionsweep.lua, one neutral-hover run at level 2/15, and
-- the drift-test climb at 3/15. The intended architecture is ions carrying lift
-- while the props are left free for stabilisation and movement, and that needs
-- the whole curve, not three points.
--
-- WHAT IT DOES
--
-- Steps the ion command up one hardware level at a time, holding each for a
-- configurable dwell, then steps back down the same way. Tilt and azimuth are
-- exactly zero throughout and the props sit at a fixed RPM. There is no drift
-- logic, no position loop, and no vertical feedback: the point is to measure
-- the plant, so nothing may quietly correct it.
--
-- HOW THRUST-TO-WEIGHT IS OBTAINED
--
-- The pods report applied commands and transport counters, not thrust, so T/W
-- has to come from motion. Immediately after a step, before speed builds and
-- drag matters, vertical acceleration is very nearly (T - W)/m, so
--
--     T/W = 1 + a / g
--
-- The harness samples acceleration in a short window right after each step for
-- exactly that reason, and separately records the terminal climb rate at the
-- end of the dwell, where drag has balanced the excess thrust.
--
-- IMPORTANT: absolute T/W depends on the configured gravity below, which is an
-- estimate. The level at which acceleration crosses ZERO does not depend on it
-- at all -- that crossing is the hover level, it falls straight out of the
-- measured accelerations, and it is the number this test exists to find. Treat
-- `hover_level` as the result and the T/W column as indicative.

local source = debug.getinfo(1, "S").source
local scriptDirectory = source:match("^@(.+)/[^/]+$")
if scriptDirectory and package and type(package.path) == "string" then
    local moduleRoot = scriptDirectory:match("^(.*)/[^/]+$")
    if moduleRoot == nil then moduleRoot = "." end
    if moduleRoot == "" then moduleRoot = "/" end
    package.path = moduleRoot .. "/?.lua;" .. moduleRoot .. "/?/init.lua;"
        .. package.path
end

local args = { ... }

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

local DWELL_SECONDS = 30          -- hold at each level
local STEP_SETTLE_SECONDS = 1.0   -- ignored after a step before measuring accel
local STEP_MEASURE_SECONDS = 3.0  -- acceleration window used for the T/W estimate
local START_LEVEL = 1
local MAX_LEVEL = 15
-- NOT a free parameter. The pod mailbox validator hardcodes `command.propRpm
-- == 64` for both stationkeep and response_map_test modes, so any other value
-- is rejected at every pod and the run dies on invalid-frame counters. Changing
-- it means redeploying pod-template/pod/control_mailbox.lua to pods 2-5.
local PROP_RPM = 64
local FALLBACK_ION_POWER = 0.07
local FALLBACK_STOP_AFTER_MS = 5000

-- Ends the ascent early and begins the descent. At the upper levels the craft
-- accelerates hard: a full dwell at 15/15 would leave the world long before 30
-- seconds elapsed, so the sweep is altitude-bounded, not level-bounded.
local CEILING_BLOCKS = 220
-- Stops the descent stepping any lower. Below this the harness holds its
-- current level and waits for the operator rather than walking the craft into
-- the ground.
local FLOOR_BLOCKS = 8

-- Only for the indicative T/W column. Estimated from drift-test run 6, where
-- level 3/15 (about 1.19 of weight) produced roughly 0.83 blocks/s^2 early in
-- the climb. The hover-level result does not depend on this value.
local GRAVITY_BLOCKS_PER_SECOND2 = 4.4

local RESULT_PATH = "/fcs/wiredframe_ion_lift_profile_result.txt"
local CONFIRMATION = "ION-LIFT"

-- Transport
local CONTROL_CHANNEL, STATUS_CHANNEL = 42042, 42043
local PROTOCOL = "helicarrier.control-frame.v1"
local MODE = "response_map_test"
local CORNERS = { "FL", "FR", "RL", "RR" }
local CORNER_SET = { FL = true, FR = true, RL = true, RR = true }
local SEND_INTERVAL_SECONDS = 0.25
local VALID_FOR_MS, SHUTDOWN_VALID_FOR_MS = 750, 5000
local PRECHECK_SECONDS, SHUTDOWN_SECONDS = 5, 3
local TELEMETRY_MAX_AGE_MS = 1250
local POD_MAX_AGE_MS = 1750

-- Loss-of-control stops. Vertical speed is deliberately NOT bounded: large
-- vertical speed is the measurement. Attitude and lateral motion are bounded,
-- because at zero commanded tilt any of either means something is wrong.
local MAX_HULL_TILT = 12
local MAX_ANGULAR_SPEED = 1.5
local MAX_HORIZONTAL_SPEED = 8
local MAX_FALL_BELOW_START = 5

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

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

local function hullTiltDegrees(q)
    local upY = 1 - 2 * (q.x * q.x + q.z * q.z)
    upY = math.max(-1, math.min(1, upY))
    return math.deg(math.acos(upY))
end

-- The driver quantises to fifteenths as applied = floor(commanded * 15) / 15.
-- Commanding the bare fraction sits exactly on a boundary where float error can
-- fall to the level below, so aim a little inside each band. Level 15 is the
-- top of the range and 1.0 is already exact there.
local function powerForLevel(level)
    if level >= 15 then return 1.0 end
    return level / 15 + 0.005
end

local function quantisedLevel(power)
    return math.floor(power * 15)
end

local function thrustToWeight(acceleration)
    if not finite(acceleration) then return nil end
    return 1 + acceleration / GRAVITY_BLOCKS_PER_SECOND2
end

local function command(level)
    if level == nil then
        return {
            ionPower = 0, fallbackIonPower = 0, propRpm = 0,
            tiltDegrees = 0, azimuthDegrees = 0, shutdown = true,
        }
    end
    return {
        ionPower = level == 0 and 0 or powerForLevel(level),
        fallbackIonPower = level == 0 and 0 or FALLBACK_ION_POWER,
        fallbackStopAfterMs = FALLBACK_STOP_AFTER_MS,
        propRpm = PROP_RPM,
        tiltDegrees = 0, azimuthDegrees = 0, shutdown = false,
    }
end

local function frame(session, sequence, sentAt, level)
    local commands = {}
    for _, corner in ipairs(CORNERS) do commands[corner] = command(level) end
    return {
        protocol = PROTOCOL, kind = "control_frame", mode = MODE, armed = true,
        session = session, sequence = sequence, sentAt = sentAt,
        validForMs = level == nil and SHUTDOWN_VALID_FOR_MS or VALID_FOR_MS,
        corners = commands,
    }
end

local function countersClean(status)
    if type(status) ~= "table" then return false end
    for _, field in ipairs({
        "missing", "duplicates", "outOfOrder", "invalid",
        "expiredBeforeApply", "applyErrors",
    }) do
        if (tonumber(status[field]) or 0) ~= 0 then return false end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Self-test: no CC APIs, no modem, no actuation
-- ---------------------------------------------------------------------------

if args[1] == "--self-test" then
    for level = 1, 15 do
        assert(quantisedLevel(powerForLevel(level)) == level,
            "level " .. level .. " must quantise to itself")
        assert(powerForLevel(level) <= 1, "command must stay inside 0..1")
    end
    assert(command(0).ionPower == 0)
    assert(command(0).propRpm == PROP_RPM, "props run even at ion level 0")
    assert(quantisedLevel(command(3).ionPower) == 3)

    local stop = frame("self", 1, 1000, nil)
    assert(stop.corners.FL.shutdown == true)
    assert(stop.corners.FL.ionPower == 0 and stop.corners.FL.propRpm == 0)
    assert(stop.validForMs == SHUTDOWN_VALID_FOR_MS)

    local live = frame("self", 2, 1001, 7)
    assert(live.protocol == PROTOCOL and live.mode == MODE and live.armed == true)
    for _, corner in ipairs(CORNERS) do
        assert(quantisedLevel(live.corners[corner].ionPower) == 7)
        assert(live.corners[corner].tiltDegrees == 0)
        assert(live.corners[corner].azimuthDegrees == 0)
        assert(live.corners[corner].propRpm == PROP_RPM)
    end

    -- T/W is anchored so that zero acceleration is hover, whatever gravity is.
    assert(math.abs(thrustToWeight(0) - 1) < 1e-12,
        "zero acceleration must read as exactly hover")
    assert(thrustToWeight(1) > 1 and thrustToWeight(-1) < 1)

    assert(countersClean({ missing = 0, duplicates = 0, outOfOrder = 0,
        invalid = 0, expiredBeforeApply = 0, applyErrors = 0 }))
    assert(not countersClean({ missing = 1 }))

    assert(PROP_RPM == 64,
        "the pod mailbox validator only accepts propRpm == 64; see the note "
            .. "above PROP_RPM before changing this")
    assert(START_LEVEL >= 1 and MAX_LEVEL <= 15 and START_LEVEL <= MAX_LEVEL)
    assert(FLOOR_BLOCKS < CEILING_BLOCKS)
    assert(STEP_SETTLE_SECONDS + STEP_MEASURE_SECONDS < DWELL_SECONDS,
        "the acceleration window must fit inside a dwell")

    print("ion lift profile self-test: PASS")
    return
end

if args[1] ~= "--ion-lift-profile" then
    error("use --ion-lift-profile; this steps the ion banks and measures lift", 0)
end

-- ---------------------------------------------------------------------------
-- Live run
-- ---------------------------------------------------------------------------

local function safeCall(api, method)
    local fn = api and api[method]
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn)
    if not ok then return nil end
    return value
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
        pcall(entry.modem.close, CONTROL_CHANNEL)
        pcall(entry.modem.close, STATUS_CHANNEL)
    end
end

local function loadSublevel()
    if type(_G.sublevel) == "table" then return _G.sublevel, "global" end
    if type(require) == "function" then
        local ok, api = pcall(require, "sublevel")
        if ok and type(api) == "table" then return api, "require" end
    end
    return nil, "unavailable"
end

print("ION LIFT PROFILE")
print(string.format("Steps ion levels %d..%d, %ds each, then back down.",
    START_LEVEL, MAX_LEVEL, DWELL_SECONDS))
print(string.format("Props fixed at %d RPM. Tilt and azimuth are exactly zero.", PROP_RPM))
print("No drift logic and no vertical feedback: the craft is NOT held.")
print(string.format("Ascent stops at +%d blocks; descent stops stepping at +%d.",
    CEILING_BLOCKS, FLOOR_BLOCKS))
print("Ctrl+T stops and commands exact-zero shutdown. Clear the area first.")
print("Type " .. CONFIRMATION .. " to arm.")
write("> ")
if read() ~= CONFIRMATION then
    print("Not armed.")
    return
end

local modem, modemName = findWiredModem()
if not modem then error("wired modem unavailable", 0) end
local sublevel, sublevelSource = loadSublevel()
if not sublevel then error("CC:Sable sublevel API unavailable", 0) end
closeChannels()
modem.open(STATUS_CHANNEL)

local session = tostring(os.getComputerID()) .. "-ionlift-" .. tostring(os.epoch("utc"))
local active = true
local stopRequested, abortReason, runError, shutdownError
local phase = "idle"
local sequence, framesSent, samples = 0, 0, 0
local finalSequence
local latestSample, latestTelemetryAt, origin
local statuses, statusAt = {}, {}
local startedAt = os.epoch("utc")
local records = {}
local currentLevel
local ceilingReached = false
local DONE_EVENT = "ion_lift_done"

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

local function rise()
    if not latestSample or not origin then return 0 end
    return latestSample.position.y - origin.position.y
end

local function verticalVelocity()
    if not latestSample then return 0 end
    return latestSample.linearVelocity.y
end

local function transmit(level)
    sequence = sequence + 1
    modem.transmit(CONTROL_CHANNEL, STATUS_CHANNEL,
        frame(session, sequence, os.epoch("utc"), level))
    framesSent = framesSent + 1
    return sequence
end

local function recordStatus(status)
    statuses[status.corner] = status
    statusAt[status.corner] = os.epoch("utc")
    if phase ~= "shutdown" and not countersClean(status) then
        abort("pod " .. status.corner .. " reported transport/apply faults")
    end
    if phase ~= "shutdown" and ((tonumber(status.fallbackCount) or 0) > 0
        or (tonumber(status.fallbackStops) or 0) > 0) then
        abort("pod " .. status.corner .. " entered stale fallback")
    end
end

local function podsFresh(expectedLevel)
    local now = os.epoch("utc")
    for _, corner in ipairs(CORNERS) do
        local status = statuses[corner]
        if not status or not statusAt[corner]
            or now - statusAt[corner] > POD_MAX_AGE_MS then
            return false, corner
        end
        if not countersClean(status) then return false, corner end
        if expectedLevel and status.appliedIonPower
            and quantisedLevel(status.appliedIonPower) ~= expectedLevel then
            return false, corner
        end
    end
    return true
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

local function receiveLoop()
    while active do
        local event, _, channel, _, message = os.pullEventRaw()
        if event == "terminate" then requestStop() end
        if event == DONE_EVENT then return end
        if event == "modem_message" and channel == STATUS_CHANNEL
            and type(message) == "table" and message.protocol == PROTOCOL
            and message.session == session and CORNER_SET[message.corner] then
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
                samples = samples + 1
                local q = sample.quaternion
                local v = sample.linearVelocity
                local a = sample.angularVelocity
                local horizontal = math.sqrt(v.x * v.x + v.z * v.z)
                local angular = math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
                if phase ~= "idle" then
                    if hullTiltDegrees(q) > MAX_HULL_TILT then
                        abort("hull tilt limit exceeded")
                    elseif angular > MAX_ANGULAR_SPEED then
                        abort("angular speed limit exceeded")
                    elseif horizontal > MAX_HORIZONTAL_SPEED then
                        abort("horizontal speed limit exceeded")
                    elseif rise() < -MAX_FALL_BELOW_START then
                        abort("fell below the start altitude")
                    end
                end
            end
        end
        rawSleep(0.05, DONE_EVENT, requestStop)
    end
end

-- Holds one level for `seconds`, sending continuously. Returns a record of what
-- the craft did. Acceleration is sampled in a window just after the step, where
-- it is closest to (T - W)/m; the terminal climb rate is taken at the end of the
-- dwell, where drag has caught up.
local function holdLevel(level, seconds, direction)
    phase = "level"
    currentLevel = level
    local beganAt = os.epoch("utc")
    local stopAt = beganAt + math.floor(seconds * 1000)
    local measureFrom = beganAt + math.floor(STEP_SETTLE_SECONDS * 1000)
    local measureTo = measureFrom + math.floor(STEP_MEASURE_SECONDS * 1000)

    local riseAtStart, velocityAtStart = rise(), verticalVelocity()
    local velocityAtMeasureStart, velocityAtMeasureEnd
    local measuredFrom, measuredTo
    local peakVelocity, minVelocity = velocityAtStart, velocityAtStart

    while os.epoch("utc") < stopAt do
        if stopRequested or abortReason then break end
        transmit(level)

        local now = os.epoch("utc")
        local vy = verticalVelocity()
        if vy > peakVelocity then peakVelocity = vy end
        if vy < minVelocity then minVelocity = vy end
        if velocityAtMeasureStart == nil and now >= measureFrom then
            velocityAtMeasureStart, measuredFrom = vy, now
        end
        if velocityAtMeasureStart ~= nil and now <= measureTo then
            velocityAtMeasureEnd, measuredTo = vy, now
        end

        if not latestTelemetryAt
            or now - latestTelemetryAt > TELEMETRY_MAX_AGE_MS then
            abort("telemetry stale")
            break
        end
        if now - beganAt > POD_MAX_AGE_MS then
            local fresh, corner = podsFresh(level)
            if not fresh then
                abort("pod " .. tostring(corner) .. " status stale or off-level")
                break
            end
        end
        if direction == "up" and rise() >= CEILING_BLOCKS then
            ceilingReached = true
            break
        end
        if not rawSleep(SEND_INTERVAL_SECONDS, DONE_EVENT, requestStop) then break end
    end

    local acceleration
    if velocityAtMeasureStart and velocityAtMeasureEnd and measuredTo
        and measuredFrom and measuredTo > measuredFrom then
        acceleration = (velocityAtMeasureEnd - velocityAtMeasureStart)
            / ((measuredTo - measuredFrom) / 1000)
    end

    local record = {
        level = level,
        direction = direction,
        commandedPower = level == 0 and 0 or powerForLevel(level),
        heldSeconds = (os.epoch("utc") - beganAt) / 1000,
        riseStart = riseAtStart,
        riseEnd = rise(),
        velocityStart = velocityAtStart,
        velocityEnd = verticalVelocity(),
        peakVelocity = peakVelocity,
        minVelocity = minVelocity,
        acceleration = acceleration,
        thrustToWeight = thrustToWeight(acceleration),
    }
    records[#records + 1] = record

    print(string.format(
        "%s level %2d/15 (ion %.3f)  rise %+8.2f -> %+8.2f  vy %+6.2f -> %+6.2f  a=%s  T/W=%s",
        direction == "up" and "UP  " or "DOWN", level, record.commandedPower,
        record.riseStart, record.riseEnd, record.velocityStart, record.velocityEnd,
        acceleration and string.format("%+.3f", acceleration) or "n/a",
        record.thrustToWeight and string.format("%.3f", record.thrustToWeight) or "n/a"))
    return record
end

local function shutdownBurst()
    phase = "shutdown"
    local stopAt = os.epoch("utc") + SHUTDOWN_SECONDS * 1000
    while os.epoch("utc") < stopAt do
        finalSequence = transmit(nil)
        rawSleep(0.1, DONE_EVENT, requestStop)
    end
    rawSleep(1, DONE_EVENT, requestStop)
    local ready, corner = podsFresh()
    if not ready then
        shutdownError = "shutdown not confirmed for " .. tostring(corner)
    end
end

local function waitForTelemetry()
    local stopAt = os.epoch("utc") + 4000
    while not latestSample and os.epoch("utc") < stopAt do
        if stopRequested or abortReason then return false end
        rawSleep(0.05, DONE_EVENT, requestStop)
    end
    return latestSample ~= nil
end

local function senderLoop()
    if not waitForTelemetry() then
        runError = abortReason or "initial telemetry unavailable"
    end

    if not runError then
        print("Precheck: zero ion, props only.")
        phase = "precheck"
        local until_ = os.epoch("utc") + PRECHECK_SECONDS * 1000
        while os.epoch("utc") < until_ and not stopRequested and not abortReason do
            transmit(0)
            rawSleep(SEND_INTERVAL_SECONDS, DONE_EVENT, requestStop)
        end
        local ready, corner = podsFresh(0)
        if not ready then
            runError = "precheck not acknowledged by " .. tostring(corner)
        end
    end

    -- Ascend.
    local topLevel = START_LEVEL
    if not runError then
        for level = START_LEVEL, MAX_LEVEL do
            if stopRequested or abortReason then break end
            topLevel = level
            holdLevel(level, DWELL_SECONDS, "up")
            if ceilingReached then
                print(string.format(
                    "Ceiling +%d blocks reached at level %d/15; descending.",
                    CEILING_BLOCKS, level))
                break
            end
        end
    end

    -- Descend back down the same ladder.
    if not runError then
        for level = topLevel - 1, 0, -1 do
            if stopRequested or abortReason then break end
            if rise() <= FLOOR_BLOCKS then
                print(string.format(
                    "Floor +%d blocks reached at level %d/15; holding.",
                    FLOOR_BLOCKS, level + 1))
                break
            end
            holdLevel(level, DWELL_SECONDS, "down")
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
            transmit(nil)
            sleep(0.1)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Result
-- ---------------------------------------------------------------------------

local endedAt = os.epoch("utc")

-- The hover level is where acceleration crosses zero. It is interpolated from
-- the two ascent levels that bracket the crossing, and unlike the T/W column it
-- does not depend on the configured gravity.
local hoverLevel
do
    local previous
    for _, record in ipairs(records) do
        if record.direction == "up" and record.acceleration then
            if previous and previous.acceleration < 0 and record.acceleration >= 0 then
                local span = record.acceleration - previous.acceleration
                if span > 0 then
                    hoverLevel = previous.level
                        + (0 - previous.acceleration) / span
                            * (record.level - previous.level)
                end
                break
            end
            previous = record
        end
    end
end

local overall = not runError and not abortReason and not shutdownError
local lines = {
    "WIRED ION LIFT PROFILE RESULT",
    "session=" .. session,
    "overall=" .. (overall and "PASS" or "FAIL"),
    "termination=" .. (stopRequested and "operator"
        or (abortReason and "abort" or "complete")),
    "run_error=" .. tostring(runError),
    "abort_reason=" .. tostring(abortReason),
    "shutdown_error=" .. tostring(shutdownError),
    "duration_seconds=" .. string.format("%.3f", (endedAt - startedAt) / 1000),
    "dwell_seconds=" .. tostring(DWELL_SECONDS),
    "step_measure_seconds=" .. tostring(STEP_MEASURE_SECONDS),
    "prop_rpm=" .. tostring(PROP_RPM),
    "start_level=" .. tostring(START_LEVEL),
    "max_level=" .. tostring(MAX_LEVEL),
    "ceiling_blocks=" .. tostring(CEILING_BLOCKS),
    "ceiling_reached=" .. tostring(ceilingReached),
    "gravity_blocks_per_second2=" .. string.format("%.3f", GRAVITY_BLOCKS_PER_SECOND2),
    "hover_level=" .. (hoverLevel and string.format("%.3f", hoverLevel) or "not_bracketed"),
    "levels_recorded=" .. tostring(#records),
    "frames_sent=" .. tostring(framesSent),
    "samples=" .. tostring(samples),
    "final_sequence=" .. tostring(finalSequence),
    "modem=" .. tostring(modemName),
    "sublevel=" .. tostring(sublevelSource),
    "",
    "# direction level ion_command held_s rise_start rise_end vy_start vy_end peak_vy accel thrust_to_weight",
}

for _, record in ipairs(records) do
    lines[#lines + 1] = string.format(
        "level %s %d %.4f %.2f %.4f %.4f %.4f %.4f %.4f %s %s",
        record.direction, record.level, record.commandedPower, record.heldSeconds,
        record.riseStart, record.riseEnd, record.velocityStart, record.velocityEnd,
        record.peakVelocity,
        record.acceleration and string.format("%.6f", record.acceleration) or "nil",
        record.thrustToWeight and string.format("%.6f", record.thrustToWeight) or "nil")
end

lines[#lines + 1] = ""
for _, corner in ipairs(CORNERS) do
    local status = statuses[corner]
    lines[#lines + 1] = string.format(
        "%s applied=%s ion=%s rpm=%s missing=%s duplicate=%s order=%s invalid=%s expired=%s errors=%s fallback=%s stops=%s",
        corner, tostring(status and status.appliedSequence),
        tostring(status and status.appliedIonPower),
        tostring(status and status.appliedPropRpm),
        tostring(status and status.missing), tostring(status and status.duplicates),
        tostring(status and status.outOfOrder), tostring(status and status.invalid),
        tostring(status and status.expiredBeforeApply),
        tostring(status and status.applyErrors),
        tostring(status and status.fallbackCount),
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
