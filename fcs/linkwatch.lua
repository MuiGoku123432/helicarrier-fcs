-- HOW MANY SECONDS OF THE FLIGHT IS THE UPLINK DEAD, and on which transport?
--
--     /fcs/linkwatch.lua                 climb, hold 180 s, land   (~4 min)
--     /fcs/linkwatch.lua --ground-only   the same watch, on the ground
--     /fcs/linkwatch.lua --hold 240      a longer observation
--     /fcs/linkwatch.lua --rate 2.5      probes per second, per corner
--     /fcs/linkwatch.lua --ground-only --corner FL --rate 10
--                                           isolated sender/receiver test
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
local targetCorner = nil
for index = 1, #args do
    local argument = args[index]
    if argument == "--ground-only" then groundOnly = true
    elseif argument == "--corner" and args[index + 1] then
        local requested = string.upper(args[index + 1])
        for _, corner in ipairs(flight.CORNERS) do
            if corner == requested then targetCorner = requested end
        end
        if not targetCorner then
            error("--corner must be FL, FR, RL, or RR", 0)
        end
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
local sendStats = {
    attempted = 0,
    accepted = 0,
    failed = 0,
    suppressed = 0,
    totalMs = 0,
    maxMs = 0,
    overTick = 0,
    over100Ms = 0,
    byType = {},
    typeOrder = {},
}

local function sendBucket(messageType)
    local key = tostring(messageType or "<nil>")
    local bucket = sendStats.byType[key]
    if not bucket then
        bucket = {
            attempted = 0, accepted = 0, failed = 0, suppressed = 0,
            totalMs = 0, maxMs = 0, overTick = 0,
        }
        sendStats.byType[key] = bucket
        sendStats.typeOrder[#sendStats.typeOrder + 1] = key
    end
    return bucket
end

banks.send = function(corner, messageType, fields)
    local key = string.upper(corner or "")
    local bucket = sendBucket(messageType)

    -- In isolated mode, higher flight/session layers still request arm and
    -- set_power keepalives. Report and suppress them here so the modem sees
    -- exactly one traffic class to exactly one destination.
    if targetCorner
        and (key ~= targetCorner or messageType ~= "set_tilt") then
        sendStats.suppressed = sendStats.suppressed + 1
        bucket.suppressed = bucket.suppressed + 1
        return true, "suppressed by single-corner diagnostic"
    end

    local started = os.epoch("utc")
    local ok, result = realBanksSend(corner, messageType, fields)
    local elapsed = os.epoch("utc") - started

    sendStats.attempted = sendStats.attempted + 1
    sendStats.totalMs = sendStats.totalMs + elapsed
    sendStats.maxMs = math.max(sendStats.maxMs, elapsed)
    bucket.attempted = bucket.attempted + 1
    bucket.totalMs = bucket.totalMs + elapsed
    bucket.maxMs = math.max(bucket.maxMs, elapsed)
    if elapsed >= 50 then
        sendStats.overTick = sendStats.overTick + 1
        bucket.overTick = bucket.overTick + 1
    end
    if elapsed >= 100 then sendStats.over100Ms = sendStats.over100Ms + 1 end

    if ok then
        sendStats.accepted = sendStats.accepted + 1
        bucket.accepted = bucket.accepted + 1
        if commandsSentTo[key] then commandsSentTo[key] = commandsSentTo[key] + 1 end
    else
        sendStats.failed = sendStats.failed + 1
        bucket.failed = bucket.failed + 1
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
    local corners = targetCorner and { targetCorner } or flight.CORNERS
    for _, corner in ipairs(corners) do
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
    -- Single-corner mode isolates rednet throughput. Periodic prop commands to
    -- all four pods would contaminate the offered rate we are trying to vary.
    if targetCorner then return 0 end

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
        -- REFUSALS, which are not losses and not timeouts.
        --
        -- rejectReply records NO fault, so a refused command is invisible to
        -- everything except this counter -- HANDOFF says so, and the first two
        -- linkwatch flights proved it by missing 98 refusals per pod that were
        -- sitting in heartbeat.txt the whole time. A tool that partitions the
        -- fault into "arrived" and "did not" without a REFUSED column is
        -- offering a false dichotomy.
        firstRejects = nil,
        lastRejects = nil,
        lastReject = nil,
        -- THE RECEIVE-SIDE COUNTERS, published by pod/payload.lua since
        -- 2026-08-28. commandsSeen says the pod ACTED on a command; `received`
        -- says one was HANDED to it by rednet.receive at all. Without the
        -- second, "sent 549, counted 406" cannot separate a command that never
        -- arrived from one that arrived and was thrown away.
        firstReceived = nil,
        lastReceived = nil,
        firstInvalid = nil,
        lastInvalid = nil,
        lastInvalidWhy = nil,
        firstUntrusted = nil,
        lastUntrusted = nil,
        firstNonCommand = nil,
        lastNonCommand = nil,
        sawReceived = false,
        framesSeen = 0,
        droppedGaps = 0,
        noCounter = false,
    }
