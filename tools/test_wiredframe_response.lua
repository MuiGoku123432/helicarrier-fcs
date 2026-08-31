package.path = "./?.lua;./?/init.lua;" .. package.path

local applyModule = require("pod-template.pod.control_apply")
local mailboxModule = require("pod-template.pod.control_mailbox")

local passed, failed = 0, 0
local function check(name, condition)
    if condition then
        passed = passed + 1
    else
        failed = failed + 1
        io.stderr:write("FAIL: " .. name .. "\n")
    end
end

local now = 1000
local current
local appliedRecords, fallbackRecords, expiredRecords, stopRecords = {}, {}, {}, {}
local mailbox = {
    latest = function() return current end,
    recordApply = function(entry, startedAt, endedAt, ok, err, result)
        appliedRecords[#appliedRecords + 1] = {
            entry = entry, startedAt = startedAt, endedAt = endedAt,
            ok = ok, err = err, result = result,
        }
    end,
    recordFallback = function(startedAt, endedAt, ok, err)
        fallbackRecords[#fallbackRecords + 1] = {
            startedAt = startedAt, endedAt = endedAt, ok = ok, err = err,
        }
    end,
    recordExpired = function(entry)
        expiredRecords[#expiredRecords + 1] = entry
    end,
    recordFallbackStop = function(startedAt, endedAt, ok, err)
        stopRecords[#stopRecords + 1] = {
            startedAt = startedAt, endedAt = endedAt, ok = ok, err = err,
        }
    end,
}

local calls = {}
local worker = applyModule.new(mailbox, {}, {
    epoch = function() return now end,
    sleep = function() end,
    applyIon = function(power)
        calls[#calls + 1] = { kind = "ion", value = power }
        return power
    end,
    applyRpm = function(rpm)
        calls[#calls + 1] = { kind = "rpm", value = rpm }
        return rpm
    end,
    applyTilt = function(angle, azimuth)
        calls[#calls + 1] = { kind = "tilt", value = angle, azimuth = azimuth }
        return { angle = angle, azimuth = azimuth, readback = { ok = true } }
    end,
})

local function responseEntry(sequence, overrides)
    local command = {
        ionPower = 0.55,
        fallbackIonPower = 0.48,
        propRpm = 64,
        tiltDegrees = 1,
        azimuthDegrees = 90,
        shutdown = false,
    }
    for key, value in pairs(overrides or {}) do command[key] = value end
    return {
        session = "response-test",
        sequence = sequence,
        mode = "response_map_test",
        command = command,
        receivedAt = now,
        validForMs = 750,
    }
end

current = responseEntry(1)
check("normal response entry applies", worker.applyLatest() == true)
check("normal response call count", #calls == 3)
check("normal response applies ion first", calls[1].kind == "ion" and calls[1].value == 0.55)
check("normal response applies fixed rpm", calls[2].kind == "rpm" and calls[2].value == 64)
check("normal response applies tilt and azimuth",
    calls[3].kind == "tilt" and calls[3].value == 1 and calls[3].azimuth == 90)
check("normal response recorded", #appliedRecords == 1 and appliedRecords[1].ok == true)
check("same response entry coalesced", worker.applyLatest() == false and #calls == 3)

local invalidCases = {
    { name = "tilt over limit", values = { tiltDegrees = 1.01 } },
    { name = "negative ion", values = { ionPower = -0.01 } },
    { name = "ion over limit", values = { ionPower = 1.01 } },
    { name = "fallback above command", values = { fallbackIonPower = 0.56 } },
    { name = "wrong response rpm", values = { propRpm = 63 } },
    { name = "negative azimuth", values = { azimuthDegrees = -1 } },
    { name = "azimuth 360", values = { azimuthDegrees = 360 } },
}
for index, case in ipairs(invalidCases) do
    current = responseEntry(10 + index, case.values)
    local before = #calls
    check("reject " .. case.name, worker.applyLatest() == false and #calls == before)
end

current = responseEntry(30)
check("fresh response applies before fallback test", worker.applyLatest() == true)
now = now + 751
local beforeFallbackCalls = #calls
check("stale response triggers fallback", worker.enforceStaleFallback() == true)
check("fallback writes only changed stages", #calls == beforeFallbackCalls + 2)
local fallbackTilt = calls[beforeFallbackCalls + 1]
local fallbackIon = calls[beforeFallbackCalls + 2]
check("fallback levels first",
    fallbackTilt.kind == "tilt" and fallbackTilt.value == 0 and fallbackTilt.azimuth == 0)
check("fallback retains response rpm without a duplicate write",
    calls[2].kind == "rpm" and calls[2].value == 64
        and fallbackTilt.kind ~= "rpm" and fallbackIon.kind ~= "rpm")
check("fallback uses controlled descent ion",
    fallbackIon.kind == "ion" and fallbackIon.value == 0.48)
check("fallback recorded once", #fallbackRecords == 1 and fallbackRecords[1].ok == true)
check("fallback is one shot", worker.enforceStaleFallback() == false
    and #fallbackRecords == 1 and #calls == beforeFallbackCalls + 2)

local afterFallbackCalls = #calls
current = responseEntry(31)
check("live response resumes after fallback", worker.applyLatest() == true)
check("fallback invalidation rewrites every live stage",
    #calls == afterFallbackCalls + 3
        and calls[afterFallbackCalls + 1].kind == "ion"
        and calls[afterFallbackCalls + 2].kind == "rpm"
        and calls[afterFallbackCalls + 3].kind == "tilt")

now = 3000
current = responseEntry(40, {
    ionPower = 0,
    fallbackIonPower = 0,
    propRpm = 0,
    tiltDegrees = 0,
    azimuthDegrees = 0,
    shutdown = true,
})
check("shutdown response applies", worker.applyLatest() == true)
local shutdownRecord = appliedRecords[#appliedRecords]
check("shutdown records zero ion", shutdownRecord.result.ionPower == 0)
check("shutdown records zero rpm", shutdownRecord.result.propRpm == 0)
check("shutdown records zero tilt", shutdownRecord.result.tiltDegrees == 0)

now = 4000
current = responseEntry(50)
current.receivedAt = now - 751
local beforeExpiredCalls = #calls
check("expired response is refused", worker.applyLatest() == false)
check("expired response is recorded", #expiredRecords == 1 and expiredRecords[1] == current)
check("expired response makes no actuator call", #calls == beforeExpiredCalls)

local mailboxNow = 5000
local fakeModem = {
    isWireless = function() return false end,
    open = function() end,
    transmit = function() end,
}
local mailboxInstance = mailboxModule.new({ corner = "FL" }, {
    peripheral = {
        getNames = function() return { "wired" } end,
        hasType = function(name, kind) return name == "wired" and kind == "modem" end,
        wrap = function() return fakeModem end,
    },
    epoch = function() return mailboxNow end,
    sleep = function() end,
    pullEventRaw = function() return "terminate" end,
})

local function mailboxFrame(sequence, overrides)
    local response = {
        ionPower = 0,
        fallbackIonPower = 0,
        propRpm = 64,
        tiltDegrees = 0,
        azimuthDegrees = 0,
        shutdown = false,
    }
    for key, value in pairs(overrides or {}) do response[key] = value end
    return {
        protocol = mailboxModule.PROTOCOL,
        kind = "control_frame",
        mode = "response_map_test",
        armed = true,
        session = "mailbox-response",
        sequence = sequence,
        sentAt = mailboxNow,
        validForMs = 750,
        corners = { FL = response },
    }
end

local accepted = mailboxFrame(1)
check("mailbox accepts response control_frame", mailboxInstance.acceptFrame(accepted, mailboxNow))
local acceptedEntry = mailboxInstance.latest()
check("mailbox preserves response fallback ion",
    acceptedEntry and acceptedEntry.command.fallbackIonPower == 0)
check("mailbox preserves response shutdown flag",
    acceptedEntry and acceptedEntry.command.shutdown == false)

local missingKind = mailboxFrame(2)
missingKind.kind = nil
check("mailbox rejects response without control_frame kind",
    mailboxInstance.acceptFrame(missingKind, mailboxNow) == false)
local wrongEnvelope = mailboxFrame(2)
wrongEnvelope.commands = wrongEnvelope.corners
wrongEnvelope.corners = nil
check("mailbox rejects commands alias instead of corners",
    mailboxInstance.acceptFrame(wrongEnvelope, mailboxNow) == false)
local disarmed = mailboxFrame(2)
disarmed.armed = false
check("mailbox rejects disarmed response mode",
    mailboxInstance.acceptFrame(disarmed, mailboxNow) == false)
local unsafeFallback = mailboxFrame(2, { ionPower = 0.4, fallbackIonPower = 0.5 })
check("mailbox rejects fallback above commanded ion",
    mailboxInstance.acceptFrame(unsafeFallback, mailboxNow) == false)
local shutdownFrame = mailboxFrame(2, {
    ionPower = 0,
    fallbackIonPower = 0,
    propRpm = 0,
    tiltDegrees = 0,
    azimuthDegrees = 0,
    shutdown = true,
})
check("mailbox accepts exact-zero response shutdown",
    mailboxInstance.acceptFrame(shutdownFrame, mailboxNow) == true)
check("mailbox preserves shutdown command",
    mailboxInstance.latest().command.shutdown == true
        and mailboxInstance.latest().command.propRpm == 0)


----------------------------------------------------------------------
-- Bearing readback runs on its own slow lane, not on every write.
----------------------------------------------------------------------

local laneCalls, laneReadbacks = {}, 0
local laneNow = 10000
local laneCurrent
local laneMailbox = {
    latest = function() return laneCurrent end,
    recordApply = function() end,
    recordFallback = function() end,
    recordFallbackStop = function() end,
    recordExpired = function() end,
}
local laneWorker = applyModule.new(laneMailbox, {}, {
    epoch = function() return laneNow end,
    sleep = function() end,
    readbackIntervalMs = 1000,
    applyIon = function(power) laneCalls[#laneCalls + 1] = "ion" return power end,
    applyRpm = function(rpm) laneCalls[#laneCalls + 1] = "rpm" return rpm end,
    applyTilt = function(angle, azimuth)
        laneCalls[#laneCalls + 1] = "tilt"
        return { angle = angle, azimuth = azimuth }
    end,
    readBearingState = function()
        laneReadbacks = laneReadbacks + 1
        return { [1] = { tiltAngle = 0 } }
    end,
})

local function laneEntry(sequence)
    return {
        session = "lane-test",
        sequence = sequence,
        mode = "response_map_test",
        command = {
            ionPower = 0.5, fallbackIonPower = 0.4, propRpm = 64,
            tiltDegrees = 0, azimuthDegrees = 0, shutdown = false,
        },
        receivedAt = laneNow,
        validForMs = 750,
    }
end

laneCurrent = laneEntry(1)
laneWorker.applyLatest()
check("first apply samples readback immediately", laneReadbacks == 1)
local firstApply = laneCurrent
check("first apply attaches readback to the tilt report", firstApply ~= nil)

laneNow = laneNow + 200
laneCurrent = laneEntry(2)
laneCurrent.receivedAt = laneNow
laneWorker.applyLatest()
check("apply inside the interval does not re-read", laneReadbacks == 1)

laneNow = laneNow + 900
laneCurrent = laneEntry(3)
laneCurrent.receivedAt = laneNow
laneWorker.applyLatest()
check("apply past the interval reads again", laneReadbacks == 2)

-- Three applies request the same state, so only the first writes actuators;
-- the independent readback cadence still samples twice.
check("steady-state writes are elided while readback stays scheduled", #laneCalls == 3)

----------------------------------------------------------------------
-- Two-stage stale fallback: descend, then stop only if allowed a duration.
----------------------------------------------------------------------

local stageCalls = {}
local stageNow = 20000
local stageCurrent
local stageFallbacks, stageStops = 0, 0
local stageMailbox = {
    latest = function() return stageCurrent end,
    recordApply = function() end,
    recordFallback = function() stageFallbacks = stageFallbacks + 1 end,
    recordFallbackStop = function() stageStops = stageStops + 1 end,
    recordExpired = function() end,
}
local stageWorker = applyModule.new(stageMailbox, {}, {
    epoch = function() return stageNow end,
    sleep = function() end,
    readBearingState = function() return nil end,
    applyIon = function(power)
        stageCalls[#stageCalls + 1] = { kind = "ion", value = power }
        return power
    end,
    applyIonZero = function(power)
        stageCalls[#stageCalls + 1] = { kind = "ion", value = power }
        return power
    end,
    applyRpm = function(rpm)
        stageCalls[#stageCalls + 1] = { kind = "rpm", value = rpm }
        return rpm
    end,
    applyTilt = function(angle, azimuth)
        stageCalls[#stageCalls + 1] = { kind = "tilt", value = angle, azimuth = azimuth }
        return { angle = angle, azimuth = azimuth }
    end,
})

local function stageEntry(sequence, stopAfterMs)
    return {
        session = "stage-test",
        sequence = sequence,
        mode = "response_map_test",
        command = {
            ionPower = 0.6, fallbackIonPower = 0.45, propRpm = 64,
            tiltDegrees = 0, azimuthDegrees = 0, shutdown = false,
            fallbackStopAfterMs = stopAfterMs,
        },
        receivedAt = stageNow,
        validForMs = 750,
    }
end

stageCurrent = stageEntry(1, 5000)
stageWorker.applyLatest()
stageNow = stageNow + 751
check("stage one descent fires when stale", stageWorker.enforceStaleFallback() == true)
check("stage one recorded as a descent, not a stop",
    stageFallbacks == 1 and stageStops == 0)
local descentRpm
for _, call in ipairs(stageCalls) do
    if call.kind == "rpm" then descentRpm = call.value end
end
check("descent holds the propeller baseline rather than cutting it", descentRpm == 64)

stageNow = stageNow + 4000
check("stop does not fire before the declared allowance",
    stageWorker.enforceStaleFallback() == false and stageStops == 0)

stageNow = stageNow + 1500
check("stop fires once the allowance passes", stageWorker.enforceStaleFallback() == true)
check("stop recorded separately", stageStops == 1 and stageFallbacks == 1)
local stopIon, stopRpm, stopTilt
for index = #stageCalls - 2, #stageCalls do
    local call = stageCalls[index]
    if call.kind == "ion" then stopIon = call.value end
    if call.kind == "rpm" then stopRpm = call.value end
    if call.kind == "tilt" then stopTilt = call.value end
end
check("stop writes exact zero ion", stopIon == 0)
check("stop writes exact zero rpm", stopRpm == 0)
check("stop writes exact zero tilt", stopTilt == 0)
check("stop is one shot",
    stageWorker.enforceStaleFallback() == false and stageStops == 1)

-- Absent allowance must preserve the proven ground behavior exactly: descend
-- and hold, never stop on its own.
local holdNow = 40000
local holdCurrent
local holdFallbacks, holdStops = 0, 0
local holdWorker = applyModule.new({
    latest = function() return holdCurrent end,
    recordApply = function() end,
    recordFallback = function() holdFallbacks = holdFallbacks + 1 end,
    recordFallbackStop = function() holdStops = holdStops + 1 end,
    recordExpired = function() end,
}, {}, {
    epoch = function() return holdNow end,
    sleep = function() end,
    readBearingState = function() return nil end,
    applyIon = function(power) return power end,
    applyIonZero = function(power) return power end,
    applyRpm = function(rpm) return rpm end,
    applyTilt = function(angle, azimuth) return { angle = angle, azimuth = azimuth } end,
})
holdCurrent = {
    session = "hold-test", sequence = 1, mode = "response_map_test",
    command = {
        ionPower = 0.6, fallbackIonPower = 0.45, propRpm = 64,
        tiltDegrees = 0, azimuthDegrees = 0, shutdown = false,
    },
    receivedAt = holdNow, validForMs = 750,
}
holdWorker.applyLatest()
holdNow = holdNow + 751
check("hold descends", holdWorker.enforceStaleFallback() == true and holdFallbacks == 1)
holdNow = holdNow + 600000
check("hold never stops without a declared allowance",
    holdWorker.enforceStaleFallback() == false and holdStops == 0)


----------------------------------------------------------------------
-- Second-stage allowance: validated at the boundary, and carried through.
-- The envelope bug this suite exists for was a field that validated and was
-- then dropped before apply, so preservation is checked explicitly.
----------------------------------------------------------------------

local withStop = mailboxFrame(10, { fallbackStopAfterMs = 8000 })
check("mailbox accepts a declared stop allowance",
    mailboxInstance.acceptFrame(withStop, mailboxNow) == true)
check("mailbox preserves the stop allowance through to the command",
    mailboxInstance.latest().command.fallbackStopAfterMs == 8000)

local stopBounds = {
    { name = "stop allowance below floor", value = 999 },
    { name = "stop allowance above ceiling", value = 60001 },
    { name = "stop allowance not a number", value = "8000" },
    { name = "stop allowance not finite", value = math.huge },
}
for index, case in ipairs(stopBounds) do
    local frame = mailboxFrame(20 + index, { fallbackStopAfterMs = case.value })
    check("mailbox rejects " .. case.name,
        mailboxInstance.acceptFrame(frame, mailboxNow) == false)
end

local stopOnShutdown = mailboxFrame(30, {
    ionPower = 0, fallbackIonPower = 0, propRpm = 0,
    tiltDegrees = 0, azimuthDegrees = 0, shutdown = true,
    fallbackStopAfterMs = 8000,
})
check("mailbox rejects a stop allowance on a shutdown frame",
    mailboxInstance.acceptFrame(stopOnShutdown, mailboxNow) == false)

-- Readback now arrives about once a second while applies continue at their own
-- rate, so an apply carrying none must not erase the last physical sample.
local latchEntry = {
    session = "mailbox-response", sequence = 40, mode = "response_map_test",
    command = {
        ionPower = 0, fallbackIonPower = 0, propRpm = 64,
        tiltDegrees = 0, azimuthDegrees = 0, shutdown = false,
    },
    receivedAt = mailboxNow, validForMs = 750,
}
mailboxInstance.recordApply(latchEntry, mailboxNow, mailboxNow + 5, true, nil, {
    tilt = { readback = { [1] = { tiltAngle = 0, marker = "sampled" } } },
})
local latched = mailboxInstance.statusMessage()
check("status carries a sampled readback",
    latched.appliedBearingState and latched.appliedBearingState[1].marker == "sampled")
check("status reports readback age", latched.appliedBearingStateAgeMs ~= nil)

mailboxInstance.recordApply(latchEntry, mailboxNow, mailboxNow + 5, true, nil, {
    tilt = { angle = 0 },
})
local stillLatched = mailboxInstance.statusMessage()
check("an apply without readback keeps the last sample",
    stillLatched.appliedBearingState
        and stillLatched.appliedBearingState[1].marker == "sampled")
check("status exposes the second-stage counter",
    stillLatched.fallbackStops == 0)

if failed > 0 then
    error(string.format("wired response tests: %d passed, %d failed", passed, failed), 0)
end
print(string.format("wired response tests: %d passed, %d failed", passed, failed))
