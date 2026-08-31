-- Direct-wired grounded nonzero-ion safety gate.
--
-- Run only while the craft is grounded and restrained:
--     /fcs/wiredframe_ground_ion_test.lua --ground-ion-check
--
-- The test keeps every bearing at zero tilt and azimuth. It first proves fresh
-- zero-ion/RPM-64 acknowledgements, applies one bounded below-hover ion level,
-- deliberately stops transmitting to prove both stale fallback stages, and
-- finally sends an explicit exact-zero shutdown. Neutral hover and tilt remain
-- locked until this grounded gate produces a clean live report.

local args = { ... }
local CONTROL_CHANNEL = 42042
local STATUS_CHANNEL = 42043
local PROTOCOL = "helicarrier.control-frame.v1"
local MODE = "response_map_test"
local CORNERS = { "FL", "FR", "RL", "RR" }
local RESULT_PATH = "/fcs/wiredframe_ground_ion_result.txt"

local RATE_HZ = 10
local VALID_FOR_MS = 750
local SHUTDOWN_VALID_FOR_MS = 5000
local PRECHECK_SECONDS = 10
local ION_SECONDS = 5
local FALLBACK_WAIT_SECONDS = 8
local SHUTDOWN_SECONDS = 5
local RESPONSE_PROP_RPM = 64

-- Ion output is quantised to fifteenths by the pod thruster driver. These
-- command values deliberately land on levels 2/15 and 1/15 respectively,
-- both below the documented 0.195 neutral-hover command threshold.
local TEST_ION_POWER = 0.14
local FALLBACK_ION_POWER = 0.07
local FALLBACK_STOP_AFTER_MS = 5000
local DOCUMENTED_HOVER_POWER = 0.195
local CONFIRMATION = "GROUND-ION"

local function groundIonFiniteNumber(value)
    return type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
end

local function groundIonNearlyEqual(a, b, tolerance)
    return groundIonFiniteNumber(a) and groundIonFiniteNumber(b)
        and math.abs(a - b) <= (tolerance or 1e-9)
end

local function groundIonCommand(kind)
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

    local ionPower = kind == "ion" and TEST_ION_POWER or 0
    local fallbackIonPower = kind == "ion" and FALLBACK_ION_POWER or 0
    return {
        ionPower = ionPower,
        fallbackIonPower = fallbackIonPower,
        fallbackStopAfterMs = FALLBACK_STOP_AFTER_MS,
        propRpm = RESPONSE_PROP_RPM,
        tiltDegrees = 0,
        azimuthDegrees = 0,
        shutdown = false,
    }
end

local function groundIonFrame(session, sequence, sentAt, kind)
    local commands = {}
    for _, corner in ipairs(CORNERS) do commands[corner] = groundIonCommand(kind) end
    return {
        protocol = PROTOCOL,
        kind = "control_frame",
        mode = MODE,
        armed = true,
        session = session,
        sequence = sequence,
        sentAt = sentAt,
        validForMs = kind == "shutdown" and SHUTDOWN_VALID_FOR_MS or VALID_FOR_MS,
        corners = commands,
    }
end

local function groundIonCountersClean(status)
    return type(status) == "table"
        and (tonumber(status.missing) or 0) == 0
        and (tonumber(status.duplicates) or 0) == 0
        and (tonumber(status.outOfOrder) or 0) == 0
        and (tonumber(status.invalid) or 0) == 0
        and (tonumber(status.expiredBeforeApply) or 0) == 0
        and (tonumber(status.applyErrors) or 0) == 0
end

local function groundIonCounterAdvanced(status, field, baseline)
    return type(status) == "table" and groundIonFiniteNumber(baseline)
        and (tonumber(status[field]) or 0) >= baseline + 1
end