end

local phase = "startup"
local sawSampleAt = false
-- OBSERVATION IS NOT CONTINUOUS, and the cadence estimate must know it.
--
-- The descent runs Session:descend, which has no sample hook, so observe()
-- stops for the whole landing. The first flight recorded that as a 51153 ms
-- telemetry interval -- a number that says nothing about the pods and drags
-- both the median and the spread with it. An interval measured across a gap
-- in the OBSERVER is not a measurement of the OBSERVED.
--
-- Same class of bug as the stall detector's previousAt, which was fixed at
-- phase boundaries and then missed here.
local resumed = true
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
    local median
    if count % 2 == 0 then
        median = (sorted[middle - 1] + sorted[middle]) / 2
    else
        median = sorted[middle]
    end
    -- SPREAD, not just the middle. The threshold is a multiple of the median,
    -- so how safe that multiple is depends entirely on how far the slowest
    -- normal frame sits from it -- and a median alone cannot say. If the max
    -- approaches the threshold on a healthy run, the multiple is too tight and
    -- the next gap reported will be the cadence, not the link.
    return median, sorted[1], sorted[count]
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

            local rejects = tonumber(pod.commandsRejected)
            if rejects then
                if entry.firstRejects == nil then entry.firstRejects = rejects end
                entry.lastRejects = rejects
            end
            if pod.lastReject then entry.lastReject = pod.lastReject end

            local function track(field, firstKey, lastKey)
                local value = tonumber(pod[field])
                if value then
                    if entry[firstKey] == nil then entry[firstKey] = value end
                    entry[lastKey] = value
                    return true
                end
                return false
            end
            if track("received", "firstReceived", "lastReceived") then
                entry.sawReceived = true
            end
            track("invalid", "firstInvalid", "lastInvalid")
            track("untrusted", "firstUntrusted", "lastUntrusted")
            track("nonCommand", "firstNonCommand", "lastNonCommand")
            if pod.lastInvalid then entry.lastInvalidWhy = pod.lastInvalid end
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
                if entry.lastFrameAt and not resumed then
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
                entry.sentAtLastAdvance = commandsSentTo[corner]
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
                -- THE DENOMINATOR STOPS HERE TOO, and this is the whole fix.
                --
                -- counted can only include what the pod has REPORTED, and at
                -- the craft's measured 1200 ms cadence that lags the send by
                -- up to a full frame. Running `sent` to the end of the watch
                -- while `counted` stops at the last frame charged every
                -- command still in flight to packet loss: the first ground run
                -- read 6.6% on all four corners across BOTH transports, which
                -- is not a thing radio loss can do. Same span on both sides,
                -- or the ratio is measuring the cadence instead of the link.
                entry.sentAtLastAdvance = commandsSentTo[corner]
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
                entry.sentAtLastAdvance = commandsSentTo[corner]
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

-- The first observation after a break establishes the clocks without recording
-- an interval; every one after it measures normally.
local function endOfObservation()
    resumed = false
