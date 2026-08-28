-- DOES A BEARING ANSWER set_tilt IN THE AIR? Nothing else. No measurement.
--
--     /fcs/tiltcheck.lua                 ground, climb, 3 confirms, land
--     /fcs/tiltcheck.lua --ground-only   the ground half alone, ~20 s
--     /fcs/tiltcheck.lua --gain 6        lower hold altitude
--     /fcs/tiltcheck.lua --repeats 5     more air confirms
--     /fcs/tiltcheck.lua --tilt 2.0      a bigger probe (see THE PROBE below)
--
-- Run it in the FCS-DEV "Flight Tools" tab. Expect about three minutes.
--
-- ---------------------------------------------------------------------------
-- WHAT IS BEING ANSWERED
--
-- In flight the bearings sometimes ignore set_tilt. On the ground they never
-- have: five ground runs, five successes, INCLUDING ONE TAKEN TWO MINUTES
-- BEFORE A FLIGHT THAT FAILED. Two of six flights got 0.00 back from all four
-- corners on a command the ground answers with 8.00.
--
-- Ruled out already: the command shape (all four corners answer it on the
-- ground), prop.active being false (it reads true in flight), and message rate
-- (run 7 failed at 8/s where runs 3-6 succeeded at 10-12/s).
--
-- What is left, untested: something about being AIRBORNE, or about the craft
-- having MOVED. This tool tests exactly that and measures nothing else, so it
-- is cheap enough to fly repeatedly for a hit rate.
--
-- ---------------------------------------------------------------------------
-- WHY THE GROUND HALF IS IN THIS FILE AND NOT LEFT TO bearingsweep
--
-- bearingsweep is a DIFFERENT CODE PATH. A ground sweep that works and a
-- flight tool that does not cannot separate "airborne" from "this tool's
-- code", which is the whole question. Here the ground confirm and the air
-- confirms call the SAME function with the same throttle, the same command
-- shape and the same readback -- only the altitude differs. Run bearingsweep
-- either side of this as the independent cross-check; that pairing is worth
-- having, it is just not the discriminator.
--
-- ---------------------------------------------------------------------------
-- THE SIGN ALTERNATES, AND THAT IS NOT COSMETIC
--
-- The net gain is -3.36 blocks/s per commanded degree on the roll axis, so a
-- one-sided 1 degree probe held across three confirms walks the craft several
-- hundred blocks. Chunk loading as the craft drifts is the leading suspect for
-- BOTH the six-second loop stall and this fault -- so a one-sided probe would
-- inject the very variable it is trying to test. Alternating +/- keeps the
-- craft near where it took off.
--
-- IT ALSO SPLITS ALTITUDE FROM MOTION FOR FREE. Confirm 1 happens from a
-- near-stationary hover: it tests AIRBORNE alone. By confirm 3 the craft has
-- been moving: that tests MOTION. Failing at 1 and failing only at 3 are
-- different diagnoses, and this is the cheapest way to tell them apart.
--
-- ---------------------------------------------------------------------------
-- THE INSTRUMENT NOBODY WAS READING
--
-- pod/payload.lua puts three things in EVERY heartbeat that no flight tool
-- here has ever looked at:
--
--     commandedTilt      state.lastTilt -- written ONLY by a set_tilt the pod
--                        ACCEPTED. The angle the pod believes it applied.
--     commandsRejected   incremented by rejectReply.
--     lastReject         why.
--
-- That last pair matters because pod/main.lua's isNewCommand drops a command
-- whose sequence <= lastSequence and answers with rejectReply -- which
-- increments commandsRejected and sends a `fault`-TYPED REPLY but RECORDS NO
-- FAULT IN THE FAULT LIST. HANDOFF lists "pod rejection" as ruled out on the
-- evidence "no faults". That evidence never covered this path. Reading three
-- fields covers it properly.
--
-- So a failure here is not a hit/miss. commandedTilt against prop.tiltAngle
-- partitions the fault space:
--
--   commandedTilt | rejects | tiltAngle | verdict
--   --------------|---------|-----------|--------------------------------------
--   stale         | flat    | 0.00      | THE COMMAND NEVER REACHED THE POD
--   stale         | RISING  | 0.00      | THE POD REFUSED IT (sequence/session)
--   tracks        | flat    | 0.00      | POD APPLIED IT, BEARING DID NOT MOVE
--   tracks        | flat    | = command | it works
--
-- THE BLIND SPOT IN ROW 3, said out loud because it will be the tempting one:
-- props.setTilt returns per-bearing setManualTarget errors in applied.bearings
-- and pod/main.lua keeps only .angle, throwing the rest away. A bearing
-- peripheral going stale in flight looks EXACTLY like row 3 and logs nothing.
-- If row 3 is what comes back, the next step is a one-line pod change to
-- record that error as a fault -- not a conclusion drawn from this run.
--
-- ---------------------------------------------------------------------------
-- THE PROBE IS 1 DEGREE
--
-- Not because it is gentle -- at -3.36 blocks/s per degree it is not -- but
-- because 1.00 is the exact angle runs 4, 5 and 6 read back, so a 0.00 is
-- unambiguous. Whether the bearings resolve half a degree is NOT MEASURED, and
-- a false failure here would cost more than the drift a smaller probe saves.
-- --tilt exists for when that is known; until then leave it alone.
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
local lateralhold = require("fcs.lateralhold")

