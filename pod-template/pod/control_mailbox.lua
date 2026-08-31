-- Direct-wired latest-command mailbox for the production control transport.
-- Reception is intentionally actuator-free so peripheral calls cannot block it.

local mailbox = {}

mailbox.CONTROL_CHANNEL = 42042
mailbox.STATUS_CHANNEL = 42043
mailbox.PROTOCOL = "helicarrier.control-frame.v1"
mailbox.GROUND_BEARING_LIMIT_DEGREES = 5
mailbox.GROUND_BEARING_PROP_RPM = 8

-- Prop RPM permitted in ion_profile. Props make thrust roughly linearly in RPM
-- (122 RPM is about hover, 64 RPM measured 52.1% of weight), so 8 RPM is about
-- 6.6% of weight: small enough that the ion curve is measurable without the
-- props confounding it, while still spinning the gyroscopic bearings, which
-- wiredframe_bearing_rpm8_run1 and wiredframe_corner_map_run1 both proved work
-- at this RPM. Zero is also allowed for a genuinely ion-only reading, but it
-- leaves the craft with NO bearing stabilisation.
mailbox.ION_PROFILE_PROP_RPM = 8

local VALID_CORNERS = { FL = true, FR = true, RL = true, RR = true }
local STATUS_OFFSET = { FL = 0.00, FR = 0.20, RL = 0.40, RR = 0.60 }

