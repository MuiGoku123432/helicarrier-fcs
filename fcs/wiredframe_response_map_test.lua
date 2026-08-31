-- Direct-wired response-map harness.
--
-- First gate (the only live mode currently enabled):
--     /fcs/wiredframe_response_map_test.lua --ground-check
--
-- This spins all pod propellers at the flight baseline while ions and bearing
-- tilt remain exactly zero, verifies physical readback, then explicitly stops
-- everything and verifies the local stale-link fallback. Flight pulses remain
-- locked until this gate has produced a clean live report.

local args = { ... }
local CONTROL_CHANNEL = 42042
local STATUS_CHANNEL = 42043
local PROTOCOL = "helicarrier.control-frame.v1"
local MODE = "response_map_test"
local CORNERS = { "FL", "FR", "RL", "RR" }
local RESULT_PATH = "/fcs/wiredframe_response_map_result.txt"
local RATE_HZ = 10
local VALID_FOR_MS = 750
local SPIN_SECONDS = 30
local SHUTDOWN_SECONDS = 5
local RESPONSE_PROP_RPM = 64

local function finiteNumber(value)
    return type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
end

local function vectorComponents(value)
    if type(value) ~= "table" then return nil end
    local x = value[1]
    if x == nil then x = value.x end
    local y = value[2]
    if y == nil then y = value.y end
    local z = value[3]
    if z == nil then z = value.z end
    if not finiteNumber(x) or not finiteNumber(y) or not finiteNumber(z) then return nil end
    return x, y, z
end

local ZERO_TILT_VECTOR_TOLERANCE = 0.005

local function verticalThrustVector(value)
    local x, y, z = vectorComponents(value)
    if not x then return false end
    local horizontal = math.sqrt((x * x) + (z * z))
    return horizontal <= ZERO_TILT_VECTOR_TOLERANCE
        and math.abs(math.abs(y) - 1) <= ZERO_TILT_VECTOR_TOLERANCE
end

-- Prints nil rather than 0 for an absent field: an absent stat means the pod
-- is running older code, and that must not look like a fast stage.
local function fmt(value)
    if type(value) ~= "number" then return "nil" end
    return string.format("%.1f", value)
end

local function compactVector(value)
    local x, y, z = vectorComponents(value)
    if not x then return "invalid" end
    return string.format("%.6g,%.6g,%.6g", x, y, z)
end

