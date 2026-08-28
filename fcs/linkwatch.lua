-- HOW MANY SECONDS OF THE FLIGHT IS THE UPLINK DEAD, and on which transport?
--
--     /fcs/linkwatch.lua                 climb, hold 180 s, land   (~4 min)
--     /fcs/linkwatch.lua --ground-only   the same watch, on the ground
--     /fcs/linkwatch.lua --hold 240      a longer observation
--     /fcs/linkwatch.lua --rate 2.5      probes per second, per corner
--     /fcs/linkwatch.lua --gain 12       hold altitude
--
-- Run it in the FCS-DEV "Flight Tools" tab. Run /fcs/netdiag.lua first: a
-- wired corner has no radio fallback.
--
-- ---------------------------------------------------------------------------
-- WHY THIS EXISTS, and why tiltcheck is the wrong instrument for it
--
-- The fault is a ~6 second UPLINK BLACKOUT: commands FCS->pod stop arriving
-- while telemetry keeps flowing and the FCS loop stays healthy. It fires on
-- roughly 2 flights in 7, at an unknown moment.
--
-- tiltcheck only watches the link during three 6-second confirm windows --
-- about 18 seconds of a 3-minute flight. It caught the blackout once, by luck.
-- Between those windows the link is unobserved, so a clean tiltcheck flight
-- says almost nothing: the fault had ~90% of the flight in which to fire
-- unseen.
--
-- This tool watches CONTINUOUSLY for the whole flight. Same craft, same
-- profile, ten times the exposure -- and it reports the answer as SECONDS OF
-- OUTAGE PER CORNER, split by transport, rather than as a hit rate over three
-- samples.
--
-- THE DECISIVE OUTCOME is a within-flight split. FR and RR are on the wired
-- bus, FL and RL on the radio. If the wireless pair accumulates outage and the
-- wired pair accumulates none, both pairs saw the same radio load in the same
-- instant and only the path differs. That settles it in one flight. Five clean
-- flights settle nothing -- see the confound in HANDOFF.md.
--
-- ---------------------------------------------------------------------------
-- WHAT IT SENDS
--
-- `set_tilt` at angle 0, to each corner, at 5 Hz. Harmless: the bearings are
-- already at zero, so this commands no attitude and no lateral force for the
-- entire flight. It is also the exact command type that goes missing, and the
-- pod COUNTS it -- pod/main.lua increments state.commandsSeen inside the
-- receive handler, so a command that never arrives cannot increment it.
--
-- A `status_request` would NOT do: pod/main.lua hands that to the sampler
-- without touching commandsSeen, so it is invisible to this measurement.
--
-- THE PROBES ARE NOT NUMBERED END TO END, and no honest version of this tool
-- can number them. The pod publishes a CUMULATIVE counter and never echoes a
-- sequence, so there is no per-probe identity to match. Attribution is by
-- delta: probes sent here against commandsSeen there. That is enough for
-- outage-seconds; it cannot say WHICH probe died.
--
-- ---------------------------------------------------------------------------
-- WHAT A "GAP" IS, and the mistake this is built to avoid
--
-- commandsSeen reaches us over the DOWNLINK. So a frozen counter has two
-- causes, and reporting them as one would repeat exactly the error that cost
-- this project a week -- calling a comms fault a bearing fault.
--
--   pod sampleAt still advancing, commandsSeen frozen   -> UPLINK gap
--   both frozen                                         -> DOWNLINK gap
--
-- The 2026-08-28 blackout was the first: five distinct pod sampleAt values
-- inside the window with commandedTilt never leaving 0.00. Every gap below is
-- labelled with which one it was, and the two are never added together.
--
-- THRESHOLDS ARE DERIVED FROM THE MEASURED TELEMETRY CADENCE, not stored.
-- The craft's pods push every 200 ms (pod/config.lua telemetryPeriodSeconds);
-- the offline harness models 1000 ms. A threshold tuned to either is wrong on
-- the other, and a gap detector that fires on the harness's normal cadence
-- would report outage on a healthy craft. So the tool measures each corner's
-- own frame interval as it runs and scales from that, with a floor.
--
-- A gap OPENS on all three of:
--   * no advance for longer than max(minGapMs, 3 x measured frame interval)
--   * at least 4 probes sent since the last advance
--   * at least 2 FRESH telemetry frames since the last advance
--
-- The last condition is what separates the two kinds of gap, and the probe
-- condition is what keeps the known ~1% steady command loss from reading as an
-- outage: at 5 Hz, four consecutive lost probes is a real event, one is noise.
--
-- ---------------------------------------------------------------------------
-- A SECOND, INDEPENDENT WITNESS
--
-- At 5 Hz the pods' 750 ms command watchdog is fed continuously, so
-- COMMAND_TIMEOUT cannot fire unless the uplink actually stops. Its per-corner
-- delta is reported next to the gaps, and the two should agree. Where they
-- disagree the report says so rather than picking one.
--
-- ---------------------------------------------------------------------------
-- WHAT IT DOES NOT MEASURE
--
-- Nothing. No gain, no coupling, no authority. It is an exposure counter, and
-- the only number it produces is seconds.
--
-- The DESCENT is unobserved: flight.Session:descend runs its own hold loop
-- with no sample hook. The watch covers ground, climb and hold, which is where
-- the fault has been seen.
--
-- COMMANDED TILT IS ZERO FOR THE WHOLE FLIGHT, which makes this the safest
-- flight in the stack -- a stalled loop leaves a standing command of zero --
-- and also means the craft has NO lateral authority. Over a 180 s hold it will
-- drift with whatever it started with, potentially a few hundred blocks. That
-- is expected, it is reported, and there is a drift abort.
-- ---------------------------------------------------------------------------

if package then
    package.path = "/?.lua;/?/init.lua;" .. package.path
