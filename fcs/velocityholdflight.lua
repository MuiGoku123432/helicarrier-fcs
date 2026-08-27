-- Layer 2: measure what a bearing tilt does to VELOCITY, then hold velocity at
-- zero with it.
--
--   /fcs/velocityholdflight.lua --ground-only    the maths and the plan
--   /fcs/velocityholdflight.lua --measure-only   phase A: the net gains
--   /fcs/velocityholdflight.lua                  measure, then hold
--   /fcs/velocityholdflight.lua --axis roll      one axis only, half the time
--
-- ---------------------------------------------------------------------------
-- WHAT MAKES THIS DIFFERENT FROM EVERY PREVIOUS ATTEMPT AT STATION KEEPING
--
-- The actuator is INVERTED and SLOW, and as of 2026-08-27 both facts are
-- measured rather than suspected. A commanded tilt makes a horizontal force
-- (+0.8165 blocks/s per degree, fast) AND rolls the hull (which is worth
-- -1.75 blocks/s per degree on the roll axis, slow). The hull term is bigger.
--
--     roll axis    NET  -0.934 blocks/s per commanded degree
--     pitch axis   NET  -0.376
--
-- **A tilt commanded to push the craft starboard moves it PORT** once the hull
-- has caught up -- after moving it starboard for the first few seconds. That
-- sign change between fast and slow IS the 1.76 -> 11.5 blocks/s runaway: a
-- quick loop closes on the fast half, which is the half with the wrong sign.
--
-- So this tool does two things no previous one did:
--
--   PHASE A measures the net gain per axis at STEADY STATE, by reverse pairs,
--   with windows long enough for the hull to have finished moving. It also
--   records the FAST response over the first seconds of the same step, so the
--   inversion is a measurement in the log rather than a claim in a comment.
--
--   PHASE B closes the loop with a hard RATE LIMIT on the commanded tilt --
--   0.05 deg/s, so a full 4 degree command takes 80 s to build. The loop
--   cannot outrun the half of the plant that makes it stable.
--
-- THE ROLL DAMPER RUNS THROUGHOUT. Layer 1 at 0.15 s under layer 2 at tens of
-- seconds: that separation is what stops the two loops chasing each other, and
-- it is why the damper had to fly first.
--
-- JUDGED ON NET DISPLACEMENT, never mean ground speed. Mean speed is a
-- magnitude, so an oscillating hull contributes to it even when the mean
-- velocity is exactly zero -- trim run 1 was judged on it and could not be.

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
local velocityhold = require("fcs.velocityhold")
local bearinggain = require("fcs.bearinggain")

local plan = {
    propRpm = 64,
    holdGain = 12,
    climbTimeout = 90,
    loopSeconds = 0.15,

    -- ONE degree, lowered from two after the first flight that actually
    -- reached the bearings. The net gain measured -3.36 blocks/s per degree on
    -- the roll axis, so a 2 degree probe drove the craft to 6.9 blocks/s
    -- against an 8.0 abort -- 86% of the limit, on a number nobody had
    -- measured before that flight. At 1 degree the same probe is about
    -- 3.4 blocks/s.
    --
    -- trimflight flew 2 degrees twice "without incident", and that is not the
    -- reassurance it looks like: it flew them through the command flood, so
    -- the tilt it actually applied is unknown. See THE VELOCITY LOOP.
    probeTilt = 1.0,

    -- LONG ENOUGH FOR THE HULL TO HAVE FINISHED. The net gain is a
    -- steady-state quantity and the hull is the slow half: roll rings at
    -- 32.7 s, pitch settles overdamped in about 30 s. A 12 s settle would
    -- measure the fast half and get the sign backwards.
    settleSeconds = 35,
    measureSeconds = 30,
    -- The first seconds of the step, where the direct force is all there is.
    fastSeconds = 6,

    -- Phase B windows. One period of the roll oscillation each, so the AC
    -- averages out of the net displacement.
    baselineSeconds = 60,
    -- LONGER THAN THE BASELINE, and deliberately. The loop sees a 15 s mean
    -- before it commands anything and then builds at 0.05 deg/s, so a window
    -- the same length as the baseline measures a loop that is still arriving.
    holdSeconds = 120,
    -- The mean the loop acts on. Comparable to the hull's 32.7 s oscillation,
    -- so the AC averages out and the DC drift is what remains.
    averageSeconds = 15,

    -- HOW OFTEN A SET-AND-HOLD COMMAND IS RE-SENT.
    --
    -- set_tilt and set_rpm have NO watchdog pod-side -- "it is set-and-hold"
    -- (pod/main.lua) -- so re-sending them every 0.15 s sample buys nothing
    -- except traffic: 4 corners x 2 command types x 6.7 Hz is about 107
    -- messages a second on top of the ion keepalive.
    --
    -- MEASURED CONSEQUENCE. The ground sweep sends one set_tilt and waits, and
    -- all four corners answer 8.00. This tool re-sent at the sample rate and
    -- all four answered 0.00, on the same craft, twenty minutes apart -- while
    -- the pods logged 72 COMMAND_TIMEOUTs, meaning ion commands were not
    -- getting through inside 750 ms either. One saturated link explains both.
    --
    -- A dropped set-and-hold command still needs re-sending; it does not need
    -- re-sending seven times a second. Any CHANGE goes out immediately.
    resendPeriodMs = 1000,
    -- HOW BIG A CHANGE IS WORTH A MESSAGE. Exact inequality is not enough: the
    -- loop is rate-limited to 0.05 deg/s, so at a 0.15 s sample it moves the
    -- command by 0.0075 degrees EVERY iteration and "changed" is always true.
    -- The throttle then never engages, which is how phase B of run 4 sent at
    -- full rate again -- 212 COMMAND_TIMEOUTs and a slowest loop of 2419 ms
    -- against a 750 ms watchdog -- while phase A, holding a fixed tilt, was
    -- clean. A twentieth of a degree is below anything the bearings resolve.
    resendDeadbandDegrees = 0.05,

    abortSpeed = velocityhold.DEFAULTS.abortSpeed,
    abortTilt = velocityhold.DEFAULTS.abortTilt,
    groundedGain = 0.6,
}