local plan = {
    propRpm = 64,
    holdGain = 12,
    climbTimeout = 90,
    loopSeconds = 0.15,

    tiltDegrees = 1.0,
    -- Long enough for the pods to have pushed at least a few 200 ms status
    -- heartbeats carrying the new tiltAngle, short enough that a 1 degree
    -- command has not built much of its 3.4 blocks/s.
    confirmSeconds = 6,
    repeats = 3,
    -- Tilt cleared, craft left alone. Not a settle -- nothing is being
    -- measured -- just enough for the last command to stop mattering.
    betweenSeconds = 4,

    -- A corner has answered if it reports at least half the commanded angle.
    -- The same threshold the velocity tool uses. The failure this looks for is
    -- 0.00 against 1.00, not a calibration error.
    answeredFraction = 0.5,

    -- THE COMMAND THROTTLE, carried over from velocityholdflight unchanged.
    -- set_tilt and set_rpm are set-and-hold with NO watchdog pod-side, so
    -- re-sending them every sample is 107 messages a second of pure load. Any
    -- CHANGE goes out immediately; the deadband is there because an exact
    -- inequality never engages against a slewing command.
    resendPeriodMs = 1000,
    resendDeadbandDegrees = 0.05,

    -- A LOOP THAT STOPS IS THE DANGEROUS FAILURE. Run 6 rolled to -15 degrees
    -- from a 1 degree command because the sample callback -- which holds every
    -- abort and the damper -- stopped executing for six seconds. A late sample
    -- neutralises rather than carrying on with the standing command.
    stallSeconds = 1.5,
    abortSpeed = 5.0,
    abortTilt = 4.0,

    -- The ground half arms the banks at collective 0, which is no lift at all,
    -- and props at 64 rpm are 52% of weight against a props-only hover
    -- bracketed at 122-124. So the craft cannot lift -- and "cannot lift" is
    -- exactly the kind of belief this project has been wrong about, so it is
    -- checked anyway.
    liftAbort = 0.5,
    groundedGain = 0.6,

    -- SEND THE FOUR-CORNER COMMAND EXACTLY ONCE, never repeating it.
    --
    -- This is bearingsweep's shape, and the difference between the two tools
    -- may be the whole fault. bearingsweep sends four set_tilts in a tight
    -- loop -- banks.send is a bare rednet.send with no yield, so they leave in
    -- one tick -- and never repeats them. This tool re-sends every second, so
    -- a command lost in that tick is covered by five retries.
    --
    -- On 2026-08-28 bearingsweep got FL 8.00 / FR 0.00 / RL 0.00 / RR 0.00 and
    -- this tool got 4/4 two minutes later. --once removes the retries so the
    -- two can be compared with the SAME instrumentation.
    sendOnce = false,
    -- Milliseconds between the four corner sends, so the burst stops being a
    -- burst. Clamped: this sleeps inside the sample callback, and the pods'
    -- watchdog is 750 ms.
    sendSpacingMs = 0,
    maxSendSpacingMs = 200,

    -- WHAT COUNTS AS ARRIVED, for the slew measurement. 90% of the commanded
    -- angle, which is well clear of the 50% the pass/fail gate uses -- a slew
    -- number taken at the pass threshold would report the bearing arriving
    -- when it is half way there.
    arrivedFraction = 0.90,
    -- Most readings kept per corner. 6 s at the pod's ~1 Hz sampler is about
    -- six; the cap is a runaway guard, not a budget.
    maxTrace = 16,
}

local args = { ... }
local groundOnly, sendOnceRequested = false, false
for index = 1, #args do
    local argument = args[index]
    if argument == "--ground-only" then groundOnly = true
    elseif argument == "--gain" then
        plan.holdGain = tonumber(args[index + 1]) or plan.holdGain
    elseif argument == "--repeats" then
        plan.repeats = tonumber(args[index + 1]) or plan.repeats
    elseif argument == "--tilt" then
        plan.tiltDegrees = tonumber(args[index + 1]) or plan.tiltDegrees
    elseif argument == "--rpm" then
        plan.propRpm = tonumber(args[index + 1]) or plan.propRpm
    elseif argument == "--settle" then
        plan.confirmSeconds = tonumber(args[index + 1]) or plan.confirmSeconds
    elseif argument == "--once" then sendOnceRequested = true
    elseif argument == "--spacing" then
        local ms = tonumber(args[index + 1]) or 0
        if ms < 0 then ms = 0 end
        if ms > plan.maxSendSpacingMs then ms = plan.maxSendSpacingMs end
        plan.sendSpacingMs = ms
    end
end

plan.sendOnce = sendOnceRequested

