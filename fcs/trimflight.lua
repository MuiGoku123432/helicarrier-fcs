-- Trim the craft's standing tilt out with bearing tilt, and measure the drift
-- it removes.
--
--   /fcs/trimflight.lua --ground-only    the maths and the plan, commanding nothing
--   /fcs/trimflight.lua                  measure the coupling, then trim
--   /fcs/trimflight.lua --probe-only     measure the coupling and stop
--
-- WHY. The standing offsets explain 94% of the craft's drift speed:
--
--     standing roll   +0.368 deg  ->  0.785 blocks/s
--     standing pitch  -0.638 deg  ->  1.361 blocks/s
--     vector sum          1.571   vs   1.670 MEASURED
--
-- A hull sitting 0.7 degrees off level points its lift 0.7 degrees off vertical
-- and slides until drag balances it. That is a DC problem and this is the DC
-- fix. It does NOT fix the CURVING -- the heading swept -225 degrees because
-- roll and pitch oscillate out of phase -- which is what the RPM damper is for.
-- Trim removes the speed; damping removes the curve; the craft needs both.
--
-- PITCH IS THE BIGGER HALF (1.361 against 0.785), so both axes are trimmed.
-- Every previous look at this craft's drift went to roll, because the repaired
-- RR deficit was a roll torque.
--
-- THE DANGEROUS PART, and how it is handled. Bearing tilt makes lateral force
-- AND roll together -- the two props of a corner sit at the same height, so
-- there is no pure attitude channel. THE SIGN OF THAT COUPLING HAS NEVER BEEN
-- MEASURED, and a saturated 12 degree command with it wrong once ran the craft
-- from 1.76 to 11.5 blocks/s.
--
-- So Phase A MEASURES the sign, by reverse pairs at 2 degrees, and Phase B
-- refuses to run if Phase A did not produce a gain worth trusting. Three
-- things make that safe which were not available before:
--
--   - the RPM damper runs THROUGHOUT, so a disturbance is arrested rather
--     than left to ring (it flew 2026-08-27: 39% less excursion)
--   - the commands are 2 degrees, not a saturated 12
--   - the trim clamp is 4 degrees against a 15 degree hardware clamp

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
local trim = require("fcs.trim")

local plan = {
    propRpm = 64,
    holdGain = 12,
    climbTimeout = 90,
    loopSeconds = 0.15,

    -- Phase A. 2 degrees is large enough to move the hull well clear of its own
    -- oscillation and small enough that a wrong sign is a nuisance rather than
    -- a runaway.
    probeTilt = 2.0,
    settleSeconds = 12,

    -- EVERY WINDOW IS ONE FULL OSCILLATION PERIOD, and that is not padding.
    --
    -- What is being measured is a DC offset of a few tenths of a degree,
    -- underneath an oscillation of several degrees at a ~42 s period that
    -- NOTHING damps on the pitch axis -- the RPM damper is roll-only, and
    -- pitch damping does not exist yet. A 20 s window is half a cycle, so its
    -- mean is dominated by wherever the swing happened to be.
    --
    -- Measured in the harness, which is exactly how this was found: 20 s
    -- windows read a "standing pitch" of +2.404 on a craft whose standing
    -- pitch is -0.638, and the trim built on it made the craft worse. The mean
    -- of a sinusoid over a whole period is its DC term; over half a period it
    -- is anything at all.
    --
    -- The cost is flight time -- about five and a half minutes -- and that is
    -- the honest price of measuring a small DC term under a large AC one.
    oscillationPeriod = 42,
    measureSeconds = 45,
    baselineSeconds = 45,
    verifySeconds = 45,

    -- Abort the probe well before the flight limits.
    probeAbortTilt = 6.0,
    groundedGain = 0.6,
}

