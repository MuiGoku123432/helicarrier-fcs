-- Ground-safe production actuator-load test for direct wired control frames.
-- Sends one four-corner frame per tick interval. Pods perform real ion writes
-- at exact zero output while reception remains latest-wins and independent.

local args = { ... }

local CONTROL_CHANNEL = 42042
local STATUS_CHANNEL = 42043
local PROTOCOL = "helicarrier.control-frame.v1"
local CORNERS = { "FL", "FR", "RL", "RR" }
local RESULT_PATH = "/fcs/wiredframe_actuator_result.txt"

local function nowMs()
    return os.epoch("utc")
end

local function buildFrame(session, sequence, sentAt)
    local corners = {}
    for _, corner in ipairs(CORNERS) do
        corners[corner] = {
            ionPower = 0,
            propRpm = 0,
            tiltDegrees = 0,
            azimuthDegrees = 0,
        }
    end
    return {
        protocol = PROTOCOL,
        kind = "control_frame",
        mode = "ground_apply",
        armed = false,
        session = session,
        sequence = sequence,
        sentAt = sentAt,
        validForMs = 750,
        corners = corners,
    }
end

local function selfTest()
    local frame = buildFrame("self-test", 7, 1234)
    assert(frame.protocol == PROTOCOL)
    assert(frame.kind == "control_frame")
    assert(frame.mode == "ground_apply")
    assert(frame.armed == false)
    assert(frame.sequence == 7)
    for _, corner in ipairs(CORNERS) do
        local command = frame.corners[corner]
        assert(command.ionPower == 0)
        assert(command.propRpm == 0)
        assert(command.tiltDegrees == 0)
        assert(command.azimuthDegrees == 0)
    end
    print("wiredframe actuator sender self-test: PASS")
end

if args[1] == "--self-test" then
    selfTest()
    return
end

local duration = tonumber(args[1]) or 30
local rate = tonumber(args[2]) or 10
if duration <= 0 then error("duration must be greater than zero", 0) end
if rate <= 0 or rate > 20 then error("rate must be greater than zero and at most 20 Hz", 0) end

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
    error("no wired modem is attached to FCS-DEV", 0)
end

local function writeResult(lines)
    local handle, openError = fs.open(RESULT_PATH, "w")
    if not handle then
        print("Could not write result: " .. tostring(openError))
        return
    end
    for _, line in ipairs(lines) do handle.writeLine(line) end
    handle.close()
end

closeEveryModem()
local modem, modemName = findWiredModem()
modem.open(STATUS_CHANNEL)

local computerId = os.getComputerID and os.getComputerID() or 0
local session = tostring(computerId) .. "-ground-apply-" .. tostring(nowMs())
local interval = 1 / rate
local sequence = 0
local done = false
local startedAt = nowMs()
local acknowledgements = {}
local ready = {}

for _, corner in ipairs(CORNERS) do acknowledgements[corner] = {} end

local function sendLoop()
    local stopAt = startedAt + math.floor(duration * 1000)
    while nowMs() < stopAt do
        sequence = sequence + 1
        modem.transmit(CONTROL_CHANNEL, STATUS_CHANNEL, buildFrame(session, sequence, nowMs()))
        sleep(interval)
    end
    -- Time for the final mailbox entry to apply and for every staggered status.
    sleep(3)
    done = true
    os.queueEvent("wiredframe_actuator_done")
end

local function receiveLoop()
    while not done do
        local event = { os.pullEventRaw() }
        if event[1] == "terminate" then error("Terminated", 0) end
        if event[1] == "wiredframe_actuator_done" then return end
        if event[1] == "modem_message" then
            local side, channel, message = event[2], event[3], event[5]
            if side == modemName and channel == STATUS_CHANNEL and type(message) == "table"
                and message.protocol == PROTOCOL then
                local corner = message.corner
                if acknowledgements[corner] then
                    ready[corner] = true
                    if message.kind == "control_ack" and message.mode == "ground_apply"
                        and message.session == session then
                        acknowledgements[corner] = message
                    end
                end
            end
        end
    end
