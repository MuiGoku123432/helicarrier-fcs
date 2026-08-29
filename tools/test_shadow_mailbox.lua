package.path = "pod-template/?.lua;" .. package.path

local mailbox = require("pod.shadow_mailbox")

local function modem(wireless)
    return {
        opened = {},
        sent = {},
        isWireless = function() return wireless end,
        open = function(channel) end,
        transmit = function(channel, replyChannel, message)
            table.insert(message.sent or {}, { channel, replyChannel, message })
        end,
    }
end

local wired = modem(false)
local wireless = modem(true)
local peripherals = {
    getNames = function() return { "wireless", "bottom" } end,
    hasType = function(name, kind) return kind == "modem" and (name == "wireless" or name == "bottom") end,
    wrap = function(name) return name == "bottom" and wired or wireless end,
}

local clock = 1000
local dependencies = {
    peripheral = peripherals,
    epoch = function() return clock end,
    sleep = function() end,
    pullEventRaw = function() return "terminate" end,
}

local offsets = { FL = 0, FR = 1, RL = 2, RR = 3 }
local function frame(session, sequence, sentAt)
    local corners = {}
    for corner, offset in pairs(offsets) do
        corners[corner] = {
            ionPower = 0.1 + offset * 0.01,
            propRpm = 500 + offset,
            tiltDegrees = offset,
            azimuthDegrees = -offset,
        }
    end
    return {
        protocol = mailbox.PROTOCOL,
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

for corner, offset in pairs(offsets) do
    local shadow = mailbox.new({ corner = corner }, dependencies)
    assert(shadow.enabled == true)
    assert(shadow.modemName == "bottom")
    assert(shadow.acceptFrame(frame("run-a", 1, 100), 110))
    assert(shadow.acceptFrame(frame("run-a", 2, 200), 210))

    local status = shadow.snapshot()
    assert(status.corner == corner)
    assert(status.firstSequence == 1)
    assert(status.lastSequence == 2)
    assert(status.received == 2)
    assert(status.missing == 0)
    assert(status.duplicates == 0)
    assert(status.outOfOrder == 0)
    assert(status.invalid == 0)
    assert(status.replacements == 1)
    assert(status.mailboxSequence == 2)
    assert(status.mailboxOnly == true)
    assert(status.actuatorCalls == 0)
    assert(shadow.state.mailbox.command.tiltDegrees == offset)
end

local shadow = mailbox.new({ corner = "FL" }, dependencies)
assert(shadow.acceptFrame(frame("run-b", 1, 100), 110))
assert(shadow.acceptFrame(frame("run-b", 3, 300), 310))
assert(not shadow.acceptFrame(frame("run-b", 3, 300), 320))
assert(not shadow.acceptFrame(frame("run-b", 2, 200), 330))

local invalid = frame("run-b", 4, 400)
invalid.armed = true
assert(not shadow.acceptFrame(invalid, 410))

local status = shadow.snapshot()
assert(status.firstSequence == 1)
assert(status.lastSequence == 3)
assert(status.received == 2)
assert(status.missing == 1)
assert(status.duplicates == 1)
assert(status.outOfOrder == 1)
assert(status.invalid == 1)
assert(status.replacements == 1)
assert(status.mailboxSequence == 3)

-- A genuinely newer FCS session replaces the old mailbox and resets its run counters.
assert(shadow.acceptFrame(frame("run-c", 1, 1000), 1010))
status = shadow.snapshot()
assert(status.session == "run-c")
assert(status.firstSequence == 1)
assert(status.lastSequence == 1)
assert(status.received == 1)
assert(status.missing == 0)
assert(status.replacements == 0)
assert(status.invalid == 1)

-- A delayed frame from an older session must not roll the mailbox backward.
assert(not shadow.acceptFrame(frame("run-b", 4, 500), 1020))
status = shadow.snapshot()
assert(status.session == "run-c")
assert(status.lastSequence == 1)
assert(status.outOfOrder == 1)

print("shadow mailbox tests: PASS")
