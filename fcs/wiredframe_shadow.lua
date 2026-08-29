-- Production-load shadow test for the direct-wired four-corner control frame.
-- Pod production programs remain running; the shadow mailbox never actuates.

local args = { ... }

local CONTROL_CHANNEL = 42042
local STATUS_CHANNEL = 42043
local PROTOCOL = "helicarrier.control-frame.v1"
local CORNERS = { "FL", "FR", "RL", "RR" }
local CORNER_OFFSET = { FL = 0, FR = 7, RL = 13, RR = 19 }
local RESULT_PATH = "/fcs/wiredframe_shadow_result.txt"

local function nowMs()
    return os.epoch("utc")
end

local function commandFor(corner, sequence)
    local phase = ((sequence + CORNER_OFFSET[corner]) % 40) / 39
    return {
        ionPower = 0.15 + 0.10 * phase,
        propRpm = 500 + 250 * phase,
        tiltDegrees = -5 + 10 * phase,
        azimuthDegrees = -2 + 4 * phase,
    }
end

local function buildFrame(session, sequence, sentAt)
    local corners = {}
    for _, corner in ipairs(CORNERS) do
        corners[corner] = commandFor(corner, sequence)
    end
    return {
        protocol = PROTOCOL,
        kind = "control_frame",
        mode = "shadow",
        armed = false,
        session = session,
        sequence = sequence,
        sentAt = sentAt,
        validForMs = 500,
        corners = corners,
    }
end

local function selfTest()
    local frame = buildFrame("self-test", 7, 1234)
    assert(frame.protocol == PROTOCOL)
    assert(frame.kind == "control_frame")
    assert(frame.mode == "shadow")
    assert(frame.armed == false)
    assert(frame.sequence == 7)
    for _, corner in ipairs(CORNERS) do
        local command = frame.corners[corner]
        assert(command.ionPower >= 0 and command.ionPower <= 1)
        assert(command.propRpm >= 0)
        assert(type(command.tiltDegrees) == "number")
        assert(type(command.azimuthDegrees) == "number")
    end
    print("wiredframe shadow sender self-test: PASS")
end

if args[1] == "--self-test" then
    selfTest()
    return
end

local duration = tonumber(args[1]) or 60
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
local session = tostring(computerId) .. "-shadow-" .. tostring(nowMs())
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
    sleep(2)
    done = true
    os.queueEvent("wiredframe_shadow_done")
end

local function receiveLoop()
    while not done do
        local event = { os.pullEventRaw() }
        if event[1] == "terminate" then error("Terminated", 0) end
        if event[1] == "wiredframe_shadow_done" then return end
        if event[1] == "modem_message" then
            local side, channel, message = event[2], event[3], event[5]
            if side == modemName and channel == STATUS_CHANNEL and type(message) == "table"
                and message.protocol == PROTOCOL and message.mode == "shadow" then
                local corner = message.corner
                if acknowledgements[corner] then
                    ready[corner] = true
                    if message.kind == "shadow_ack" and message.session == session then
                        acknowledgements[corner] = message
                    end
                end
            end
        end
    end
end

print("Production-load wired shadow test")
print("Modem: " .. modemName .. "  channel: " .. CONTROL_CHANNEL)
print("Pods must be running their normal startup programs.")
print("SHADOW/DISARMED: no direct-frame actuator calls.")
print("Sending at " .. rate .. " Hz for " .. duration .. " seconds.")

local ok, runError = pcall(function()
    parallel.waitForAll(sendLoop, receiveLoop)
end)
modem.close(STATUS_CHANNEL)
if not ok then error(runError, 0) end

local lines = {
    "WIRED FRAME PRODUCTION-LOAD SHADOW RESULT",
    "session=" .. session,
    "modem=" .. modemName,
    "duration_s=" .. tostring(duration),
    "requested_rate_hz=" .. tostring(rate),
    "frames_sent=" .. tostring(sequence),
    "physical_transmissions=" .. tostring(sequence),
    "frame_mode=shadow",
    "frame_armed=false",
}

local passed = true
local aggregateDeliveries = 0
for _, corner in ipairs(CORNERS) do
    local ack = acknowledgements[corner]
    local firstSequence = tonumber(ack.firstSequence)
    local lastSequence = tonumber(ack.lastSequence)
    local mailboxSequence = tonumber(ack.mailboxSequence)
    local received = tonumber(ack.received) or 0
    local missing = tonumber(ack.missing) or 0
    local duplicates = tonumber(ack.duplicates) or 0
    local outOfOrder = tonumber(ack.outOfOrder) or 0
    local invalid = tonumber(ack.invalid) or 0
    local replacements = tonumber(ack.replacements) or 0
    local actuatorCalls = tonumber(ack.actuatorCalls)
    aggregateDeliveries = aggregateDeliveries + received

    local cornerPassed = ready[corner] == true
        and firstSequence == 1
        and lastSequence == sequence
        and mailboxSequence == sequence
        and received == sequence
        and missing == 0
        and duplicates == 0
        and outOfOrder == 0
        and invalid == 0
        and replacements == math.max(0, sequence - 1)
        and ack.mailboxOnly == true
        and actuatorCalls == 0
        and ack.transport == "wired"
    if not cornerPassed then passed = false end

    lines[#lines + 1] = string.format(
        "%s ready=%s first=%s last=%s received=%d missing=%d duplicates=%d out_of_order=%d invalid=%d replacements=%d mailbox=%s actuator_calls=%s result=%s",
        corner,
        tostring(ready[corner] == true),
        tostring(firstSequence or "none"),
        tostring(lastSequence or "none"),
        received,
        missing,
        duplicates,
        outOfOrder,
        invalid,
        replacements,
        tostring(mailboxSequence or "none"),
        tostring(actuatorCalls or "none"),
        cornerPassed and "PASS" or "FAIL"
    )
end
lines[#lines + 1] = "aggregate_verified_deliveries=" .. tostring(aggregateDeliveries)
lines[#lines + 1] = "overall=" .. (passed and "PASS" or "FAIL")

for _, line in ipairs(lines) do print(line) end
writeResult(lines)
print("Saved: " .. RESULT_PATH)
