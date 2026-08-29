local function readFile(path)
    local handle = assert(io.open(path, "r"))
    local source = handle:read("*a")
    handle:close()
    return source
end

local main = readFile("pod-template/pod/main.lua")
local mailbox = readFile("pod-template/pod/control_mailbox.lua")
local apply = readFile("pod-template/pod/control_apply.lua")
local passed = 0

local function check(condition, message)
    assert(condition, message)
    passed = passed + 1
end

check(not main:find("local function networkLoop", 1, true),
    "legacy Rednet networkLoop must remain retired")
check(not main:find("rednet.receive(config.protocol)", 1, true),
    "active pod source must not receive legacy Rednet commands")
check(not main:find("local function watchdogLoop", 1, true),
    "legacy command timeout watchdog must remain retired")
check(not main:find("local function applyPowerLoop", 1, true),
    "legacy inline power worker must remain retired")
check(main:find('require("pod.control_mailbox").new(config)', 1, true),
    "active pod must construct the wired control mailbox")
check(main:find('require("pod.control_apply").new(controlMailbox, thrusters)', 1, true),
    "active pod must construct the independent actuator worker")
check(main:find("parallel.waitForAll(controlMailbox.receiveLoop, controlMailbox.statusLoop, controlApply.loop, samplerLoop, statusLoop, displayLoop)", 1, true),
    "wired receive, apply, sampling, status, and display loops must run independently")
check(mailbox:find('mailbox.PROTOCOL = "helicarrier.control-frame.v1"', 1, true),
    "mailbox protocol must remain explicit")
check(mailbox:find('message.mode ~= "ground_apply"', 1, true),
    "ground_apply must have a dedicated validation boundary")
check(mailbox:find("command.ionPower == 0", 1, true),
    "first actuator stage must reject non-zero ion power")
check(mailbox:find("command.propRpm == 0", 1, true),
    "first actuator stage must reject non-zero prop RPM")
check(mailbox:find("command.tiltDegrees == 0", 1, true),
    "first actuator stage must reject non-zero tilt")
check(mailbox:find("command.azimuthDegrees == 0", 1, true),
    "first actuator stage must reject non-zero azimuth")
check(apply:find("controlMailbox.latest()", 1, true),
    "actuator worker must read only the newest mailbox entry")
check(apply:find("currentTime %- entry.receivedAt > entry.validForMs"),
    "stale entries must be rejected before actuator application")
check(apply:find("pcall(applyZero, 0)", 1, true),
    "ground stage must make a guarded exact-zero actuator call")
check(apply:find("controlMailbox.recordApply", 1, true),
    "applied sequence must be reported separately")
check(apply:find("controlMailbox.recordFallback", 1, true),
    "stale communication must trigger a recorded zero fallback")

print(string.format("pod direct-control architecture: %d passed, 0 failed", passed))
