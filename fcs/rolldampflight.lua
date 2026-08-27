-- Does damping with differential propeller RPM actually damp?
--
--   /fcs/rolldampflight.lua --ground-only    math against live attitude, no flight
--   /fcs/rolldampflight.lua                  the A/B flight
--   /fcs/rolldampflight.lua --pulse 3 --window 40
--
-- THE MEASUREMENT: the same disturbance twice, damper off then on.
--
--   pulse +P rpm differential for T s -> release -> log W s   DAMPER OFF
--   pulse +P rpm differential for T s -> release -> log W s   DAMPER ON
--
-- Verdict is the decay of the roll RATE envelope and the number of zero
-- crossings. A damper that works shows a shorter time constant and fewer
-- crossings from the same starting rate. Nothing here trusts a single number:
-- the pulse also RE-MEASURES the authority, so a run that disagrees with
-- 0.0941 deg/s^2 per rpm says so instead of quietly damping by the wrong gain.
--
-- WHY A PULSE RATHER THAN THE CRAFT'S OWN OSCILLATION. The strafe is what we
-- actually want damped, but it is uncontrolled -- two 105 s windows need not
-- start alike, and this document's history is full of numbers that looked
-- solid in isolation and disagreed across runs. A pulse starts both halves
-- from the same rate, which is the only way the comparison means anything.
--
-- WHAT IT COMMANDS. Differential propeller RPM only. No ion attitude demand,
-- no bearing tilt: ions are 28x too coarse to damp and bearing roll torque
-- needs a vertical moment arm nobody has measured. The ions hold ALTITUDE and
-- nothing else, through the same flight primitives every other tool uses.
--
-- SAFETY, all of it learned the hard way and all of it in HANDOFF:
--   - props are NEVER left asymmetric; every exit path restores the base rpm
--   - props are NEVER cut in the air -- they carry ~52% of weight at 64 rpm
--   - shutdown runs UNDER THE LISTENER, or its commands cannot be acked
--   - the damper is clamped to +/-4 rpm and floors each corner at 8

if package then
    package.path = "/?.lua;/?/init.lua;" .. package.path
end

local config = require("fcs.config")
local banks = require("fcs.banks")
local flight = require("fcs.flight")
local profile = require("fcs.mixer_profile")
local atmosphere = require("fcs.atmosphere")
local rolldamp = require("fcs.rolldamp")

-- ---------------------------------------------------------------------------
-- Plan
-- ---------------------------------------------------------------------------

local plan = {
    -- Propeller base. 64 rpm carries ~52% of craft weight; the ions carry the
    -- rest. The damper rides on top of this, +/-4 at most.
    propRpm = 64,
    -- Where the A/B happens. High enough that ground effect and a bad landing
    -- are not in the way, low enough that the +23 block hold ceiling is not.
    holdGain = 12,
    climbTimeout = 90,
    -- The disturbance. 3 rpm is what the damper itself asks for at the
    -- strafe's peak rate, so the pulse exercises the actuator's real range.
    pulseRpm = 3,
    pulseSeconds = 3.0,
    -- How long to watch the decay. The undamped period is ~42 s, so 40 s sees
    -- roughly one full cycle -- enough for crossings to differ.
    windowSeconds = 40,
    -- Between the halves: wait for the craft to go quiet again, so phase B
    -- does not start on top of phase A's leftovers.
    settleRate = 0.08,
    settleTimeout = 90,
    -- DIVERGENCE. A damper with its sign inverted drives the oscillation, and
    -- it is the failure mode that looks most like success: it commands
    -- confidently, at the right magnitude, and the craft gets worse. Left to
    -- the generic 20 degree abort it reaches 20 degrees -- the harness's
    -- wrongsign run does exactly that. These stop it an octave earlier and say
    -- WHY, which the abort limit cannot.
    divergeRoll = 8.0,
    divergeGrowth = 2.5,
    divergeFloor = 0.10,
    -- Below this peak rate in the UNDAMPED half, the pulse did not disturb the
    -- craft and there is nothing to compare.
    minimumDisturbance = 0.05,
    loopSeconds = 0.15,
    -- Below this gain the craft is on the ground and props may be stopped.
    groundedGain = 0.6,
}

