local config = require("fcs.config")
local network = require("fcs.network")
local protocol = require("fcs.protocol")

local banks = {}
local CORNERS = { "FL", "FR", "RL", "RR" }
local state = {}
local lastStatusRequest = 0
local sequence = 0
local session = tostring(os.getComputerID()) .. ":" .. tostring(os.epoch("utc"))

for _, corner in ipairs(CORNERS) do
    state[corner] = {
        corner = corner,
        hostname = config.wireless.podHostnames[corner],
        online = false,
    }
end

local function nextSequence()
    sequence = sequence + 1
    return sequence
end

local function send(corner, messageType, fields, allowDiscovery)
    local opened = network.open()
    if not opened then
        return false, "wireless network unavailable"
    end

    local podId = network.lookupPod(corner)
    if not podId and allowDiscovery then
        podId = network.discoverPod(corner)
    end
    if not podId then
        state[corner].online = false
        return false, "pod not found: " .. tostring(state[corner].hostname)
    end

    local message = fields or {}
    message.corner = corner
    message.sequence = message.sequence or nextSequence()
    message.session = session
    rednet.send(podId, protocol.message(messageType, message), config.wireless.protocol)
    state[corner].podId = podId
    return true, message.sequence
end

-- Counters, so a message that is sent but never lands can be told apart from
-- one that lands and is then thrown away by a guard below.
banks.stats = {
    seen = 0, badProtocol = 0, wrongType = 0, unknownCorner = 0,
    hostnameMismatch = 0, senderMismatch = 0, accepted = 0,
    perCorner = { FL = 0, FR = 0, RL = 0, RR = 0 },
    -- Rejections attributed to the corner that claimed them, and the last one
    -- in full. A bare senderMismatch counter says a pod is being thrown away
    -- but not WHICH, and "which" is the whole diagnosis: a corner whose
    -- messages are all rejected on sender id is a duplicate host, not a dead
    -- pod, and no timeout change touches it. See /fcs/podprobe.lua.
    rejectedPerCorner = { FL = 0, FR = 0, RL = 0, RR = 0 },
    lastSenderMismatch = nil,
}

local function acceptStatus(senderId, message)
    local corner = message.corner
    if not state[corner] then
        banks.stats.unknownCorner = banks.stats.unknownCorner + 1
        return
    end

    if message.hostname ~= config.wireless.podHostnames[corner] then
        banks.stats.hostnameMismatch = banks.stats.hostnameMismatch + 1
        banks.stats.rejectedPerCorner[corner] =
            (banks.stats.rejectedPerCorner[corner] or 0) + 1
        return
    end

    local expectedId = network.lookupPod(corner)
    if expectedId and senderId ~= expectedId then
        banks.stats.senderMismatch = banks.stats.senderMismatch + 1
        banks.stats.rejectedPerCorner[corner] =
            (banks.stats.rejectedPerCorner[corner] or 0) + 1
        banks.stats.lastSenderMismatch = string.format("%s expected=%s got=%s",
            corner, tostring(expectedId), tostring(senderId))
        return
    end

    banks.stats.accepted = banks.stats.accepted + 1
    banks.stats.perCorner[corner] = (banks.stats.perCorner[corner] or 0) + 1
    network.rememberPod(corner, senderId)

    local pod = state[corner]
    for key, value in pairs(message) do
        pod[key] = value
    end
    pod.podId = senderId
    pod.receivedAt = os.epoch("utc")
    pod.online = true

    -- Stamp replies SEPARATELY from general telemetry.
    --
    -- pod.type is whatever arrived most recently, and pods broadcast
    -- unprompted status every telemetryPeriodSeconds (200 ms). So a waiter
    -- that decides by reading pod.type has to observe the ack inside the gap
    -- before the next status overwrites it -- a coin flip, and a losing one
    -- once a listener coroutine is draining the queue concurrently.
    --
    -- HANDOFF.md records "acks were being clobbered by status messages" as a
    -- WRONG diagnosis that the harness could not reproduce. It reproduces the
    -- moment there is a concurrent listener: the run_axisresponse harness hit
    -- it as "no reply from the FL pod within 1000 ms" on a set_rpm that the
    -- pod had in fact applied.
    --
    -- These stamps are never overwritten by a later status, so a reply cannot
    -- be missed by being late to look.
    if message.type == "ack" then
        pod.lastAckAt = pod.receivedAt
        pod.lastAckSequence = message.sequence
    elseif message.type == "fault" then
        pod.lastFaultAt = pod.receivedAt
        pod.lastFaultSequence = message.sequence
    end
end

function banks.poll()
    if not config.wireless.enabled then
        return
    end

    local opened = network.open()
    if not opened then
        for _, corner in ipairs(CORNERS) do
            state[corner].online = false
        end
        return
    end

    while true do
        local senderId, message = rednet.receive(config.wireless.protocol, 0)
        if not senderId then
            break
        end
        banks.handle(senderId, message)
    end

    banks.tick()
end

-- Handle exactly one received message.
function banks.handle(senderId, message)
        banks.stats.seen = banks.stats.seen + 1
        local valid = protocol.validate(message)
        -- ack carries the same full telemetry payload as status, and it is the
        -- only reply that proves a set_rpm actually landed.
        if not valid then
            banks.stats.badProtocol = banks.stats.badProtocol + 1
        elseif message.type == "status" or message.type == "fault"
                or message.type == "ack" then
            acceptStatus(senderId, message)
        else
            banks.stats.wrongType = banks.stats.wrongType + 1
        end
end

-- Block until one message arrives. Meant to run in its own coroutine under
-- parallel(): CC discards events that do not match a filtered wait, and the
-- sample loop spends most of its time inside sublevel API calls waiting on
-- task_complete -- so anything received inline is thrown away. A dedicated
-- listener has its own filter and keeps hearing while the other loop blocks.
function banks.listen(timeout)
    if not config.wireless.enabled then
        return false
    end
    if not network.open() then
        return false
    end

    local senderId, message = rednet.receive(config.wireless.protocol, timeout)
    if not senderId then
        return false
    end

    banks.handle(senderId, message)
    return true
end

-- Periodic upkeep: poll requests and offline marking. Cheap, no receiving.
function banks.tick()
    if not config.wireless.enabled or not network.open() then
        return
    end

    local now = os.epoch("utc")
    if now - lastStatusRequest >= config.wireless.statusRequestPeriodMs then
        for _, corner in ipairs(CORNERS) do
            send(corner, "status_request", nil, false)
        end
        lastStatusRequest = now
    end

    for _, corner in ipairs(CORNERS) do
        local pod = state[corner]
        if not pod.receivedAt or now - pod.receivedAt > config.wireless.offlineAfterMs then
            pod.online = false
        end
    end
end

function banks.getState()
    return state
end

function banks.send(corner, messageType, fields)
    corner = string.upper(corner or "")
    if not state[corner] then
        return false, "unknown corner: " .. corner
    end
    return send(corner, messageType, fields, true)
end

function banks.corners()
    return CORNERS
end

return banks
