-- Assemble a telemetry message from a SNAPSHOT plus live scalars.
--
-- Pure: no peripheral calls, no mutation of the snapshot it is given. That is
-- the whole point of the file existing.
--
-- MEASURED 2026-08-26. The pod used to build this straight off the hardware,
-- inline in networkLoop, every time the FCS polled. thrusters.telemetry() runs
-- 160 peripheral getters inside a nested parallel.waitForAll, and `parallel`
-- pulls events UNFILTERED and hands each one only to its own children -- all of
-- which are waiting on task_complete. So every rednet_message that arrived
-- during that ~250 ms window was pulled off the queue and DISCARDED. Not
-- queued. Not redelivered.
--
-- That cost 4 of 40, then 2 of 80, commands with the logger polling every 2 s,
-- and exactly 0 of 80 with it stopped (flight-logs/podprobe_result*.txt). The
-- craft's own telemetry period measures the window: 1250 ms observed against a
-- configured 1.00 s is the 250 ms build, and 250 ms per 2000 ms poll is the
-- 5-12% loss predicted against the 2.5-5% measured.
--
-- The fix is not to make the read cheaper. It is to move it OFF the coroutine
-- that receives commands: a coroutine is deaf only to work it does ITSELF.
-- Run 3 proves the sibling case is safe -- the sampler was building a payload
-- 20% of the time and networkLoop lost nothing.
--
-- Two rules this file exists to keep:
--
--   1. NEVER hand back the snapshot's own tables. The old code appended
--      state.faults into the table thrusters.telemetry() returned, which was
--      fine while that table was freshly built and discarded. Against a CACHED
--      table the same line appends the fault list to itself on every message,
--      forever -- the unbounded-fault-list bug that destroyed six runs of
--      flight data, reintroduced by a one-word change.
--
--   2. Cheap scalars are ALWAYS live, never sampled. `armed` and
--      `currentPower` change on command boundaries, not on sample boundaries,
--      and a stale arm state is a safety-relevant lie: fcs/reboot.lua decides
--      whether rebooting a pod will drop lift by reading exactly these.

local payload = {}

local function copyList(source)
    local out = {}
    for index = 1, #(source or {}) do
        out[index] = source[index]
    end
    return out
end

-- ctx = { sample = {at=, thrusters=, props=}, state=, config=, computerId=, now= }
function payload.status(messageType, ctx)
    local sample = ctx.sample or {}
    local state = ctx.state or {}
    local config = ctx.config or {}

    local telemetry = {}

    -- Shallow copy: every field of the sampled reading, none of its identity.
    for key, value in pairs(sample.thrusters or {}) do
        telemetry[key] = value
    end

    -- Rebuilt per message, never shared. See rule 1 above.
    telemetry.faults = copyList((sample.thrusters or {}).faults)
    for _, fault in ipairs(state.faults or {}) do
        telemetry.faults[#telemetry.faults + 1] = fault
    end

    -- The prop reading is passed by reference deliberately: nothing mutates it,
    -- and rednet serialises on send, so copying it would be pure cost.
    telemetry.prop = sample.props

    -- How old the sampled half is. Without this a consumer cannot tell a live
    -- reading from one taken before its own command -- and this document has
    -- already lost four runs to a telemetry field that did not report what it
    -- looked like.
    telemetry.sampleAt = sample.at
    telemetry.sampleAgeMs = (sample.at and ctx.now) and (ctx.now - sample.at) or nil

    -- Live scalars. Never sampled. See rule 2 above.
    telemetry.corner = config.corner
    telemetry.hostname = config.hostname
    telemetry.armed = state.armed
    telemetry.currentPower = state.currentPower
    telemetry.fallbackPower = config.fallbackPower
    telemetry.commsLossPower = config.commsLossPower
    telemetry.commandedTilt = state.lastTilt
    telemetry.commandedTiltAzimuth = state.lastTiltAzimuth
    telemetry.lastCommandAt = state.lastCommandAt
    telemetry.podComputerId = ctx.computerId
    telemetry.bootedAt = state.bootedAt
    telemetry.commandsSeen = state.commandsSeen
    telemetry.commandsApplied = state.commandsApplied
    telemetry.commandsRejected = state.commandsRejected
    telemetry.lastReject = state.lastReject

    telemetry.type = messageType or "status"
    return telemetry
end

return payload
