-- Standalone, non-actuating wired frame receiver for a pod computer.
-- Usage: /pod/wiredframe_test.lua FL   (or FR, RL, RR)

local args = { ... }

local CONTROL_CHANNEL = 42042
local STATUS_CHANNEL = 42043
local PROTOCOL = "helicarrier.wired-frame-test.v1"
local VALID_CORNERS = { FL = true, FR = true, RL = true, RR = true }
local STATUS_OFFSET = { FL = 0.00, FR = 0.20, RL = 0.40, RR = 0.60 }

local function nowMs()
    return os.epoch("utc")
end

local function newState()
    return {
        session = nil,
        firstSequence = nil,
        lastSequence = nil,
        received = 0,
        missing = 0,
        duplicates = 0,
        outOfOrder = 0,
        invalid = 0,
        lastToken = nil,
        lastReceivedAt = nil,
    }
end

local function resetForSession(state, session)
    local fresh = newState()
    fresh.session = session
    for key, value in pairs(fresh) do state[key] = value end
end

local function acceptFrame(state, corner, message, receivedAt)
    if type(message) ~= "table" or message.protocol ~= PROTOCOL
        or message.kind ~= "control_test" or message.actuate ~= false
        or type(message.session) ~= "string" or type(message.sequence) ~= "number"
        or type(message.corners) ~= "table" or type(message.corners[corner]) ~= "table" then
        state.invalid = state.invalid + 1
        return false
    end

    local own = message.corners[corner]
    if own.token ~= corner .. ":" .. tostring(message.sequence) then
        state.invalid = state.invalid + 1
        return false
    end

    if state.session ~= message.session then resetForSession(state, message.session) end

    local sequence = message.sequence
    if state.lastSequence == nil then
        state.firstSequence = sequence
        state.lastSequence = sequence
        state.received = 1
    elseif sequence == state.lastSequence then
        state.duplicates = state.duplicates + 1
        return false
    elseif sequence < state.lastSequence then
        state.outOfOrder = state.outOfOrder + 1
        return false
    else
        if sequence > state.lastSequence + 1 then
            state.missing = state.missing + sequence - state.lastSequence - 1
        end
        state.lastSequence = sequence
        state.received = state.received + 1
    end

    state.lastToken = own.token
    state.lastReceivedAt = receivedAt
    return true
end

local function selfTest()
    local state = newState()
    local function frame(sequence)
        return {
            protocol = PROTOCOL,
            kind = "control_test",
            session = "self-test",
            sequence = sequence,
            actuate = false,
            corners = { FL = { token = "FL:" .. tostring(sequence) } },
        }
    end

    assert(acceptFrame(state, "FL", frame(1), 100))
    assert(acceptFrame(state, "FL", frame(3), 200))
    assert(not acceptFrame(state, "FL", frame(3), 300))
    assert(not acceptFrame(state, "FL", frame(2), 400))
    assert(state.firstSequence == 1)
    assert(state.lastSequence == 3)
    assert(state.received == 2)
    assert(state.missing == 1)
    assert(state.duplicates == 1)
    assert(state.outOfOrder == 1)
    print("wiredframe pod receiver self-test: PASS")
end

if args[1] == "--self-test" then
    selfTest()
    return
end

local corner = string.upper(tostring(args[1] or ""))
if not VALID_CORNERS[corner] then
    error("usage: /pod/wiredframe_test.lua FL|FR|RL|RR", 0)
end

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
    error("no wired modem is attached to pod " .. corner, 0)
end

closeEveryModem()
local modem, modemName = findWiredModem()
modem.open(CONTROL_CHANNEL)

local state = newState()
local running = true

local function statusMessage()
    return {
        protocol = PROTOCOL,
        kind = state.session and "ack" or "ready",
        corner = corner,
        session = state.session,
        firstSequence = state.firstSequence,
        lastSequence = state.lastSequence,
        received = state.received,
        missing = state.missing,
        duplicates = state.duplicates,
        outOfOrder = state.outOfOrder,
        invalid = state.invalid,
        lastToken = state.lastToken,
        lastReceivedAt = state.lastReceivedAt,
        reportedAt = nowMs(),
    }
end

local function receiveLoop()
    while running do
        local event = { os.pullEventRaw() }
        if event[1] == "terminate" then
            running = false
            os.queueEvent("wiredframe_receiver_stopped")
            return
        end
        if event[1] == "modem_message" then
            local side, channel, message = event[2], event[3], event[5]
            if side == modemName and channel == CONTROL_CHANNEL then
                acceptFrame(state, corner, message, nowMs())
            end
        end
    end
end

local function statusLoop()
    sleep(STATUS_OFFSET[corner])
    while running do
        modem.transmit(STATUS_CHANNEL, CONTROL_CHANNEL, statusMessage())
        sleep(1)
    end
end

print("Wired frame receiver: " .. corner)
print("Modem: " .. modemName .. "  channel: " .. CONTROL_CHANNEL)
print("NO ACTUATORS ARE USED. Hold Ctrl+T to stop; reboot restores normal startup.")

local ok, runError = pcall(function()
    parallel.waitForAny(receiveLoop, statusLoop)
end)
running = false
modem.close(CONTROL_CHANNEL)

print(string.format(
    "%s stopped: first=%s last=%s received=%d missing=%d duplicates=%d out_of_order=%d invalid=%d",
    corner,
    tostring(state.firstSequence or "none"),
    tostring(state.lastSequence or "none"),
    state.received,
    state.missing,
    state.duplicates,
    state.outOfOrder,
    state.invalid
))

if not ok then error(runError, 0) end