local args = { ... }
local groundOnly, probeOnly = false, false
for index = 1, #args do
    local argument = args[index]
    if argument == "--ground-only" then groundOnly = true
    elseif argument == "--probe-only" then probeOnly = true
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
    local ok, file = pcall(fs.open, "/fcs/trimflight_result.txt", "w")
    if ok and file then
        file.write(table.concat(lines, "\n"))
        file.close()
        print("")
        print("Saved to /fcs/trimflight_result.txt")
    end
end

local session = flight.new({
    config = config,
    profile = profile,
    atmosphere = atmosphere,
    note = note,
    sampleSeconds = plan.loopSeconds,
})

-- ---------------------------------------------------------------------------
-- Commanding
-- ---------------------------------------------------------------------------

local rate = rolldamp.newRateEstimator({ windowSeconds = 0.6 })
local startedAt = os.epoch("utc")
local commandedProps, commandedTilt = false, false

-- The trim currently applied, in hull axes. Held here rather than recomputed,
-- so every loop re-sends the SAME command -- the link drops a few percent and
-- re-sending is the retry.
local applied = { starboard = 0, bow = 0 }

local function feed(state, now)
    if state and state.valid and state.roll then
        rate:push((now - startedAt) / 1000, state.roll)
    end
    return rate:rate()
end

-- Ground speed, horizontal magnitude. Taken from the WORLD velocity rather
-- than resolved into hull axes: the magnitude is frame-independent, and this
-- is the number the whole exercise is judged on, so it should not depend on an
-- axis convention that has been wrong before on this craft.
local function groundSpeed(state)
    local velocity = state and state.linearVelocityWorld
    if not velocity then return nil end
    local x, z = velocity.x or velocity[1], velocity.z or velocity[3]
    if not x or not z then return nil end
    return math.sqrt(x * x + z * z)
end

-- The propellers, with the damper riding on top.
local function commandProps(rollRate)
    local differential = rollRate and rolldamp.differentialFor(rollRate) or 0
    session:sendProps(rolldamp.cornerRpm(plan.propRpm, differential,
        { minimumRpm = config.propeller.minimumRpm }))
    commandedProps = true
    return differential
end

-- A common-mode bearing tilt, resolved from hull-axis components.
--
-- FIRE AND FORGET, like vectorprobe: actuators.setTilt blocks up to 1000 ms
-- per corner waiting for an ack, and inside a loop that is a second in which
-- no command of any kind goes out. set_tilt is set-and-hold with no watchdog,
-- so a dropped one is re-sent a fifth of a second later.
--
-- mirror=true because the pair only ADDS when the down-facing bearing is
-- flipped: commanding a common azimuth is not a weak input, it is exactly zero.
local function commandTilt(starboard, bow)
    local magnitude = math.sqrt(starboard * starboard + bow * bow)
    -- heading 0 = bow, 90 = starboard. MEASURED on all four corners.
    local heading = math.deg(math.atan2(starboard, bow))
    local azimuth = lateralhold.azimuthForHeading(heading)

    for _, corner in ipairs(flight.CORNERS) do
        banks.send(corner, "set_tilt", {
            angle = magnitude, azimuth = azimuth, bearing = nil, mirror = true,
        })
    end
    applied.starboard, applied.bow = starboard, bow
    if magnitude > 0 then commandedTilt = true end
end

local function clearTilt()
    for _, corner in ipairs(flight.CORNERS) do
        banks.send(corner, "set_tilt",
            { angle = 0, azimuth = 0, bearing = nil, mirror = true })
    end
    applied.starboard, applied.bow = 0, 0
end

-- ---------------------------------------------------------------------------
-- Windows
-- ---------------------------------------------------------------------------

