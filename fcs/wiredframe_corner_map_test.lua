-- Safe direct-wired independent corner mapping test.
-- Ions remain at zero, all propellers run at RPM 8, and only one corner tilts at a time.

local args = { ... }
local CONTROL_CHANNEL = 42042
local STATUS_CHANNEL = 42043
local PROTOCOL = "helicarrier.control-frame.v1"
local MODE = "ground_bearing_test"
local RESULT_PATH = "/fcs/wiredframe_corner_map_result.txt"
local CORNERS = { "FL", "FR", "RL", "RR" }
local PROP_RPM = 8
local TILT_DEGREES = 5
local PHASE_DURATION_S = 3
local DONE_EVENT = "wiredframe_corner_map_test_done"

local function nowMs()
    return os.epoch("utc")
end

local function finiteNumber(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function zeroTargets()
    local targets = {}
    for _, corner in ipairs(CORNERS) do targets[corner] = 0 end
    return targets
end

local function cornerTargets(activeCorner, tiltDegrees)
    local targets = zeroTargets()
    targets[activeCorner] = tiltDegrees
    return targets
end

local function buildPhases()
    local result = {
        { name = "zero_start", active = "ALL", targets = zeroTargets() },
    }
    for _, corner in ipairs(CORNERS) do
        result[#result + 1] = {
            name = corner .. "_positive",
            active = corner,
            targets = cornerTargets(corner, TILT_DEGREES),
        }
        result[#result + 1] = {
            name = corner .. "_zero_after_positive",
            active = corner,
            targets = zeroTargets(),
        }
        result[#result + 1] = {
            name = corner .. "_negative",
            active = corner,
            targets = cornerTargets(corner, -TILT_DEGREES),
        }
        result[#result + 1] = {
            name = corner .. "_zero_after_negative",
            active = corner,
            targets = zeroTargets(),
        }
    end
    result[#result + 1] = {
        name = "zero_final",
        active = "ALL",
        targets = zeroTargets(),
    }
    return result
end

local function commandFor(tiltDegrees)
    return {
        ionPower = 0,
        propRpm = PROP_RPM,
        tiltDegrees = tiltDegrees,
        azimuthDegrees = 0,
    }
end

local function buildFrame(session, sequence, sentAt, targets)
    local commands = {}
    for _, corner in ipairs(CORNERS) do
        commands[corner] = commandFor(targets[corner] or 0)
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
        corners = commands,
    }
end