local function groundIonSelfTest()
    assert(TEST_ION_POWER < DOCUMENTED_HOVER_POWER)
    assert(FALLBACK_ION_POWER > 0 and FALLBACK_ION_POWER < TEST_ION_POWER)
    assert(math.floor(TEST_ION_POWER * 15) == 2)
    assert(math.floor(FALLBACK_ION_POWER * 15) == 1)
    assert(FALLBACK_STOP_AFTER_MS >= 1000 and FALLBACK_STOP_AFTER_MS <= 60000)
    assert(FALLBACK_WAIT_SECONDS * 1000
        > VALID_FOR_MS + FALLBACK_STOP_AFTER_MS + 1000)

    local spin = groundIonFrame("self", 1, 1000, "spin")
    local ion = groundIonFrame("self", 2, 1100, "ion")
    local stop = groundIonFrame("self", 3, 1200, "shutdown")
    assert(spin.protocol == PROTOCOL and spin.kind == "control_frame")
    assert(spin.mode == MODE and spin.armed == true)
    assert(spin.validForMs == VALID_FOR_MS)
    assert(ion.validForMs == VALID_FOR_MS)
    assert(stop.validForMs == SHUTDOWN_VALID_FOR_MS)

    for _, corner in ipairs(CORNERS) do
        local spinCommand = spin.corners[corner]
        assert(spinCommand.ionPower == 0 and spinCommand.fallbackIonPower == 0)
        assert(spinCommand.fallbackStopAfterMs == FALLBACK_STOP_AFTER_MS)
        assert(spinCommand.propRpm == RESPONSE_PROP_RPM)
        assert(spinCommand.tiltDegrees == 0 and spinCommand.azimuthDegrees == 0)
        assert(spinCommand.shutdown == false)

        local ionCommand = ion.corners[corner]
        assert(ionCommand.ionPower == TEST_ION_POWER)
        assert(ionCommand.fallbackIonPower == FALLBACK_ION_POWER)
        assert(ionCommand.fallbackStopAfterMs == FALLBACK_STOP_AFTER_MS)
        assert(ionCommand.propRpm == RESPONSE_PROP_RPM)
        assert(ionCommand.tiltDegrees == 0 and ionCommand.azimuthDegrees == 0)
        assert(ionCommand.shutdown == false)

        local stopCommand = stop.corners[corner]
        assert(stopCommand.ionPower == 0 and stopCommand.fallbackIonPower == 0)
        assert(stopCommand.fallbackStopAfterMs == nil)
        assert(stopCommand.propRpm == 0)
        assert(stopCommand.tiltDegrees == 0 and stopCommand.azimuthDegrees == 0)
        assert(stopCommand.shutdown == true)
    end

    assert(groundIonCountersClean({}))
    assert(not groundIonCountersClean({ missing = 1 }))
    assert(not groundIonCountersClean({ applyErrors = 1 }))
    assert(groundIonCounterAdvanced({ fallbackCount = 3 }, "fallbackCount", 2))
    assert(not groundIonCounterAdvanced({ fallbackCount = 2 }, "fallbackCount", 2))
    assert(not groundIonCounterAdvanced({ fallbackCount = 3 }, "fallbackCount", nil))
    print("wired grounded ion sender self-test: PASS")
end

if args[1] == "--self-test" then
    groundIonSelfTest()
    return
end

if args[1] ~= "--ground-ion-check" then
    error("neutral hover and tilt remain safety-locked; use --ground-ion-check", 0)
end

print("GROUNDED NONZERO-ION SAFETY GATE")
print("Required: craft grounded, restrained, and clear of personnel/structures.")
print(string.format(
    "Command %.2f (level 2/15), fallback %.2f (level 1/15), stop after %.1fs.",
    TEST_ION_POWER, FALLBACK_ION_POWER, FALLBACK_STOP_AFTER_MS / 1000))
print("Propellers will run at 64 RPM; tilt and azimuth remain exactly zero.")
write("Type " .. CONFIRMATION .. " to continue: ")
local confirmation = read()
if confirmation ~= CONFIRMATION then error("operator confirmation not received", 0) end