-- Hold a commanded tilt for `seconds`, running the damper, and return the mean
-- hull angles and ground speed over the window.
--
-- The offset is a MEAN, never a reading: the hull swings either side of it by
-- several times its size.
local function measureWindow(label, seconds, starboard, bow)
    local samples = {}
    session.cheapRead = true
    commandTilt(starboard, bow)

    local stop = session:hold(seconds, function(state, now)
        session:trim(plan.holdGain, flight.MAX_CLIMB_RATE, 0, state)
        local rollRate = feed(state, now)
        commandProps(rollRate)
        commandTilt(starboard, bow)   -- re-sent: the loop is the retry

        if state and state.valid and state.roll and state.pitch then
            samples[#samples + 1] = {
                roll = state.roll,
                pitch = state.pitch,
                speed = groundSpeed(state),
            }
            if math.abs(state.roll) > plan.probeAbortTilt
                or math.abs(state.pitch) > plan.probeAbortTilt then
                return string.format("tilt passed %.1f deg (roll %.2f pitch %.2f)",
                    plan.probeAbortTilt, state.roll, state.pitch)
            end
        end
    end)

    local meanRoll = trim.mean(samples, "roll")
    local meanPitch = trim.mean(samples, "pitch")
    local meanSpeed = trim.mean(samples, "speed")
    note(string.format("  %-22s roll %+6.3f  pitch %+6.3f  speed %5s  (%d samples)",
        label, meanRoll or 0, meanPitch or 0,
        meanSpeed and string.format("%.3f", meanSpeed) or "?", #samples))
    return { roll = meanRoll, pitch = meanPitch, speed = meanSpeed,
             count = #samples }, stop
end

-- Let a commanded tilt reach equilibrium before measuring it.
local function settleAt(starboard, bow)
    session.cheapRead = true
    return session:hold(plan.settleSeconds, function(state, now)
        session:trim(plan.holdGain, flight.MAX_CLIMB_RATE, 0, state)
        commandProps(feed(state, now))
        commandTilt(starboard, bow)
        if state and state.valid and state.roll
            and (math.abs(state.roll) > plan.probeAbortTilt
                 or math.abs(state.pitch or 0) > plan.probeAbortTilt) then
            return string.format("tilt passed %.1f deg while settling",
                plan.probeAbortTilt)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Phase A: the coupling, by reverse pairs
-- ---------------------------------------------------------------------------

local function probeAxis(axis)
    note("")
    note(string.format("  -- %s axis, +/-%.1f deg --", axis, plan.probeTilt))

    local isRoll = axis == "roll"
    local function componentsFor(amount)
        if isRoll then return amount, 0 else return 0, amount end
    end

    local positiveStop = settleAt(componentsFor(plan.probeTilt))
    if positiveStop then note("  " .. positiveStop) return nil, positiveStop end
    local positive, stopP = measureWindow(
        string.format("at %+.1f deg", plan.probeTilt),
        plan.measureSeconds, componentsFor(plan.probeTilt))
    if stopP then return nil, stopP end

    local negativeStop = settleAt(componentsFor(-plan.probeTilt))
    if negativeStop then note("  " .. negativeStop) return nil, negativeStop end
    local negative, stopN = measureWindow(
        string.format("at %+.1f deg", -plan.probeTilt),
        plan.measureSeconds, componentsFor(-plan.probeTilt))
    if stopN then return nil, stopN end

    local field = isRoll and "roll" or "pitch"
    local gain = trim.staticGain(plan.probeTilt, positive[field],
        -plan.probeTilt, negative[field])

    if not gain then
        note("  no gain: the reverse pair did not produce usable samples")
        return nil
    end

    note(string.format("  GAIN %.4f hull deg per commanded deg  (predicted %.3f)",
        gain, trim.predictedGain() or 0))
    -- Report the sign only when there IS one. A gain of 0.0000 is not
    -- "negative" -- `gain > 0` is false for zero, and the first version said
    -- NEGATIVE for a craft whose bearings did nothing at all, which is the
    -- most misleading thing it could have said.
    if math.abs(gain) < trim.DEFAULTS.minimumUsableGain then
        note("  the coupling sign is INDETERMINATE -- the response is too small"
            .. " to have one")
    else
        note(string.format("  the coupling sign is %s",
            gain > 0 and "POSITIVE: a positive tilt raises the hull angle"
            or "NEGATIVE: a positive tilt lowers the hull angle"))
    end
    if math.abs(gain) < trim.DEFAULTS.minimumUsableGain then
        note(string.format("  ** below the %.2f needed to trust it. Trim would be a"
            .. " large command derived from noise.", trim.DEFAULTS.minimumUsableGain))
    end

    -- A gain wildly off the prediction is the signature of a window that did
    -- not average the oscillation away -- the AC is larger than the DC, so a
    -- badly-placed window reads the swing rather than the response.
    local predicted = trim.predictedGain()
    if predicted and predicted > 0 then
        local ratio = math.abs(gain) / predicted
        if ratio > 2.0 or ratio < 0.5 then
            note(string.format("  ** %.1fx the predicted %.3f. Either the prediction"
                .. " is wrong (it was 2.9x off for the", ratio, predicted))
            note("  ** damper) or the window did not average the oscillation out.")
            note("  ** Compare the two reverse-pair readings above: if they are not")
            note("  ** roughly symmetric about the standing offset, it is the window.")
        end
    end
    return gain
end

-- ---------------------------------------------------------------------------
-- Ground mode
-- ---------------------------------------------------------------------------

local function groundCheck()
    note("GROUND CHECK -- commanding nothing")
    note("")
    note("  the case, from the passive drift flight:")
    note(string.format("    standing roll  %+.3f deg -> %.3f blocks/s",
        trim.MEASURED.standingRoll, trim.driftSpeed(trim.MEASURED.standingRoll)))
    note(string.format("    standing pitch %+.3f deg -> %.3f blocks/s",
        trim.MEASURED.standingPitch, trim.driftSpeed(trim.MEASURED.standingPitch)))
    note(string.format("    vector sum                  %.3f blocks/s",
        trim.combinedDrift(trim.MEASURED.standingRoll, trim.MEASURED.standingPitch)))
    note("    measured mean ground speed  1.670 blocks/s")
    note("")

    local predicted = trim.predictedGain()
    note(string.format("  predicted gain %.3f hull deg per commanded deg", predicted))
    note("  (a PREDICTION. The same kind of prediction was 2.9x high for the")
    note("   RPM damper, which is why phase A measures it instead.)")
    note("")
    note("  what the trim would be, at the predicted gain:")
    for _, entry in ipairs({
        { "roll", trim.MEASURED.standingRoll },
        { "pitch", trim.MEASURED.standingPitch },
    }) do
        local tilt = trim.tiltFor(entry[2], predicted)
        note(string.format("    %-5s offset %+.3f -> tilt %+.3f deg, costing %.3f blocks/s",
            entry[1], entry[2], tilt or 0, math.abs(trim.bearingDrift(tilt or 0))))
    end
    note("")

    local state = session:read()
    if state and state.valid then
        note(string.format("  live attitude: roll %+.3f  pitch %+.3f  speed %s",
            state.roll or 0, state.pitch or 0,
            groundSpeed(state) and string.format("%.3f", groundSpeed(state)) or "?"))
    else
        note("  no valid attitude sample")
    end
end

-- ---------------------------------------------------------------------------
-- Report
-- ---------------------------------------------------------------------------

local function report(before, after, gains, tilts)
    note("")
    note("== RESULT ==")
    note("")
    note("                          BEFORE        AFTER")
    note(string.format("  standing roll         %+8.3f     %+8.3f  deg",
        before.roll or 0, after.roll or 0))
    note(string.format("  standing pitch        %+8.3f     %+8.3f  deg",
        before.pitch or 0, after.pitch or 0))
    note(string.format("  ground speed          %8.3f     %8.3f  blocks/s",
        before.speed or 0, after.speed or 0))
    note("")
    note(string.format("  trim applied: %+.3f deg starboard, %+.3f deg bow",
        tilts.starboard, tilts.bow))
    note(string.format("  measured gains: roll %.4f  pitch %.4f",
        gains.roll or 0, gains.pitch or 0))
    note("")

    local beforeTilt = math.sqrt((before.roll or 0) ^ 2 + (before.pitch or 0) ^ 2)
    local afterTilt = math.sqrt((after.roll or 0) ^ 2 + (after.pitch or 0) ^ 2)

    if afterTilt < beforeTilt * 0.5 then
        note(string.format("  TRIMMED. Standing tilt %.3f -> %.3f deg, a %.0f%% reduction.",
            beforeTilt, afterTilt, (1 - afterTilt / beforeTilt) * 100))
    elseif afterTilt < beforeTilt then
        note(string.format("  PARTIAL. Standing tilt %.3f -> %.3f deg. Better, but the"
            .. " gain or the clamp is limiting it.", beforeTilt, afterTilt))
    else
        note(string.format("  NOT TRIMMED. Standing tilt %.3f -> %.3f deg -- no better.",
            beforeTilt, afterTilt))
        note("  If it got WORSE, the measured gain has the wrong sign and phase A")
        note("  should have caught it; check the reverse pair samples above.")
    end

    if before.speed and after.speed and before.speed > 0.05 then
        note(string.format("  Ground speed %.3f -> %.3f blocks/s (%+.0f%%).",
            before.speed, after.speed,
            (after.speed / before.speed - 1) * 100))
        note(string.format("  For reference the trim's own lateral force is worth"
            .. " about %.3f blocks/s.",
            math.sqrt(trim.bearingDrift(tilts.starboard) ^ 2
                + trim.bearingDrift(tilts.bow) ^ 2)))
    end
end

-- ---------------------------------------------------------------------------

local function mainLoop()
    note("BEARING TRIM -- measure the coupling, then cancel the standing tilt")
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
    note("== A: the coupling, by reverse pairs ==")
    note("  (the damper runs throughout; this is what makes it safe)")
    local gains = {}
    local rollGain, rollStop = probeAxis("roll")
    if rollStop then return end
    gains.roll = rollGain
    local pitchGain, pitchStop = probeAxis("pitch")
    if pitchStop then return end
    gains.pitch = pitchGain

    clearTilt()
    if probeOnly then
        note("")
        note("--probe-only: measured the coupling, not trimming.")
        note("")
        note("== descend and land ==")
        session:descend()
        return
    end

    note("")
    note("== B: baseline, no trim ==")
    settleAt(0, 0)
    local before = measureWindow("untrimmed", plan.baselineSeconds, 0, 0)

    local rollTilt, rollWhy = trim.tiltFor(before.roll, gains.roll)
    local pitchTilt, pitchWhy = trim.tiltFor(before.pitch, gains.pitch)
    if not rollTilt or not pitchTilt then
        note("")
        note("  REFUSING TO TRIM:")
        if not rollTilt then note("    roll: " .. tostring(rollWhy)) end
        if not pitchTilt then note("    pitch: " .. tostring(pitchWhy)) end
        note("  A trim computed from a gain this small is a large command")
        note("  derived from noise, which is the shape of the runaway this")
        note("  tool exists to avoid.")
        note("")
        note("== descend and land ==")
        session:descend()
        return
    end

    -- The roll axis is trimmed by a STARBOARD-pointing tilt and the pitch axis
    -- by a BOW-pointing one, because that is which component of the commanded
    -- vector couples into which hull angle.
    local tilts = { starboard = rollTilt, bow = pitchTilt }
    note("")
    note(string.format("== B: trim %+.3f starboard, %+.3f bow ==",
        tilts.starboard, tilts.bow))

    local settleStop = settleAt(tilts.starboard, tilts.bow)
    if settleStop then
        note("  " .. settleStop)
        clearTilt()
        return
    end
    local after = measureWindow("trimmed", plan.verifySeconds,
        tilts.starboard, tilts.bow)

    report(before, after, gains, tilts)

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

    -- Symmetric first, whatever else happens.
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
