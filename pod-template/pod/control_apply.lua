-- Independent actuator worker for direct-wired control frames.
-- Reception remains free while these peripheral calls yield.

local apply = {}

function apply.new(controlMailbox, thrusterApi, dependencies)
    dependencies = dependencies or {}
    local epoch = dependencies.epoch or function() return os.epoch("utc") end
    local sleepFor = dependencies.sleep or sleep
    local propsApi = dependencies.props
    local bearingLimit = dependencies.bearingLimit or 1
    local bearingPropRpm = dependencies.bearingPropRpm or 8
    local responseBearingLimit = dependencies.responseBearingLimit or 1
    local responsePropRpm = dependencies.responsePropRpm or 64
    local responseIonMin = dependencies.responseIonMin or 0
    local responseIonMax = dependencies.responseIonMax or 1

    local applyIonZero = dependencies.applyIonZero or dependencies.applyZero
        or function(power) return thrusterApi.applyExact(power) end
    local applyIon = dependencies.applyIon or applyIonZero
    local applyRpm = dependencies.applyRpm or dependencies.applyRpmZero
        or function(rpm)
            if not propsApi or type(propsApi.setRpm) ~= "function" then
                error("direct control requires props.setRpm", 0)
            end
            return propsApi.setRpm(rpm)
        end
    local applyTilt = dependencies.applyTilt
        or function(angle, azimuth)
            if not propsApi or type(propsApi.setTilt) ~= "function" then
                error("direct control requires props.setTilt", 0)
            end
            return propsApi.setTilt(angle, azimuth or 0, nil, true)
        end

    -- Bearing readback is twelve peripheral calls -- six methods on each of two
    -- bearings. It proved spool-up for the ground gate, but it is confirmation,
    -- not control feedback: the controller already knows what it commanded and
    -- the pod acknowledges what it applied. Running it on every write inflated
    -- apply latency for no control benefit, so it now runs on its own slow lane
    -- and the mailbox latches the last sample.
    local readbackIntervalMs = dependencies.readbackIntervalMs or 1000
    local readBearingState = dependencies.readBearingState
        or function()
            if not propsApi or type(propsApi.readBearingState) ~= "function" then
                return nil
            end
            return propsApi.readBearingState()
        end
    local lastReadbackAt

    local handledSession, handledSequence
    local fallbackSession, fallbackSequence
    local fallbackStartedAt
    local stopSession, stopSequence

    -- Cache only values whose peripheral call returned successfully. A new
    -- session invalidates the whole cache so its first command reasserts every
    -- actuator field even when it happens to match the previous session.
    local appliedCache = {}
    local cacheSession

    local function invalidateAppliedCache()
        appliedCache = {}
    end

    local function prepareSession(session)
        if cacheSession ~= session then
            invalidateAppliedCache()
            cacheSession = session
        end
    end

    local function finite(value)
        return type(value) == "number" and value == value
            and value > -math.huge and value < math.huge
    end

    -- Due immediately on the first apply so a gate sees physical state at once
    -- rather than waiting out a full interval.
    local function readbackDue(now)
        return lastReadbackAt == nil
            or (now - lastReadbackAt) >= readbackIntervalMs
    end

    local function attachReadback(applied, now)
        if type(applied.tilt) ~= "table" or not readbackDue(now) then return false end
        local ok, readings = pcall(readBearingState)
        -- A failed readback must not fail the write that already succeeded.
        if ok and readings ~= nil then
            applied.tilt.readback = readings
        end
        lastReadbackAt = now
        return true
    end

    local function sameEntry(entry)
        return entry and entry.session == handledSession
            and entry.sequence == handledSequence
    end

    local function markHandled(entry)
        handledSession = entry.session
        handledSequence = entry.sequence
        fallbackSession = nil
        fallbackSequence = nil
        fallbackStartedAt = nil
        stopSession = nil
        stopSequence = nil
    end

    local function safeControlEntry(entry)
        local command = entry and entry.command
        if not entry or type(command) ~= "table" then return false end

        if entry.mode == "ground_apply" then
            return command.ionPower == 0
                and command.propRpm == 0
                and command.tiltDegrees == 0
                and command.azimuthDegrees == 0
        end

        if entry.mode == "ground_bearing_test" then
            return command.ionPower == 0
                and command.propRpm == bearingPropRpm
                and finite(command.tiltDegrees)
                and command.tiltDegrees >= -bearingLimit
                and command.tiltDegrees <= bearingLimit
                and command.azimuthDegrees == 0
        end

        local responseMode = entry.mode == "response_map_test"
        local stationkeepMode = entry.mode == "stationkeep"
        if responseMode or stationkeepMode then
            if command.shutdown == true then
                return command.ionPower == 0
                    and command.fallbackIonPower == 0
                    and command.propRpm == 0
                    and command.tiltDegrees == 0
                    and command.azimuthDegrees == 0
            end

            local tiltLimit = stationkeepMode and 6 or responseBearingLimit
            return command.shutdown == false
                and finite(command.ionPower)
                and command.ionPower >= responseIonMin
                and command.ionPower <= responseIonMax
                and finite(command.fallbackIonPower)
                and command.fallbackIonPower >= responseIonMin
                and command.fallbackIonPower <= command.ionPower
                and command.propRpm == responsePropRpm
                and finite(command.tiltDegrees)
                and command.tiltDegrees >= -tiltLimit
                and command.tiltDegrees <= tiltLimit
                and finite(command.azimuthDegrees)
                and command.azimuthDegrees >= 0
                and command.azimuthDegrees < 360
        end

        return false
    end

    -- Per-stage timing. `max_apply_ms` is a maximum over whole applies, so it
    -- cannot show which call inside an apply is expensive, and it stays pinned
    -- to the slowest apply even when most applies get cheaper. These break the
    -- apply into its actual peripheral stages.
    local function runWrite(entry, forceSafe)
        local startedAt = epoch()
        local timings = {}
        local function cloneResult(value)
            if type(value) ~= "table" then return value end
            local copy = {}
            for key, item in pairs(value) do
                if key ~= "readback" then copy[key] = item end
            end
            return copy
        end
        local function timed(name, requestedA, requestedB, fn, a, b)
            local cached = appliedCache[name]
            if cached and cached.requestedA == requestedA
                    and cached.requestedB == requestedB then
                timings[name] = timings[name] or 0
                timings[name .. "Skipped"] = (timings[name .. "Skipped"] or 0) + 1
                return cloneResult(cached.result)
            end

            local calledAt = epoch()
            local value = fn(a, b)
            timings[name] = (timings[name] or 0) + (epoch() - calledAt)
            appliedCache[name] = {
                requestedA = requestedA,
                requestedB = requestedB,
                -- Readback is attached later and must never be replayed as a
                -- fresh sample when this peripheral write is skipped.
                result = cloneResult(value),
            }
            return value
        end
        local ok, result = pcall(function()
            local command = entry.command
            local responseMode = entry.mode == "response_map_test"
                or entry.mode == "stationkeep"
            local bearingMode = entry.mode == "ground_bearing_test" or responseMode
            local ionPower = responseMode
                and (forceSafe and command.fallbackIonPower or command.ionPower)
                or 0
            -- These expressions preserve the proven ground behavior exactly.
            local propRpm = forceSafe and 0 or entry.command.propRpm
            local tilt = forceSafe and 0 or entry.command.tiltDegrees
            local azimuth = 0
            if responseMode then
                -- Response fallback retains the validated prop baseline while
                -- leveling the bearings and applying controlled descent.
                propRpm = command.propRpm
                azimuth = forceSafe and 0 or command.azimuthDegrees
            end

            local applied = {}
            local writeAt = startedAt
            if responseMode and forceSafe then
                if bearingMode then
                    applied.tilt = timed("tilt", tilt, azimuth, applyTilt, tilt, azimuth)
                    applied.tiltDegrees = tilt
                    applied.azimuthDegrees = azimuth
                    applied.propRpm = timed("rpm", propRpm, nil, applyRpm, propRpm)
                end
                applied.ionPower = timed("ion", ionPower, nil, applyIon, ionPower)
            else
                applied.ionPower = responseMode
                    and timed("ion", ionPower, nil, applyIon, ionPower)
                    or timed("ion", 0, nil, applyIonZero, 0)
                if bearingMode then
                    applied.propRpm = timed("rpm", propRpm, nil, applyRpm, propRpm)
                    if responseMode then
                        applied.tilt = timed("tilt", tilt, azimuth, applyTilt, tilt, azimuth)
                    else
                        applied.tilt = timed("tilt", tilt, 0, applyTilt, tilt)
                    end
                    applied.tiltDegrees = tilt
                    applied.azimuthDegrees = azimuth
                end
            end
            local readbackAt = epoch()
            local sampled = attachReadback(applied, writeAt)
            if sampled then
                timings.readback = epoch() - readbackAt
                timings.readbackCount = 1
            end
            applied.timings = timings
            return applied
        end)
        local endedAt = epoch()
        return startedAt, endedAt, ok, result
    end

    -- Terminal fallback. Writes the exact-zero state that ground shutdown
    -- already proves, and is deliberately not routed through runWrite so no
    -- mode's command values can reach it.
    local function runStop()
        local startedAt = epoch()
        local ok, result = pcall(function()
            local applied = {}
            applied.ionPower = applyIonZero(0)
            applied.tilt = applyTilt(0, 0)
            applied.tiltDegrees = 0
            applied.azimuthDegrees = 0
            applied.propRpm = applyRpm(0)
            return applied
        end)
        return startedAt, epoch(), ok, result
    end

    local instance = {}

    function instance.applyLatest()
        local entry = controlMailbox.latest()
        if not safeControlEntry(entry) or sameEntry(entry) then return false end

        local now = epoch()
        prepareSession(entry.session)
        if now - entry.receivedAt > entry.validForMs then
            controlMailbox.recordExpired(entry)
            markHandled(entry)
            return false
        end

        local startedAt, endedAt, ok, result = runWrite(entry, false)
        controlMailbox.recordApply(entry, startedAt, endedAt, ok,
            ok and nil or result, ok and result or nil)
        if ok then markHandled(entry) end
        return ok
    end

    function instance.enforceStaleFallback()
        local entry = controlMailbox.latest()
        if not safeControlEntry(entry) then return false end

        local now = epoch()
        if now - entry.receivedAt <= entry.validForMs then return false end

        local alreadyDescending = fallbackSession == entry.session
            and fallbackSequence == entry.sequence
        if not alreadyDescending then
            prepareSession(entry.session)
            local startedAt, endedAt, ok, result = runWrite(entry, true)
            -- A fallback changes the safety epoch. The next live command must
            -- rewrite every field even when it requests the same values.
            invalidateAppliedCache()
            controlMailbox.recordFallback(startedAt, endedAt, ok, ok and nil or result)
            fallbackSession = entry.session
            fallbackSequence = entry.sequence
            fallbackStartedAt = now
            return ok
        end

        -- Second stage. The descent state above holds indefinitely unless the
        -- sender declared how long to allow for it, because a pod cannot know
        -- from local state whether it is still airborne. Once that allowance
        -- passes, hold zero rather than run props and ions unattended forever.
        local stopAfterMs = entry.command.fallbackStopAfterMs
        if not finite(stopAfterMs) or stopAfterMs <= 0 then return false end
        if stopSession == entry.session and stopSequence == entry.sequence then
            return false
        end
        if not fallbackStartedAt or (now - fallbackStartedAt) < stopAfterMs then
            return false
        end

        local startedAt, endedAt, ok, result = runStop()
        invalidateAppliedCache()
        controlMailbox.recordFallbackStop(startedAt, endedAt, ok, ok and nil or result)
        stopSession = entry.session
        stopSequence = entry.sequence
        return ok
    end

    function instance.loop()
        while true do
            instance.applyLatest()
            instance.enforceStaleFallback()
            sleepFor(0.01)
        end
    end

    return instance
end

return apply