end

local config = require("fcs.config")
local banks = require("fcs.banks")
local flight = require("fcs.flight")
local profile = require("fcs.mixer_profile")
local atmosphere = require("fcs.atmosphere")
local rolldamp = require("fcs.rolldamp")

local plan = {
    propRpm = 64,
    holdGain = 12,
    climbTimeout = 90,
    holdSeconds = 180,
    loopSeconds = 0.10,

    -- PROBES PER SECOND PER CORNER. Four corners at 5 Hz is 20 msg/s, against
    -- the ~9 the craft flies at now and the 107 that once starved the pods'
    -- watchdog. Rate and failure are uncorrelated by measurement (HANDOFF,
    -- "FOUR HYPOTHESES THAT DIED"), and 5 Hz is what keeps the watchdog fed so
    -- COMMAND_TIMEOUT stays a clean second witness.
    probeRate = 5.0,
    maxProbeRate = 10.0,

    -- Ground watch either side of the flight, using the SAME watcher, so a
    -- corner that gaps on the ground is not mistaken for one that gaps in the
    -- air.
    groundSeconds = 20,
    -- Props need to reach speed before anything else happens.
    spinUpSeconds = 6,

    -- GAP THRESHOLDS. minGapMs is the floor; the live threshold is
    -- max(minGapMs, frameMultiple x the corner's own measured frame interval).
    minGapMs = 800,
    frameMultiple = 3,
    gapOpenProbes = 4,
    gapOpenFrames = 2,
    -- The downlink is judged on frames alone, so it needs its own floor.
    minDownlinkGapMs = 1200,
    downlinkFrameMultiple = 4,
    -- Frame intervals kept per corner for the cadence estimate. 24 at 200 ms
    -- is about five seconds of history -- long enough to be a median, short
    -- enough to follow a real change.
    maxIntervals = 24,
    -- Runaway guard on the gap lists, not a budget.
    maxGapsPerCorner = 60,

    -- A LOOP THAT STOPS IS THE DANGEROUS FAILURE. Run 6 rolled to -15 degrees
    -- because the sample callback stopped executing for six seconds. Here the
    -- standing command is already zero, so there is nothing to neutralise --
    -- but a stall is DATA: run 6's "six second loop stall" is suspected to be
    -- this same event, so it goes into the timeline rather than just aborting.
    stallSeconds = 1.5,
    abortSpeed = 5.0,
    abortTilt = 4.0,
    abortDrift = 400,

    -- The ground half arms at collective 0 with props at 64 rpm, which is
    -- about 52% of weight against a props-only hover bracketed at 122-124. It
    -- cannot lift -- and "cannot lift" is the kind of belief this project has
    -- been wrong about, so it is checked.
    liftAbort = 0.5,
    groundedGain = 0.6,
}

local args = { ... }
local groundOnly = false
for index = 1, #args do
    local argument = args[index]
    if argument == "--ground-only" then groundOnly = true
    elseif argument == "--gain" then
        plan.holdGain = tonumber(args[index + 1]) or plan.holdGain
    elseif argument == "--hold" then
        plan.holdSeconds = tonumber(args[index + 1]) or plan.holdSeconds
    elseif argument == "--rpm" then
        plan.propRpm = tonumber(args[index + 1]) or plan.propRpm
    elseif argument == "--ground" then
        plan.groundSeconds = tonumber(args[index + 1]) or plan.groundSeconds
    elseif argument == "--rate" then
        local rate = tonumber(args[index + 1]) or plan.probeRate
        if rate < 0.5 then rate = 0.5 end
        if rate > plan.maxProbeRate then rate = plan.maxProbeRate end
        plan.probeRate = rate
    end
end

local probePeriodMs = 1000 / plan.probeRate

local lines = {}
local function note(text)
    lines[#lines + 1] = text
    print(text)
end

local function save()
    local ok, file = pcall(fs.open, "/fcs/linkwatch_result.txt", "w")
    if ok and file then
        file.write(table.concat(lines, "\n"))
        file.close()
        print("")
        print("Saved to /fcs/linkwatch_result.txt")
    end
end

local session = flight.new({
    config = config,
    profile = profile,
    atmosphere = atmosphere,
    note = note,
    sampleSeconds = plan.loopSeconds,
})

local rate = rolldamp.newRateEstimator({ windowSeconds = 0.6 })
local startedAt = os.epoch("utc")
local takeoffAt = nil
local commandedProps = false
local launchX, launchZ

-- ---------------------------------------------------------------------------
-- Craft state helpers. Copied from tiltcheck rather than shared: this tool
-- exists to diagnose the same fault and must not be able to inherit a change
-- made to that tool mid-investigation.
-- ---------------------------------------------------------------------------

local function speedOf(state)
    local velocity = state and state.valid and state.linearVelocityWorld
    if not velocity then return 0 end
    local x = velocity.x or velocity[1] or 0
    local z = velocity.z or velocity[3] or 0
    return math.sqrt(x * x + z * z)
end

local function horizontal(position)
    if not position then return nil end
    local x = position.x or position[1]
    local z = position.z or position[3]
    if not x or not z then return nil end
    return x, z
end

local function displacement(state)
    if not (state and state.valid) then return nil end
    local x, z = horizontal(state.position)
    if not x then return nil end
    if not launchX then launchX, launchZ = x, z end
    local dx, dz = x - launchX, z - launchZ
    return math.sqrt(dx * dx + dz * dz)
end

local function gainOf(state)
    if not (state and state.valid) then return nil end
    local y = session:craftY(state)
    if not y or not session.groundY then return nil end
    return y - session.groundY
end

local function limits(state, airborne)
    if not (state and state.valid) then return nil end
    local speed = speedOf(state)
    if speed > plan.abortSpeed then
        return string.format("ground speed %.2f blocks/s passed the %.1f limit",
            speed, plan.abortSpeed)
    end
    if math.abs(state.roll or 0) > plan.abortTilt
        or math.abs(state.pitch or 0) > plan.abortTilt then
        return string.format("hull tilt passed %.1f deg (roll %.2f pitch %.2f)",
            plan.abortTilt, state.roll or 0, state.pitch or 0)
    end
    local drift = displacement(state)
    if airborne and drift and drift > plan.abortDrift then
        return string.format("drifted %.0f blocks from launch, past the %.0f limit",
            drift, plan.abortDrift)
    end
    if not airborne then
        local gain = gainOf(state)
        if gain and gain > plan.liftAbort then
            return string.format("LIFTED to +%.2f during a ground watch", gain)
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Commanding
-- ---------------------------------------------------------------------------

local probesSent, probeMessages = { FL = 0, FR = 0, RL = 0, RR = 0 }, 0
local lastProbeAt, lastPropsSentAt, lastDifferential = 0, 0, nil
local propMessages = 0

-- EVERY COMMAND THIS COMPUTER SENDS, per corner.
--
-- commandsSeen on the pod is a TOTAL: pod/main.lua increments it for set_tilt,
-- set_rpm, set_power, arm -- every command it dispatches. So probes alone are
-- the wrong denominator for a loss rate, and the first version of this tool
-- printed "230 sent, 505 counted" and a loss of 0.0%, which is not a number.
--
-- Counting has to happen at banks.send because Session:send, Session:sendProps
-- and Session:arm all go through it and none of them is mine to instrument.
--
-- THIS IS THE PATCH NETDIAG GOT BURNED BY, and it is safe HERE for a reason
-- worth stating: netdiag replaced network.open to CHANGE BEHAVIOUR across
-- coroutines, and another CC tab -- a separate Lua environment with its own
-- copy of the module -- undid it mid-measurement. This only counts, in this
-- environment, for sends made in this environment. Another tab's sends were
-- never ours to count, and a count that a reload discards is a count that
-- never happened here.
local commandsSentTo = { FL = 0, FR = 0, RL = 0, RR = 0 }
local realBanksSend = banks.send
banks.send = function(corner, messageType, fields)
    local ok, result = realBanksSend(corner, messageType, fields)
    if ok then
        local key = string.upper(corner or "")
        if commandsSentTo[key] then commandsSentTo[key] = commandsSentTo[key] + 1 end
    end
    return ok, result
end

local function feed(state, now)
    if state and state.valid and state.roll then
        rate:push((now - startedAt) / 1000, state.roll)
    end
    return rate:rate()
end

-- THE PROBE. Angle zero, all four corners, on its own clock.
--
-- banks.send is a bare rednet.send with no yield, so the four leave in one
-- tick. That shape was tested and cleared -- tiltcheck --once reproduced it
-- and got 4/4 -- so it is kept, and the burst is what makes the four corners
-- comparable within a single instant.
local function probe(now)
    if (now - lastProbeAt) < probePeriodMs then return false end
    for _, corner in ipairs(flight.CORNERS) do
        local ok = banks.send(corner, "set_tilt",
            { angle = 0, azimuth = 0, bearing = nil, mirror = true })
        if ok then
            probesSent[corner] = probesSent[corner] + 1
            probeMessages = probeMessages + 1
        end
    end
    lastProbeAt = now
    return true
end

-- The props are held with the roll damper, exactly as tiltcheck flies them, so
-- the craft this watches is the craft that produced the fault.
local function commandProps(rollRate)
    local differential = rollRate and rolldamp.differentialFor(rollRate) or 0
    local now = os.epoch("utc")
    if differential ~= lastDifferential or (now - lastPropsSentAt) >= 1000 then
        session:sendProps(rolldamp.cornerRpm(plan.propRpm, differential,
            { minimumRpm = config.propeller.minimumRpm }))
        propMessages = propMessages + #flight.CORNERS
        lastPropsSentAt = now
        lastDifferential = differential
        commandedProps = true
    end
    return differential
end

local function clearTilt()
    for _, corner in ipairs(flight.CORNERS) do
        banks.send(corner, "set_tilt",
            { angle = 0, azimuth = 0, bearing = nil, mirror = true })
    end
end

-- ---------------------------------------------------------------------------
-- THE WATCHER
-- ---------------------------------------------------------------------------

local function timeoutsIn(faults)
    local total = 0
    if type(faults) == "table" then
        for _, fault in ipairs(faults) do
            local count = tostring(fault):match("COMMAND_TIMEOUT x(%d+)")
            if count then total = total + tonumber(count)
            elseif tostring(fault):find("COMMAND_TIMEOUT") then total = total + 1 end
        end
    elseif type(faults) == "string" then
        local count = faults:match("COMMAND_TIMEOUT x(%d+)")
        if count then total = total + tonumber(count)
        elseif faults:find("COMMAND_TIMEOUT") then total = total + 1 end
    end
    return total
end

local watch = {}
for _, corner in ipairs(flight.CORNERS) do
    watch[corner] = {
        transport = "?",
        modemName = nil,
        firstSeen = nil,
        lastSeen = nil,
        lastAdvanceAt = nil,
        probesAtLastAdvance = 0,
        -- The POD's own clock. A fresh value is proof the downlink is alive,
        -- which is the whole discriminator.
        lastSampleAt = nil,
        lastFrameAt = nil,
        frameSource = nil,
        freshFrames = 0,
        intervals = {},
        openGap = nil,
        gaps = {},
        openDown = nil,
        downGaps = {},
        firstTimeouts = nil,
        lastTimeouts = nil,
        framesSeen = 0,
        droppedGaps = 0,
        noCounter = false,
    }
end

local phase = "startup"
local sawSampleAt = false
-- The span the watch actually covered, measured rather than assumed. The
-- verdict used to quote plan.holdSeconds, which is a plan and not an
-- observation -- a --ground-only run claimed 180 s of exposure it never had.
local firstObserveAt, lastObserveAt = nil, nil

-- The median of the recent frame intervals for one corner. Median, not mean:
-- a single long interval from a paused world tick must not move the threshold
-- the way an average would.
local function typicalFrameMs(entry)
    local count = #entry.intervals
    if count < 3 then return nil end
    local sorted = {}
    for index = 1, count do sorted[index] = entry.intervals[index] end
    table.sort(sorted)
    local middle = math.floor(count / 2) + 1
    if count % 2 == 0 then
        return (sorted[middle - 1] + sorted[middle]) / 2
    end
    return sorted[middle]
end

local function gapThresholdMs(entry)
    local frame = typicalFrameMs(entry)
    if not frame then return plan.minGapMs end
    local scaled = frame * plan.frameMultiple
    if scaled > plan.minGapMs then return scaled end
    return plan.minGapMs
end

local function downlinkThresholdMs(entry)
    local frame = typicalFrameMs(entry)
    if not frame then return plan.minDownlinkGapMs end
    local scaled = frame * plan.downlinkFrameMultiple
    if scaled > plan.minDownlinkGapMs then return scaled end
    return plan.minDownlinkGapMs
end

local function pushGap(entry, list, gap)
    if #list >= plan.maxGapsPerCorner then
        entry.droppedGaps = entry.droppedGaps + 1
        return
    end
    list[#list + 1] = gap
end

-- Seconds since takeoff, or since the run started if we are still on the
-- ground. Returning nil before takeoff printed "--" against every ground gap,
-- which loses the one thing a timeline is for: WHEN.
local function flightClock(now)
    return (now - (takeoffAt or startedAt)) / 1000
end

-- Called from every sample callback, in every phase.
local function observe(now, state)
    if not firstObserveAt then firstObserveAt = now end
    lastObserveAt = now
    local gain = gainOf(state)
    local drift = displacement(state)

    for _, corner in ipairs(flight.CORNERS) do
        local pod = banks.getState()[corner]
        local entry = watch[corner]

        if pod then
            if pod.modemWireless == false then entry.transport = "wired"
            elseif pod.modemWireless == true then entry.transport = "wireless" end
            entry.modemName = pod.modemName or entry.modemName

            local timeouts = timeoutsIn(pod.faults)
            if entry.firstTimeouts == nil then entry.firstTimeouts = timeouts end
            entry.lastTimeouts = timeouts
        end

        local seen = pod and tonumber(pod.commandsSeen) or nil
        if seen == nil then
            entry.noCounter = true
        else
            -- --- FRESH FRAME? ---------------------------------------------
            -- sampleAt is the pod's own sample clock. receivedAt is this
            -- computer's receipt time and is the fallback for firmware that
            -- predates sampleAt -- weaker, because a stale cache re-delivered
            -- would look fresh, but better than refusing to judge at all.
            local stamp = pod and tonumber(pod.sampleAt)
            local source = "sampleAt"
            if stamp then
                sawSampleAt = true
            else
                stamp = pod and tonumber(pod.receivedAt)
                source = "receivedAt"
            end
            entry.frameSource = entry.frameSource or source

            if stamp and stamp ~= entry.lastSampleAt then
                if entry.lastFrameAt then
                    local interval = now - entry.lastFrameAt
                    if interval > 0 then
                        entry.intervals[#entry.intervals + 1] = interval
                        if #entry.intervals > plan.maxIntervals then
                            table.remove(entry.intervals, 1)
                        end
                    end
                end
                entry.lastSampleAt = stamp
                entry.lastFrameAt = now
                entry.framesSeen = entry.framesSeen + 1
                entry.freshFrames = entry.freshFrames + 1

                -- A fresh frame ends a downlink gap.
                if entry.openDown then
                    local down = entry.openDown
                    down.endAt = now
                    down.seconds = (now - down.startAt) / 1000
                    pushGap(entry, entry.downGaps, down)
                    entry.openDown = nil
                end
            end

            -- --- COUNTER ADVANCE? -----------------------------------------
            if entry.firstSeen == nil then
                entry.firstSeen = seen
                entry.lastSeen = seen
                entry.lastAdvanceAt = now
                entry.probesAtLastAdvance = probesSent[corner]
                -- The denominator starts HERE, not at process start: counted
                -- is a delta from firstSeen, so sent has to be one too.
                entry.sentAtStart = commandsSentTo[corner]
            elseif seen > entry.lastSeen then
                if entry.openGap then
                    local gap = entry.openGap
                    gap.endAt = now
                    gap.seconds = (now - gap.startAt) / 1000
                    gap.probesLost = probesSent[corner] - gap.startProbes
                    pushGap(entry, entry.gaps, gap)
                    entry.openGap = nil
                end
                entry.lastSeen = seen
                entry.lastAdvanceAt = now
                entry.probesAtLastAdvance = probesSent[corner]
                entry.freshFrames = 0
            elseif seen < entry.lastSeen then
                -- The pod rebooted: its counters reset. Not an outage, and
                -- adding a negative delta to a loss rate would be nonsense.
                entry.rebooted = (entry.rebooted or 0) + 1
                entry.firstSeen = seen
                entry.lastSeen = seen
                entry.lastAdvanceAt = now
                entry.probesAtLastAdvance = probesSent[corner]
                entry.sentAtStart = commandsSentTo[corner]
                entry.freshFrames = 0
                if entry.openGap then entry.openGap = nil end
            end

            -- --- UPLINK GAP OPEN? -----------------------------------------
            if not entry.openGap and entry.lastAdvanceAt then
                local silentMs = now - entry.lastAdvanceAt
                local probesSince = probesSent[corner] - entry.probesAtLastAdvance
                if silentMs >= gapThresholdMs(entry)
                    and probesSince >= plan.gapOpenProbes
                    and entry.freshFrames >= plan.gapOpenFrames then
                    entry.openGap = {
                        startAt = entry.lastAdvanceAt,
                        declaredAt = now,
                        startProbes = entry.probesAtLastAdvance,
                        phase = phase,
                        clock = flightClock(entry.lastAdvanceAt),
                        gain = gain,
                        drift = drift,
                        thresholdMs = gapThresholdMs(entry),
                    }
                end
            end

            -- --- DOWNLINK GAP OPEN? ---------------------------------------
            if not entry.openDown and entry.lastFrameAt then
                if (now - entry.lastFrameAt) >= downlinkThresholdMs(entry) then
                    entry.openDown = {
                        startAt = entry.lastFrameAt,
                        declaredAt = now,
                        phase = phase,
                        clock = flightClock(entry.lastFrameAt),
                        gain = gain,
                        drift = drift,
                    }
                end
            end
        end
    end
end

-- Close whatever is still open, so a blackout that is still running when the
-- flight ends is counted rather than discarded.
local function closeOpen(now)
    for _, corner in ipairs(flight.CORNERS) do
        local entry = watch[corner]
        if entry.openGap then
            local gap = entry.openGap
            gap.endAt = now
            gap.seconds = (now - gap.startAt) / 1000
            gap.probesLost = probesSent[corner] - gap.startProbes
            gap.stillOpen = true
            pushGap(entry, entry.gaps, gap)
            entry.openGap = nil
        end
        if entry.openDown then
            local down = entry.openDown
            down.endAt = now
            down.seconds = (now - down.startAt) / 1000
            down.stillOpen = true
            pushGap(entry, entry.downGaps, down)
            entry.openDown = nil
        end
    end
end

-- ---------------------------------------------------------------------------
-- The watch loop body, shared by every phase so only altitude differs.
-- ---------------------------------------------------------------------------

local stalls = {}
local previousAt = os.epoch("utc")
local slowestLoop = 0
local peakSpeed, endDrift, endGain = 0, nil, nil

-- Did the sample callback stop running? Shared by the hold watch and the
-- climb, because the climb is airborne time too and a stall there is the same
-- event -- run 6's stall has never been pinned to a phase.
local function checkStall(now)
    local elapsed = now - previousAt
    if elapsed > slowestLoop then slowestLoop = elapsed end
    previousAt = now

    if elapsed > plan.stallSeconds * 1000 then
        -- Nothing to neutralise -- the standing command is zero -- so this is
        -- recorded and the watch continues. A stall is the suspected shape of
        -- run 6, and ending the flight here would throw away the observation
        -- that matters most.
        stalls[#stalls + 1] = {
            seconds = elapsed / 1000,
            clock = flightClock(now),
            phase = phase,
        }
        clearTilt()
    end
end

local function tick(state, now, airborne)
    if airborne then
        session:trim(plan.holdGain, flight.MAX_CLIMB_RATE, 0, state)
    end
    commandProps(feed(state, now))
    probe(now)
    observe(now, state)
    checkStall(now)

    if state and state.valid then
        local speed = speedOf(state)
        if speed > peakSpeed then peakSpeed = speed end
        endDrift = displacement(state) or endDrift
        endGain = gainOf(state) or endGain
    end

    return limits(state, airborne)
end

local function watchFor(seconds, airborne, label)
    phase = label
    session.cheapRead = true
    -- RESET THE STALL CLOCK AT EVERY PHASE BOUNDARY. Between phases this tool
    -- does blocking work -- preflight sleeps a second, setAllProps retries per
    -- corner -- and none of it is the sample callback failing to run. Carrying
    -- previousAt across the boundary charged that gap to the loop and reported
    -- a 1.3 s stall on a healthy run. A stall detector that cries wolf is one
    -- that gets ignored on the run that matters.
    previousAt = os.epoch("utc")
    return session:hold(seconds, function(state, now)
        return tick(state, now, airborne)
    end)
end

-- ---------------------------------------------------------------------------
-- THE REPORT
-- ---------------------------------------------------------------------------

local function totalOutage(entry)
    local total, longest = 0, 0
    for _, gap in ipairs(entry.gaps) do
        total = total + gap.seconds
        if gap.seconds > longest then longest = gap.seconds end
    end
    return total, longest
end

local function totalDownlink(entry)
    local total = 0
    for _, gap in ipairs(entry.downGaps) do total = total + gap.seconds end
    return total
end

-- How many corners were inside an uplink gap at the same instant, at the worst
-- moment of the run. A blackout that hits all four simultaneously is NOT a
-- transport fault, whatever the wiring, and that outcome has to be visible.
local function peakConcurrency()
    local events = {}
    for _, corner in ipairs(flight.CORNERS) do
        for _, gap in ipairs(watch[corner].gaps) do
            events[#events + 1] = { at = gap.startAt, delta = 1 }
            events[#events + 1] = { at = gap.endAt, delta = -1 }
        end
    end
    -- Closing edges before opening edges at the same instant, so two gaps that
    -- merely touch are not counted as overlapping.
    table.sort(events, function(a, b)
        if a.at == b.at then return a.delta < b.delta end
        return a.at < b.at
    end)
    local open, peak, peakAt = 0, 0, nil
    for _, event in ipairs(events) do
        open = open + event.delta
        if open > peak then peak, peakAt = open, event.at end
    end
    return peak, peakAt
end

local function report()
    note("")
    note("== WHAT EACH CORNER SAW ==")
    note("")
    note("  commandsSeen is the pod's TOTAL command count -- set_tilt, set_rpm,")
    note("  set_power, arm -- so `sent` below is every command this computer")
    note("  sent that corner, not just the probes. loss% is sent against counted.")
    note("")
    note("  corner  transport  modem  probes    sent  counted  loss%  gaps  outage_s  longest_s  timeouts")

    local byTransport = {}
    for _, corner in ipairs(flight.CORNERS) do
        local entry = watch[corner]
        local counted = (entry.firstSeen and entry.lastSeen)
            and (entry.lastSeen - entry.firstSeen) or 0
        local sent = commandsSentTo[corner] - (entry.sentAtStart or 0)
        local loss = (sent > 0) and (100 * (sent - counted) / sent) or 0
        if loss < 0 then loss = 0 end
        local outage, longest = totalOutage(entry)
        local timeouts = (entry.lastTimeouts and entry.firstTimeouts)
            and (entry.lastTimeouts - entry.firstTimeouts) or 0

        local bucket = byTransport[entry.transport]
        if not bucket then
            bucket = { outage = 0, gaps = 0, corners = {}, timeouts = 0 }
            byTransport[entry.transport] = bucket
        end
        bucket.outage = bucket.outage + outage
        bucket.gaps = bucket.gaps + #entry.gaps
        bucket.timeouts = bucket.timeouts + timeouts
        bucket.corners[#bucket.corners + 1] = corner

        note(string.format("  %-6s  %-9s  %-5s  %6d  %6d  %7d  %5.1f  %4d  %8.1f  %9.1f  %8d",
            corner, entry.transport, entry.modemName or "--",
            probesSent[corner], sent, counted, loss,
            #entry.gaps, outage, longest, timeouts))
    end

    -- --- CADENCE, so the thresholds can be checked rather than trusted -----
    note("")
    note("  measured telemetry cadence and the gap threshold it produced:")
    for _, corner in ipairs(flight.CORNERS) do
        local entry = watch[corner]
        local frame = typicalFrameMs(entry)
        note(string.format("    %-6s frames %4d   interval %s   uplink gap > %.0f ms   source %s",
            corner, entry.framesSeen,
            frame and string.format("%6.0f ms", frame) or "    -- ",
            gapThresholdMs(entry), entry.frameSource or "--"))
    end

    -- --- EVERY GAP --------------------------------------------------------
    local anyGap = false
    for _, corner in ipairs(flight.CORNERS) do
        if #watch[corner].gaps > 0 or #watch[corner].downGaps > 0 then anyGap = true end
    end

    note("")
    note("== GAPS ==")
    if not anyGap then
        note("")
        note("  none. Every corner counted probes continuously for the whole watch.")
    else
        note("")
        note("  t+s is from takeoff, or from the start of the run while grounded.")
        note("")
        note("  corner  kind      t+s     dur_s  alt     drift   probes_lost  phase")
        for _, corner in ipairs(flight.CORNERS) do
            local entry = watch[corner]
            for _, gap in ipairs(entry.gaps) do
                note(string.format("  %-6s  UPLINK  %7s  %5.1f  %6s  %6s  %11s  %s%s",
                    corner,
                    gap.clock and string.format("%.1f", gap.clock) or "--",
                    gap.seconds,
                    gap.gain and string.format("%+.1f", gap.gain) or "--",
                    gap.drift and string.format("%.0f", gap.drift) or "--",
                    gap.probesLost and tostring(gap.probesLost) or "--",
                    gap.phase, gap.stillOpen and "  (open at end)" or ""))
            end
            for _, gap in ipairs(entry.downGaps) do
                note(string.format("  %-6s  DOWN    %7s  %5.1f  %6s  %6s  %11s  %s%s",
                    corner,
                    gap.clock and string.format("%.1f", gap.clock) or "--",
                    gap.seconds,
                    gap.gain and string.format("%+.1f", gap.gain) or "--",
                    gap.drift and string.format("%.0f", gap.drift) or "--",
                    "--",
                    gap.phase, gap.stillOpen and "  (open at end)" or ""))
            end
            if entry.droppedGaps > 0 then
                note(string.format("  %-6s  ** %d further gaps not listed (cap %d)",
                    corner, entry.droppedGaps, plan.maxGapsPerCorner))
            end
        end
        note("")
        note("  UPLINK: the pod's sample clock kept advancing and its command")
        note("  counter did not. DOWN: the pod stopped reporting at all, which")
        note("  is a DIFFERENT fault and is never added into the uplink total.")
        note("  Resolution is one telemetry frame either side of each gap.")
    end

    -- --- THE SPLIT --------------------------------------------------------
    note("")
    note("== OUTAGE BY TRANSPORT ==")
    note("")
    note("  CORNER-SECONDS: outage summed over the corners on that transport, so")
    note("  two corners deaf for 6 s each is 12, not 6. The comparison between")
    note("  the two rows is the measurement; the absolute value is not.")
    note("")
    local order = { "wired", "wireless", "?" }
    local outageFor = {}
    for _, kind in ipairs(order) do
        local bucket = byTransport[kind]
        if bucket then
            outageFor[kind] = bucket.outage
            note(string.format("  %-9s (%s)   %6.1f corner-seconds   %d gaps   %d COMMAND_TIMEOUTs",
                kind, table.concat(bucket.corners, " "), bucket.outage,
                bucket.gaps, bucket.timeouts))
        end
    end

    local peak, peakAt = peakConcurrency()
    note("")
    note(string.format("  corners simultaneously in an uplink gap, at worst: %d of 4%s",
        peak, peakAt and string.format("  (t+%.1f s)", flightClock(peakAt)) or ""))

    -- --- VERDICT ----------------------------------------------------------
    note("")
    note("== VERDICT ==")
    note("")

    local wired = outageFor["wired"] or 0
    local wireless = outageFor["wireless"] or 0
    local haveBoth = byTransport["wired"] ~= nil and byTransport["wireless"] ~= nil

    if not haveBoth then
        note("  CANNOT SPLIT. This run did not see both a wired and a wireless")
        note("  corner reporting its own transport. Either the pods are running")
        note("  firmware older than pod/main.lua in the repo, or every corner is")
        note("  on the same bus. Run /fcs/netdiag.lua.")
    elseif wired == 0 and wireless == 0 then
        local watched = (firstObserveAt and lastObserveAt)
            and (lastObserveAt - firstObserveAt) / 1000 or 0
        note("  NO UPLINK OUTAGE, AND THAT SETTLES NOTHING. The fault fires on")
        note("  roughly 2 flights in 7, so one clean run is exactly what the null")
        note(string.format("  predicts. This run watched the link for %.0f s against tiltcheck's", watched))
        note("  ~18 s, so it is worth much more than a clean tiltcheck -- but it")
        note("  is not an answer. Fly it again.")
        local downTotal = 0
        for _, corner in ipairs(flight.CORNERS) do
            downTotal = downTotal + totalDownlink(watch[corner])
        end
        if downTotal > 0 then
            note("")
            note(string.format("  There WAS %.1f corner-seconds of DOWNLINK silence. That is a real", downTotal))
            note("  fault and it is not this one: the uplink kept delivering through")
            note("  it. See the gap table.")
        end
    elseif peak >= 4 then
        note("  ** THE BLACKOUT IS NOT THE TRANSPORT. **")
        note("")
        note("  All four corners went deaf in the same instant, across BOTH a")
        note("  cable and a radio. No property of either path can do that. The")
        note("  fault is on the transmit side -- this computer, or Sable's")
        note("  registration of the sublevel the pods live on -- and the wired")
        note("  bus cannot fix it.")
        note("")
        note(string.format("  wired %.1f s, wireless %.1f s.", wired, wireless))
        note("  STOP RETROFITTING THE BUS and instrument the send instead.")
    elseif wireless > 0 and wired == 0 then
        note("  ** THE RADIO IS THE FAULT, AND THE WIRED BUS FIXES IT. **")
        note("")
        note(string.format("  wireless %.1f s of outage across %d gaps; wired ZERO.",
            wireless, byTransport["wireless"].gaps))
        note("  Both pairs saw the same radio load in the same instant and only")
        note("  the path differs, so this is immune to the load confound. Move")
        note("  FL and RL onto the cable.")
    elseif wired > 0 and wireless == 0 then
        note("  ** THE CABLE IS WORSE THAN THE RADIO. ** Unexpected, and the")
        note("  reason this reports both directions rather than checking for the")
        note("  answer it wanted.")
        note(string.format("  wired %.1f s, wireless ZERO. Check the cable run and", wired))
        note("  re-run /fcs/netdiag.lua before flying again.")
    else
        note(string.format("  MIXED: wired %.1f s, wireless %.1f s, worst concurrency %d of 4.",
            wired, wireless, peak))
        note("  Both transports lost commands but not together. That is neither")
        note("  the radio-only picture nor the all-four blackout -- read the gap")
        note("  table above before drawing anything from it.")
    end

    -- --- CROSS-CHECKS -----------------------------------------------------
    note("")
    note("== CROSS-CHECKS ==")
    note("")
    for _, corner in ipairs(flight.CORNERS) do
        local entry = watch[corner]
        local timeouts = (entry.lastTimeouts and entry.firstTimeouts)
            and (entry.lastTimeouts - entry.firstTimeouts) or 0
        local outage = totalOutage(entry)
        if outage > 0 and timeouts == 0 then
            note(string.format("  %s: %.1f s of outage but ZERO COMMAND_TIMEOUTs. The two"
                .. " witnesses disagree.", corner, outage))
            note("     At " .. string.format("%.1f", plan.probeRate) .. " Hz the pod's 750 ms")
            note("     watchdog should have fired. Treat this gap as unconfirmed.")
        elseif outage == 0 and timeouts > 0 then
            note(string.format("  %s: %d COMMAND_TIMEOUTs but no gap detected. The uplink"
                .. " stopped", corner, timeouts))
            note("     for longer than 750 ms without the counter freezing long")
            note("     enough to declare a gap. Lower --rate or read the raw counts.")
        end
        if entry.noCounter then
            note("  " .. corner .. ": reported no commandsSeen at some point. Older pod firmware?")
        end
        if entry.rebooted then
            note(string.format("  %s: counters reset %d time(s) -- the pod REBOOTED mid-watch."
                .. " Loss%% is measured from the reset.", corner, entry.rebooted))
        end
        local down = totalDownlink(entry)
        if down > 0 then
            note(string.format("  %s: %.1f s of DOWNLINK silence. Not counted as uplink outage.",
                corner, down))
        end
    end
    if not sawSampleAt then
        note("  ** NO POD PUBLISHED sampleAt. Freshness fell back to local receipt")
        note("  ** time, which cannot tell a re-delivered stale cache from a new")
        note("  ** sample. The uplink/downlink split above is weaker than it looks.")
        note("  ** Redeploy pod-template and /fcs/reboot.lua all.")
    end

    if #stalls > 0 then
        note("")
        note("== LOOP STALLS ==")
        note("")
        note("  The sample callback stopped executing. Run 6's six-second stall is")
        note("  suspected to be this same blackout seen from the other side.")
        for _, stall in ipairs(stalls) do
            note(string.format("    %.1f s at t+%s  (%s)", stall.seconds,
                stall.clock and string.format("%.1f", stall.clock) or "--",
                stall.phase))
        end
    end

    note("")
    note("== RUN ==")
    note("")
    note(string.format("  probes %d at %.1f Hz per corner   prop commands %d",
        probeMessages, plan.probeRate, propMessages))
    note(string.format("  slowest loop %d ms   peak speed %.2f blocks/s", slowestLoop, peakSpeed))
    note(string.format("  final drift %s blocks   final altitude %s",
        endDrift and string.format("%.0f", endDrift) or "--",
        endGain and string.format("%+.1f", endGain) or "--"))
    if session.aborted then
        note("  ABORTED: " .. tostring(session.aborted))
    end
end

-- ---------------------------------------------------------------------------

local function mainLoop()
    note("LINK WATCH -- how many seconds of this flight is the uplink dead?")
    note("utc_ms=" .. tostring(os.epoch("utc")))
    note(string.format("probe set_tilt angle 0 at %.1f Hz per corner   props %d rpm",
        plan.probeRate, plan.propRpm))
    if groundOnly then
        note(string.format("GROUND ONLY: %d s watch, no flight.", plan.groundSeconds))
    else
        note(string.format("climb to +%d, hold %d s, land. Ground watch %d s either side.",
            plan.holdGain, plan.holdSeconds, plan.groundSeconds))
        note("Commanded tilt is ZERO throughout, so the craft has no lateral")
        note("authority and WILL drift. That is expected and reported.")
    end
    note("Nothing is measured. This is an exposure counter.")
    note("")

    if not session:preflight() then
        note("PREFLIGHT FAILED -- not flying.")
        return
    end

    note("== GROUND ==")
    note(string.format("  props to %d rpm. Ions stay at zero collective, so there is",
        plan.propRpm))
    note("  no path to lift -- checked anyway.")
    local spun, reason = session:setAllProps(plan.propRpm)
    commandedProps = true
    if not spun then
        note("  could not set base props: " .. tostring(reason))
        return
    end

    -- Let the props reach speed before the watch starts, so the spin-up is not
    -- inside the cadence estimate.
    local spinStop = watchFor(plan.spinUpSeconds, false, "spinup")
    if spinStop then
        note("  stopped during spin-up: " .. tostring(spinStop))
        return
    end

    note(string.format("  watching the link on the ground for %d s.", plan.groundSeconds))
    local groundStop = watchFor(plan.groundSeconds, false, "ground-before")
    if groundStop then
        note("")
        note("  ground watch stopped: " .. tostring(groundStop))
        closeOpen(os.epoch("utc"))
        report()
        return
    end

    if groundOnly then
        closeOpen(os.epoch("utc"))
        report()
        return
    end

    note("")
    note("== CLIMB to +" .. plan.holdGain .. " ==")
    note("  the watch runs during the climb too: the craft is airborne from the")
    note("  moment it leaves the ground, and the fault has never been shown to")
    note("  wait for level flight.")
    phase = "climb"
    takeoffAt = os.epoch("utc")
    if not session:arm() then
        note("could not arm -- not flying.")
        closeOpen(os.epoch("utc"))
        report()
        return
    end

    previousAt = os.epoch("utc")
    local climbed, climbWhy = session:climb(plan.holdGain, plan.climbTimeout,
        function(state, now)
            -- climb() ignores what an onSample returns, so aborts here are
            -- flight.lua's own checkLimits. This observes and commands only.
            commandProps(feed(state, now))
            probe(now)
            observe(now, state)
            checkStall(now)
            if state and state.valid then
                endDrift = displacement(state) or endDrift
                endGain = gainOf(state) or endGain
            end
        end)

    if not climbed then
        note("  climb failed or aborted: " .. tostring(climbWhy))
        clearTilt()
        session:descend()
        closeOpen(os.epoch("utc"))
        report()
        return
    end

    note("")
    note(string.format("== HOLD %d s ==", plan.holdSeconds))
    note("  this is the observation. Nothing happens except probes.")
    local holdStop = watchFor(plan.holdSeconds, true, "hold")
    if holdStop then
        note("")
        note("  hold stopped: " .. tostring(holdStop))
    end

    clearTilt()
    note("")
    note("== descend and land ==")
    note("  the descent is NOT watched: Session:descend has no sample hook.")
    session:descend()

    note("")
    note("== GROUND, after ==")
    note("  the same watch on the same craft that just flew. A corner that gaps")
    note("  in the air and not here was airborne, not broken.")
    phase = "ground-after"
    watchFor(plan.groundSeconds, false, "ground-after")

    closeOpen(os.epoch("utc"))
    report()
end

local function listenLoop()
    while true do
        if not banks.listen(1) then sleep(0.05) end
    end
end

local ok, err = pcall(parallel.waitForAny, mainLoop, listenLoop)
if not ok then
    note("")
    note("RUN ERROR: " .. tostring(err))
end

-- SHUTDOWN RUNS UNDER THE LISTENER, or its commands cannot be acknowledged.
local function shutdown()
    clearTilt()

    if not commandedProps then
        note("")
        note("  nothing was commanded; props untouched.")
        pcall(session.finish, session)
        return
    end

    session:sendProps(rolldamp.cornerRpm(plan.propRpm, 0,
        { minimumRpm = config.propeller.minimumRpm }))

    local state = session:read()
    local altitude = state and session:craftY(state)
    local gain = (altitude and session.groundY) and (altitude - session.groundY) or nil

    if gain and gain > plan.groundedGain then
        note("")
        note(string.format("  STILL AIRBORNE at +%.1f -- leaving props at %d rpm.",
            gain, plan.propRpm))
        note("  Cutting them here removes ~52% of the lift. Land with")
        note("  /fcs/bankctl.lua; the props and the bearings are level.")
    else
        local stopped, why = session:setAllProps(0)
        if not stopped then
            note("  WARNING: could not stop all props -- " .. tostring(why))
        end
    end

    pcall(session.finish, session)
end

pcall(parallel.waitForAny, shutdown, listenLoop)
save()