local lines = {}
local function note(text)
    lines[#lines + 1] = text
    print(text)
end

local function save()
    local ok, file = pcall(fs.open, "/fcs/tiltcheck_result.txt", "w")
    if ok and file then
        file.write(table.concat(lines, "\n"))
        file.close()
        print("")
        print("Saved to /fcs/tiltcheck_result.txt")
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
local commandedProps, commandedTilt = false, false
local applied = { starboard = 0, bow = 0 }
local launchX, launchZ

local function feed(state, now)
    if state and state.valid and state.roll then
        rate:push((now - startedAt) / 1000, state.roll)
    end
    return rate:rate()
end

-- ---------------------------------------------------------------------------
-- Commanding, throttled. Copied from velocityholdflight rather than shared,
-- deliberately: this tool exists to diagnose that tool's fault, and it must
-- not be able to inherit a change made to it mid-investigation. The extraction
-- into a common module comes after this question is answered.
-- ---------------------------------------------------------------------------

-- The azimuth a given command carries. Shared by the sender and the
-- confirmation, because the confirmation NEEDS it: commandedTilt is a
-- MAGNITUDE and every confirm here uses the same 1.00, so a stale value left
-- over from the previous confirm is indistinguishable from a fresh one. The
-- azimuth flips 180 degrees when the sign alternates, and that is what makes
-- "the pod saw THIS command" answerable rather than "the pod saw A command".
local function azimuthFor(starboard, bow)
    local heading = math.deg(math.atan2(starboard, bow))
    return lateralhold.azimuthForHeading(heading)
end

-- Smallest angle between two azimuths, degrees.
local function azimuthApart(a, b)
    local difference = math.abs((a - b) % 360)
    if difference > 180 then difference = 360 - difference end
    return difference
end

local lastTiltSentAt, tiltMessages = 0, 0
-- Reset at the top of every confirm. --once uses this to send the command for
-- that window exactly once.
local windowTiltSends = 0

local function commandTilt(starboard, bow)
    local now = os.epoch("utc")
    local magnitudeWanted = math.abs(starboard) + math.abs(bow)
    -- --once: one send per window. Going to ZERO is never suppressed -- that
    -- is the command that stops things, and the stall neutralise depends on it.
    if plan.sendOnce and magnitudeWanted > 0 and windowTiltSends > 0 then
        return
    end
    local changed = math.abs(starboard - applied.starboard) >= plan.resendDeadbandDegrees
        or math.abs(bow - applied.bow) >= plan.resendDeadbandDegrees
        or (starboard == 0 and bow == 0
            and (applied.starboard ~= 0 or applied.bow ~= 0))
    if not changed and (now - lastTiltSentAt) < plan.resendPeriodMs then
        return
    end

    local magnitude = math.sqrt(starboard * starboard + bow * bow)
    local azimuth = azimuthFor(starboard, bow)
    for index, corner in ipairs(flight.CORNERS) do
        banks.send(corner, "set_tilt", {
            angle = magnitude, azimuth = azimuth, bearing = nil, mirror = true,
        })
        tiltMessages = tiltMessages + 1
        -- Break the burst apart. banks.send is a bare rednet.send with no
        -- yield, so without this all four leave in the same tick.
        if plan.sendSpacingMs > 0 and index < #flight.CORNERS then
            sleep(plan.sendSpacingMs / 1000)
        end
    end
    if magnitude > 0 then windowTiltSends = windowTiltSends + 1 end
    applied.starboard, applied.bow = starboard, bow
    lastTiltSentAt = now
    if magnitude > 0 then commandedTilt = true end
end

-- Never throttled. Clearing the tilt is the one command that must not wait on
-- a resend window, and it resets the throttle so the next command is a change.
local function clearTilt()
    applied.starboard, applied.bow = 0, 0
    lastTiltSentAt = 0
    for _, corner in ipairs(flight.CORNERS) do
        banks.send(corner, "set_tilt",
            { angle = 0, azimuth = 0, bearing = nil, mirror = true })
    end
end

local lastPropsSentAt, lastDifferential, propMessages = 0, nil, 0

local function commandProps(rollRate)
    local differential = rollRate and rolldamp.differentialFor(rollRate) or 0
    local now = os.epoch("utc")
    if differential ~= lastDifferential
        or (now - lastPropsSentAt) >= plan.resendPeriodMs then
        session:sendProps(rolldamp.cornerRpm(plan.propRpm, differential,
            { minimumRpm = config.propeller.minimumRpm }))
        propMessages = propMessages + #flight.CORNERS
        lastPropsSentAt = now
        lastDifferential = differential
        commandedProps = true
    end
    return differential
end

-- ---------------------------------------------------------------------------
-- Reading the pods. Everything the decision table needs, per corner.
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

-- HAS THIS CRAFT'S POD FIRMWARE EVER PUBLISHED commandedTilt?
--
-- The field comes from pod/payload.lua, which lives on the FOUR POD COMPUTERS,
-- not here. If those are running an older build the field is simply absent --
-- and absent looks exactly like "the pod never saw the command", which would
-- turn a genuine bearing failure into a confident wrong diagnosis. So the tool
-- tracks whether it has EVER seen the field and refuses to read anything into
-- its absence if it has not.
local sawCommandedTiltEver = false

local function snapshot()
    local pods = {}
    for _, corner in ipairs(flight.CORNERS) do
        local pod = banks.getState()[corner]
        local prop = pod and pod.prop
        pods[corner] = {
            online = pod and pod.online or false,
            -- What the POD believes it applied. Only ever written by a
            -- set_tilt the pod accepted.
            commandedTilt = pod and pod.commandedTilt or nil,
            commandedTiltAzimuth = pod and pod.commandedTiltAzimuth or nil,
            -- WHICH TRANSPORT THIS CORNER IS ON, from the pod itself.
            modemWireless = pod and pod.modemWireless,
            modemName = pod and pod.modemName or nil,
            rejected = (pod and tonumber(pod.commandsRejected)) or 0,
            lastReject = pod and pod.lastReject or nil,
            timeouts = timeoutsIn(pod and pod.faults),
            -- What the BEARING actually did.
            tiltAngle = prop and tonumber(prop.tiltAngle) or nil,
            active = prop and prop.active or nil,
            bearingRpm = prop and tonumber(prop.bearingRpm) or nil,
            -- PER BEARING. The pod has sampled both of these every cycle since
            -- 2026-08-26 and nothing on this side has ever read them.
            -- perBearingTilt is getTiltAngle per bearing; perBearingTarget is
            -- getManualTarget, the vector the MOD stored -- which separates
            -- "the mod took the target and the bearing sat still" from
            -- "setManualTarget never took".
            perBearingTilt = prop and prop.perBearingTilt or nil,
            perBearingTarget = prop and prop.perBearingTarget or nil,
            controllerRpm = prop and tonumber(prop.controllerRpm) or nil,
            telemetry = prop ~= nil,
        }
        if type(pods[corner].commandedTilt) == "number" then
            sawCommandedTiltEver = true
        end
    end
    return pods
end

-- The tilt angle a stored manual target implies.
--
-- pod/props.lua builds the target as
--     { sin(tilt)cos(swing), +/-cos(tilt), sin(tilt)sin(swing) }
-- about the bearing's own getBlockNormal, and the mod normalises it. Every
-- bearing on this craft has a +/-Y normal -- a counter-rotating pair reads
-- {0,1,0} and {0,-1,0} -- so the angle off vertical IS the tilt. Returns nil
-- rather than guessing if the vector is not that shape.
local function targetAngle(vector)
    if type(vector) ~= "table" then return nil end
    local x, y, z = vector[1], vector[2], vector[3]
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return nil
    end
    return math.deg(math.atan2(math.sqrt(x * x + z * z), math.abs(y)))
end

-- "wired" / "wireless" / "?" for one corner, as the POD reports it.
local function transportOf(pod)
    if pod.modemWireless == false then return "wired" end
    if pod.modemWireless == true then return "wireless" end
    return "?"
end

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

local function limits(state)
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
    return nil
end

-- ---------------------------------------------------------------------------
-- THE CONFIRM. One function, used on the ground and in the air, so the only
-- thing that differs between them is altitude.
-- ---------------------------------------------------------------------------

local results = {}

-- Per-bearing rows for one corner: what each bearing was TOLD (the stored
-- manual target) against what it DID (getTiltAngle).
local function bearingRows(corner, pod, magnitude)
    local rows, stored, moved, seen = {}, 0, 0, 0
    local tilts = pod.perBearingTilt
    local targets = pod.perBearingTarget
    if type(tilts) ~= "table" and type(targets) ~= "table" then
        return nil, 0, 0, 0
    end
    for index = 1, 8 do
        local tilt = type(tilts) == "table" and tonumber(tilts[index]) or nil
        local target = type(targets) == "table" and targets[index] or nil
        local wanted = targetAngle(target)
        if tilt ~= nil or wanted ~= nil then
            seen = seen + 1
            if wanted and wanted >= magnitude * plan.answeredFraction then
                stored = stored + 1
            end
            if tilt and math.abs(tilt) >= magnitude * plan.answeredFraction then
                moved = moved + 1
            end
            rows[#rows + 1] = string.format("%s.%d told %s did %s", corner, index,
                wanted and string.format("%.2f", wanted) or "--",
                tilt and string.format("%.2f", tilt) or "--")
        end
    end
    return rows, stored, moved, seen
end

-- ---------------------------------------------------------------------------
-- HOW LONG A BEARING TAKES TO REACH A COMMANDED ANGLE.
--
-- Nothing in this project has ever measured this, and every tool assumes it is
-- instant. The 2026-08-28 ground evidence says it is not:
--
--     32 rpm, 3 s settle, 8 deg   4/4      (bearingsweep runs 4 and 5)
--     48 rpm, 3 s settle, 8 deg   1 of 4   (bearingsweep, and the one corner
--                                           that "answered" never had to move)
--     48 rpm, 6 s hold,   8 deg   4/4      (this tool, twice)
--
-- These are GYROSCOPIC bearings. A spinning gyro resists reorientation in
-- proportion to its angular momentum, so the slew should get SLOWER as rpm
-- rises -- which is the direction that table shows.
--
-- IT IS NOT ONLY A DIAGNOSTIC. velocityhold rate-limits its command to
-- 0.05 deg/s because the HULL is assumed to be the slow element. If the
-- bearing takes seconds to reach the angle it was told, there is a lag in the
-- plant that nothing models.
--
-- THE RESOLUTION FLOOR, stated because it bounds every number below: the pod's
-- sampler is one 160-getter read per cycle, measured at about 1 s, and it
-- pushes telemetry once per cycle. So tiltAngle is quantised to ~1 s and a
-- slew faster than that reads as "arrived by the first sample". Readings are
-- stamped with the POD's own sampleAt, not with receipt time, so transport lag
-- does not smear them.
-- ---------------------------------------------------------------------------

local function newTrace()
    local trace = {}
    for _, corner in ipairs(flight.CORNERS) do
        trace[corner] = { readings = {}, lastAt = nil, arrivedAt = nil }
    end
    return trace
end

-- One sample. Keeps a reading only when the POD's sample clock has advanced,
-- so re-reading the same cached telemetry six times does not become six points.
local function traceSample(trace, commandedAt, magnitude, now)
    for _, corner in ipairs(flight.CORNERS) do
        local pod = banks.getState()[corner]
        local prop = pod and pod.prop
        local angle = prop and tonumber(prop.tiltAngle)
        local at = pod and tonumber(pod.sampleAt)
        local entry = trace[corner]
        -- Fall back to the FCS clock where a pod does not stamp its sample;
        -- then a reading counts as new only when the ANGLE moved.
        local stamp = at or now
        local isNew = (at and entry.lastAt ~= at)
            or (not at and (#entry.readings == 0
                or entry.readings[#entry.readings].angle ~= angle))
        if angle and isNew and stamp >= commandedAt then
            entry.lastAt = at
            if #entry.readings < plan.maxTrace then
                entry.readings[#entry.readings + 1] = { at = stamp, angle = angle }
            end
            if not entry.arrivedAt
                and math.abs(angle) >= magnitude * plan.arrivedFraction then
                entry.arrivedAt = stamp - commandedAt
            end
        end
    end
end

-- IS THE BEARING MOVING, even though it has not arrived?
--
-- Without this the short-settle case diagnoses itself as "the mod stored the
-- target and the bearings did not move" while the trace plainly shows them
-- travelling. A tool that says a moving bearing is stuck is worse than one
-- that says nothing -- it is the shape of every wrong finding in HANDOFF.
local function traceMoving(trace, magnitude)
    local moved = 0
    for _, corner in ipairs(flight.CORNERS) do
        local readings = trace[corner].readings
        if #readings >= 2 then
            local first = math.abs(readings[1].angle)
            local last = math.abs(readings[#readings].angle)
            -- Travelled a real distance, and is not just noise about zero.
            if last - first >= magnitude * 0.1 and last >= magnitude * 0.1 then
                moved = moved + 1
            end
        end
    end
    return moved
end

local function reportTrace(trace, magnitude)
    local anyArrived, anySamples = false, false
    local rows = {}
    for _, corner in ipairs(flight.CORNERS) do
        local entry = trace[corner]
        if #entry.readings > 0 then anySamples = true end
        if entry.arrivedAt then anyArrived = true end
        local seen = {}
        for _, reading in ipairs(entry.readings) do
            seen[#seen + 1] = string.format("%.2f", reading.angle)
        end
        rows[#rows + 1] = string.format("%s %7s  %s", corner,
            entry.arrivedAt and string.format("%.1fs", entry.arrivedAt / 1000)
                or "not yet",
            table.concat(seen, " "))
    end
    if not anySamples then return end

    note(string.format("    slew to %.0f%% of %.2f deg, by the pods' own sample clock:",
        plan.arrivedFraction * 100, magnitude))
    for _, row in ipairs(rows) do note("      " .. row) end
    if not anyArrived then
        note("      NO CORNER ARRIVED inside the window. That is a settle too")
        note("      short for this rpm, not necessarily a bearing that refuses.")
    end
    note("      (the pod sampler is ~1 s, so this cannot resolve faster than that)")
end

local function confirm(label, starboard, airborne)
    local magnitude = math.abs(starboard)
    local azimuth = azimuthFor(starboard, 0)
    windowTiltSends = 0
    local trace, commandedAt = newTrace(), nil
    local before = snapshot()

    local slowestLoop, previousAt = 0, os.epoch("utc")
    local tiltAtOpen, propAtOpen = tiltMessages, propMessages
    local openedAt = os.epoch("utc")
    local peakSpeed, endRoll, endPitch, endGain, endDrift = 0, 0, 0, nil, nil
    local stalled = nil

    session.cheapRead = true
    local stop = session:hold(plan.confirmSeconds, function(state, now)
        -- Altitude hold ONLY in the air. On the ground commanded.collective
        -- stays 0, which is what makes the ground half safe: the banks are
        -- armed but every ion is at zero.
        if airborne then
            session:trim(plan.holdGain, flight.MAX_CLIMB_RATE, 0, state)
        end
        commandProps(feed(state, now))
        commandTilt(starboard, 0)
        -- The instant the command first went out. Everything the slew number
        -- means is measured from here.
        if not commandedAt and windowTiltSends > 0 then commandedAt = now end
        if commandedAt then traceSample(trace, commandedAt, magnitude, now) end

        local elapsed = now - previousAt
        if elapsed > slowestLoop then slowestLoop = elapsed end
        previousAt = now

        -- Came back from a stall: neutralise before anything else. The craft
        -- has been flying on a standing command with nothing watching it.
        if elapsed > plan.stallSeconds * 1000 then
            stalled = elapsed / 1000
            commandTilt(0, 0)
            return string.format("LOOP STALLED for %.1f s -- neutralised."
                .. " Nothing was watching the craft for that long.", elapsed / 1000)
        end

        if state and state.valid then
            local speed = speedOf(state)
            if speed > peakSpeed then peakSpeed = speed end
            endRoll, endPitch = state.roll or 0, state.pitch or 0
            endDrift = displacement(state) or endDrift
            local y = session:craftY(state)
            if y and session.groundY then endGain = y - session.groundY end
        end

        if airborne then
            return limits(state)
        end
        -- The ground half's only limit: it must not be airborne.
        if endGain and endGain > plan.liftAbort then
            return string.format("LIFTED to +%.2f during a ground check", endGain)
        end
        return nil
    end)

    -- READ BEFORE CLEARING. Reading after the clear would sample a bearing on
    -- its way back to zero and call it a failure.
    local after = snapshot()
    clearTilt()

    local shown, cmdShown, answered, seconds = {}, {}, 0, (os.epoch("utc") - openedAt) / 1000
    local rejects, timeouts, inactive, noTelemetry = 0, 0, 0, 0
    local podSaw = 0
    for _, corner in ipairs(flight.CORNERS) do
        local pod = after[corner]
        local angle = pod.tiltAngle
        shown[#shown + 1] = string.format("%s %s", corner,
            angle and string.format("%.2f", angle) or "--")
        cmdShown[#cmdShown + 1] = string.format("%s %s", corner,
            pod.commandedTilt and string.format("%.2f", pod.commandedTilt) or "--")
        if angle and math.abs(angle) >= magnitude * plan.answeredFraction then
            answered = answered + 1
        end
        -- Did the POD accept THIS command? Angle AND azimuth, because the
        -- angle alone cannot tell this confirm's 1.00 from the last one's.
        if pod.commandedTilt
            and math.abs(pod.commandedTilt - magnitude) < plan.resendDeadbandDegrees
            and (type(pod.commandedTiltAzimuth) ~= "number"
                or azimuthApart(pod.commandedTiltAzimuth, azimuth) < 5) then
            podSaw = podSaw + 1
        end
        rejects = rejects + (pod.rejected - before[corner].rejected)
        timeouts = timeouts + (pod.timeouts - before[corner].timeouts)
        if pod.active == false then inactive = inactive + 1 end
        if not pod.telemetry then noTelemetry = noTelemetry + 1 end
    end

    -- PER BEARING, across all four corners.
    local bearingLines, storedTotal, movedTotal, bearingsSeen = {}, 0, 0, 0
    for _, corner in ipairs(flight.CORNERS) do
        local rows, stored, moved, seen = bearingRows(corner, after[corner], magnitude)
        if rows then
            for _, row in ipairs(rows) do bearingLines[#bearingLines + 1] = row end
            storedTotal = storedTotal + stored
            movedTotal = movedTotal + moved
            bearingsSeen = bearingsSeen + seen
        end
    end

    local messages = (tiltMessages - tiltAtOpen) + (propMessages - propAtOpen)
    local ok = answered == #flight.CORNERS

    note("")
    note(string.format("  %s -- commanded %+.2f deg", label, starboard))
    note("    bearing reports:  " .. table.concat(shown, "  "))
    note("    pod believes:     " .. table.concat(cmdShown, "  "))
    note(string.format("    %d/%d answered   pod accepted %d/%d   rejects %+d"
        .. "   timeouts %+d", answered, #flight.CORNERS, podSaw,
        #flight.CORNERS, rejects, timeouts))

    -- THE TRANSPORT A/B, said out loud on every confirm. A wired corner
    -- answering while a wireless one does not is the whole experiment, and it
    -- must not depend on anyone remembering which corners were wired.
    local byTransport = {}
    for _, corner in ipairs(flight.CORNERS) do
        local kind = transportOf(after[corner])
        byTransport[kind] = byTransport[kind] or { ok = 0, total = 0, corners = {} }
        local entry = byTransport[kind]
        entry.total = entry.total + 1
        local angle = after[corner].tiltAngle
        if angle and math.abs(angle) >= magnitude * plan.answeredFraction then
            entry.ok = entry.ok + 1
        end
        entry.corners[#entry.corners + 1] = corner
    end
    -- A CLEAN SPLIT: one transport answered on every corner and another
    -- answered on none. That is the experiment's headline and it must not be
    -- reported as a bearing fault, which is what the first version did.
    local wonKind, lostKind
    for kind, entry in pairs(byTransport) do
        if entry.total > 0 and entry.ok == entry.total then wonKind = kind end
        if entry.total > 0 and entry.ok == 0 then lostKind = kind end
    end
    local transportSplit = (wonKind and lostKind and wonKind ~= lostKind)
        and { won = wonKind, lost = lostKind,
              wonCorners = table.concat(byTransport[wonKind].corners, " "),
              lostCorners = table.concat(byTransport[lostKind].corners, " ") }
        or nil

    local kinds = {}
    for _, kind in ipairs({ "wired", "wireless", "?" }) do
        local entry = byTransport[kind]
        if entry then
            kinds[#kinds + 1] = string.format("%s %d/%d (%s)", kind, entry.ok,
                entry.total, table.concat(entry.corners, " "))
        end
    end
    if #kinds > 1 then
        note("    by transport:  " .. table.concat(kinds, "   "))
    end
    note(string.format("    %.1f msg/s   slowest loop %.0f ms   alt %s"
        .. "   drift %s   peak %.2f blocks/s",
        messages / math.max(seconds, 0.001), slowestLoop,
        endGain and string.format("%+.1f", endGain) or "?",
        endDrift and string.format("%.0f", endDrift) or "?", peakSpeed))
    note(string.format("    roll %+.2f  pitch %+.2f", endRoll or 0, endPitch or 0))
    reportTrace(trace, magnitude)

    -- The per-bearing rows, printed whenever they disagree with each other or
    -- with the command. A pair that answers together needs no explanation.
    if bearingsSeen > 0 and (movedTotal < bearingsSeen or storedTotal < bearingsSeen) then
        note(string.format("    per bearing: %d/%d stored the target, %d/%d moved",
            storedTotal, bearingsSeen, movedTotal, bearingsSeen))
        local row = {}
        for _, line in ipairs(bearingLines) do
            row[#row + 1] = line
            if #row == 2 then
                note("      " .. table.concat(row, "   "))
                row = {}
            end
        end
        if #row > 0 then note("      " .. table.concat(row, "   ")) end
    end

    -- THE DECISION TABLE. Only reached on a failure, and it says which of the
    -- three layers the command died in rather than "it did not work".
    local verdict
    if ok then
        verdict = "OK"
        note("    -> ALL FOUR ANSWERED.")
    elseif noTelemetry > 0 then
        verdict = "NO TELEMETRY"
        note(string.format("    -> %d corner(s) sent no prop telemetry at all."
            .. " Nothing can be concluded", noTelemetry))
        note("       about the bearings from this confirm.")
    elseif transportSplit then
        verdict = string.format("%s OK, %s DEAD", string.upper(transportSplit.won),
            string.upper(transportSplit.lost))
        note(string.format("    -> SPLIT BY TRANSPORT. Every %s corner answered (%s) and",
            transportSplit.won, transportSplit.wonCorners))
        note(string.format("       no %s corner did (%s).",
            transportSplit.lost, transportSplit.lostCorners))
        note("       Same FCS, same loop, same command, same instant -- the only")
        note("       thing that differs is how the command travelled. That is the")
        note("       experiment answering: the failure is in the transport, not in")
        note("       the flight code, the pods, or the bearings.")
    elseif rejects > 0 then
        verdict = "POD REFUSED"
        note("    -> THE POD REFUSED THE COMMAND. commandsRejected rose during")
        note("       this window, and a rejectReply records NO fault -- which is")
        note("       why 'no faults' never ruled this out. Reasons seen:")
        for _, corner in ipairs(flight.CORNERS) do
            if after[corner].rejected > before[corner].rejected then
                note(string.format("       %s: %s", corner,
                    tostring(after[corner].lastReject)))
            end
        end
    elseif podSaw == 0 and not sawCommandedTiltEver then
        verdict = "DIAGNOSIS BLIND"
        note("    -> CANNOT TELL. No corner has reported commandedTilt at any point")
        note("       in this run, which means the POD firmware is older than")
        note("       pod/payload.lua in the repo and does not publish the field.")
        note("       An absent field is indistinguishable from 'the pod never saw")
        note("       the command', so nothing is concluded. Redeploy pod-template")
        note("       to all four pod computers and run this again -- the bearing")
        note("       readback above is still true, just not diagnosable.")
    elseif podSaw == 0 then
        verdict = "NEVER ARRIVED"
        note("    -> THE COMMAND NEVER REACHED THE PODS. No corner's")
        note("       commandedTilt moved to the commanded angle and nothing was")
        note("       rejected, so the set_tilt was lost on the link.")
    elseif inactive > 0 then
        verdict = "BEARINGS INACTIVE"
        note(string.format("    -> %d corner(s) report prop.active FALSE. At 0 rpm"
            .. " a bearing", inactive))
        note("       STORES the target and ignores it. Check the props are turning.")
    elseif traceMoving(trace, magnitude) > 0 then
        verdict = "STILL SLEWING"
        note("    -> THE BEARINGS ARE MOVING AND THE WINDOW ENDED FIRST.")
        note("       The trace above shows them travelling toward the commanded")
        note("       angle and not reaching it. THIS IS NOT A FAULT -- it is a")
        note(string.format("       settle too short for %d rpm at %.2f deg. Re-run with a",
            plan.propRpm, magnitude))
        note("       longer --settle before concluding anything about the craft.")
        note("       These are GYROSCOPIC bearings: the faster the props turn,")
        note("       the more angular momentum resists reorientation, so the")
        note("       settle that worked at a lower rpm will not work here.")
    elseif bearingsSeen > 0 and storedTotal == 0 then
        verdict = "TARGET NEVER STORED"
        note("    -> setManualTarget DID NOT TAKE. The pod accepted the command")
        note("       and called setManualTarget, but getManualTarget reads NOTHING")
        note("       back out of the mod on any bearing. The failure is between")
        note("       the pod and the mod, not in the link and not in the bearing.")
        note("       pod/main.lua discards setManualTarget's per-bearing error, so")
        note("       redeploy pod-template for the fault text that names it.")
    elseif bearingsSeen > 0 and storedTotal > 0 and movedTotal == 0 then
        verdict = "STORED, NOT OBEYED"
        note("    -> THE MOD STORED THE TARGET AND THE BEARINGS DID NOT MOVE.")
        note("       getManualTarget reads the commanded vector back, and")
        note("       getTiltAngle stays at zero. props.lua documents exactly this")
        note("       at 0 RPM -- 'the target is stored and completely ignored' --")
        note("       so check the props are ACTUALLY turning, whatever")
        note("       prop.active says. This is the strongest single clue the")
        note("       craft can give and no tool has ever read it before.")
    else
        verdict = "BEARING IGNORED IT"
        note("    -> THE POD APPLIED IT AND THE BEARING DID NOT MOVE.")
        note("       commandedTilt tracks the command, nothing was rejected, the")
        note("       bearings report ACTIVE, and tiltAngle stayed put. That is the")
        note("       mod layer, not the link and not this code.")
        note("       NOTE THE BLIND SPOT: props.setTilt's per-bearing")
        note("       setManualTarget error is discarded by pod/main.lua, so a")
        note("       stale bearing peripheral looks exactly like this and logs")
        note("       nothing. Do not conclude further without that one-line")
        note("       pod change.")
    end

    if stalled then
        note(string.format("    ** THE LOOP STALLED for %.1f s during this confirm."
            .. " The tilt was", stalled))
        note("    ** neutralised. This confirm says nothing about the bearings.")
        verdict = "STALLED"
    end

    results[#results + 1] = {
        label = label, verdict = verdict, ok = ok, answered = answered,
        podSaw = podSaw, rejects = rejects, timeouts = timeouts,
        gain = endGain, drift = endDrift, peak = peakSpeed,
        slowestLoop = slowestLoop, stop = stop,
    }
    return ok, stop
end

local function coast(seconds, airborne)
    session.cheapRead = true
    return session:hold(seconds, function(state, now)
        if airborne then
            session:trim(plan.holdGain, flight.MAX_CLIMB_RATE, 0, state)
        end
        commandProps(feed(state, now))
        commandTilt(0, 0)
        if state and state.valid then displacement(state) end
        if airborne then return limits(state) end
        return nil
    end)
end

-- ---------------------------------------------------------------------------

local function report()
    note("")
    note("== RESULT ==")
    note("")
    note("  where              answered  pod saw  rejects  timeouts   alt   verdict")
    for _, entry in ipairs(results) do
        note(string.format("  %-17s   %d/4      %d/4     %+4d     %+5d   %5s   %s",
            entry.label, entry.answered, entry.podSaw, entry.rejects,
            entry.timeouts,
            entry.gain and string.format("%+.0f", entry.gain) or "?",
            entry.verdict))
    end

    local ground, groundOk, air, airOk = 0, 0, 0, 0
    for _, entry in ipairs(results) do
        if entry.gain and entry.gain > plan.groundedGain then
            air = air + 1
            if entry.ok then airOk = airOk + 1 end
        else
            ground = ground + 1
            if entry.ok then groundOk = groundOk + 1 end
        end
    end

    note("")
    note(string.format("  ground %d/%d answered      air %d/%d answered",
        groundOk, ground, airOk, air))

    local splits = 0
    for _, entry in ipairs(results) do
        if entry.verdict:find("DEAD") then splits = splits + 1 end
    end
    if splits > 0 then
        note("")
        note(string.format("  %d of %d confirms SPLIT BY TRANSPORT. That is the answer to the",
            splits, #results))
        note("  2026-08-28 blackout: the command reaches one bus and not the other,")
        note("  on the same craft at the same instant. Nothing about the bearings,")
        note("  the pods or the control loop distinguishes those corners.")
    end
    note("")

    if ground > 0 and air > 0 and groundOk == ground and airOk == 0 then
        note("  THE FAULT IS BEING AIRBORNE, not this code. The same function")
        note("  with the same command answered on the ground and did not answer")
        note("  in the air, minutes apart, on the same craft.")
    elseif ground > 0 and air > 0 and groundOk == ground and airOk < air then
        note("  INTERMITTENT IN THE AIR ONLY. Look at WHICH air confirms failed:")
        note("  the first is from a near-stationary hover and tests ALTITUDE; the")
        note("  later ones follow real displacement and test MOTION. Failing only")
        note("  late points at the drift, which points at chunk loading.")
    elseif groundOk < ground then
        note("  IT FAILED ON THE GROUND TOO. That is new -- five ground runs have")
        note("  never failed -- so something on the craft has changed. Do not fly")
        note("  anything else until /fcs/bearingsweep.lua is understood.")
    elseif air == 0 and groundOk == ground then
        note("  THE GROUND HALF PASSED, which is what it has always done -- five")
        note("  ground runs, five successes. It says nothing about the fault on")
        note("  its own. The flight is the experiment; run this without")
        note("  --ground-only.")
    elseif airOk == air and groundOk == ground then
        note("  EVERYTHING ANSWERED. The fault did not reproduce on this run. It")
        note("  is intermittent -- two of six flights -- so ONE clean run is not")
        note("  evidence that it is gone. Fly this again; the point of a 3 minute")
        note("  tool is the hit rate, not the single result.")
    end

    note("")
    note("  Run /fcs/bearingsweep.lua either side of this as the independent")
    note("  cross-check. It is a different code path, so it cannot separate")
    note("  'airborne' from 'this tool' -- that is what the ground confirm above")
    note("  is for -- but it is the standing reference this craft has five clean")
    note("  runs of.")
end

-- ---------------------------------------------------------------------------

local function mainLoop()
    note("TILT CHECK -- does a bearing answer set_tilt in the air?")
    note("utc_ms=" .. tostring(os.epoch("utc")))
    note(string.format("probe %.2f deg   %d air confirms   hold +%d   props %d rpm",
        plan.tiltDegrees, plan.repeats, plan.holdGain, plan.propRpm))
    note("Nothing is measured. This is a hit rate.")
    note("")

    if not session:preflight() then
        note("PREFLIGHT FAILED -- not flying.")
        return
    end

    note("== GROUND ==")
    note(string.format("  props to %d rpm. Ions stay at zero collective, so there",
        plan.propRpm))
    note("  is no path to lift -- checked anyway.")
    local spun, reason = session:setAllProps(plan.propRpm)
    commandedProps = true
    if not spun then
        note("  could not set base props: " .. tostring(reason))
        return
    end
    -- Let the props reach speed. A bearing below its rpm is INACTIVE and
    -- stores the target rather than obeying it, which would read as the fault
    -- this tool is looking for.
    coast(6, false)

    local groundOk, groundStop = confirm("ground, before", plan.tiltDegrees, false)
    if groundStop then
        note("")
        note("  ground check stopped: " .. tostring(groundStop))
        return
    end
    if not groundOk then
        note("")
        note("  ** THE GROUND CHECK FAILED. NOT FLYING.")
        note("  ** Five ground runs have never failed. Something on the craft has")
        note("  ** changed, and flying now would measure that instead of the")
        note("  ** airborne fault. Run /fcs/bearingsweep.lua.")
        report()
        return
    end

    if not sawCommandedTiltEver then
        note("")
        note("  ** THE PODS ARE NOT PUBLISHING commandedTilt.")
        note("  ** The bearings answered, so the flight is still worth making --")
        note("  ** but if a confirm fails in the air this tool will NOT be able")
        note("  ** to say whether the command was lost, refused, or applied and")
        note("  ** ignored. That diagnosis is the reason it exists. Redeploy")
        note("  ** pod-template to the four pod computers first if you can.")
    end

    if groundOnly then
        report()
        return
    end

    note("")
    note("== CLIMB to +" .. plan.holdGain .. " ==")
    if not session:arm() then
        note("could not arm -- not flying.")
        return
    end
    if not session:climb(plan.holdGain, plan.climbTimeout) then
        note("climb failed or aborted")
        clearTilt()
        session:descend()
        return
    end

    note("")
    note("== AIR ==")
    note("  signs alternate so the craft stays near where it took off. Confirm 1")
    note("  is from a near-stationary hover and tests ALTITUDE; the later ones")
    note("  follow real displacement and test MOTION.")

    for index = 1, plan.repeats do
        local sign = (index % 2 == 1) and 1 or -1
        local _, stop = confirm(string.format("air %d", index),
            sign * plan.tiltDegrees, true)
        if stop then
            note("")
            note("  stopped during air confirm " .. index .. ": " .. tostring(stop))
            break
        end
        if index < plan.repeats then
            local coastStop = coast(plan.betweenSeconds, true)
            if coastStop then
                note("")
                note("  stopped between confirms: " .. tostring(coastStop))
                break
            end
        end
    end

    clearTilt()
    note("")
    note("== descend and land ==")
    session:descend()

    -- The second ground confirm, on the same craft that just flew. If the air
    -- confirms failed and this one passes, the craft did not break -- it was
    -- airborne.
    note("")
    note("== GROUND, after ==")
    coast(4, false)
    confirm("ground, after", plan.tiltDegrees, false)

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
    if commandedTilt then clearTilt() end

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