local args = { ... }
local groundOnly = false
for index = 1, #args do
    local argument = args[index]
    if argument == "--ground-only" then
        groundOnly = true
    elseif argument == "--pulse" then
        plan.pulseRpm = tonumber(args[index + 1]) or plan.pulseRpm
    elseif argument == "--window" then
        plan.windowSeconds = tonumber(args[index + 1]) or plan.windowSeconds
    elseif argument == "--hold" then
        plan.holdGain = tonumber(args[index + 1]) or plan.holdGain
    end
end

local lines = {}
local function note(text)
    lines[#lines + 1] = text
    print(text)
end

local function save()
    local ok, file = pcall(fs.open, "/fcs/rolldampflight_result.txt", "w")
    if ok and file then
        file.write(table.concat(lines, "\n"))
        file.close()
        print("")
        print("Saved to /fcs/rolldampflight_result.txt")
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
-- Analysis
--
-- Deliberately simple and stated in full, because a fit nobody can check is
-- how this project produced roll authorities from 3.98 to 86.03 across ten
-- runs that all looked fine.
-- ---------------------------------------------------------------------------

-- Zero crossings of the roll RATE. An undamped oscillator keeps crossing; a
-- damped one stops. Counted on the rate rather than the angle because the
-- angle also carries the standing 0.31 degree offset, which would add
-- crossings or remove them depending on which side of zero it sits.
local function peakAbsRoll(samples)
    local peak = 0
    for _, sample in ipairs(samples) do
        local magnitude = math.abs(sample.roll or 0)
        if magnitude > peak then peak = magnitude end
    end
    return peak
end

-- ---------------------------------------------------------------------------
-- The damper, as the flight loop runs it
-- ---------------------------------------------------------------------------

-- ONE estimator for the whole run, fed by every read.
--
-- Session:rates is not usable here: it reads angularVelocityBody, which reads
-- exactly 0.0000 in a third of samples, and Session:readCheap -- the only read
-- fast enough for a 0.15 s loop -- omits angular velocity entirely. So the rate
-- comes from the ANGLE, the same way the axis-response fit does. Discovered by
-- the harness, which sat through a 90 s settle timeout waiting for a rate that
-- could never arrive.
local rate = rolldamp.newRateEstimator({ windowSeconds = 0.6 })
local startedAt = os.epoch("utc")

-- Read, feed the estimator, and hand back both. Every loop below goes through
-- this, so there is exactly one place where a sample can fail to reach the
-- estimator -- which is the failure that produces a damper commanding zero
-- while everything else looks healthy.
local function sample()
    local state = session:readCheap()
    local now = (os.epoch("utc") - startedAt) / 1000
    if state and state.valid and state.roll then
        rate:push(now, state.roll)
    end
    return state, rate:rate(), now
end

-- Is the damper making things worse? Returns a reason, or nil.
--
-- Only ever called while the damper is actually commanding. Two independent
-- tests, because either alone has a blind spot: a growth ratio cannot see a
-- craft that starts already far over, and an angle threshold cannot see a slow
-- divergence that has not got there yet.
local function divergence(roll, rollRate, baseline)
    if math.abs(roll or 0) > plan.divergeRoll then
        return string.format("roll reached %.1f deg while DAMPING", roll)
    end
    if baseline and baseline > plan.divergeFloor and rollRate
        and math.abs(rollRate) > baseline * plan.divergeGrowth then
        return string.format("roll rate GREW from %.3f to %.3f deg/s while damping",
            baseline, math.abs(rollRate))
    end
    return nil
end

local function signWarning(reason)
    note("")
    note("  ** " .. reason)
    note("  ** THE DAMPER IS DRIVING THE OSCILLATION. That is a SIGN error:")
    note("  ** a positive roll rate must be answered with a NEGATIVE")
    note("  ** differential (port down, starboard up). Check the corner sign")
    note("  ** map in rolldamp.cornerRpm and the axis convention in")
    note("  ** attitude.lua before flying this again.")
    note("")
end

local function damperCommand(rollRate)
    return rolldamp.differentialFor(rollRate, {
        maxDifferentialRpm = rolldamp.DEFAULTS.maxDifferentialRpm,
    })
end

-- Has this run ever commanded a propeller? shutdown must not "normalise" the
-- differential on a run that never spun anything up: cornerRpm(base, 0) is
-- base, so the tidy-up would spin all four to 64 on a --ground-only check that
-- has just finished announcing it commands nothing. Caught in the harness.
local commandedProps = false

local function commandDifferential(differential)
    local rpms = rolldamp.cornerRpm(plan.propRpm, differential,
        { minimumRpm = config.propeller.minimumRpm })
    session:sendProps(rpms)
    commandedProps = true
    return rpms
end

-- ---------------------------------------------------------------------------
-- Ground mode: prove the signs and the magnitudes without leaving the ground
-- ---------------------------------------------------------------------------

local function groundCheck()
    note("GROUND CHECK -- commanding nothing")
    note("")

    local perRpm = rolldamp.MEASURED.flightAuthorityPerRpm
    local critical = rolldamp.criticalDamping()
    note(string.format("  measured authority   %.4f deg/s^2 per rpm", perRpm))
    note(string.format("  critical damping     %.4f deg/s^2", critical))
    note(string.format("  critical arrives at  %.1f rpm (clamp %d)",
        critical / perRpm, rolldamp.DEFAULTS.maxDifferentialRpm))
    note("")

    note("  rate (deg/s)  ->  differential  ->  FL   FR   RL   RR")
    for _, rate in ipairs({ -1.5, -0.9, -0.3, -0.04, 0, 0.04, 0.3, 0.9, 1.5 }) do
        local differential = damperCommand(rate)
        local rpms = rolldamp.cornerRpm(plan.propRpm, differential,
            { minimumRpm = config.propeller.minimumRpm })
        note(string.format("  %+6.2f          ->  %+3d           ->  %3d  %3d  %3d  %3d",
            rate, differential, rpms.FL, rpms.FR, rpms.RL, rpms.RR))
    end
    note("")

    -- The sign convention, checked rather than asserted. Positive differential
    -- raises the PORT corners, which is a positive roll demand -- so a craft
    -- rolling POSITIVE must be answered with a NEGATIVE differential.
    local rolling = damperCommand(0.9)
    if rolling < 0 then
        note("  SIGN OK: a positive roll rate is answered with a negative")
        note("  differential, which lowers port and raises starboard.")
    else
        note("  ** SIGN WRONG: a positive roll rate asks for " .. tostring(rolling))
        note("  ** This would DRIVE the oscillation instead of damping it.")
        note("  ** Do not fly.")
    end
    note("")

    local state = session:read()
    if state and state.valid then
        note(string.format("  live attitude: roll %+.2f deg  pitch %+.2f deg",
            state.roll or 0, state.pitch or 0))

        -- Fill the estimator from real reads, so the ground check exercises
        -- the SAME path the flight loop uses rather than a shortcut.
        for _ = 1, 6 do
            sample()
            sleep(plan.loopSeconds)
        end
        local live = rate:rate()
        if live then
            note(string.format("  live roll rate: %+.3f deg/s over %d samples"
                .. " -> would command %+d rpm",
                live, rate:count(), damperCommand(live)))
        else
            note("  ** no roll rate after 6 samples -- the estimator is not being")
            note("  ** fed, and the damper would command zero all flight.")
        end
    else
        note("  no valid attitude sample")
    end
end

-- ---------------------------------------------------------------------------
-- One half of the A/B
-- ---------------------------------------------------------------------------

-- Feed the estimator from a sample the hold loop already took, and hand back
-- the current rate. One place, so there is exactly one way for a sample to
-- fail to reach the estimator.
local function feed(state, now)
    if state and state.valid and state.roll then
        rate:push((now - startedAt) / 1000, state.roll)
    end
    return rate:rate()
end

-- Both halves of the A/B run on Session:hold, NOT on a hand-rolled loop.
--
-- The first version of this file did hand-roll one, and the harness showed
-- exactly what that costs: nothing was sending ion commands, so the pods'
-- 750 ms watchdog disarmed the banks mid-measurement, the craft sank onto the
-- ground, and the roll froze -- while the tool happily recorded 167 samples of
-- a craft that could not rotate and reported a verdict about them.
--
-- hold() re-arms and re-sends every keepAliveMs, checks the abort limits, and
-- drops to the survivable ion level if one trips. Everything this loop adds
-- rides in its onSample hook.
local function recordWindow(label, damped)
    local samples = {}
    session.cheapRead = true

    note(string.format("  %s: pulsing %+d rpm for %.1f s",
        label, plan.pulseRpm, plan.pulseSeconds))

    commandDifferential(plan.pulseRpm)
    local pulseStop = session:hold(plan.pulseSeconds, function(state, now)
        session:trim(plan.holdGain, flight.MAX_CLIMB_RATE, 0, state)
        feed(state, now)
        -- Re-sent every iteration: the link drops a few percent of commands
        -- and set_rpm is idempotent, so the loop IS the retry.
        commandDifferential(plan.pulseRpm)
    end)
    if pulseStop then
        note("  " .. label .. ": " .. tostring(pulseStop))
        commandDifferential(0)
        return samples, pulseStop
    end

    local releasedAt = os.epoch("utc")
    local baseline = nil
    note(string.format("  %s: released, logging %.0f s", label, plan.windowSeconds))

    local stop = session:hold(plan.windowSeconds, function(state, now)
        session:trim(plan.holdGain, flight.MAX_CLIMB_RATE, 0, state)
        local rollRate = feed(state, now)

        local commanded = 0
        if damped and rollRate then
            commanded = damperCommand(rollRate)
            baseline = baseline or math.abs(rollRate)
            local diverging = divergence(state and state.roll, rollRate, baseline)
            if diverging then
                commandDifferential(0)
                signWarning(diverging)
                return "DIVERGING: " .. diverging
            end
        end
        commandDifferential(commanded)

        if rollRate then
            samples[#samples + 1] = {
                t = (now - releasedAt) / 1000,
                roll = state.roll,
                rollRate = rollRate,
                commanded = commanded,
            }
        end
    end)

    commandDifferential(0)
    if stop then note("  " .. label .. ": " .. tostring(stop)) end
    return samples, stop
end

-- SETTLE RUNS THE DAMPER. Deliberately, and it is not cheating.
--
-- Both halves must start from the same quiet state or the comparison is
-- meaningless, and waiting passively for quiet cannot work: the thing being
-- measured is an oscillation the craft does not damp on its own. After an
-- UNDAMPED phase A the craft is ringing at whatever amplitude the pulse left,
-- and passive waiting rang out the full 90 s timeout in the harness -- phase B
-- never ran at all.
--
-- Nothing is measured here, so using the actuator to get to the start line
-- biases nothing. And if the damper cannot quiet the craft, that is a finding
-- in itself and the run says so instead of timing out mysteriously.
local function settle(label)
    note(string.format("  damping to quiet (|rate| < %.2f deg/s)", plan.settleRate))
    session.cheapRead = true
    local quietSince, baseline = nil, nil

    local stop = session:hold(plan.settleTimeout, function(state, now)
        session:trim(plan.holdGain, flight.MAX_CLIMB_RATE, 0, state)
        local rollRate = feed(state, now)
        commandDifferential(rollRate and damperCommand(rollRate) or 0)

        if rollRate then
            baseline = baseline or math.abs(rollRate)
            local diverging = divergence(state and state.roll, rollRate, baseline)
            if diverging then
                signWarning(diverging)
                return "DIVERGING: " .. diverging
            end
        end

        if rollRate and math.abs(rollRate) < plan.settleRate then
            quietSince = quietSince or now
            if now - quietSince > 3000 then
                note(string.format("  %s: quiet at %.3f deg/s", label, rollRate))
                return "quiet"
            end
        else
            quietSince = nil
        end
    end)

    commandDifferential(0)
    if stop == "quiet" then return true end
    note("  " .. label .. ": " .. (stop and tostring(stop)
        or ("the DAMPER could not quiet the craft within "
            .. plan.settleTimeout .. " s -- that is itself a result")))
    return false
end

-- ---------------------------------------------------------------------------
-- Verdict
-- ---------------------------------------------------------------------------

local function report(off, on)
    note("")
    note("== RESULT ==")
    note("")

    local offCrossings, onCrossings = rolldamp.zeroCrossings(off), rolldamp.zeroCrossings(on)
    local offDecay, offPeak = rolldamp.decayTime(off)
    local onDecay, onPeak = rolldamp.decayTime(on)

    note("                        DAMPER OFF     DAMPER ON")
    note(string.format("  samples               %8d      %8d", #off, #on))
    note(string.format("  peak roll rate        %8.3f      %8.3f  deg/s", offPeak or 0, onPeak or 0))
    note(string.format("  peak |roll|           %8.2f      %8.2f  deg",
        peakAbsRoll(off), peakAbsRoll(on)))
    note(string.format("  zero crossings        %8d      %8d  (above %.2f deg/s)",
        offCrossings, onCrossings, rolldamp.DEFAULTS.deadbandRate))
    -- Said out loud every run, because it reads like a verdict and is not one.
    note("      (crossings are AMPLITUDE-BLIND: a damper that arrests the big")
    note("       swing early then drifts across zero at a tenth the amplitude")
    note("       scores WORSE here. Peak excursion and decay carry the result.)")
    note(string.format("  time to 1/e           %8s      %8s  s",
        offDecay and string.format("%.1f", offDecay) or "never",
        onDecay and string.format("%.1f", onDecay) or "never"))
    note("")

    -- FIRST: did the disturbance happen at all? A pulse that produced nothing
    -- makes every number below a comparison of noise, and "the damper had no
    -- effect" is the wrong conclusion to draw from it -- the actuator never
    -- moved the craft in the first place, which is a different and larger
    -- problem.
    if (offPeak or 0) < plan.minimumDisturbance then
        note(string.format("  NO DISTURBANCE. The undamped pulse produced a peak rate of"
            .. " %.4f deg/s,", offPeak or 0))
        note(string.format("  below the %.2f this needs to measure anything. The %d rpm"
            .. " differential", plan.minimumDisturbance, plan.pulseRpm))
        note("  did not move the craft, so nothing below is about damping.")
        note("")
        note("  Check, in this order: are all four props actually turning at the")
        note("  commanded rpm (prop.controllerRpm, not targetRpm)? Is the craft")
        note("  airborne -- a grounded hull carries the moment and cannot roll?")
        note("  Is the differential reaching the pods at all?")
        return
    end

    -- THE AUTHORITY, re-measured from the undamped pulse. Free, independent of
    -- the damping result, and the one number the damper's gain rests on.
    local measured, peak, seconds =
        rolldamp.authorityFromPulse(off, plan.pulseRpm, plan.pulseSeconds)
    local stored = rolldamp.MEASURED.flightAuthorityPerRpm
    if measured then
        local drift = (measured - stored) / stored
        note(string.format("  AUTHORITY, re-measured from the undamped pulse:"))
        note(string.format("    %.4f deg/s^2 per rpm  (%+.1f%% vs the stored %.4f)",
            measured, drift * 100, stored))
        note(string.format("    %d rpm reached %.3f deg/s in %.1f s",
            plan.pulseRpm, peak, seconds))
        if math.abs(drift) > 0.20 then
            note("    ** That is more than 20% from the figure the damper's gain")
            note("    ** uses. Either this run is unusual or the stored value is")
            note("    ** stale -- re-measure before trusting the damping result.")
        end
        note("")
    end

    -- The comparison is only meaningful if both halves started alike.
    if (offPeak or 0) > 0 and (onPeak or 0) > 0 then
        local ratio = math.abs((onPeak - offPeak) / offPeak)
        if ratio > 0.25 then
            note(string.format("  ** The two halves started %.0f%% apart (%.3f vs %.3f deg/s).",
                ratio * 100, offPeak, onPeak))
            note("  ** They are not comparable. Re-fly before believing anything below.")
            note("")
        end
    end

    if not offDecay and onDecay then
        note("  DAMPED. Undamped never decayed inside the window; damped did,")
        note(string.format("  in %.1f s.", onDecay))
    elseif offDecay and onDecay and onDecay < offDecay * 0.7 then
        note(string.format("  DAMPED. Decay went %.1f s -> %.1f s, a %.0f%% improvement.",
            offDecay, onDecay, (1 - onDecay / offDecay) * 100))
    elseif peakAbsRoll(on) < peakAbsRoll(off) * 0.8 then
        note(string.format("  PARTIAL. Decay did not clearly improve, but the damped half"
            .. " went %.1f deg against %.1f -- the craft physically travelled less.",
            peakAbsRoll(on), peakAbsRoll(off)))
    else
        note("  NO EFFECT MEASURED. Before blaming the law, check the SIGN:")
        note("  a damper with the sign wrong drives the oscillation, and that")
        note("  shows up as a LARGER peak in the damped half, not a smaller one.")
    end

    note("")
    note("  t(s), roll(deg), rate(deg/s), commanded(rpm) -- damper OFF then ON")
    for _, half in ipairs({ { "OFF", off }, { "ON", on } }) do
        for index, sample in ipairs(half[2]) do
            if index % 4 == 1 then
                note(string.format("  %-3s %6.2f %8.2f %8.3f %+3d",
                    half[1], sample.t, sample.roll or 0, sample.rollRate or 0,
                    sample.commanded or 0))
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Flight
-- ---------------------------------------------------------------------------

local function mainLoop()
    note("ROLL DAMPER -- A/B on an injected pulse")
    note("utc_ms=" .. tostring(os.epoch("utc")))
    note("")

    if groundOnly then
        groundCheck()
        return
    end

    groundCheck()
    note("")

    if not session:preflight() then
        note("PREFLIGHT FAILED -- not flying.")
        return
    end

    note("")
    note("== spin up ==")
    local spun, reason = session:setAllProps(plan.propRpm)
    -- Set even on failure: a partial application is exactly when shutdown most
    -- needs to put the props back symmetric.
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
    note("== A: damper OFF ==")
    if not settle("A") then return end
    local off = recordWindow("A", false)
    if session.aborted then return end

    note("")
    note("== B: damper ON ==")
    if not settle("B") then return end
    local on = recordWindow("B", true)

    report(off, on)

    note("")
    note("== descend and land ==")
    session:descend()
end

local function listenLoop()
    while true do
        if not banks.listen(1) then
            sleep(0.05)
        end
    end
end

local ok, err = pcall(parallel.waitForAny, mainLoop, listenLoop)
if not ok then
    note("")
    note("RUN ERROR: " .. tostring(err))
end

-- SHUTDOWN RUNS UNDER THE LISTENER. waitForAny kills listenLoop the moment
-- mainLoop returns, and every command that waits for a reply -- which
-- setAllProps does -- would then be unanswerable. That is how a run ends with
-- three corners at 64 and one at 0, which is a large roll couple.
local function shutdown()
    if not commandedProps then
        -- Nothing was ever commanded, so there is nothing to put back. Saying
        -- so beats a silent return: "no cleanup needed" and "cleanup failed
        -- quietly" look identical afterwards.
        note("")
        note("  nothing was commanded; props untouched.")
        pcall(session.finish, session)
        return
    end

    -- Symmetric FIRST, before anything else can go wrong. Whatever else
    -- happens, the craft must not be left with a standing differential.
    commandDifferential(0)

    local state = session:read()
    local altitude = state and session:craftY(state)
    local gain = (altitude and session.groundY) and (altitude - session.groundY) or nil

    if gain and gain > plan.groundedGain then
        note("")
        note(string.format("  STILL AIRBORNE at +%.1f -- leaving props at %d rpm.",
            gain, plan.propRpm))
        note("  They carry ~52% of the craft's weight; cutting them here is a")
        note("  drop, and cutting them unevenly is the roll that has put this")
        note("  craft on its side more than once. Land with /fcs/bankctl.lua.")
    elseif not groundOnly then
        local stopped, reason = session:setAllProps(0)
        if not stopped then
            note("  WARNING: could not stop all props -- " .. tostring(reason))
        end
    end

    pcall(session.finish, session)
end

pcall(parallel.waitForAny, shutdown, listenLoop)
save()