local args = { ... }
local groundOnly, measureOnly, onlyAxis = false, false, nil
for index = 1, #args do
    local argument = args[index]
    if argument == "--ground-only" then groundOnly = true
    elseif argument == "--measure-only" then measureOnly = true
    elseif argument == "--axis" then onlyAxis = args[index + 1]
    elseif argument == "--probe" then
        plan.probeTilt = tonumber(args[index + 1]) or plan.probeTilt
    end
end

local lines = {}
local function note(text)
    lines[#lines + 1] = text
    print(text)
end

local function save()
    local ok, file = pcall(fs.open, "/fcs/velocityholdflight_result.txt", "w")
    if ok and file then
        file.write(table.concat(lines, "\n"))
        file.close()
        print("")
        print("Saved to /fcs/velocityholdflight_result.txt")
    end
end

local session = flight.new({
    config = config,
    profile = profile,
    atmosphere = atmosphere,
    note = note,
    sampleSeconds = plan.loopSeconds,
})

-- What phase A measures. Held here, not written into velocityhold, so a later
-- run cannot inherit this one's numbers.
local measured = { starboard = nil, bow = nil }

local rate = rolldamp.newRateEstimator({ windowSeconds = 0.6 })
local startedAt = os.epoch("utc")
local commandedProps, commandedTilt = false, false
local applied = { starboard = 0, bow = 0 }

local function feed(state, now)
    if state and state.valid and state.roll then
        rate:push((now - startedAt) / 1000, state.roll)
    end
    return rate:rate()
end

-- Fire and forget, mirrored, re-sent every loop -- the link drops a few percent
-- and set_tilt is set-and-hold, so the loop IS the retry. A blocking waiter
-- here would be a full second of silence per corner.
local lastTiltSentAt, tiltMessages = 0, 0

local function commandTilt(starboard, bow)
    local now = os.epoch("utc")
    local changed = math.abs(starboard - applied.starboard) >= plan.resendDeadbandDegrees
        or math.abs(bow - applied.bow) >= plan.resendDeadbandDegrees
        -- Going to zero always goes out: it is the command that stops things.
        or (starboard == 0 and bow == 0
            and (applied.starboard ~= 0 or applied.bow ~= 0))
    -- Unchanged and recently sent: nothing to say. The pods hold it.
    if not changed and (now - lastTiltSentAt) < plan.resendPeriodMs then
        return
    end

    local magnitude = math.sqrt(starboard * starboard + bow * bow)
    local heading = math.deg(math.atan2(starboard, bow))
    local azimuth = lateralhold.azimuthForHeading(heading)
    for _, corner in ipairs(flight.CORNERS) do
        banks.send(corner, "set_tilt", {
            angle = magnitude, azimuth = azimuth, bearing = nil, mirror = true,
        })
        tiltMessages = tiltMessages + 1
    end
    applied.starboard, applied.bow = starboard, bow
    lastTiltSentAt = now
    if magnitude > 0 then commandedTilt = true end
end

local function clearTilt()
    -- Never throttled. Clearing the tilt is the one command that must not wait
    -- on a resend window, and it resets the throttle so the next command is
    -- seen as a change.
    applied.starboard, applied.bow = 0, 0
    lastTiltSentAt = 0
    for _, corner in ipairs(flight.CORNERS) do
        banks.send(corner, "set_tilt",
            { angle = 0, azimuth = 0, bearing = nil, mirror = true })
    end
    applied.starboard, applied.bow = 0, 0
end

local lastPropsSentAt, lastDifferential, propMessages = 0, nil, 0

local function commandProps(rollRate)
    local differential = rollRate and rolldamp.differentialFor(rollRate) or 0
    local now = os.epoch("utc")
    -- The differential is an INTEGER, so "changed" is exact and the damper
    -- still gets every command it asks for the instant it asks. What is
    -- throttled is repeating a number the pods already hold.
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
-- CONFIRM THE TILT FROM TELEMETRY. THE RULE, and run 1 is why it is here.
--
-- Phase A of the first flight measured a net gain of +0.0020 blocks/s per
-- degree on the roll axis and -0.0069 on pitch, off windows in which the
-- velocity and the hull attitude were IDENTICAL at +2 and -2 degrees. That is
-- not a small response. That is no response: the bearings never moved, and the
-- tool reported it as a measurement and went looking for which of three
-- earlier measurements was wrong.
--
-- A bearing only obeys a manual target while it is ACTIVE -- "at 0 RPM the
-- target is stored and completely ignored: getTiltAngle stays 0 and
-- getThrustVector does not move" (props.lua). The pods report both `active`
-- and the achieved `tiltAngle` every second, and this tool was not reading
-- either. bearingsweep does; five findings in HANDOFF died of not doing it.
-- ---------------------------------------------------------------------------

-- COMMAND_TIMEOUT means the pod was ARMED and no command reached it inside
-- 750 ms, so it DISARMED and dropped to comms-loss power. It is the pods
-- telling us the control loop is not keeping up.
--
-- Run 1 of this tool logged 72 of them across the four pods in 344 s -- three
-- per pod per minute -- while a GROUND run of the same length on the same day
-- logged zero. Every number that flight produced was taken from a craft whose
-- banks were dropping out several times a minute, and nothing in the report
-- said so. The tool measured a net gain instead and blamed three earlier
-- measurements for disagreeing with it.
local function podTimeouts()
    local total = 0
    for _, corner in ipairs(flight.CORNERS) do
        local pod = banks.getState()[corner]
        local faults = pod and pod.faults
        if type(faults) == "table" then
            for _, fault in ipairs(faults) do
                local count = tostring(fault):match("COMMAND_TIMEOUT x(%d+)")
                if count then
                    total = total + tonumber(count)
                elseif tostring(fault):find("COMMAND_TIMEOUT") then
                    total = total + 1
                end
            end
        elseif type(faults) == "string" then
            local count = faults:match("COMMAND_TIMEOUT x(%d+)")
            if count then total = total + tonumber(count)
            elseif faults:find("COMMAND_TIMEOUT") then total = total + 1 end
        end
    end
    return total
end

local function tiltReadback()
    local reported, missing = {}, {}
    for _, corner in ipairs(flight.CORNERS) do
        local pod = banks.getState()[corner]
        local prop = pod and pod.prop
        if not prop then
            missing[#missing + 1] = corner .. ": no telemetry"
        elseif not prop.active then
            missing[#missing + 1] = corner .. ": bearings NOT ACTIVE"
        elseif type(prop.tiltAngle) ~= "number" then
            missing[#missing + 1] = corner .. ": no tiltAngle reported"
        else
            reported[corner] = prop.tiltAngle
        end
    end
    return reported, missing
end

-- Command a tilt, wait, and refuse to go on unless every corner confirms it.
local function confirmTilt(magnitude)
    note("")
    note(string.format("  confirming the bearings answer a %.1f deg command", magnitude))
    session.cheapRead = true
    session:hold(6, function(state, now)
        session:trim(plan.holdGain, flight.MAX_CLIMB_RATE, 0, state)
        commandProps(feed(state, now))
        commandTilt(magnitude, 0)
    end)

    note(string.format("    outgoing during the check: %d tilt + %d rpm messages"
        .. " (%.0f/s)", tiltMessages, propMessages,
        (tiltMessages + propMessages) / 6))

    local reported, missing = tiltReadback()
    local shown, confirmed = {}, 0
    for _, corner in ipairs(flight.CORNERS) do
        local angle = reported[corner]
        shown[#shown + 1] = string.format("%s %s", corner,
            angle and string.format("%.2f", angle) or "--")
        if angle and math.abs(angle) >= magnitude * 0.5 then confirmed = confirmed + 1 end
    end
    note("    reported tilt: " .. table.concat(shown, "  "))
    for _, reason in ipairs(missing) do note("    " .. reason) end

    commandTilt(0, 0)
    if confirmed == #flight.CORNERS then
        note("    all four corners answered. The actuator is live.")
        return true
    end

    note("")
    note(string.format("  ** ONLY %d OF %d CORNERS ANSWERED. NOT MEASURING.",
        confirmed, #flight.CORNERS))
    note("  ** A gain measured while the bearings are not moving is not a small")
    note("  ** gain, it is no measurement at all -- and run 1 of this tool")
    note("  ** reported exactly that and blamed three earlier measurements.")
    note("  **")
    note("  ** Check, in this order: are the props actually turning (a bearing")
    note("  ** at 0 rpm stores a manual target and ignores it)? Do the pods")
    note("  ** report prop.active? Does /fcs/bearingsweep.lua still get a tilt")
    note("  ** readback of 8.00 on FL -- that is the same command on the ground")
    note("  ** and takes two minutes.")
    return false
end

local function limits(state)
    if not (state and state.valid) then return nil end
    local speed = 0
    local velocity = state.linearVelocityWorld
    if velocity then
        local x = velocity.x or velocity[1] or 0
        local z = velocity.z or velocity[3] or 0
        speed = math.sqrt(x * x + z * z)
    end
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
-- Windows
-- ---------------------------------------------------------------------------

local function horizontal(position)
    if not position then return nil end
    local x = position.x or position[1]
    local z = position.z or position[3]
    if not x or not z then return nil end
    return x, z
end

-- Hold a fixed tilt and report the mean BODY velocity it produced, plus the
-- net displacement and the mean hull angles.
local function measureWindow(label, seconds, starboard, bow, onCommand)
    local sumBow, sumStarboard, count = 0, 0, 0
    local sumRoll, sumPitch = 0, 0
    local firstX, firstZ, firstAt, lastX, lastZ, lastAt
    local fastBow, fastStarboard, fastCount = 0, 0, 0
    local openedAt = os.epoch("utc")
    local timeoutsAtOpen = podTimeouts()
    local slowestLoop, previousAt = 0, openedAt
    session.cheapRead = true

    local stop = session:hold(seconds, function(state, now)
        session:trim(plan.holdGain, flight.MAX_CLIMB_RATE, 0, state)
        commandProps(feed(state, now))
        if onCommand then onCommand(state, now) else commandTilt(starboard, bow) end

        -- THE LOOP PERIOD, because the watchdog is 750 ms and a loop that
        -- misses it disarms the banks. Measured rather than assumed: the plan
        -- says 0.15 s and run 1's pods say something took longer.
        local elapsed = now - previousAt
        if elapsed > slowestLoop then slowestLoop = elapsed end
        previousAt = now

        local limit = limits(state)
        if limit then return limit end

        if state and state.valid then
            local body = velocityhold.components(state, config.axes)
            if body then
                count = count + 1
                sumBow = sumBow + body.bow
                sumStarboard = sumStarboard + body.starboard
                sumRoll = sumRoll + (state.roll or 0)
                sumPitch = sumPitch + (state.pitch or 0)
                if (now - openedAt) / 1000 <= plan.fastSeconds then
                    fastCount = fastCount + 1
                    fastBow = fastBow + body.bow
                    fastStarboard = fastStarboard + body.starboard
                end
            end
            local x, z = horizontal(state.position)
            if x then
                if not firstX then firstX, firstZ, firstAt = x, z, now end
                lastX, lastZ, lastAt = x, z, now
            end
        end
    end)

    if count == 0 then
        note("  " .. label .. ": no usable samples")
        return nil, stop
    end

    local result = {
        bow = sumBow / count,
        starboard = sumStarboard / count,
        roll = sumRoll / count,
        pitch = sumPitch / count,
        count = count,
        fastBow = fastCount > 0 and (fastBow / fastCount) or nil,
        fastStarboard = fastCount > 0 and (fastStarboard / fastCount) or nil,
        netDrift = velocityhold.netDrift(firstX, firstZ, lastX, lastZ,
            (lastAt and firstAt) and ((lastAt - firstAt) / 1000) or nil),
    }

    result.timeouts = podTimeouts() - timeoutsAtOpen
    result.slowestLoop = slowestLoop

    -- The achieved tilt, from the pods, every window. A window whose commanded
    -- and reported tilt disagree is not a measurement of the commanded one.
    local reported = tiltReadback()
    local sum, seen = 0, 0
    for _, angle in pairs(reported) do sum = sum + angle seen = seen + 1 end
    result.reportedTilt = seen > 0 and (sum / seen) or nil

    note(string.format("  %-20s v_bow %+6.3f  v_stbd %+6.3f  roll %+5.2f  pitch %+5.2f"
        .. "  net %5s  tilt %5s  (%d)",
        label, result.bow, result.starboard, result.roll, result.pitch,
        result.netDrift and string.format("%.3f", result.netDrift) or "?",
        result.reportedTilt and string.format("%.2f", result.reportedTilt) or "--",
        count))

    -- THE BANKS DISARMED DURING THIS WINDOW. Said out loud, because everything
    -- above was measured on a craft that kept losing its ions.
    if result.timeouts > 0 then
        note(string.format("    ** %d COMMAND_TIMEOUT%s in this window -- the pods"
            .. " DISARMED. Slowest loop", result.timeouts,
            result.timeouts == 1 and "" or "s"))
        note(string.format("    ** %.0f ms against the pods' 750 ms watchdog. These"
            .. " numbers are suspect.", result.slowestLoop))
    end
    return result, stop
end

local function settleAt(starboard, bow)
    session.cheapRead = true
    return session:hold(plan.settleSeconds, function(state, now)
        session:trim(plan.holdGain, flight.MAX_CLIMB_RATE, 0, state)
        commandProps(feed(state, now))
        commandTilt(starboard, bow)
        return limits(state)
    end)
end

-- ---------------------------------------------------------------------------
-- Phase A: the net gain, per axis, by reverse pairs at steady state
-- ---------------------------------------------------------------------------

local function probeAxis(axis)
    local isStarboard = axis == "starboard"
    local name = isStarboard and "ROLL axis (starboard tilt)" or "PITCH axis (bow tilt)"
    note("")
    note(string.format("  -- %s, +/-%.1f deg --", name, plan.probeTilt))

    local function componentsFor(amount)
        if isStarboard then return amount, 0 else return 0, amount end
    end
    local field = isStarboard and "starboard" or "bow"
    local fastField = isStarboard and "fastStarboard" or "fastBow"

    local settleStop = settleAt(componentsFor(plan.probeTilt))
    if settleStop then note("  " .. settleStop) return nil, settleStop end
    local positive, stopP = measureWindow(string.format("at %+.1f deg", plan.probeTilt),
        plan.measureSeconds, componentsFor(plan.probeTilt))
    if stopP or not positive then return nil, stopP end

    -- The fast response is read from the step INTO the negative side, where
    -- the command reverses by 2T and the hull has not yet moved.
    local reverseOpened = { }
    local negativeSettle = session:hold(plan.fastSeconds, function(state, now)
        session:trim(plan.holdGain, flight.MAX_CLIMB_RATE, 0, state)
        commandProps(feed(state, now))
        commandTilt(componentsFor(-plan.probeTilt))
        local limit = limits(state)
        if limit then return limit end
        if state and state.valid then
            local body = velocityhold.components(state, config.axes)
            if body then
                reverseOpened[#reverseOpened + 1] = body[field]
            end
        end
    end)
    if negativeSettle then note("  " .. negativeSettle) return nil, negativeSettle end

    local settleStop2 = settleAt(componentsFor(-plan.probeTilt))
    if settleStop2 then note("  " .. settleStop2) return nil, settleStop2 end
    local negative, stopN = measureWindow(string.format("at %+.1f deg", -plan.probeTilt),
        plan.measureSeconds, componentsFor(-plan.probeTilt))
    if stopN or not negative then return nil, stopN end

    local gain = velocityhold.netGain(plan.probeTilt, positive[field],
        -plan.probeTilt, negative[field])
    if not gain then
        note("  no gain: the reverse pair did not produce usable samples")
        return nil
    end

    -- A GAIN MEASURED THROUGH A STARVED LINK IS NOT A GAIN. If the banks were
    -- disarming during either half, the craft was not in the state the
    -- measurement assumes and the number should not be carried forward.
    local starved = (positive.timeouts or 0) + (negative.timeouts or 0)
    if starved > 0 then
        note(string.format("  ** %d COMMAND_TIMEOUTs across the pair. The pods disarmed"
            .. " while this was", starved))
        note("  ** being measured, so the craft was not flying the way the")
        note("  ** measurement assumes. NOT USING THIS GAIN.")
        return nil
    end

    -- DID THE ACTUATOR ACTUALLY REVERSE? The reported tilt is a magnitude, so
    -- both halves read about +2; what says the command took is that it is near
    -- the commanded size in BOTH. A pair measured at zero tilt produces a
    -- gain of zero and looks exactly like a craft the bearings cannot move.
    for _, half in ipairs({ { "+", positive }, { "-", negative } }) do
        local angle = half[2].reportedTilt
        if not angle or math.abs(angle) < plan.probeTilt * 0.5 then
            note(string.format("  ** THE %s HALF REPORTED %s deg AGAINST %.1f COMMANDED.",
                half[1], angle and string.format("%.2f", angle) or "nothing",
                plan.probeTilt))
            note("  ** The bearings did not move, so this is not a measurement of")
            note("  ** anything. Do not read the gain below as a small response.")
            return nil
        end
    end

    local direct = bearinggain.perDegree({
        thrustPerBearing = bearinggain.REFERENCE.thrustPerBearing * 4,
    })
    note(string.format("  NET GAIN %+.4f blocks/s per commanded degree", gain))
    note(string.format("  the direct bearing force alone is %+.4f", direct))

    if gain * direct < 0 then
        note("  INVERTED, as predicted: the hull term is larger than the direct")
        note("  force and points the other way. A tilt commanded to push one way")
        note("  moves the craft the OTHER way once the hull has caught up.")
    else
        note("  ** NOT INVERTED. That contradicts the measured coupling and the")
        note("  ** measured bearing gain, which together predict a net of the")
        note("  ** opposite sign. One of the three is wrong -- do NOT close the")
        note("  ** loop on this until it is understood.")
    end

    -- THE FAST RESPONSE, from the first seconds of the reversal. This is the
    -- half of the plant with the other sign, and it is the reason the loop is
    -- rate-limited. Reported as a measurement, not a claim.
    if #reverseOpened > 0 then
        local total = 0
        for _, value in ipairs(reverseOpened) do total = total + value end
        local fast = total / #reverseOpened
        note(string.format("  in the first %.0f s after reversing to %+.1f deg,"
            .. " v_%s was %+.3f", plan.fastSeconds, -plan.probeTilt,
            isStarboard and "stbd" or "bow", fast))
        note(string.format("  (steady state at that tilt: %+.3f)", negative[field]))
        if fast * negative[field] < 0 then
            note("  THE FAST AND SLOW RESPONSES HAVE OPPOSITE SIGNS -- measured, on")
            note("  this flight. That is the runaway, and it is why phase B rate-")
            note("  limits the command.")
        end
    end

    local usable, why = velocityhold.usable(gain)
    if not usable then
        note("  ** " .. tostring(why) .. " -- not usable for the loop.")
        return nil
    end
    return gain
end

-- ---------------------------------------------------------------------------
-- Phase B: the loop
-- ---------------------------------------------------------------------------

local function holdWindow(label, seconds, active)
    local target = { starboard = 0, bow = 0 }
    local command = { starboard = 0, bow = 0 }
    local lastAt = os.epoch("utc")
    local saturated = 0
    local effortSum, effortCount = 0, 0
    -- THE LOOP SEES A MEAN, NOT A READING. The velocity carries the hull's
    -- 32.7 s oscillation on top of the drift being held, and commanding
    -- against the swing injects energy rather than removing it.
    local averager = velocityhold.newAverager({
        windowSeconds = plan.averageSeconds,
    })

    -- Named for what it does rather than for the parameter it is passed as:
    -- tools/test_forwardrefs.lua matches by NAME, and a local sharing a name
    -- with a parameter used earlier in the file reads to it as a forward call.
    -- The checker being blunt is what makes it cheap; this is the cost.
    local function driveLoop(state, now)
        local dt = (now - lastAt) / 1000
        lastAt = now
        if active and state and state.valid then
            local body = velocityhold.components(state, config.axes)
            if body then
                averager:push((now - startedAt) / 1000, body.bow, body.starboard)
            end
            local meanBow, meanStarboard = averager:mean()
            if meanBow then
                local tiltS = velocityhold.tiltFor(meanStarboard, measured.starboard)
                local tiltB = velocityhold.tiltFor(meanBow, measured.bow)
                target.starboard, target.bow = tiltS, tiltB
                if math.abs(tiltS) >= velocityhold.DEFAULTS.maxTiltDegrees
                    or math.abs(tiltB) >= velocityhold.DEFAULTS.maxTiltDegrees then
                    saturated = saturated + 1
                end
            end
        end
        -- RATE LIMITED even when the target is zero, so switching the loop off
        -- does not step the bearings either.
        command.starboard = velocityhold.slew(command.starboard, target.starboard, dt)
        command.bow = velocityhold.slew(command.bow, target.bow, dt)
        commandTilt(command.starboard, command.bow)
        effortSum = effortSum + math.sqrt(command.starboard * command.starboard
            + command.bow * command.bow)
        effortCount = effortCount + 1
    end
    local lastTarget = target

    local result, stop = measureWindow(label, seconds, 0, 0, driveLoop)
    if result then
        result.finalTilt = { starboard = command.starboard, bow = command.bow }
        result.wantedTilt = { starboard = lastTarget.starboard, bow = lastTarget.bow }
        result.saturated = saturated
        result.effort = effortCount > 0 and (effortSum / effortCount) or 0
    end
    return result, stop
end

-- ---------------------------------------------------------------------------
-- Ground mode
-- ---------------------------------------------------------------------------

local function groundCheck()
    note("GROUND CHECK -- commanding nothing")
    note("")

    local direct = bearinggain.perDegree({
        thrustPerBearing = bearinggain.REFERENCE.thrustPerBearing * 4,
    })
    local hull = velocityhold.hullDriftPerDegree()
    note(string.format("  direct bearing force   %+.4f blocks/s per commanded deg",
        direct))
    note("  (from the ground sweep: getThrust x4 at 64 rpm. Re-run")
    note("   /fcs/bearingsweep.lua after any change to the hull's load.)")
    note(string.format("  hull tilt -> drift     %+.4f blocks/s per HULL deg", hull))
    note("")
    note("  the measured couplings, and what they predict for the NET:")
    for _, entry in ipairs({
        { "roll  (starboard tilt)", -0.8205, 1 },
        { "pitch (bow tilt)", 0.5588, -1 },
    }) do
        local net, hullTerm = velocityhold.predictNet(direct, entry[2], entry[3])
        note(string.format("    %-22s coupling %+.4f -> hull %+.3f, NET %+.3f",
            entry[1], entry[2], hullTerm, net))
    end
    note("")
    note("  THE NET IS INVERTED ON BOTH AXES. A tilt commanded to push starboard")
    note("  moves the craft PORT once the hull catches up -- after moving it")
    note("  starboard for the first few seconds. That sign change between fast")
    note("  and slow is the 1.76 -> 11.5 blocks/s runaway.")
    note("")
    note("  These are PREDICTIONS -- three measured numbers multiplied together,")
    note("  which is not a measurement. Phase A measures the net directly.")
    note("")
    note(string.format("  the loop, once measured: rate limit %.2f deg/s (a full %.1f deg",
        velocityhold.DEFAULTS.slewPerSecond, velocityhold.DEFAULTS.maxTiltDegrees))
    note(string.format("  command takes %.0f s to build), relaxation %.1f, deadband"
        .. " %.2f blocks/s",
        velocityhold.DEFAULTS.maxTiltDegrees / velocityhold.DEFAULTS.slewPerSecond,
        velocityhold.DEFAULTS.relaxation, velocityhold.DEFAULTS.deadbandSpeed))
    note("")
    note("  what it would command, at the PREDICTED roll-axis net:")
    local predicted = velocityhold.predictNet(direct, -0.8205, 1)
    for _, speed in ipairs({ -1.7, -0.8, -0.05, 0.05, 0.8, 1.7 }) do
        local tilt = velocityhold.tiltFor(speed, predicted)
        note(string.format("    drifting %+.2f blocks/s -> tilt %+.3f deg", speed, tilt))
    end
    note("")

    local refused = velocityhold.tiltFor(1.5, nil)
    note(string.format("  with nothing measured it commands %d. That is the point:", refused))
    note("  the loop refuses until phase A has run.")
    note("")

    local state = session:read()
    if state and state.valid then
        note(string.format("  live attitude: roll %+.3f  pitch %+.3f",
            state.roll or 0, state.pitch or 0))
    else
        note("  no valid attitude sample")
    end
end

-- ---------------------------------------------------------------------------
-- Report
-- ---------------------------------------------------------------------------

local function report(before, after)
    note("")
    note("== RESULT ==")
    note("")
    note("                          LOOP OFF       LOOP ON")
    note(string.format("  mean v_bow            %+10.3f    %+10.3f  blocks/s",
        before.bow, after.bow))
    note(string.format("  mean v_starboard      %+10.3f    %+10.3f  blocks/s",
        before.starboard, after.starboard))
    note(string.format("  NET drift             %10s    %10s  blocks/s",
        before.netDrift and string.format("%.3f", before.netDrift) or "?",
        after.netDrift and string.format("%.3f", after.netDrift) or "?"))
    note(string.format("  mean roll / pitch      %+5.2f/%+5.2f    %+5.2f/%+5.2f  deg",
        before.roll, before.pitch, after.roll, after.pitch))
    note("")
    note(string.format("  the loop ended at %+.3f starboard, %+.3f bow",
        after.finalTilt.starboard, after.finalTilt.bow))
    -- STILL BUILDING? The rate limit is deliberately slower than the hull, so a
    -- window shorter than the build time measures a loop that never finished
    -- arriving. Saying so is the difference between "the gain is wrong" and
    -- "the window was short", and those have opposite fixes.
    if after.wantedTilt then
        local shortfall = math.max(
            math.abs(after.wantedTilt.starboard - after.finalTilt.starboard),
            math.abs(after.wantedTilt.bow - after.finalTilt.bow))
        if shortfall > 0.1 then
            note(string.format("  IT WAS STILL BUILDING: it wanted %+.3f / %+.3f and had"
                .. " reached %+.3f / %+.3f.",
                after.wantedTilt.starboard, after.wantedTilt.bow,
                after.finalTilt.starboard, after.finalTilt.bow))
            note(string.format("  At %.2f deg/s that shortfall needs another %.0f s. The"
                .. " result below is a", velocityhold.DEFAULTS.slewPerSecond,
                shortfall / velocityhold.DEFAULTS.slewPerSecond))
            note("  LOWER BOUND on what the loop can do -- lengthen the window before")
            note("  concluding anything about the gain.")
            note("")
        end
    end
    if (after.saturated or 0) > 0 then
        note(string.format("  it asked for a clamped command on %d samples -- the drift",
            after.saturated))
        note("  was more than 4 degrees of tilt can hold against.")
    end
    note("")

    -- ATTRIBUTION REQUIRES ACTION, and this guard exists because the harness
    -- produced a "WORSE, 108% MORE" verdict on a run where the loop ended at
    -- +0.015 / -0.201 degrees. It had barely commanded anything: the gain was
    -- large, the drift was small, so the correction it wanted was a fifth of a
    -- degree. The drift moved on its own between two 60 s windows on a craft
    -- that oscillates, and the report blamed the loop.
    --
    -- If the loop did not act, the A/B says nothing about the loop -- whatever
    -- the two numbers did.
    -- WHAT COUNTS AS ACTING DEPENDS ON THE GAIN, and a fixed threshold got
    -- this wrong on run 4. With a net gain of -3.56 blocks/s per degree, the
    -- tilt that cancels a 1.4 blocks/s drift is 0.40 degrees, and half of that
    -- after relaxation. The loop commanded 0.173 and was told it had not
    -- acted, against an absolute 0.25 floor written when the gain was expected
    -- to be four times smaller. The floor has to scale with the plant.
    local gain = measured.starboard
    local wanted = nil
    if gain and math.abs(gain) > 1e-6 and before.netDrift then
        wanted = math.abs(before.netDrift / gain) * velocityhold.DEFAULTS.relaxation
    end
    local MINIMUM_EFFORT = wanted and math.max(0.02, wanted * 0.5) or 0.25
    if wanted then
        note(string.format("  the measured gain says %.3f deg would cancel the baseline"
            .. " drift;", math.abs(before.netDrift / gain)))
        note(string.format("  at relaxation %.1f the loop should ask for %.3f, and it"
            .. " averaged %.3f.",
            velocityhold.DEFAULTS.relaxation, wanted, after.effort or 0))
        note("")
    end
    if (after.effort or 0) < MINIMUM_EFFORT then
        note(string.format("  INCONCLUSIVE. The loop averaged %.3f deg of commanded tilt,",
            after.effort or 0))
        note(string.format("  below the %.2f this needs to be attributable. It did not act,",
            MINIMUM_EFFORT))
        note("  so whatever the drift did, it did not do it.")
        note("")
        note("  That is not a fault: a large net gain means small corrections, and")
        note("  a craft already near station has nothing to correct. Re-fly with a")
        note("  craft that is actually drifting.")
        note("")
        note(string.format("  (for the record: net drift %.3f -> %.3f blocks/s)",
            before.netDrift or 0, after.netDrift or 0))
    elseif before.netDrift and after.netDrift then
        local change = (1 - after.netDrift / before.netDrift) * 100
        if before.netDrift < 0.15 then
            note(string.format("  INCONCLUSIVE. The craft was only drifting %.3f blocks/s"
                .. " with the", before.netDrift))
            note("  loop OFF, which is near the deadband. There was nothing to hold.")
        elseif change > 25 then
            note(string.format("  HELD. Net drift %.3f -> %.3f blocks/s, %.0f%% less.",
                before.netDrift, after.netDrift, change))
            -- AGAINST THE DESIGN, not against zero. A proportional loop
            -- under-relaxed by half settles at v/(1+0.5) of the disturbance,
            -- so 33% is what it is BUILT to remove -- not a shortfall.
            local expected = (1 - 1 / (1 + velocityhold.DEFAULTS.relaxation)) * 100
            note(string.format("  A proportional loop at relaxation %.1f is designed to"
                .. " remove %.0f%%,", velocityhold.DEFAULTS.relaxation, expected))
            note(string.format("  so %.0f%% is the loop working as built. Raising the"
                .. " relaxation toward 1.0", change))
            note("  removes more, at the cost of overshoot on a plant that inverts.")
            note("  Compare the trim flights, which cut the standing tilt by 74% and")
            note("  did not reduce the drift at all: this loop does not care what the")
            note("  standing tilt is, only where the craft ends up.")
        elseif change > -25 then
            note(string.format("  NO CLEAR EFFECT. Net drift %.3f -> %.3f blocks/s.",
                before.netDrift, after.netDrift))
            note("  Most likely: the rate limit is so slow the command never built")
            note("  inside the window. Check the final tilt above -- if it is small")
            note("  against what the drift wanted, lengthen the window before")
            note("  touching the gain.")
        else
            note(string.format("  WORSE. Net drift %.3f -> %.3f blocks/s, %.0f%% MORE.",
                before.netDrift, after.netDrift, -change))
            note("  With a measured net gain this should not happen. Suspect the")
            note("  window: 60 s against a 30 s hull response is only two time")
            note("  constants, so the loop may still have been building.")
        end
    end
    note("")
    note(string.format("  MEASURED THIS FLIGHT:  roll axis %+.4f, pitch axis %+.4f",
        measured.starboard or 0, measured.bow or 0))
    note("  blocks/s per commanded degree. Do not store them: the craft's mass")
    note("  and the bearing thrust both move, and this gain is built from both.")
end

-- ---------------------------------------------------------------------------

local function mainLoop()
    note("VELOCITY HOLD -- measure the net gain, then hold station")
    note("utc_ms=" .. tostring(os.epoch("utc")))
    note("")

    groundCheck()
    if groundOnly then return end
    note("")

    if not session:preflight() then
        note("PREFLIGHT FAILED -- not flying.")
        return
    end

    note("")
    note("== spin up ==")
    local spun, reason = session:setAllProps(plan.propRpm)
    commandedProps = true
    if not spun then
        note("could not set base props: " .. tostring(reason))
        return
    end
    if not session:arm() then
        note("could not arm -- not flying.")
        return
    end

    note("")
    note("== climb to +" .. plan.holdGain .. " ==")
    if not session:climb(plan.holdGain, plan.climbTimeout) then
        note("climb failed or aborted")
        return
    end

    note("")
    note("== A: the NET gain per axis, by reverse pairs at steady state ==")
    note("  (the roll damper runs throughout; windows are long enough for the")
    note("   hull to have finished moving, which is what makes it the NET)")

    if not confirmTilt(plan.probeTilt) then
        clearTilt()
        note("")
        note("== descend and land ==")
        session:descend()
        return
    end

    if onlyAxis ~= "pitch" then
        local gain, stop = probeAxis("starboard")
        if stop then clearTilt() session:descend() return end
        measured.starboard = gain
    end
    if onlyAxis ~= "roll" then
        local gain, stop = probeAxis("bow")
        if stop then clearTilt() session:descend() return end
        measured.bow = gain
    end

    clearTilt()

    local haveGains = (onlyAxis == "roll" and measured.starboard)
        or (onlyAxis == "pitch" and measured.bow)
        or (measured.starboard and measured.bow)

    if measureOnly or not haveGains then
        note("")
        if not haveGains then
            note("  NOT CLOSING THE LOOP. Phase A did not produce a usable net gain")
            note("  on every axis it needs one for. A loop on a gain that small is")
            note("  a saturated command derived from noise, which is the shape of")
            note("  the runaway this tool exists to avoid.")
        else
            note("  --measure-only: not closing the loop.")
        end
        note("")
        note("== descend and land ==")
        session:descend()
        return
    end

    note("")
    note("== B: baseline, loop OFF ==")
    -- SETTLE FIRST. The baseline window used to open the instant phase A's
    -- last 2 degree probe was released, so it measured a craft still coasting
    -- out of a commanded tilt rather than its own steady drift. In the harness
    -- that produced a baseline of 0.519 blocks/s on a craft whose standing
    -- drift is nearer 1.0, and the loop was then blamed for the craft
    -- returning to normal. trimflight settles before its baseline for exactly
    -- this reason; this did not.
    note(string.format("  settling %.0f s at zero tilt first", plan.settleSeconds))
    local settleStop = settleAt(0, 0)
    if settleStop then
        note("  " .. settleStop)
        clearTilt()
        session:descend()
        return
    end
    local before = measureWindow("loop off", plan.baselineSeconds, 0, 0)
    if not before then
        clearTilt()
        session:descend()
        return
    end

    note("")
    note("== B: loop ON ==")
    local after, holdStop = holdWindow("loop on", plan.holdSeconds, true)
    if holdStop or not after then
        note("  " .. tostring(holdStop))
        clearTilt()
        note("")
        note("== descend and land ==")
        session:descend()
        return
    end

    report(before, after)

    clearTilt()
    note("")
    note("== descend and land ==")
    session:descend()
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
    elseif not groundOnly then
        local stopped, why = session:setAllProps(0)
        if not stopped then
            note("  WARNING: could not stop all props -- " .. tostring(why))
        end
    end

    pcall(session.finish, session)
end

pcall(parallel.waitForAny, shutdown, listenLoop)
save()