end

-- Call before any phase that stops observing, so the next interval is dropped.
local function observationBreak()
    resumed = true
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
    endOfObservation()
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
    observationBreak()
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
    local processSeconds = math.max(0.001,
        (os.epoch("utc") - startedAt) / 1000)
    local averageMs = sendStats.attempted > 0
        and (sendStats.totalMs / sendStats.attempted) or 0

    note("")
    note("== SEND CALLS ==")
    note("")
    note(targetCorner
        and ("  isolated target: " .. targetCorner .. " (set_tilt probes only)")
        or "  scope: all LinkWatch banks.send calls")
    note(string.format(
        "  modem attempts %d   rednet accepted %d   false %d   suppressed %d   accepted/s %.2f",
        sendStats.attempted, sendStats.accepted, sendStats.failed,
        sendStats.suppressed, sendStats.accepted / processSeconds))
    note(string.format(
        "  call duration avg %.2f ms   max %d ms   >=50ms %d   >=100ms %d",
        averageMs, sendStats.maxMs, sendStats.overTick, sendStats.over100Ms))
    note("  accepted means rednet accepted the send; it does NOT mean the pod received it.")
    note("")
    note("  message type       attempted  accepted  false  suppressed  accepted/s  max_ms  >=50ms")
    for _, messageType in ipairs(sendStats.typeOrder) do
        local bucket = sendStats.byType[messageType]
        note(string.format("  %-18s %9d  %8d  %5d  %10d  %10.2f  %6d  %6d",
            messageType, bucket.attempted, bucket.accepted, bucket.failed,
            bucket.suppressed, bucket.accepted / processSeconds,
            bucket.maxMs, bucket.overTick))
    end

    note("")
    note("== WHAT EACH CORNER SAW ==")
    note("")
    note("  commandsSeen is the pod's TOTAL command count -- set_tilt, set_rpm,")
    note("  set_power, arm -- so `sent` below is every command this computer")
    note("  sent that corner, not just the probes. loss% is sent against counted.")
    note("")
    note("  corner  transport  modem  probes    sent  counted  loss%  gaps  outage_s  longest_s  timeouts  rejects")

    local byTransport = {}
    for _, corner in ipairs(flight.CORNERS) do
        local entry = watch[corner]
        local counted = (entry.firstSeen and entry.lastSeen)
            and (entry.lastSeen - entry.firstSeen) or 0
        local sent = (entry.sentAtLastAdvance or 0) - (entry.sentAtStart or 0)
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

        local rejects = (entry.lastRejects and entry.firstRejects)
            and (entry.lastRejects - entry.firstRejects) or 0
        note(string.format("  %-6s  %-9s  %-5s  %6d  %6d  %7d  %5.1f  %4d  %8.1f  %9.1f  %8d  %7d",
            corner, entry.transport, entry.modemName or "--",
            probesSent[corner], sent, counted, loss,
            #entry.gaps, outage, longest, timeouts, rejects))
    end

    -- --- WHERE THE COMMANDS WENT -------------------------------------------
    --
    -- THE SPLIT THAT MATTERS, and the one this tool could not make until the
    -- pods published `received`. Three faults read identically as "loss":
    --
    --   never arrived   sent but rednet.receive never handed it over --
    --                   the wire, or CC's 256-event queue dropping it
    --   discarded       arrived and thrown away before dispatch: failed
    --                   protocol.validate, or not addressed to this pod
    --   acted on        reached a command branch and moved commandsSeen
    --
    -- Only the middle one is anything the pod's code can fix, and only the
    -- first implicates the transport or the queue. Reporting a single loss%
    -- over all three is how this investigation spent two flights unable to
    -- say which of them was happening.
    local anyReceived = false
    for _, corner in ipairs(flight.CORNERS) do
        if watch[corner].sawReceived then anyReceived = true end
    end

    note("")
    note("== WHERE THE COMMANDS WENT ==")
    note("")
    if not anyReceived then
        note("  ** THE PODS ARE NOT PUBLISHING `received`. They are running pod")
        note("  ** firmware older than pod-template in the repo, so a command that")
        note("  ** never arrived cannot be told from one the pod threw away.")
        note("  ** Redeploy pod-template and /fcs/reboot.lua all.")
    else
        note("  corner    sent  arrived  acted_on  discarded  never_arrived  arrived%")
        for _, corner in ipairs(flight.CORNERS) do
            local entry = watch[corner]
            local function delta(firstKey, lastKey)
                if entry[firstKey] == nil or entry[lastKey] == nil then return nil end
                return entry[lastKey] - entry[firstKey]
            end
            local sent = (entry.sentAtLastAdvance or 0) - (entry.sentAtStart or 0)
            local arrived = delta("firstReceived", "lastReceived")
            local acted = (entry.firstSeen and entry.lastSeen)
                and (entry.lastSeen - entry.firstSeen) or 0
            local invalid = delta("firstInvalid", "lastInvalid") or 0
            local untrusted = delta("firstUntrusted", "lastUntrusted") or 0
            local discarded = invalid + untrusted
            local never = arrived and (sent - arrived) or nil
            if never and never < 0 then never = 0 end
            note(string.format("  %-6s  %6d  %7s  %8d  %9d  %13s  %7s",
                corner, sent,
                arrived and tostring(arrived) or "--",
                acted, discarded,
                never and tostring(never) or "--",
                (arrived and sent > 0)
                    and string.format("%.1f", 100 * arrived / sent) or "--"))
        end
        note("")
        note("  discarded = failed protocol.validate + not addressed to this pod.")
        note("  never_arrived = sent here and never handed to the pod's")
        note("  rednet.receive: the wire, or CC's 256-event queue.")
        note("")
        note("  All columns are deltas over the same window, aligned to within")
        note("  the few commands in flight when the watch opened -- so arrived%")
        note("  slightly over 100 means zero loss, not a miscount. Read anything")
        note("  under about 95% as real.")

        -- The reading, stated rather than left to the reader.
        local sentTotal, arrivedTotal, discardedTotal = 0, 0, 0
        for _, corner in ipairs(flight.CORNERS) do
            local entry = watch[corner]
            local sent = (entry.sentAtLastAdvance or 0) - (entry.sentAtStart or 0)
            -- Single-corner mode still listens to every pod for safety, but
            -- only the selected corner belongs in its delivery aggregate.
            if sent > 0 then
                sentTotal = sentTotal + sent
                if entry.firstReceived and entry.lastReceived then
                    arrivedTotal = arrivedTotal + (entry.lastReceived - entry.firstReceived)
                end
                if entry.firstInvalid and entry.lastInvalid then
                    discardedTotal = discardedTotal
                        + (entry.lastInvalid - entry.firstInvalid)
                end
                if entry.firstUntrusted and entry.lastUntrusted then
                    discardedTotal = discardedTotal
                        + (entry.lastUntrusted - entry.firstUntrusted)
                end
            end
        end
        local missing = sentTotal - arrivedTotal
        note("")
        if sentTotal > 0 and missing > sentTotal * 0.05 then
            note(string.format("  ** %d of %d commands NEVER REACHED THE PODS (%.1f%%).",
                missing, sentTotal, 100 * missing / sentTotal))
            note("  ** They were sent and rednet.receive never handed them over, so")
            note("  ** the fault is BELOW networkLoop: the modem, or the computer's")
            note("  ** event queue dropping them before any pod code runs. No change")
            note("  ** to the pod's dispatch can recover these.")
        elseif discardedTotal > 0 then
            note(string.format("  ** The commands ARRIVED. %d were discarded before dispatch",
                discardedTotal))
            note("  ** (last reason: " .. tostring(watch.FL.lastInvalidWhy or "not addressed here") .. ").")
            note("  ** This is pod-side and fixable in networkLoop.")
        else
            note("  Sent, arrived and acted-on agree. Whatever is being lost is not")
            note("  being lost on the way IN.")
        end
    end

    -- --- LOAD AND LOSS PER SECOND ------------------------------------------
    --
    -- THE ONLY NUMBERS THAT COMPARE TWO FLIGHTS. Runs differ in duration and
    -- in achieved rate -- flight 1 watched 313 s at 2.53 Hz, flight 2 watched
    -- 133 s at 0.50 Hz -- so totals cannot be set against each other and loss%
    -- alone is misleading: halving the send rate halves the losses and
    -- LENGTHENS the silence between sends, which moves loss% and the timeout
    -- rate in OPPOSITE directions. Both per-second figures, side by side, are
    -- what showed the loss was not driven by this tool's own traffic.
    local watchedSeconds = (firstObserveAt and lastObserveAt)
        and (lastObserveAt - firstObserveAt) / 1000 or 0
    if watchedSeconds > 0 then
        note("")
        note(string.format("  per second of the %.0f s watched -- compare THESE across flights,", watchedSeconds))
        note("  never the totals:")
        note("")
        note("    corner  sent/s  lost/s  timeouts/s")
        for _, corner in ipairs(flight.CORNERS) do
            local entry = watch[corner]
            local counted = (entry.firstSeen and entry.lastSeen)
                and (entry.lastSeen - entry.firstSeen) or 0
            local sent = (entry.sentAtLastAdvance or 0) - (entry.sentAtStart or 0)
            local lost = sent - counted
            if lost < 0 then lost = 0 end
            local timeouts = (entry.lastTimeouts and entry.firstTimeouts)
                and (entry.lastTimeouts - entry.firstTimeouts) or 0
            note(string.format("    %-6s  %6.2f  %6.2f  %10.3f", corner,
                sent / watchedSeconds, lost / watchedSeconds,
                timeouts / watchedSeconds))
        end
    end

    -- --- CADENCE, so the thresholds can be checked rather than trusted -----
    note("")
    note("  measured telemetry cadence and the gap threshold it produced:")
    for _, corner in ipairs(flight.CORNERS) do
        local entry = watch[corner]
        local frame, low, high = typicalFrameMs(entry)
        note(string.format("    %-6s frames %4d   interval %s (%s..%s)   uplink gap > %.0f ms   source %s",
            corner, entry.framesSeen,
            frame and string.format("%.0f ms", frame) or "--",
            low and string.format("%.0f", low) or "--",
            high and string.format("%.0f", high) or "--",
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

    -- SUB-THRESHOLD LOSS OUTRANKS A CLEAN GAP COUNT.
    --
    -- The first flight reported "NO UPLINK OUTAGE" above 354 COMMAND_TIMEOUTs
    -- and 23% command loss on every corner. Both statements were true: every
    -- loss burst was shorter than the 3.6 s floor the measured cadence
    -- produced, so no gap opened. But a headline that says "no outage" over a
    -- link losing a quarter of its commands is a lie by omission, and this
    -- tool exists because this project spent a week believing one.
    --
    -- A gap count answers "was there a BLACKOUT". It does not answer "is the
    -- link healthy", and only one of those was ever in the headline.
    local timeoutTotal, worstLoss = 0, 0
    for _, corner in ipairs(flight.CORNERS) do
        local entry = watch[corner]
        local timeouts = (entry.lastTimeouts and entry.firstTimeouts)
            and (entry.lastTimeouts - entry.firstTimeouts) or 0
        timeoutTotal = timeoutTotal + timeouts
        local counted = (entry.firstSeen and entry.lastSeen)
            and (entry.lastSeen - entry.firstSeen) or 0
        local sent = (entry.sentAtLastAdvance or 0) - (entry.sentAtStart or 0)
        local loss = (sent > 0) and (100 * (sent - counted) / sent) or 0
        if loss > worstLoss then worstLoss = loss end
    end

    if timeoutTotal > 0 and wired == 0 and wireless == 0 then
        note("  ** THE LINK LOST COMMANDS AND NO GAP WAS LONG ENOUGH TO SHOW IT. **")
        note("")
        note(string.format("  %d COMMAND_TIMEOUTs and up to %.1f%% command loss, with ZERO",
            timeoutTotal, worstLoss))
        note(string.format("  gaps -- so every loss burst was shorter than the %.1f s floor",
            gapThresholdMs(watch.FL) / 1000))
        note("  the measured telemetry cadence produced. This is NOT the six-second")
        note("  blackout, and it is NOT a clean flight.")
        note("")
        local wiredT = (byTransport["wired"] and byTransport["wired"].timeouts) or 0
        local wirelessT = (byTransport["wireless"] and byTransport["wireless"].timeouts) or 0
        if haveBoth and wiredT > 0 and wirelessT > 0 then
            note(string.format("  It is also NOT the transport: wired %d timeouts against",
                wiredT))
            note(string.format("  wireless %d. Both paths, the same rate. That leaves this", wirelessT))
            note("  computer's sending, the pods' receiving, or THIS TOOL'S OWN LOAD.")
            note("")
            note("  Fly it again at a DIFFERENT --rate and compare the per-second")
            note("  table above, not the totals. If timeouts/s tracks sent/s, this")
            note("  tool's traffic is manufacturing the loss. If timeouts/s holds")
            note("  or RISES as sent/s falls, the loss is the craft's and sparser")
            note("  sends merely let each burst cross the pod's 750 ms watchdog.")
        end
        note("")
    end

    if targetCorner then
        note("  SINGLE-CORNER THROUGHPUT RUN. Transport comparison is intentionally")
        note("  disabled: only " .. targetCorner .. " received probes.")
        note("  Compare SEND CALLS accepted/s with this corner's arrived/s.")
        note("  If one pod accepts the full requested rate, the earlier ~21/s")
        note("  plateau is shared sender/load pressure. If this pod alone plateaus")
        note("  near its previous ~5/s, the ceiling is receiver-side.")
    elseif not haveBoth then
        note("  CANNOT SPLIT. This run did not see both a wired and a wireless")
        note("  corner reporting its own transport. Either the pods are running")
        note("  firmware older than pod/main.lua in the repo, or every corner is")
        note("  on the same bus. Run /fcs/netdiag.lua.")
    elseif wired == 0 and wireless == 0 then
        local watched = (firstObserveAt and lastObserveAt)
            and (lastObserveAt - firstObserveAt) / 1000 or 0
        note("  NO GAP LONGER THAN THE FLOOR, AND THAT SETTLES NOTHING. The")
        note("  blackout fires on roughly 2 flights in 7, so one clean run is")
        note("  exactly what the null predicts.")
        note(string.format("  This run watched the link for %.0f s against tiltcheck's ~18 s,", watched))
        note("  so it is worth much more than a clean tiltcheck -- but it is not")
        note("  an answer. Fly it again.")
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
        local rejects = (entry.lastRejects and entry.firstRejects)
            and (entry.lastRejects - entry.firstRejects) or 0
        if rejects > 0 then
            note(string.format("  %s: %d commands REFUSED (last: %s). Refused is not lost --",
                corner, rejects, tostring(entry.lastReject)))
            note("     the command arrived and the pod declined it, and rejectReply")
            note("     records no fault, so this counter is the only witness.")
            if tostring(entry.lastReject) == "not_armed" then
                note("     `not_armed` is DOWNSTREAM of a timeout: the watchdog disarms")
                note("     on 750 ms of silence, then the next set_power is refused.")
                note("     Count it as evidence of the silence, not a separate fault.")
            end
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
    -- THE ACHIEVED RATE, not the requested one. The first flight asked for
    -- 5 Hz and delivered 2.5: the sample callback's real period on the craft
    -- is ~400 ms, not the 100 ms in the plan, and probe() fires once per
    -- callback. Printing the plan here reported a rate that never happened,
    -- which is the exact failure mode this project keeps paying for.
    local watched = (firstObserveAt and lastObserveAt)
        and (lastObserveAt - firstObserveAt) / 1000 or 0
    local achievedCorner = targetCorner or "FL"
    local achieved = (watched > 0)
        and (probesSent[achievedCorner] / watched) or 0
    note(string.format("  probes %d   ACHIEVED %.2f Hz %s (asked %.1f)   prop commands %d",
        probeMessages, achieved,
        targetCorner and ("to " .. targetCorner) or "per corner",
        plan.probeRate, propMessages))
    if plan.probeRate > 0 and achieved < plan.probeRate * 0.8 then
        note(string.format("  ** the loop could not carry %.1f Hz. Every rate-dependent",
            plan.probeRate))
        note("  ** statement in this report means the ACHIEVED rate.")
    end
    note(string.format("  slowest loop %d ms   peak speed %.2f blocks/s", slowestLoop, peakSpeed))
    note(string.format("  final drift %s blocks   final altitude %s",
        endDrift and string.format("%.0f", endDrift) or "--",
        endGain and string.format("%+.1f", endGain) or "--"))
    if session.aborted then
        note("  ABORTED: " .. tostring(session.aborted))
    end
    -- A RUNAWAY ON A ZERO COMMAND IS A FINDING, not a footnote in the run
    -- block. Commanded tilt is zero for this whole flight, so any large ground
    -- speed is the craft's own standing trim integrating with nothing opposing
    -- it -- and every drift figure on record is 1.0-1.4 blocks/s, measured
    -- over far shorter windows or with control active.
    if peakSpeed > plan.abortSpeed then
        note("")
        note(string.format("  ** THE CRAFT RAN AWAY TO %.1f blocks/s ON A ZERO TILT COMMAND,", peakSpeed))
        note(string.format("  ** drifting %s blocks. Nothing was commanding lateral force: this",
            endDrift and string.format("%.0f", endDrift) or "?"))
        note("  ** is the hull's own trim offset accelerating unopposed. It is a")
        note("  ** SEPARATE fault from the link, it is why the watch ended early,")
        note("  ** and no drift figure on record is within an order of magnitude")
        note("  ** of it.")
    end
end

-- ---------------------------------------------------------------------------

local function mainLoop()
    if targetCorner and not groundOnly then
        error("--corner requires --ground-only", 0)
    end

    note("LINK WATCH -- how many seconds of this flight is the uplink dead?")
    note("utc_ms=" .. tostring(os.epoch("utc")))
    note(string.format("probe set_tilt angle 0 at %.1f Hz per corner   props %d rpm",
        plan.probeRate, plan.propRpm))
    if targetCorner then
        note("single-corner target=" .. targetCorner
            .. "; all-corner prop traffic suppressed")
    end
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
    if targetCorner then
        note(string.format("  SINGLE-CORNER sender diagnostic: %s only.", targetCorner))
        note("  Props and ions are left unchanged; the observation sends only")
        note("  zero-degree set_tilt probes to the selected pod.")
    else
        note(string.format("  props to %d rpm. Ions stay at zero collective, so there is",
            plan.propRpm))
        note("  no path to lift -- checked anyway.")
        local spun, reason = session:setAllProps(plan.propRpm)
        commandedProps = true
        if not spun then
            note("  could not set base props: " .. tostring(reason))
            return
        end

        -- Let the props reach speed before the watch starts, so the spin-up is
        -- not inside the cadence estimate.
        local spinStop = watchFor(plan.spinUpSeconds, false, "spinup")
        if spinStop then
            note("  stopped during spin-up: " .. tostring(spinStop))
            return
        end
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
    observationBreak()
    local climbed, climbWhy = session:climb(plan.holdGain, plan.climbTimeout,
        function(state, now)
            -- climb() ignores what an onSample returns, so aborts here are
            -- flight.lua's own checkLimits. This observes and commands only.
            commandProps(feed(state, now))
            probe(now)
            observe(now, state)
            endOfObservation()
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
    observationBreak()
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
