-- Regression guard for pod command receipt/application decoupling.
-- Run with: LUA_PATH='pod-template/?.lua;pod-template/?/init.lua;;' luajit tools/test_pod_command_receipt.lua

local path = "pod-template/pod/main.lua"
local handle = assert(io.open(path, "r"), "could not open " .. path)
local source = handle:read("*a")
handle:close()

local function findAfter(needle, startAt)
    local index = source:find(needle, startAt or 1, true)
    assert(index, "missing expected pod behavior: " .. needle)
    return index
end

local function expectBefore(first, second, label)
    assert(first < second, label)
end

local applyLoop = findAfter("local function applyPowerLoop()")
local receiveLoop = findAfter("local function receiveLoop()", applyLoop)
local applyCall = findAfter("pcall(thrusters.applyCommand, pending.power)", applyLoop)
expectBefore(applyLoop, applyCall, "actuator apply must stay in the dedicated worker")
expectBefore(applyCall, receiveLoop, "receive loop must not invoke thrusters.applyCommand inline")

local setPower = findAfter('elseif message.type == "set_power" then', receiveLoop)
local setRpm = findAfter('elseif message.type == "set_rpm" then', setPower)
local setPowerBlock = source:sub(setPower, setRpm - 1)

local receipt = assert(setPowerBlock:find('state.lastCommandAt = receivedAt', 1, true),
    "set_power must refresh watchdog time at validated receipt")
local handoff = assert(setPowerBlock:find('os.queueEvent("pod_apply_power")', 1, true),
    "set_power must hand actuator work to the worker")
local acknowledgement = assert(setPowerBlock:find('lightReply(senderId, "ack")', 1, true),
    "set_power must acknowledge validated receipt")
expectBefore(receipt, handoff, "watchdog receipt time must precede deferred actuator work")
expectBefore(handoff, acknowledgement, "handoff must precede the receipt acknowledgement")
assert(not setPowerBlock:find("thrusters.applyCommand", 1, true),
    "set_power must not perform hardware application inline")
assert(setPowerBlock:find("powerSession = state.powerSession or 0", 1, true),
    "queued power must be tagged with its armed session")

local arm = findAfter('elseif message.type == "arm" then', receiveLoop)
local armBlock = source:sub(arm, setPower - 1)
assert(armBlock:find("state.powerSession = (state.powerSession or 0) + 1", 1, true),
    "a transition into the armed state must start a new power session")
assert(source:find("state.powerSession == pending.powerSession", applyLoop, true),
    "an apply must be accepted only in the session that received it")

local disarm = findAfter('elseif message.type == "disarm" then', setRpm)
local watchdog = findAfter("local function watchdogLoop()", disarm)
local disarmBlock = source:sub(disarm, watchdog - 1)
assert(disarmBlock:find("pendingPower = nil", 1, true),
    "disarm must discard a queued power command")

print("pod command receipt regression: 13 passed, 0 failed")
