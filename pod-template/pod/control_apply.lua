-- Latest-wins actuator worker for the direct wired control mailbox.
-- The first live stage permits only exact-zero ion writes on the ground.

local apply = {}

function apply.new(controlMailbox, thrusterApi, dependencies)
    dependencies = dependencies or {}
    local epoch = dependencies.epoch or function() return os.epoch("utc") end
    local sleepFor = dependencies.sleep or sleep
    local applyZero = dependencies.applyZero or thrusterApi.applyExact

    local lastHandledSession
    local lastHandledSequence
    local fallbackSession
    local fallbackSequence

    local instance = {}

    local function sameEntry(entry)
        return entry and entry.session == lastHandledSession
            and entry.sequence == lastHandledSequence
    end

    local function markHandled(entry)
        lastHandledSession = entry.session
        lastHandledSequence = entry.sequence
    end

    local function safeGroundEntry(entry)
        local command = entry and entry.command
        return entry and entry.mode == "ground_apply"
            and type(command) == "table"
            and command.ionPower == 0
            and command.propRpm == 0
            and command.tiltDegrees == 0
            and command.azimuthDegrees == 0
    end

    local function runZeroWrite()
        local startedAt = epoch()
        local ok, result = pcall(applyZero, 0)
        local endedAt = epoch()
        return startedAt, endedAt, ok, result
    end

    function instance.applyLatest()
        local entry = controlMailbox.latest()
        if not safeGroundEntry(entry) or sameEntry(entry) then return false end

        local currentTime = epoch()
        if currentTime - entry.receivedAt > entry.validForMs then
            controlMailbox.recordExpired(entry)
            markHandled(entry)
            return false
        end

        local startedAt, endedAt, ok, result = runZeroWrite()
        controlMailbox.recordApply(entry, startedAt, endedAt, ok, result)
        markHandled(entry)
        fallbackSession = nil
        fallbackSequence = nil
        return ok
    end

    function instance.enforceStaleFallback()
        local entry = controlMailbox.latest()
        if not safeGroundEntry(entry) then return false end
        if epoch() - entry.receivedAt <= entry.validForMs then return false end
        if fallbackSession == entry.session and fallbackSequence == entry.sequence then return false end

        local startedAt, endedAt, ok, result = runZeroWrite()
        controlMailbox.recordFallback(startedAt, endedAt, ok, result)
        fallbackSession = entry.session
        fallbackSequence = entry.sequence
        return ok
    end

    function instance.loop()
        while true do
            instance.applyLatest()
            instance.enforceStaleFallback()
            sleepFor(0.05)
        end
    end

    return instance
end

return apply
