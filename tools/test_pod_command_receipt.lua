local function readFile(path)
    local handle = assert(io.open(path, "r"))
    local source = handle:read("*a")
    handle:close()
    return source
end

local main = readFile("pod-template/pod/main.lua")
local mailbox = readFile("pod-template/pod/control_mailbox.lua")
local apply = readFile("pod-template/pod/control_apply.lua")
local props = readFile("pod-template/pod/props.lua")
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
check(main:find('local controlMailboxModule = require("pod.control_mailbox")', 1, true)
        and main:find("controlMailboxModule.new(config)", 1, true),
    "active pod must construct the wired control mailbox")
check(main:find('require("pod.control_apply").new(controlMailbox, thrusters, {', 1, true),
    "active pod must construct the independent actuator worker")
check(main:find("props = props", 1, true),
    "bearing application must receive the local prop/bearing API")
check(main:find("bearingPropRpm = controlMailboxModule.GROUND_BEARING_PROP_RPM", 1, true),
    "bearing worker must receive the same explicit RPM safety constant")
check(main:find("parallel.waitForAll(controlMailbox.receiveLoop, controlMailbox.statusLoop, controlApply.loop, samplerLoop, statusLoop, displayLoop)", 1, true),
    "wired receive, apply, sampling, status, and display loops must run independently")

check(mailbox:find('mailbox.PROTOCOL = "helicarrier.control-frame.v1"', 1, true),
    "mailbox protocol must remain explicit")
check(mailbox:find("mailbox.GROUND_BEARING_LIMIT_DEGREES = 5", 1, true),
    "ground bearing limit must remain explicit")
check(mailbox:find("mailbox.GROUND_BEARING_PROP_RPM = 8", 1, true),
    "ground bearing RPM must remain explicit")
check(mailbox:find('message.mode == "ground_apply"', 1, true),
    "ground_apply must retain a dedicated validation boundary")
check(mailbox:find('message.mode == "ground_bearing_test"', 1, true),
    "ground_bearing_test must have a separate validation boundary")
check(mailbox:find('message.mode == "ion_profile"', 1, true),
    "ion_profile must have a separate validation boundary")
check(mailbox:find("mailbox.ION_PROFILE_PROP_RPM = 8", 1, true),
    "ion profile prop RPM must remain explicit")
check(mailbox:find("command.propRpm == mailbox.ION_PROFILE_PROP_RPM", 1, true),
    "ion_profile must bound prop RPM to the explicit near-zero-lift value")
check(mailbox:find("command.ionPower == 0", 1, true),
    "ground modes must reject non-zero ion power")
check(mailbox:find("command.propRpm == 0", 1, true),
    "ground_apply must reject non-zero prop RPM")
check(mailbox:find("command.propRpm == mailbox.GROUND_BEARING_PROP_RPM", 1, true),
    "bearing mode must require the explicit safe prop RPM")
check(mailbox:find("command.tiltDegrees == 0", 1, true),
    "ground_apply must remain exact-zero tilt")
check(mailbox:find("command.azimuthDegrees == 0", 1, true),
    "ground modes must reject non-zero azimuth")
check(mailbox:find("command.tiltDegrees >= -mailbox.GROUND_BEARING_LIMIT_DEGREES", 1, true)
        and mailbox:find("command.tiltDegrees <= mailbox.GROUND_BEARING_LIMIT_DEGREES", 1, true),
    "bearing test tilt must remain bounded on both sides")
check(mailbox:find("appliedTiltDegrees = entry.command.tiltDegrees", 1, true),
    "successful applied bearing target must be exposed in status")
check(mailbox:find("appliedBearingState = state.appliedBearingState", 1, true),
    "physical bearing readback must ride in the existing status packet")

check(apply:find("controlMailbox.latest()", 1, true),
    "actuator worker must read only the newest mailbox entry")
check(apply:find("now %- entry.receivedAt > entry.validForMs"),
    "stale entries must be rejected before actuator application")
check(apply:find("local ok, result = pcall(function()", 1, true),
    "ground actuator calls must remain guarded")
check(apply:find("timings[name] = (timings[name] or 0)", 1, true),
    "every actuator stage must be timed separately, because a per-apply maximum"
        .. " cannot show which peripheral call is the expensive one")
check(apply:find('timings[name .. "Skipped"]', 1, true),
    "write-elision must expose skipped actuator stages")
check(apply:find("invalidateAppliedCache()", 1, true)
        and apply:find("prepareSession(entry.session)", 1, true),
    "session changes and stale fallback must invalidate write-elision state")
check(mailbox:find("readbackApplies = state.stageCounts.readback", 1, true),
    "the count of applies carrying a readback must be reported, so a slow lane"
        .. " can be told from an unchanged one")
check(apply:find('timed("ion", 0, nil, applyIonZero, 0)', 1, true),
    "every active ground mode must force exact-zero ion power")
check(apply:find('timed("rpm", propRpm, nil, applyRpm, propRpm)', 1, true),
    "bearing mode must apply the guarded requested RPM")
check(apply:find("local propRpm = forceSafe and 0 or entry.command.propRpm", 1, true),
    "bearing fallback must force zero prop RPM")
check(apply:find('timed("tilt", tilt, 0, applyTilt, tilt)', 1, true),
    "bearing mode must use the local bearing setter")
check(apply:find("local tilt = forceSafe and 0 or entry.command.tiltDegrees", 1, true),
    "bearing fallback must force zero tilt")
check(apply:find("controlMailbox.recordApply", 1, true),
    "applied sequence must be reported separately")
check(apply:find("controlMailbox.recordFallback", 1, true),
    "stale communication must trigger a recorded safe fallback")
check(props:find('sample("getTiltAngle")', 1, true)
        and props:find('sample("getStabilizationStrength")', 1, true)
        and props:find('sample("getRotationSpeed")', 1, true),
    "physical gyro tilt, stabilization, and rotation must be sampled locally")

print(string.format("pod direct-control architecture: %d passed, 0 failed", passed))
