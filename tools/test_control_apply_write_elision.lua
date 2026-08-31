local applyModule = dofile("pod-template/pod/control_apply.lua")

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message, 2) end
end

local function command(overrides)
    local value = {
        ionPower = 0.5,
        fallbackIonPower = 0.2,
        fallbackStopAfterMs = 50,
        propRpm = 64,
        tiltDegrees = 0,
        azimuthDegrees = 0,
        shutdown = false,
    }
    for key, replacement in pairs(overrides or {}) do value[key] = replacement end
    return value
end

local function harness(options)
    options = options or {}
    local now = 1000
    local entry = {
        session = "session-a",
        sequence = 1,
        mode = "response_map_test",
        receivedAt = now,
        validForMs = 100,
        command = command(),
    }
    local calls = { ion = {}, rpm = {}, tilt = {} }
    local records = { apply = {}, fallback = {}, stop = {}, expired = {} }
    local rpmFailures = options.rpmFailures or 0

    local mailbox = {}
    function mailbox.latest() return entry end
    function mailbox.recordApply(_, _, _, ok, err, applied)
        records.apply[#records.apply + 1] = { ok = ok, err = err, applied = applied }
    end
    function mailbox.recordFallback(_, _, ok, err)
        records.fallback[#records.fallback + 1] = { ok = ok, err = err }
    end
    function mailbox.recordFallbackStop(_, _, ok, err)
        records.stop[#records.stop + 1] = { ok = ok, err = err }
    end
    function mailbox.recordExpired(expired)
        records.expired[#records.expired + 1] = expired
    end

    local worker = applyModule.new(mailbox, {}, {
        epoch = function() return now end,
        readBearingState = options.readBearingState or function() return nil end,
        applyIon = function(value)
            calls.ion[#calls.ion + 1] = value
            return value
        end,
        applyIonZero = function(value)
            calls.ion[#calls.ion + 1] = value
            return value
        end,
        applyRpm = function(value)
            calls.rpm[#calls.rpm + 1] = value
            if rpmFailures > 0 then
                rpmFailures = rpmFailures - 1
                error("injected rpm failure", 0)
            end
            return value
        end,
        applyTilt = function(angle, azimuth)
            calls.tilt[#calls.tilt + 1] = { angle = angle, azimuth = azimuth or 0 }
            return { angle = angle, azimuth = azimuth or 0 }
        end,
    })

    return {
        worker = worker,
        calls = calls,
        records = records,
        entry = function() return entry end,
        setEntry = function(value) entry = value end,
        now = function() return now end,
        setNow = function(value) now = value end,
    }
end

local h = harness()
expect(h.worker.applyLatest(), "first command should apply")
expect(#h.calls.ion == 1 and #h.calls.rpm == 1 and #h.calls.tilt == 1,
    "first command must write all fields")

local prior = h.entry()
h.setEntry({
    session = prior.session,
    sequence = 2,
    mode = prior.mode,
    receivedAt = h.now(),
    validForMs = prior.validForMs,
    command = command(),
})
expect(h.worker.applyLatest(), "same-value command should still be acknowledged")
expect(#h.calls.ion == 1 and #h.calls.rpm == 1 and #h.calls.tilt == 1,
    "same-value command should elide all peripheral writes")
local skipped = h.records.apply[#h.records.apply].applied.timings
expect(skipped.ionSkipped == 1 and skipped.rpmSkipped == 1 and skipped.tiltSkipped == 1,
    "elided stages should be visible in apply timings")

local readback = harness({
    readBearingState = function() return { { tiltAngle = 0 } } end,
})
expect(readback.worker.applyLatest(), "readback fixture should apply first command")
local firstReadback = readback.records.apply[#readback.records.apply].applied
expect(firstReadback.tilt.readback ~= nil, "first write should carry its readback sample")
local readbackEntry = readback.entry()
readback.setEntry({
    session = readbackEntry.session,
    sequence = 2,
    mode = readbackEntry.mode,
    receivedAt = readback.now(),
    validForMs = readbackEntry.validForMs,
    command = command(),
})
expect(readback.worker.applyLatest(), "readback fixture should accept skipped command")
local skippedReadback = readback.records.apply[#readback.records.apply].applied
expect(skippedReadback.tilt.readback == nil,
    "skipped tilt must not replay an old readback as a fresh sample")

prior = h.entry()
h.setEntry({
    session = "session-b",
    sequence = 1,
    mode = prior.mode,
    receivedAt = h.now(),
    validForMs = prior.validForMs,
    command = command(),
})
expect(h.worker.applyLatest(), "new session command should apply")
expect(#h.calls.ion == 2 and #h.calls.rpm == 2 and #h.calls.tilt == 2,
    "new session must invalidate cache and rewrite all fields")

h.setNow(1200)
expect(h.worker.enforceStaleFallback(), "stale command should enter fallback")
expect(#h.records.fallback == 1, "fallback should be recorded once")
local afterFallback = {
    ion = #h.calls.ion,
    rpm = #h.calls.rpm,
    tilt = #h.calls.tilt,
}
h.setEntry({
    session = "session-b",
    sequence = 2,
    mode = "response_map_test",
    receivedAt = h.now(),
    validForMs = 100,
    command = command(),
})
expect(h.worker.applyLatest(), "command after fallback should apply")
expect(#h.calls.ion == afterFallback.ion + 1
        and #h.calls.rpm == afterFallback.rpm + 1
        and #h.calls.tilt == afterFallback.tilt + 1,
    "fallback must invalidate cache so every field is rewritten")

h.setNow(1400)
expect(h.worker.enforceStaleFallback(), "second stale command should enter fallback")
h.setNow(1460)
expect(h.worker.enforceStaleFallback(), "fallback timeout should enter terminal stop")
expect(#h.records.stop == 1, "terminal stop should be recorded once")
local afterStop = {
    ion = #h.calls.ion,
    rpm = #h.calls.rpm,
    tilt = #h.calls.tilt,
}
h.setEntry({
    session = "session-b",
    sequence = 3,
    mode = "response_map_test",
    receivedAt = h.now(),
    validForMs = 100,
    command = command({ ionPower = 0, fallbackIonPower = 0 }),
})
expect(h.worker.applyLatest(), "command after terminal stop should apply")
expect(#h.calls.ion == afterStop.ion + 1
        and #h.calls.rpm == afterStop.rpm + 1
        and #h.calls.tilt == afterStop.tilt + 1,
    "terminal stop must invalidate cache so every field is rewritten")

local failed = harness({ rpmFailures = 1 })
expect(not failed.worker.applyLatest(), "injected RPM failure should fail apply")
expect(#failed.calls.ion == 1 and #failed.calls.rpm == 1 and #failed.calls.tilt == 0,
    "failed apply should stop after RPM")
expect(failed.worker.applyLatest(), "failed entry should retry")
expect(#failed.calls.ion == 1, "successful ion write should remain cached across retry")
expect(#failed.calls.rpm == 2, "failed RPM write must not enter cache")
expect(#failed.calls.tilt == 1, "retry should continue through tilt")

print(string.format("control apply write-elision tests: PASS (%d checks)", checks))
