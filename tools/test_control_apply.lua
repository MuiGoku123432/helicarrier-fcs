package.path = "pod-template/?.lua;" .. package.path

local mailboxModule = require("pod.control_mailbox")
local applyModule = require("pod.control_apply")

local wired = {
    isWireless = function() return false end,
    open = function() end,
    transmit = function() end,
}
local peripherals = {
    getNames = function() return { "bottom" } end,
    hasType = function(name, kind) return name == "bottom" and kind == "modem" end,
    wrap = function() return wired end,
}

local clock = 100
local dependencies = {
    peripheral = peripherals,
    epoch = function() return clock end,
    sleep = function() end,
    pullEventRaw = function() return "terminate" end,
}

local function frame(sequence, receivedSession)
    local corners = {}
    for _, corner in ipairs({ "FL", "FR", "RL", "RR" }) do
        corners[corner] = {
            ionPower = 0,
            propRpm = 0,
            tiltDegrees = 0,
            azimuthDegrees = 0,
        }
    end
    return {
        protocol = mailboxModule.PROTOCOL,
        kind = "control_frame",
        mode = "ground_apply",
        armed = false,
        session = receivedSession or "apply-test",
        sequence = sequence,
        sentAt = clock,
        validForMs = 750,
        corners = corners,
    }
end

local mailbox = mailboxModule.new({ corner = "FL" }, dependencies)
local writes = {}
local thrusters = {
    applyExact = function(power)
        writes[#writes + 1] = power
        clock = clock + 120
        return power
    end,
}
local actuator = applyModule.new(mailbox, thrusters, dependencies)

assert(mailbox.acceptFrame(frame(1), clock))
assert(actuator.applyLatest())
assert(#writes == 1 and writes[1] == 0)
assert(not actuator.applyLatest())

-- Sequence 2 is intentionally replaced before the worker is free; sequence 3 wins.
clock = 300
assert(mailbox.acceptFrame(frame(2), clock))
clock = 400
assert(mailbox.acceptFrame(frame(3), clock))
assert(actuator.applyLatest())
assert(#writes == 1) -- same successful zero is elided

local status = mailbox.snapshot()
assert(status.received == 3)
assert(status.appliedSequence == 3)
assert(status.applyCount == 2)
assert(status.coalesced == 1)
assert(status.applyErrors == 0)
assert(status.actuatorCalls == 2)

-- A stale command is never applied, then the worker performs one zero fallback.
clock = 600
assert(mailbox.acceptFrame(frame(4), clock))
clock = 1400
assert(not actuator.applyLatest())
assert(status.appliedSequence == 3)
assert(actuator.enforceStaleFallback())
assert(not actuator.enforceStaleFallback())
assert(#writes == 1) -- already-zero fallback is recorded without a duplicate write

status = mailbox.snapshot()
assert(status.expiredBeforeApply == 1)
assert(status.fallbackCount == 1)
assert(status.actuatorCalls == 3)
assert(status.applyErrors == 0)

-- Defense in depth: the mailbox rejects any non-zero ground actuator command.
clock = 1600
local unsafe = frame(5)
unsafe.corners.FL.ionPower = 0.01
assert(not mailbox.acceptFrame(unsafe, clock))
assert(mailbox.snapshot().invalid == 1)

print("control apply tests: PASS")