local function groundIonModems()
    local result = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            result[#result + 1] = { name = name, modem = peripheral.wrap(name) }
        end
    end
    return result
end

local function findGroundIonWiredModem()
    for _, entry in ipairs(groundIonModems()) do
        local ok, wireless = pcall(entry.modem.isWireless)
        if ok and wireless == false then return entry.name, entry.modem end
    end
    return nil, nil
end

local modemName, modem = findGroundIonWiredModem()
if not modem then error("no wired modem attached", 0) end
for _, entry in ipairs(groundIonModems()) do pcall(entry.modem.closeAll) end
modem.open(STATUS_CHANNEL)

local computerId = os.getComputerID()
local session = string.format("%d-response-ground-ion-%d", computerId, os.epoch("utc"))
local latest = {}
local precheckSeen, ionSeen = {}, {}
local fallbackSeen, fallbackStopSeen, shutdownSeen = {}, {}, {}
local fallbackBaseline, fallbackStopBaseline = {}, {}
local sequence, framesSent = 0, 0
local transmitting = true
local currentPhase = "idle"
local runError

local function groundIonApplied(message, ionPower, propRpm)
    return message.appliedMode == MODE
        and groundIonNearlyEqual(message.appliedIonPower, ionPower)
        and message.appliedPropRpm == propRpm
        and message.appliedTiltDegrees == 0
        and message.appliedAzimuthDegrees == 0
end

local function recordGroundIonStatus(message)
    local corner = message.corner
    latest[corner] = message

    if currentPhase == "precheck" and groundIonApplied(message, 0, RESPONSE_PROP_RPM)
        and groundIonCountersClean(message) then
        precheckSeen[corner] = true
    end
    if currentPhase == "ion" and groundIonApplied(message, TEST_ION_POWER, RESPONSE_PROP_RPM) then
        ionSeen[corner] = true
    end
    if currentPhase == "fallback" then
        -- Fallback writes are deliberately recorded as counters, not as new
        -- applied commands. The applied* fields continue to describe the last
        -- accepted live frame, so counter deltas are the authoritative proof.
        if groundIonCounterAdvanced(message, "fallbackCount", fallbackBaseline[corner]) then
            fallbackSeen[corner] = true
        end
        if groundIonCounterAdvanced(message, "fallbackStops", fallbackStopBaseline[corner]) then
            fallbackStopSeen[corner] = true
        end
    end
    if currentPhase == "shutdown" and groundIonApplied(message, 0, 0) then
        shutdownSeen[corner] = true
    end
end

local function groundIonReceiveLoop()
    while transmitting do
        local _, _, channel, _, message = os.pullEvent("modem_message")
        if channel == STATUS_CHANNEL and type(message) == "table"
            and message.protocol == PROTOCOL
            and message.session == session
            and type(message.corner) == "string" then
            recordGroundIonStatus(message)
        end
    end
end

local function transmitGroundIonFrame(kind)
    sequence = sequence + 1
    local now = os.epoch("utc")
    modem.transmit(CONTROL_CHANNEL, STATUS_CHANNEL,
        groundIonFrame(session, sequence, now, kind))
    framesSent = framesSent + 1
end

local function runGroundIonPhase(seconds, kind, name)
    currentPhase = name
    local periodMs = math.floor(1000 / RATE_HZ)
    local stopAt = os.epoch("utc") + math.floor(seconds * 1000)
    local nextAt = os.epoch("utc")
    while os.epoch("utc") < stopAt do
        transmitGroundIonFrame(kind)
        nextAt = nextAt + periodMs
        local remaining = nextAt - os.epoch("utc")
        if remaining > 0 then sleep(remaining / 1000) end
    end
end

local function groundIonPrechecksPassed()
    for _, corner in ipairs(CORNERS) do
        local status = latest[corner]
        if precheckSeen[corner] ~= true or not groundIonCountersClean(status)
            or not groundIonApplied(status, 0, RESPONSE_PROP_RPM)
            or (tonumber(status.fallbackCount) or 0) ~= 0
            or (tonumber(status.fallbackStops) or 0) ~= 0 then
            return false, corner
        end
    end
    return true
end

local function groundIonCommandsPassed()
    for _, corner in ipairs(CORNERS) do
        local status = latest[corner]
        if ionSeen[corner] ~= true or not groundIonCountersClean(status)
            or not groundIonApplied(status, TEST_ION_POWER, RESPONSE_PROP_RPM)
            or (tonumber(status.fallbackCount) or 0) ~= 0
            or (tonumber(status.fallbackStops) or 0) ~= 0 then
            return false, corner
        end
    end
    return true
end

local function groundIonShutdownBurst(seconds)
    local stopAt = os.epoch("utc") + math.floor(seconds * 1000)
    while os.epoch("utc") < stopAt do
        pcall(transmitGroundIonFrame, "shutdown")
        sleep(0.1)
    end
end

local function groundIonSendLoop()
    print("Precheck: zero ion, 64 RPM, zero tilt.")
    runGroundIonPhase(PRECHECK_SECONDS, "spin", "precheck")
    local ready, corner = groundIonPrechecksPassed()
    if not ready then
        error("fresh clean precheck not confirmed for " .. tostring(corner), 0)
    end

    print(string.format("Applying bounded ion power %.2f for %ds.",
        TEST_ION_POWER, ION_SECONDS))
    runGroundIonPhase(ION_SECONDS, "ion", "ion")
    local ionReady, ionCorner = groundIonCommandsPassed()
    if not ionReady then
        error("clean nonzero application not confirmed for " .. tostring(ionCorner), 0)
    end
    for _, cornerName in ipairs(CORNERS) do
        local status = latest[cornerName]
        fallbackBaseline[cornerName] = tonumber(status.fallbackCount) or 0
        fallbackStopBaseline[cornerName] = tonumber(status.fallbackStops) or 0
    end

    print("Stopping control frames to exercise staged fallback.")
    currentPhase = "fallback"
    sleep(FALLBACK_WAIT_SECONDS)

    print("Fallback window complete; commanding explicit shutdown.")
    runGroundIonPhase(SHUTDOWN_SECONDS, "shutdown", "shutdown")
    sleep(3)
    transmitting = false
end

local ok, err = pcall(parallel.waitForAny, groundIonSendLoop, groundIonReceiveLoop)
if not ok then
    runError = tostring(err)
    currentPhase = "emergency_shutdown"
    groundIonShutdownBurst(2)
    transmitting = false
end
pcall(modem.close, STATUS_CHANNEL)

local lines = {
    "WIRED FRAME GROUNDED NONZERO ION GATE",
    "session=" .. session,
    "modem=" .. tostring(modemName),
    "mode=" .. MODE,
    "armed=true",
    "safety=GROUND_RESTRAINED_ZERO_TILT_BELOW_HOVER",
    "test_ion_power=" .. tostring(TEST_ION_POWER),
    "test_ion_level=2/15",
    "fallback_ion_power=" .. tostring(FALLBACK_ION_POWER),
    "fallback_ion_level=1/15",
    "fallback_stop_after_ms=" .. tostring(FALLBACK_STOP_AFTER_MS),
    "documented_hover_power=" .. tostring(DOCUMENTED_HOVER_POWER),
    "response_prop_rpm=" .. tostring(RESPONSE_PROP_RPM),
    "precheck_seconds=" .. tostring(PRECHECK_SECONDS),
    "ion_seconds=" .. tostring(ION_SECONDS),
    "fallback_wait_seconds=" .. tostring(FALLBACK_WAIT_SECONDS),
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
        and precheckSeen[corner] == true
        and ionSeen[corner] == true
        and fallbackSeen[corner] == true
        and fallbackStopSeen[corner] == true
        and shutdownSeen[corner] == true
        and received == framesSent
        and groundIonCountersClean(status)
        and (tonumber(status.appliedSequence) or -1) == sequence
        and groundIonApplied(status, 0, 0)
        and (tonumber(status.fallbackCount) or 0) == 1
        and (tonumber(status.fallbackStops) or 0) == 1
    if not cornerPass then overall = false end

    lines[#lines + 1] = string.format(
        "%s recv=%d missing=%s dup=%s order=%s invalid=%s applied=%s applies=%s coalesced=%s expired=%s errors=%s fallbacks=%s fallback_stops=%s precheck_seen=%s ion_seen=%s fallback_seen=%s fallback_stop_seen=%s shutdown_seen=%s applied_ion=%s applied_rpm=%s applied_tilt=%s max_apply_ms=%s result=%s",
        corner,
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
        tostring(status and status.fallbackStops or "nil"),
        tostring(precheckSeen[corner] == true),
        tostring(ionSeen[corner] == true),
        tostring(fallbackSeen[corner] == true),
        tostring(fallbackStopSeen[corner] == true),
        tostring(shutdownSeen[corner] == true),
        tostring(status and status.appliedIonPower or "nil"),
        tostring(status and status.appliedPropRpm or "nil"),
        tostring(status and status.appliedTiltDegrees or "nil"),
        tostring(status and status.maxApplyMs or "nil"),
        cornerPass and "PASS" or "FAIL")
end
lines[#lines + 1] = "aggregate_verified_deliveries=" .. tostring(aggregate)
lines[#lines + 1] = "overall=" .. (overall and "PASS" or "FAIL")

local file = fs.open(RESULT_PATH, "w")
if not file then error("unable to write " .. RESULT_PATH, 0) end
file.write(table.concat(lines, "\n"))
file.close()

print("Result: " .. (overall and "PASS" or "FAIL"))
print("Report written to " .. RESULT_PATH)
if not overall then error("grounded nonzero-ion safety gate failed", 0) end