end

print("Ground-safe wired actuator-load test")
print("Modem: " .. modemName .. "  channel: " .. CONTROL_CHANNEL)
print("Pods must be running their normal startup programs.")
print("REAL ION WRITES AT EXACT ZERO; no lift, RPM, tilt, or azimuth.")
print("Sending at " .. rate .. " Hz for " .. duration .. " seconds.")

local ok, runError = pcall(function()
    parallel.waitForAll(sendLoop, receiveLoop)
end)
modem.close(STATUS_CHANNEL)
if not ok then error(runError, 0) end

local lines = {
    "WIRED FRAME GROUND ACTUATOR-LOAD RESULT",
    "session=" .. session,
    "modem=" .. modemName,
    "duration_s=" .. tostring(duration),
    "requested_rate_hz=" .. tostring(rate),
    "frames_sent=" .. tostring(sequence),
    "physical_transmissions=" .. tostring(sequence),
    "frame_mode=ground_apply",
    "frame_armed=false",
    "commanded_ion_power=0",
    "commanded_prop_rpm=0",
    "commanded_tilt_degrees=0",
    "commanded_azimuth_degrees=0",
}

local passed = true
local aggregateDeliveries = 0
for _, corner in ipairs(CORNERS) do
    local ack = acknowledgements[corner]
    local firstSequence = tonumber(ack.firstSequence)
    local lastSequence = tonumber(ack.lastSequence)
    local mailboxSequence = tonumber(ack.mailboxSequence)
    local appliedSequence = tonumber(ack.appliedSequence)
    local received = tonumber(ack.received) or 0
    local missing = tonumber(ack.missing) or 0
    local duplicates = tonumber(ack.duplicates) or 0
    local outOfOrder = tonumber(ack.outOfOrder) or 0
    local invalid = tonumber(ack.invalid) or 0
    local applyCount = tonumber(ack.applyCount) or 0
    local applyErrors = tonumber(ack.applyErrors) or 0
    local actuatorCalls = tonumber(ack.actuatorCalls) or 0
    local coalesced = tonumber(ack.coalesced) or 0
    local expired = tonumber(ack.expiredBeforeApply) or 0
    local fallbacks = tonumber(ack.fallbackCount) or 0
    local maxApplyMs = tonumber(ack.maxApplyMs) or 0
    aggregateDeliveries = aggregateDeliveries + received

    local cornerPassed = ready[corner] == true
        and firstSequence == 1
        and lastSequence == sequence
        and mailboxSequence == sequence
        and appliedSequence == sequence
        and received == sequence
        and missing == 0
        and duplicates == 0
        and outOfOrder == 0
        and invalid == 0
        and applyCount > 0
        and applyErrors == 0
        and expired == 0
        and applyCount + coalesced == sequence
        and actuatorCalls == applyCount + fallbacks
        and ack.transport == "wired"
    if not cornerPassed then passed = false end

    lines[#lines + 1] = string.format(
        "%s ready=%s recv=%d missing=%d dup=%d order=%d invalid=%d mailbox=%s applied=%s applies=%d coalesced=%d expired=%d fallbacks=%d actuator_calls=%d max_apply_ms=%d result=%s",
        corner,
        tostring(ready[corner] == true),
        received,
        missing,
        duplicates,
        outOfOrder,
        invalid,
        tostring(mailboxSequence or "none"),
        tostring(appliedSequence or "none"),
        applyCount,
        coalesced,
        expired,
        fallbacks,
        actuatorCalls,
        maxApplyMs,
        cornerPassed and "PASS" or "FAIL"
    )
end
lines[#lines + 1] = "aggregate_verified_deliveries=" .. tostring(aggregateDeliveries)
lines[#lines + 1] = "overall=" .. (passed and "PASS" or "FAIL")

for _, line in ipairs(lines) do print(line) end
writeResult(lines)
print("Saved: " .. RESULT_PATH)
