-- Safe direct-wired bearing application test.
-- Ions remain at zero while all four corners run at safe RPM 8 and follow a bounded tilt pattern.

local args = { ... }
local CONTROL_CHANNEL = 42042
local STATUS_CHANNEL = 42043
local PROTOCOL = "helicarrier.control-frame.v1"
local MODE = "ground_bearing_test"
local RESULT_PATH = "/fcs/wiredframe_bearing_result.txt"
local CORNERS = { "FL", "FR", "RL", "RR" }
local MAX_TILT_DEGREES = 5
local DONE_EVENT = "wiredframe_bearing_test_done"

local function nowMs()
    return os.epoch("utc")
end

local function finiteNumber(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function commandFor(tiltDegrees)
    return {
        ionPower = 0,
        propRpm = 8,
        tiltDegrees = tiltDegrees,
        azimuthDegrees = 0,
    }
end

local function buildFrame(session, sequence, sentAt, tiltDegrees)
    local corners = {}
    for _, corner in ipairs(CORNERS) do
        corners[corner] = commandFor(tiltDegrees)
    end
    return {
        protocol = PROTOCOL,
        kind = "control_frame",
        mode = MODE,
        armed = false,
        session = session,
        sequence = sequence,
        sentAt = sentAt,
        validForMs = 500,
        corners = corners,
    }
end

local function selfTest()
    local frame = buildFrame("self-test", 7, 1000, 5)
    assert(frame.protocol == PROTOCOL)
    assert(frame.mode == MODE and frame.armed == false)
    for _, corner in ipairs(CORNERS) do
        local command = frame.corners[corner]
        assert(command.ionPower == 0 and command.propRpm == 8)
        assert(command.tiltDegrees == 5 and command.azimuthDegrees == 0)
    end
    print("wired bearing sender self-test: PASS")
end

if args[1] == "--self-test" then
    selfTest()
    return
end

local amplitude = tonumber(args[1]) or 5
local rate = tonumber(args[2]) or 10
if not finiteNumber(amplitude) or amplitude <= 0 or amplitude > MAX_TILT_DEGREES then
    error("tilt amplitude must be > 0 and <= " .. MAX_TILT_DEGREES .. " degree", 0)
end
if not finiteNumber(rate) or rate <= 0 or rate > 20 then
    error("rate must be > 0 and <= 20 Hz", 0)
end

local phases = {
    { name = "zero_start", tilt = 0, duration = 3 },
    { name = "positive", tilt = amplitude, duration = 3 },
    { name = "zero_middle", tilt = 0, duration = 3 },
    { name = "negative", tilt = -amplitude, duration = 3 },
    { name = "zero_final", tilt = 0, duration = 3 },
}

local function allModems()
    local found = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "modem") then
            found[#found + 1] = { name = name, modem = peripheral.wrap(name) }
        end
    end
    return found
end

local function closeEveryModem()
    for _, entry in ipairs(allModems()) do
        if type(entry.modem.closeAll) == "function" then entry.modem.closeAll() end
    end
end

local function findWiredModem()
    for _, entry in ipairs(allModems()) do
        local modem = entry.modem
        if type(modem.isWireless) == "function" and not modem.isWireless() then
            return modem, entry.name
        end
    end
    error("no wired modem found", 0)
end

local function writeResult(lines)
    local handle = fs.open(RESULT_PATH, "w")
    if not handle then error("cannot write " .. RESULT_PATH, 0) end
    handle.write(table.concat(lines, "\n") .. "\n")
    handle.close()
end

closeEveryModem()
local modem, modemName = findWiredModem()
modem.open(STATUS_CHANNEL)

local session = tostring(os.getComputerID()) .. "-ground-bearing-" .. tostring(nowMs())
local interval = 1 / rate
local acknowledgements = {}
local phaseSeen = {}
for _, phase in ipairs(phases) do phaseSeen[phase.name] = {} end
local currentPhase
local sequence = 0
local done = false
local startedAt = nowMs()

local function matchingTilt(value, target)
    return finiteNumber(value) and math.abs(value - target) <= 0.0001
end

local function bearingReadbackMatches(message, target)
    local readings = message.appliedBearingState
    if type(readings) ~= "table" or next(readings) == nil then return false end

    local expectedMagnitude = math.abs(target)
    for _, reading in pairs(readings) do
        if type(reading) ~= "table"
            or not finiteNumber(reading.tiltDegrees)
            or math.abs(reading.tiltDegrees - expectedMagnitude) > 1.0
            or not finiteNumber(reading.stabilizationStrength)
            or reading.stabilizationStrength <= 0
            or not finiteNumber(reading.rotationSpeed) then
            return false
        end
    end
    return true
end

local function receiveLoop()
    while not done do
        local event = { os.pullEventRaw() }
        if event[1] == "terminate" then error("Terminated", 0) end
        if event[1] == DONE_EVENT then return end
        if event[1] == "modem_message" and event[2] == modemName
            and event[3] == STATUS_CHANNEL then
            local message = event[5]
            if type(message) == "table" and message.protocol == PROTOCOL
                and (message.kind == "control_ack" or message.kind == "control_ready")
                and message.corner then
                acknowledgements[message.corner] = message
                if currentPhase and message.session == session
                    and message.appliedMode == MODE
                    and matchingTilt(message.appliedTiltDegrees, currentPhase.tilt)
                    and message.appliedPropRpm == 8
                    and bearingReadbackMatches(message, currentPhase.tilt) then
                    phaseSeen[currentPhase.name][message.corner] = true
                end
            end
        end
    end
end

local function sendLoop()
    print("WIRED BEARING TEST -- DISARMED, IONS 0, PROPS 8")
    print(string.format("tilt pattern 0, +%.3f, 0, -%.3f, 0 degrees at %.2f Hz",
        amplitude, amplitude, rate))
    print("waiting for pod ready/status frames...")
    sleep(2)

    for _, phase in ipairs(phases) do
        currentPhase = phase
        print(string.format("phase %-12s tilt %+0.3f for %.1f s",
            phase.name, phase.tilt, phase.duration))
        local phaseEndsAt = nowMs() + math.floor(phase.duration * 1000)
        repeat
            sequence = sequence + 1
            modem.transmit(CONTROL_CHANNEL, STATUS_CHANNEL,
                buildFrame(session, sequence, nowMs(), phase.tilt))
            sleep(interval)
        until nowMs() >= phaseEndsAt
    end

    currentPhase = nil
    print("sender stopped; waiting 3 s for local zero-tilt fallback evidence...")
    sleep(3)
    done = true
    os.queueEvent(DONE_EVENT)
end

local ok, runError = pcall(function()
    parallel.waitForAll(receiveLoop, sendLoop)
end)

local endedAt = nowMs()
local lines = {
    "WIRED FRAME GROUND BEARING RESULT",
    "session=" .. session,
    "modem=" .. tostring(modemName),
    "requested_rate_hz=" .. tostring(rate),
    "tilt_amplitude_degrees=" .. tostring(amplitude),
    "phase_duration_s=3",
    "frames_sent=" .. tostring(sequence),
    "physical_transmissions=" .. tostring(sequence),
    "frame_mode=" .. MODE,
    "frame_armed=false",
    "commanded_ion_power=0",
    "commanded_prop_rpm=8",
    "commanded_azimuth_degrees=0",
    "elapsed_ms=" .. tostring(endedAt - startedAt),
    "verification=physical_getTiltAngle_and_stabilization_status",
    "measured_bearing_readback=getTiltAngle_in_control_ack",
}

local passed = ok
local aggregateDeliveries = 0
for _, phase in ipairs(phases) do
    local fields = { "phase=" .. phase.name, "tilt=" .. tostring(phase.tilt) }
    for _, corner in ipairs(CORNERS) do
        local seen = phaseSeen[phase.name][corner] == true
        fields[#fields + 1] = corner .. "=" .. tostring(seen)
        if not seen then passed = false end
    end
    lines[#lines + 1] = table.concat(fields, " ")
end

for _, corner in ipairs(CORNERS) do
    local ack = acknowledgements[corner]
    local cornerPassed = type(ack) == "table"
        and ack.session == session
        and ack.firstSequence == 1
        and ack.lastSequence == sequence
        and ack.received == sequence
        and ack.missing == 0
        and ack.duplicates == 0
        and ack.outOfOrder == 0
        and ack.invalid == 0
        and ack.expiredBeforeApply == 0
        and ack.applyErrors == 0
        and ack.appliedSequence == sequence
        and ack.appliedMode == MODE
        and ack.appliedIonPower == 0
        and ack.appliedPropRpm == 8
        and matchingTilt(ack.appliedTiltDegrees, 0)
        and ack.appliedAzimuthDegrees == 0
        and ack.fallbackCount >= 1

    if ack then aggregateDeliveries = aggregateDeliveries + (ack.received or 0) end
    if not cornerPassed then passed = false end
    lines[#lines + 1] = string.format(
        "%s ready=%s recv=%s missing=%s dup=%s order=%s invalid=%s mailbox=%s applied=%s applies=%s coalesced=%s expired=%s errors=%s fallbacks=%s actuator_calls=%s applied_tilt=%s applied_rpm=%s max_apply_ms=%s result=%s",
        corner,
        tostring(ack ~= nil),
        tostring(ack and ack.received),
        tostring(ack and ack.missing),
        tostring(ack and ack.duplicates),
        tostring(ack and ack.outOfOrder),
        tostring(ack and ack.invalid),
        tostring(ack and ack.mailboxSequence),
        tostring(ack and ack.appliedSequence),
        tostring(ack and ack.applyCount),
        tostring(ack and ack.coalesced),
        tostring(ack and ack.expiredBeforeApply),
        tostring(ack and ack.applyErrors),
        tostring(ack and ack.fallbackCount),
        tostring(ack and ack.actuatorCalls),
        tostring(ack and ack.appliedTiltDegrees),
        tostring(ack and ack.appliedPropRpm),
        tostring(ack and ack.maxApplyMs),
        cornerPassed and "PASS" or "FAIL")
end

lines[#lines + 1] = "aggregate_verified_deliveries=" .. tostring(aggregateDeliveries)
if not ok then lines[#lines + 1] = "run_error=" .. tostring(runError) end
lines[#lines + 1] = "overall=" .. (passed and "PASS" or "FAIL")

writeResult(lines)
for _, line in ipairs(lines) do print(line) end
print("Saved to " .. RESULT_PATH)

if not passed then error("ground bearing test failed; read " .. RESULT_PATH, 0) end