local function finiteNumber(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function validCommand(command)
    return type(command) == "table"
        and finiteNumber(command.ionPower)
        and command.ionPower >= 0 and command.ionPower <= 1
        and finiteNumber(command.propRpm)
        and command.propRpm >= 0
        and finiteNumber(command.tiltDegrees)
        and finiteNumber(command.azimuthDegrees)
end

local function validMode(message, command)
    if message.mode == "shadow" then return message.armed == false end
    if type(command) ~= "table" then return false end

    local function finite(value)
        return type(value) == "number" and value == value
            and value > -math.huge and value < math.huge
    end

    -- Ion lift measurement. Deliberately its own boundary rather than a relaxed
    -- response_map_test: ions run the full range, props are held at a
    -- near-zero-lift RPM so they do not confound the measurement, and there is
    -- NO lateral authority at all. Tilt and azimuth must be exactly zero, so
    -- this mode can never be used to fly the craft sideways.
    if message.mode == "ion_profile" then
        if message.armed ~= true then return false end

        if command.shutdown == true then
            return command.ionPower == 0
                and command.fallbackIonPower == 0
                and command.propRpm == 0
                and command.tiltDegrees == 0
                and command.azimuthDegrees == 0
                and command.fallbackStopAfterMs == nil
        end

        if command.fallbackStopAfterMs ~= nil then
            if not finite(command.fallbackStopAfterMs)
                or command.fallbackStopAfterMs < 1000
                or command.fallbackStopAfterMs > 60000 then
                return false
            end
        end

        return command.shutdown == false
            and finite(command.ionPower)
            and command.ionPower >= 0 and command.ionPower <= 1
            and finite(command.fallbackIonPower)
            and command.fallbackIonPower >= 0
            and command.fallbackIonPower <= command.ionPower
            and (command.propRpm == 0
                or command.propRpm == mailbox.ION_PROFILE_PROP_RPM)
            and command.tiltDegrees == 0
            and command.azimuthDegrees == 0
    end

    local responseMode = message.mode == "response_map_test"
    local stationkeepMode = message.mode == "stationkeep"
    if responseMode or stationkeepMode then
        if message.armed ~= true then return false end

        if command.shutdown == true then
            return command.ionPower == 0
                and command.fallbackIonPower == 0
                and command.propRpm == 0
                and command.tiltDegrees == 0
                and command.azimuthDegrees == 0
                and command.fallbackStopAfterMs == nil
        end

        -- Optional second-stage fallback. Absent means the pod holds the
        -- descent state indefinitely. Present, it must be long enough to be a
        -- landing allowance rather than a cutout racing the first stage.
        if command.fallbackStopAfterMs ~= nil then
            if not finite(command.fallbackStopAfterMs)
                or command.fallbackStopAfterMs < 1000
                or command.fallbackStopAfterMs > 60000 then
                return false
            end
        end

        local bearingLimit = stationkeepMode and 6 or 1
        return command.shutdown == false
            and finite(command.ionPower)
            and command.ionPower >= 0 and command.ionPower <= 1
            and finite(command.fallbackIonPower)
            and command.fallbackIonPower >= 0
            and command.fallbackIonPower <= command.ionPower
            and command.propRpm == 64
            and finite(command.tiltDegrees)
            and command.tiltDegrees >= -bearingLimit
            and command.tiltDegrees <= bearingLimit
            and finite(command.azimuthDegrees)
            and command.azimuthDegrees >= 0 and command.azimuthDegrees < 360
    end

    if message.armed ~= false then return false end

    if message.mode == "ground_apply" then
        -- Preserve the proven exact-zero ion-only safety boundary.
        return command.ionPower == 0
            and command.propRpm == 0
            and command.tiltDegrees == 0
            and command.azimuthDegrees == 0
    end

    if message.mode == "ground_bearing_test" then
        -- Keep ions off and allow only the bounded low-RPM physical gyro test.
        return command.ionPower == 0
            and command.propRpm == mailbox.GROUND_BEARING_PROP_RPM
            and command.azimuthDegrees == 0
            and command.tiltDegrees >= -mailbox.GROUND_BEARING_LIMIT_DEGREES
            and command.tiltDegrees <= mailbox.GROUND_BEARING_LIMIT_DEGREES
    end

    return false
end

local function blankState()
    return {
        session = nil,
        sessionSentAt = nil,
        firstSequence = nil,
        lastSequence = nil,
        received = 0,
        missing = 0,
        duplicates = 0,
        outOfOrder = 0,
        invalid = 0,
        replacements = 0,
        mailbox = nil,
        appliedSequence = nil,
        appliedMode = nil,
        appliedIonPower = nil,
        appliedPropRpm = nil,
        appliedTiltDegrees = nil,
        appliedAzimuthDegrees = nil,
        appliedBearingState = nil,
        appliedBearingStateAt = nil,
        applyCount = 0,
        applyErrors = 0,
        actuatorCalls = 0,
        coalesced = 0,
        expiredBeforeApply = 0,
        fallbackCount = 0,
        fallbackStops = 0,
        lastApplyMs = nil,
        maxApplyMs = 0,
        applyMsTotal = 0,
        stageTotals = { ion = 0, rpm = 0, tilt = 0, readback = 0 },
        stageMax = { ion = 0, rpm = 0, tilt = 0, readback = 0 },
        stageCounts = { ion = 0, rpm = 0, tilt = 0, readback = 0 },
        lastApplyError = nil,
    }
end

local function resetForSession(state, session, sentAt)
    local invalid = state.invalid
    for key in pairs(state) do state[key] = nil end
    local fresh = blankState()
    fresh.session = session
    fresh.sessionSentAt = sentAt
    fresh.invalid = invalid
    for key, value in pairs(fresh) do state[key] = value end
end

function mailbox.new(config, dependencies)
    dependencies = dependencies or {}
    local peripheralApi = dependencies.peripheral or peripheral
    local epoch = dependencies.epoch or function() return os.epoch("utc") end
    local sleepFor = dependencies.sleep or sleep
    local pullEventRaw = dependencies.pullEventRaw or os.pullEventRaw

    local corner = tostring(config and config.corner or "")
    if not VALID_CORNERS[corner] then
        error("control mailbox requires config.corner FL|FR|RL|RR", 0)
    end

    local wiredModem, wiredModemName
    for _, name in ipairs(peripheralApi.getNames()) do
        if peripheralApi.hasType(name, "modem") then
            local candidate = peripheralApi.wrap(name)
            if type(candidate.isWireless) == "function" and not candidate.isWireless() then
                wiredModem = candidate
                wiredModemName = name
                break
            end
        end
    end

    local state = blankState()
    local instance = {
        enabled = wiredModem ~= nil,
        modemName = wiredModemName,
        state = state,
    }

    if wiredModem then wiredModem.open(mailbox.CONTROL_CHANNEL) end

    function instance.acceptFrame(message, receivedAt)
        local command = type(message) == "table" and type(message.corners) == "table"
            and message.corners[corner] or nil
        if type(message) ~= "table" or message.protocol ~= mailbox.PROTOCOL
            or message.kind ~= "control_frame" or type(message.session) ~= "string"
            or message.session == "" or not finiteNumber(message.sequence)
            or message.sequence < 1 or message.sequence % 1 ~= 0
            or not finiteNumber(message.sentAt) or not finiteNumber(message.validForMs)
            or message.validForMs < 50 or message.validForMs > 5000
            or not validCommand(command) or not validMode(message, command) then
            state.invalid = state.invalid + 1
            return false
        end

        if state.session ~= message.session then
            if state.sessionSentAt and message.sentAt < state.sessionSentAt then
                state.outOfOrder = state.outOfOrder + 1
                return false
            end
            resetForSession(state, message.session, message.sentAt)
        end

        local sequence = message.sequence
        if state.lastSequence == nil then
            state.firstSequence = sequence
            if sequence > 1 then state.missing = sequence - 1 end
        elseif sequence == state.lastSequence then
            state.duplicates = state.duplicates + 1
            return false
        elseif sequence < state.lastSequence then
            state.outOfOrder = state.outOfOrder + 1
            return false
        elseif sequence > state.lastSequence + 1 then
            state.missing = state.missing + sequence - state.lastSequence - 1
        end

        if state.mailbox ~= nil then state.replacements = state.replacements + 1 end
        state.lastSequence = sequence
        state.received = state.received + 1
        state.mailbox = {
            mode = message.mode,
            session = message.session,
            sequence = sequence,
            sentAt = message.sentAt,
            receivedAt = receivedAt,
            validForMs = message.validForMs,
            command = {
                ionPower = command.ionPower,
                fallbackIonPower = command.fallbackIonPower,
                propRpm = command.propRpm,
                tiltDegrees = command.tiltDegrees,
                azimuthDegrees = command.azimuthDegrees,
                shutdown = command.shutdown,
                fallbackStopAfterMs = command.fallbackStopAfterMs,
            },
        }
        return true
    end

    function instance.latest()
        return state.mailbox
    end

    function instance.recordApply(entry, startedAt, endedAt, ok, applyError, applyReport)
        if not entry or entry.session ~= state.session then return false end
        if state.appliedSequence and entry.sequence <= state.appliedSequence then return false end

        local previous = state.appliedSequence or 0
        state.coalesced = state.coalesced + math.max(0, entry.sequence - previous - 1)
        state.actuatorCalls = state.actuatorCalls + 1
        local elapsed = math.max(0, endedAt - startedAt)
        state.lastApplyMs = elapsed
        state.maxApplyMs = math.max(state.maxApplyMs, elapsed)
        state.applyMsTotal = state.applyMsTotal + elapsed
        if ok then
            state.appliedSequence = entry.sequence
            state.appliedMode = entry.mode
            state.appliedIonPower = entry.command.ionPower
            state.appliedPropRpm = entry.command.propRpm
            state.appliedTiltDegrees = entry.command.tiltDegrees
            state.appliedAzimuthDegrees = entry.command.azimuthDegrees
            local timings = applyReport and applyReport.timings or nil
            if type(timings) == "table" then
                for _, stage in ipairs({ "ion", "rpm", "tilt" }) do
                    local value = timings[stage]
                    if type(value) == "number" then
                        state.stageTotals[stage] = state.stageTotals[stage] + value
                        state.stageCounts[stage] = state.stageCounts[stage] + 1
                        if value > state.stageMax[stage] then
                            state.stageMax[stage] = value
                        end
                    end
                end
                -- Counted separately: only some applies carry a readback, so a
                -- mean over all applies would understate what one costs.
                if timings.readbackCount then
                    local value = timings.readback or 0
                    state.stageTotals.readback = state.stageTotals.readback + value
                    state.stageCounts.readback = state.stageCounts.readback + 1
                    if value > state.stageMax.readback then
                        state.stageMax.readback = value
                    end
                end
            end

            local readback = applyReport and applyReport.tilt
                and applyReport.tilt.readback or nil
            if readback then
                state.appliedBearingState = readback
                state.appliedBearingStateAt = endedAt
            end
            state.applyCount = state.applyCount + 1
            state.lastApplyError = nil
        else
            state.applyErrors = state.applyErrors + 1
            state.lastApplyError = tostring(applyError)
        end
        return true
    end

    function instance.recordExpired(entry)
        if not entry or entry.session ~= state.session then return end
        state.expiredBeforeApply = state.expiredBeforeApply + 1
    end

    function instance.recordFallback(startedAt, endedAt, ok, applyError)
        state.fallbackCount = state.fallbackCount + 1
        state.actuatorCalls = state.actuatorCalls + 1
        local elapsed = math.max(0, endedAt - startedAt)
        state.lastApplyMs = elapsed
        state.maxApplyMs = math.max(state.maxApplyMs, elapsed)
        if not ok then
            state.applyErrors = state.applyErrors + 1
            state.lastApplyError = tostring(applyError)
        end
    end

    -- Second-stage fallback is recorded separately from the descent stage so a
    -- report can tell "levelled and descending" apart from "stopped".
    function instance.recordFallbackStop(startedAt, endedAt, ok, applyError)
        state.fallbackStops = state.fallbackStops + 1
        state.actuatorCalls = state.actuatorCalls + 1
        local elapsed = math.max(0, endedAt - startedAt)
        state.lastApplyMs = elapsed
        state.maxApplyMs = math.max(state.maxApplyMs, elapsed)
        if not ok then
            state.applyErrors = state.applyErrors + 1
            state.lastApplyError = tostring(applyError)
        end
    end

    local function stageMean(stage)
        local count = state.stageCounts[stage]
        if not count or count == 0 then return nil end
        return state.stageTotals[stage] / count
    end

    function instance.statusMessage()
        local current = state.mailbox
        local reportedAt = epoch()
        return {
            protocol = mailbox.PROTOCOL,
            kind = state.session and "control_ack" or "control_ready",
            mode = current and current.mode or "ready",
            corner = corner,
            session = state.session,
            firstSequence = state.firstSequence,
            lastSequence = state.lastSequence,
            received = state.received,
            missing = state.missing,
            duplicates = state.duplicates,
            outOfOrder = state.outOfOrder,
            invalid = state.invalid,
            replacements = state.replacements,
            mailboxSequence = current and current.sequence or nil,
            mailboxAgeMs = current and (reportedAt - current.receivedAt) or nil,
            appliedSequence = state.appliedSequence,
            appliedMode = state.appliedMode,
            appliedIonPower = state.appliedIonPower,
            appliedPropRpm = state.appliedPropRpm,
            appliedTiltDegrees = state.appliedTiltDegrees,
            appliedAzimuthDegrees = state.appliedAzimuthDegrees,
            appliedBearingState = state.appliedBearingState,
            appliedBearingStateAgeMs = state.appliedBearingStateAt
                and (reportedAt - state.appliedBearingStateAt) or nil,
            applyCount = state.applyCount,
            applyErrors = state.applyErrors,
            actuatorCalls = state.actuatorCalls,
            coalesced = state.coalesced,
            expiredBeforeApply = state.expiredBeforeApply,
            fallbackCount = state.fallbackCount,
            fallbackStops = state.fallbackStops,
            lastApplyMs = state.lastApplyMs,
            maxApplyMs = state.maxApplyMs,
            meanApplyMs = state.applyCount > 0
                and (state.applyMsTotal / state.applyCount) or nil,
            stageMeanIonMs = stageMean("ion"),
            stageMeanRpmMs = stageMean("rpm"),
            stageMeanTiltMs = stageMean("tilt"),
            stageMeanReadbackMs = stageMean("readback"),
            stageMaxIonMs = state.stageMax.ion,
            stageMaxRpmMs = state.stageMax.rpm,
            stageMaxTiltMs = state.stageMax.tilt,
            stageMaxReadbackMs = state.stageMax.readback,
            readbackApplies = state.stageCounts.readback,
            lastApplyError = state.lastApplyError,
            reportedAt = reportedAt,
            mailboxOnly = current and current.mode == "shadow" or false,
            transport = "wired",
        }
    end

    function instance.receiveLoop()
        if not wiredModem then
            while true do sleepFor(60) end
        end
        while true do
            local event = { pullEventRaw() }
            if event[1] == "terminate" then error("Terminated", 0) end
            if event[1] == "modem_message" and event[2] == wiredModemName
                and event[3] == mailbox.CONTROL_CHANNEL then
                local message = event[5]
                if type(message) == "table" and message.protocol == mailbox.PROTOCOL then
                    instance.acceptFrame(message, epoch())
                end
            end
        end
    end

    function instance.statusLoop()
        if not wiredModem then
            while true do sleepFor(60) end
        end
        sleepFor(STATUS_OFFSET[corner])
        while true do
            wiredModem.transmit(mailbox.STATUS_CHANNEL, mailbox.CONTROL_CHANNEL, instance.statusMessage())
            sleepFor(1)
        end
    end

    function instance.snapshot()
        return instance.statusMessage()
    end

    return instance
end

return mailbox