local function selfTest()
    local phases = buildPhases()
    assert(#phases == 18)
    local frame = buildFrame("self-test", 7, 1000, cornerTargets("FL", TILT_DEGREES))
    assert(frame.protocol == PROTOCOL)
    assert(frame.mode == MODE and frame.armed == false)
    for _, corner in ipairs(CORNERS) do
        local command = frame.corners[corner]
        assert(command.ionPower == 0 and command.propRpm == PROP_RPM)
        assert(command.azimuthDegrees == 0)
        assert(command.tiltDegrees == (corner == "FL" and TILT_DEGREES or 0))
    end
    for _, corner in ipairs(CORNERS) do
        assert(phases[#phases].targets[corner] == 0)
    end
    print("wired corner map sender self-test: PASS")
end

if args[1] == "--self-test" then
    selfTest()
    return
end

local rate = tonumber(args[1]) or 10
if not finiteNumber(rate) or rate <= 0 or rate > 20 then
    error("rate must be > 0 and <= 20 Hz", 0)
end

local phases = buildPhases()
for _, phase in ipairs(phases) do phase.duration = PHASE_DURATION_S end

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

local function matchingTilt(value, target)
    return finiteNumber(value) and math.abs(value - target) <= 0.0001
end

local function vectorComponents(value)
    if type(value) ~= "table" then return nil end
    local x = value[1] or value.x
    local y = value[2] or value.y
    local z = value[3] or value.z
    if not finiteNumber(x) or not finiteNumber(y) or not finiteNumber(z) then return nil end
    return x, y, z
end

local function formatVector(value)
    local x, y, z = vectorComponents(value)
    if not x then return "nil" end
    return string.format("%.6f,%.6f,%.6f", x, y, z)
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
            or not finiteNumber(reading.rotationSpeed)
            or reading.active ~= true
            or not vectorComponents(reading.thrustVector)
            or type(reading.manualTarget) ~= "table" then
            return false
        end
    end
    return true
end

closeEveryModem()
local modem, modemName = findWiredModem()
modem.open(STATUS_CHANNEL)

local session = tostring(os.getComputerID()) .. "-corner-map-" .. tostring(nowMs())
local interval = 1 / rate
local acknowledgements = {}
local phaseSeen = {}
local phaseSamples = {}
for _, phase in ipairs(phases) do
    phaseSeen[phase.name] = {}
    phaseSamples[phase.name] = {}
end
local currentPhase
local sequence = 0
local done = false
local startedAt = nowMs()

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
                if currentPhase and message.session == session then
                    local target = currentPhase.targets[message.corner] or 0
                    if message.appliedMode == MODE
                        and matchingTilt(message.appliedTiltDegrees, target)
                        and message.appliedIonPower == 0
                        and message.appliedPropRpm == PROP_RPM
                        and message.appliedAzimuthDegrees == 0
                        and bearingReadbackMatches(message, target) then
                        phaseSeen[currentPhase.name][message.corner] = true
                        phaseSamples[currentPhase.name][message.corner] = message.appliedBearingState
                    end
                end
            end
        end
    end
end

local function sendLoop()
    print("WIRED CORNER MAP -- DISARMED, IONS 0, PROPS 8")
    print("Each corner moves +5, 0, -5, 0 while the other corners remain at zero.")
    print(string.format("%d phases, %.1f s each, %.2f Hz; about %.0f seconds total",
        #phases, PHASE_DURATION_S, rate, #phases * PHASE_DURATION_S + 5))
    print("waiting for pod ready/status frames...")
    sleep(2)

    for _, phase in ipairs(phases) do
        currentPhase = phase
        print(string.format("phase %-24s active=%s FL=%+g FR=%+g RL=%+g RR=%+g",
            phase.name, phase.active,
            phase.targets.FL, phase.targets.FR, phase.targets.RL, phase.targets.RR))
        local phaseEndsAt = nowMs() + math.floor(phase.duration * 1000)
        repeat
            sequence = sequence + 1
            modem.transmit(CONTROL_CHANNEL, STATUS_CHANNEL,
                buildFrame(session, sequence, nowMs(), phase.targets))
            sleep(interval)
        until nowMs() >= phaseEndsAt
    end

    currentPhase = nil
    print("sender stopped; waiting 3 s for local RPM-0 / tilt-0 fallback evidence...")
    sleep(3)
    done = true
    os.queueEvent(DONE_EVENT)
end

local ok, runError = pcall(function()
    parallel.waitForAll(receiveLoop, sendLoop)
end)

local endedAt = nowMs()
local lines = {
    "WIRED FRAME CORNER MAP RESULT",
    "session=" .. session,
    "modem=" .. tostring(modemName),
    "requested_rate_hz=" .. tostring(rate),
    "tilt_amplitude_degrees=" .. tostring(TILT_DEGREES),
    "phase_duration_s=" .. tostring(PHASE_DURATION_S),
    "phase_count=" .. tostring(#phases),
    "frames_sent=" .. tostring(sequence),
    "physical_transmissions=" .. tostring(sequence),
    "frame_mode=" .. MODE,
    "frame_armed=false",
    "commanded_ion_power=0",
    "commanded_prop_rpm=" .. tostring(PROP_RPM),
    "commanded_azimuth_degrees=0",
    "status_transport=existing_batched_1hz",
    "verification=getTiltAngle_stabilization_rotation_thrustVector_manualTarget",
    "elapsed_ms=" .. tostring(endedAt - startedAt),
}

local passed = ok
local aggregateDeliveries = 0
for _, phase in ipairs(phases) do
    local fields = {
        "phase=" .. phase.name,
        "active=" .. phase.active,
    }
    for _, corner in ipairs(CORNERS) do
        local seen = phaseSeen[phase.name][corner] == true
        fields[#fields + 1] = corner .. "_target=" .. tostring(phase.targets[corner])
        fields[#fields + 1] = corner .. "_seen=" .. tostring(seen)
        if not seen then passed = false end
    end
    lines[#lines + 1] = table.concat(fields, " ")

    for _, corner in ipairs(CORNERS) do
        local readings = phaseSamples[phase.name][corner]
        if type(readings) == "table" then
            for bearingIndex, reading in ipairs(readings) do
                lines[#lines + 1] = string.format(
                    "readback phase=%s corner=%s bearing=%d target=%g tilt=%s stabilization=%s rotation=%s active=%s thrust=%s manual_target=%s",
                    phase.name,
                    corner,
                    bearingIndex,
                    phase.targets[corner],
                    tostring(reading.tiltDegrees),
                    tostring(reading.stabilizationStrength),
                    tostring(reading.rotationSpeed),
                    tostring(reading.active),
                    formatVector(reading.thrustVector),
                    formatVector(reading.manualTarget))
            end
        end
    end
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
        and ack.appliedPropRpm == PROP_RPM
        and matchingTilt(ack.appliedTiltDegrees, 0)
        and ack.appliedAzimuthDegrees == 0
        and ack.fallbackCount >= 1
        and bearingReadbackMatches(ack, 0)

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

if not passed then error("corner map test failed; read " .. RESULT_PATH, 0) end
