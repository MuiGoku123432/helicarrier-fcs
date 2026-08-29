-- Standalone wired transport proof for FCS-DEV.
-- Sends one non-actuating frame containing all four corners and records
-- cumulative acknowledgements from the pod test receivers.

local args = { ... }

local CONTROL_CHANNEL = 42042
local STATUS_CHANNEL = 42043
local PROTOCOL = "helicarrier.wired-frame-test.v1"
local CORNERS = { "FL", "FR", "RL", "RR" }
local RESULT_PATH = "/fcs/wiredframe_test_result.txt"

local function nowMs()
    return os.epoch("utc")
end

local function buildFrame(session, sequence, sentAt)
    local corners = {}
    for _, corner in ipairs(CORNERS) do
        corners[corner] = {
            token = corner .. ":" .. tostring(sequence),
        }
    end
    return {
        protocol = PROTOCOL,
        kind = "control_test",
        session = session,
        sequence = sequence,
        sentAt = sentAt,
        actuate = false,
        corners = corners,
    }
end

local function selfTest()
    local frame = buildFrame("self-test", 7, 1234)
    assert(frame.protocol == PROTOCOL)
    assert(frame.kind == "control_test")
    assert(frame.sequence == 7)
    assert(frame.actuate == false)
    for _, corner in ipairs(CORNERS) do
        assert(frame.corners[corner].token == corner .. ":7")
    end
    print("wiredframe sender self-test: PASS")
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
local session = tostring(computerId) .. "-" .. tostring(nowMs())
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

    -- Allow every staggered one-second pod status loop to report the final frame.
    sleep(2)
    done = true
    os.queueEvent("wiredframe_test_done")
end

local function receiveLoop()
    while not done do
        local event = { os.pullEventRaw() }
        if event[1] == "terminate" then error("Terminated", 0) end
        if event[1] == "wiredframe_test_done" then return end
        if event[1] == "modem_message" then
            local side, channel, message = event[2], event[3], event[5]
            if side == modemName and channel == STATUS_CHANNEL and type(message) == "table"
                and message.protocol == PROTOCOL then
                local corner = message.corner
                if acknowledgements[corner] then
                    ready[corner] = true
                    if message.kind == "ack" and message.session == session then
                        acknowledgements[corner] = message
                    end
                end
            end
        end
    end
end

print("Wired frame test")
print("Modem: " .. modemName .. "  channel: " .. CONTROL_CHANNEL)
print("Run the pod receivers first. Sending at " .. rate .. " Hz for " .. duration .. " seconds.")

local ok, runError = pcall(function()
    parallel.waitForAll(sendLoop, receiveLoop)
end)
modem.close(STATUS_CHANNEL)

if not ok then error(runError, 0) end

local lines = {
    "WIRED FRAME TEST RESULT",
    "session=" .. session,
    "modem=" .. modemName,
    "duration_s=" .. tostring(duration),
    "requested_rate_hz=" .. tostring(rate),
    "frames_sent=" .. tostring(sequence),
    "physical_transmissions=" .. tostring(sequence),
    "actuator_commands=0",
}

local passed = true
for _, corner in ipairs(CORNERS) do
    local ack = acknowledgements[corner]
    local firstSequence = tonumber(ack.firstSequence)
    local lastSequence = tonumber(ack.lastSequence)
    local received = tonumber(ack.received) or 0
    local missing = tonumber(ack.missing) or 0
    local duplicates = tonumber(ack.duplicates) or 0
    local outOfOrder = tonumber(ack.outOfOrder) or 0
    local invalid = tonumber(ack.invalid) or 0
    local cornerPassed = ready[corner] == true
        and firstSequence == 1
        and lastSequence == sequence
        and received == sequence
        and missing == 0
        and duplicates == 0
        and outOfOrder == 0
        and invalid == 0
    if not cornerPassed then passed = false end

    lines[#lines + 1] = string.format(
        "%s ready=%s first=%s last=%s received=%d missing=%d duplicates=%d out_of_order=%d invalid=%d result=%s",
        corner,
        tostring(ready[corner] == true),
        tostring(firstSequence or "none"),
        tostring(lastSequence or "none"),
        received,
        missing,
        duplicates,
        outOfOrder,
        invalid,
        cornerPassed and "PASS" or "FAIL"
    )
end
lines[#lines + 1] = "overall=" .. (passed and "PASS" or "FAIL")

for _, line in ipairs(lines) do print(line) end
writeResult(lines)
print("Saved: " .. RESULT_PATH)