local function inspectSpinReadback(message)
    local readings = message.appliedBearingState
    if type(readings) ~= "table" or next(readings) == nil then
        return false, "no_bearing_state", "none"
    end

    local details = {}
    local failure
    for name, reading in pairs(readings) do
        local label = tostring(name)
        if type(reading) ~= "table" then
            failure = failure or (label .. ":not_table")
            details[#details + 1] = label .. "[not_table]"
        else
            local thrustOk = vectorComponents(reading.thrustVector) ~= nil
            local measuredTiltOk = finiteNumber(reading.tiltAngle)
                and math.abs(reading.tiltAngle) <= 1
            -- CC:Sable may omit getTiltAngle at exact zero. In this ground-only
            -- gate, a near-vertical physical thrust vector independently proves
            -- zero deflection; nonzero-tilt tests still require a numeric angle.
            local zeroTiltVectorOk = reading.tiltAngle == nil
                and verticalThrustVector(reading.thrustVector)
            local tiltOk = measuredTiltOk or zeroTiltVectorOk
            local stabilizationOk = finiteNumber(reading.stabilizationStrength)
                and reading.stabilizationStrength > 0
            local rotationOk = finiteNumber(reading.rotationSpeed)
            local activeOk = reading.active == true
            local manualOk = type(reading.manualTarget) == "table"

            if not tiltOk then failure = failure or (label .. ":tilt") end
            if not stabilizationOk then failure = failure or (label .. ":stabilization") end
            if not rotationOk then failure = failure or (label .. ":rotation") end
            if not activeOk then failure = failure or (label .. ":inactive") end
            if not thrustOk then failure = failure or (label .. ":thrust") end
            if not manualOk then failure = failure or (label .. ":manual_target") end

            details[#details + 1] = string.format(
                "%s[tilt=%s,stabilization=%s,rotation=%s,active=%s,thrust=%s,manual_type=%s]",
                label,
                tostring(reading.tiltAngle),
                tostring(reading.stabilizationStrength),
                tostring(reading.rotationSpeed),
                tostring(reading.active),
                compactVector(reading.thrustVector),
                type(reading.manualTarget))
        end
    end
    table.sort(details)
    return failure == nil, failure or "ok", table.concat(details, ";")
end

local function command(spinning)
    return {
        ionPower = 0,
        fallbackIonPower = 0,
        propRpm = spinning and RESPONSE_PROP_RPM or 0,
        tiltDegrees = 0,
        azimuthDegrees = 0,
        shutdown = not spinning,
    }
end

local function buildFrame(session, sequence, sentAt, spinning)
    local commands = {}
    for _, corner in ipairs(CORNERS) do commands[corner] = command(spinning) end
    return {
        protocol = PROTOCOL,
        kind = "control_frame",
        mode = MODE,
        armed = true,
        session = session,
        sequence = sequence,
        sentAt = sentAt,
        validForMs = VALID_FOR_MS,
        corners = commands,
    }
end

local function selfTest()
    assert(SPIN_SECONDS == 30, "ground spool window must remain 30 seconds")
    assert(verticalThrustVector({ 0, 1, 0 }))
    assert(verticalThrustVector({ x = 0, y = -1, z = 0 }))
    assert(not verticalThrustVector({ 0.02, 0.9998, 0 }))
    assert(not verticalThrustVector({ 0, 1 }))
    local spin = buildFrame("self", 1, 1000, true)
    for _, corner in ipairs(CORNERS) do
        local value = spin.corners[corner]
        assert(value.ionPower == 0 and value.fallbackIonPower == 0)
        assert(value.propRpm == 64 and value.tiltDegrees == 0)
        assert(value.azimuthDegrees == 0 and value.shutdown == false)
    end
    local stop = buildFrame("self", 2, 1100, false)
    for _, corner in ipairs(CORNERS) do
        local value = stop.corners[corner]
        assert(value.ionPower == 0 and value.fallbackIonPower == 0)
        assert(value.propRpm == 0 and value.tiltDegrees == 0)
        assert(value.azimuthDegrees == 0 and value.shutdown == true)
    end
    print("wired response map sender self-test: PASS")
end

local function selfTestReadback()
    local function bearing(extra)
        local reading = {
            stabilizationStrength = 1,
            rotationSpeed = 19.2,
            active = true,
            manualTarget = {},
            thrustVector = { 0, 1, 0 },
        }
        for key, value in pairs(extra or {}) do reading[key] = value end
        return { appliedBearingState = { front = reading } }
    end
    -- Numeric zero tilt is still the normal accepted case.
    assert(inspectSpinReadback(bearing({ tiltAngle = 0 })))
    -- CC:Sable omits the angle at exact zero; a vertical vector proves it.
    assert(inspectSpinReadback(bearing()))
    -- A missing angle must NOT excuse a physically deflected bearing.
    local tilted = bearing()
    tilted.appliedBearingState.front.thrustVector = { 0.2, 0.98, 0 }
    local ok, reason = inspectSpinReadback(tilted)
    assert(not ok and reason == "front:tilt", tostring(reason))
    -- A missing angle with an unreadable vector must fail closed.
    local unreadable = bearing()
    unreadable.appliedBearingState.front.thrustVector = nil
    assert(not inspectSpinReadback(unreadable))
    -- An out-of-bound numeric angle still fails regardless of the vector.
    assert(not inspectSpinReadback(bearing({ tiltAngle = 5 })))
    assert(not inspectSpinReadback({ appliedBearingState = {} }))
    print("wired response map readback self-test: PASS")
end

if args[1] == "--self-test" then
    selfTest()
    selfTestReadback()
    return
end

if args[1] ~= "--ground-check" and args[1] ~= "--self-test" then
    error("flight pulses are safety-locked; run --ground-check first", 0)
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
        if ok and wireless == false then return entry.name, entry.modem end
    end
    return nil, nil
end

local modemName, modem = findWiredModem()
if not modem then error("no wired modem attached", 0) end
for _, entry in ipairs(allModems()) do pcall(entry.modem.closeAll) end
modem.open(STATUS_CHANNEL)

local computerId = os.getComputerID()
local session = string.format("%d-response-ground-%d", computerId, os.epoch("utc"))
local latest = {}
local latestSpin = {}
local spinCommandSeen, spinReadbackSeen, shutdownSeen = {}, {}, {}
local spinSamples, spinReadbackPassSamples = {}, {}
local spinReadbackReason, spinReadbackSummary = {}, {}
local spinTrace, spinNextTraceAt, spinFirstPassAt = {}, {}, {}
local startedAt = os.epoch("utc")
local sequence, framesSent = 0, 0
local transmitting = true
local runError

local function recordSpinStatus(message)
    local corner = message.corner
    local elapsed = (os.epoch("utc") - startedAt) / 1000
    spinCommandSeen[corner] = true
    latestSpin[corner] = message
    spinSamples[corner] = (spinSamples[corner] or 0) + 1

    local readbackOk, reason, summary = inspectSpinReadback(message)
    spinReadbackReason[corner] = reason
    spinReadbackSummary[corner] = summary
    if readbackOk then
        spinReadbackSeen[corner] = true
        spinReadbackPassSamples[corner] = (spinReadbackPassSamples[corner] or 0) + 1
        if not spinFirstPassAt[corner] then spinFirstPassAt[corner] = elapsed end
    end

    local nextTraceAt = spinNextTraceAt[corner] or 0
    if elapsed >= nextTraceAt then
        spinTrace[corner] = spinTrace[corner] or {}
        spinTrace[corner][#spinTrace[corner] + 1] = string.format(
            "t=%.1fs reason=%s %s", elapsed, reason, summary)
        spinNextTraceAt[corner] = nextTraceAt + 5
    end
end

local function receiveLoop()
    while transmitting do
        local _, side, channel, _, message = os.pullEvent("modem_message")
        if channel == STATUS_CHANNEL and type(message) == "table"
            and message.protocol == PROTOCOL
            and message.session == session
            and type(message.corner) == "string" then
            latest[message.corner] = message
            if message.appliedMode == MODE
                and message.appliedIonPower == 0
                and message.appliedPropRpm == RESPONSE_PROP_RPM
                and message.appliedTiltDegrees == 0
                and message.appliedAzimuthDegrees == 0 then
                recordSpinStatus(message)
            end
            if message.appliedMode == MODE
                and message.appliedIonPower == 0
                and message.appliedPropRpm == 0
                and message.appliedTiltDegrees == 0
                and message.appliedAzimuthDegrees == 0 then
                shutdownSeen[message.corner] = true
            end
        end
    end
end

local function transmitFrame(spinning)
    sequence = sequence + 1
    local now = os.epoch("utc")
    modem.transmit(CONTROL_CHANNEL, STATUS_CHANNEL,
        buildFrame(session, sequence, now, spinning))
    framesSent = framesSent + 1
end

local function phase(seconds, spinning)
    local periodMs = math.floor(1000 / RATE_HZ)
    local stopAt = os.epoch("utc") + math.floor(seconds * 1000)
    local nextAt = os.epoch("utc")
    while os.epoch("utc") < stopAt do
        transmitFrame(spinning)
        nextAt = nextAt + periodMs
        local remaining = nextAt - os.epoch("utc")
        if remaining > 0 then sleep(remaining / 1000) end
    end
end

local function sendLoop()
    print("Response-map ground safety gate")
    print("Ions 0, tilt 0, propellers 64 RPM; the ship must remain grounded.")
    phase(SPIN_SECONDS, true)
    print("Spin gate complete; commanding explicit shutdown.")
    phase(SHUTDOWN_SECONDS, false)
    sleep(3)
    transmitting = false
end

local ok, err = pcall(parallel.waitForAny, sendLoop, receiveLoop)
if not ok then runError = tostring(err) transmitting = false end
pcall(modem.close, STATUS_CHANNEL)

local lines = {
    "WIRED FRAME RESPONSE MAP GROUND GATE",
    "session=" .. session,
    "modem=" .. tostring(modemName),
    "mode=" .. MODE,
    "armed=true",
    "safety=GROUND_ONLY_ZERO_ION_ZERO_TILT",
    "response_prop_rpm=" .. tostring(RESPONSE_PROP_RPM),
    "spin_seconds=" .. tostring(SPIN_SECONDS),
    "shutdown_seconds=" .. tostring(SHUTDOWN_SECONDS),
    "requested_rate_hz=" .. tostring(RATE_HZ),
    "frames_sent=" .. tostring(framesSent),
    "final_sequence=" .. tostring(sequence),
}
if runError then lines[#lines + 1] = "run_error=" .. runError end

local overall = runError == nil
local aggregate = 0
for _, corner in ipairs(CORNERS) do
    local status = latest[corner]
    local received = status and tonumber(status.received) or 0
    aggregate = aggregate + received
    local cornerPass = status ~= nil
        and spinCommandSeen[corner] == true
        and spinReadbackSeen[corner] == true
        and shutdownSeen[corner] == true
        and received == framesSent
        and (tonumber(status.missing) or 0) == 0
        and (tonumber(status.duplicates) or 0) == 0
        and (tonumber(status.outOfOrder) or 0) == 0
        and (tonumber(status.invalid) or 0) == 0
        and (tonumber(status.expiredBeforeApply) or 0) == 0
        and (tonumber(status.applyErrors) or 0) == 0
        and (tonumber(status.appliedSequence) or -1) == sequence
        and status.appliedMode == MODE
        and status.appliedIonPower == 0
        and status.appliedPropRpm == 0
        and status.appliedTiltDegrees == 0
        and (tonumber(status.fallbackCount) or 0) >= 1
    if not cornerPass then overall = false end
    lines[#lines + 1] = string.format(
        "%s ready=%s recv=%d missing=%s dup=%s order=%s invalid=%s applied=%s applies=%s coalesced=%s expired=%s errors=%s fallbacks=%s actuator_calls=%s spin_command_seen=%s spin_sequence=%s spin_readback_seen=%s spin_samples=%s spin_ok_samples=%s spin_first_pass_s=%s spin_reason=%s shutdown_seen=%s applied_ion=%s applied_rpm=%s applied_tilt=%s max_apply_ms=%s result=%s",
        corner,
        tostring(status and status.ready == true),
        received,
        tostring(status and status.missing or "nil"),
        tostring(status and status.duplicates or "nil"),
        tostring(status and status.outOfOrder or "nil"),
        tostring(status and status.invalid or "nil"),
        tostring(status and status.appliedSequence or "nil"),
        tostring(status and status.applyCount or "nil"),
        tostring(status and status.coalesced or "nil"),
        tostring(status and status.expiredBeforeApply or "nil"),
        tostring(status and status.applyErrors or "nil"),
        tostring(status and status.fallbackCount or "nil"),
        tostring(status and status.actuatorCalls or "nil"),
        tostring(spinCommandSeen[corner] == true),
        tostring(latestSpin[corner] and latestSpin[corner].appliedSequence or "nil"),
        tostring(spinReadbackSeen[corner] == true),
        tostring(spinSamples[corner] or 0),
        tostring(spinReadbackPassSamples[corner] or 0),
        tostring(spinFirstPassAt[corner] or "nil"),
        tostring(spinReadbackReason[corner] or "no_spin_status"),
        tostring(shutdownSeen[corner] == true),
        tostring(status and status.appliedIonPower or "nil"),
        tostring(status and status.appliedPropRpm or "nil"),
        tostring(status and status.appliedTiltDegrees or "nil"),
        tostring(status and status.maxApplyMs or "nil"),
        cornerPass and "PASS" or "FAIL")
    -- Where the apply time actually goes. A per-apply maximum cannot answer
    -- this: only some applies carry a readback, so the maximum stays pinned to
    -- one of those even when every other apply gets cheaper.
    lines[#lines + 1] = string.format(
        "%s apply_mean_ms=%s ion[mean=%s max=%s] rpm[mean=%s max=%s]"
            .. " tilt[mean=%s max=%s] readback[mean=%s max=%s applies=%s]",
        corner,
        fmt(status and status.meanApplyMs),
        fmt(status and status.stageMeanIonMs), fmt(status and status.stageMaxIonMs),
        fmt(status and status.stageMeanRpmMs), fmt(status and status.stageMaxRpmMs),
        fmt(status and status.stageMeanTiltMs), fmt(status and status.stageMaxTiltMs),
        fmt(status and status.stageMeanReadbackMs), fmt(status and status.stageMaxReadbackMs),
        tostring(status and status.readbackApplies or "nil"))
    lines[#lines + 1] = string.format(
        "%s spin_readback_last=%s",
        corner,
        tostring(spinReadbackSummary[corner] or "none"))
    lines[#lines + 1] = string.format(
        "%s spin_trace=%s",
        corner,
        spinTrace[corner] and table.concat(spinTrace[corner], " | ") or "none")
end
lines[#lines + 1] = "aggregate_verified_deliveries=" .. tostring(aggregate)
lines[#lines + 1] = "overall=" .. (overall and "PASS" or "FAIL")

local file = fs.open(RESULT_PATH, "w")
if not file then error("unable to write " .. RESULT_PATH, 0) end
file.write(table.concat(lines, "\n"))
file.close()

print("Result: " .. (overall and "PASS" or "FAIL"))
print("Report written to " .. RESULT_PATH)
if not overall then error("response-map ground safety gate failed", 0) end
