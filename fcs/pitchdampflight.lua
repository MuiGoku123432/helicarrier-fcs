-- Measure the pitch axis, then damp it.
--
--   /fcs/pitchdampflight.lua --ground-only   the maths and the signs, no flight
--   /fcs/pitchdampflight.lua --measure-only  phase A only: authority + spring
--   /fcs/pitchdampflight.lua                 measure, then the A/B
--   /fcs/pitchdampflight.lua --pulse 3 --window 120
--
-- WHY THIS IS THE LARGEST WIN LEFT. The drift CURVES -- the velocity heading
-- swept -225 degrees in 47 s -- because roll and pitch oscillate out of phase,
-- so the tilt vector rotates. The roll half is damped and flew: 39% less
-- excursion, 40% faster decay. THE PITCH HALF HAS NEVER BEEN TOUCHED, and it
-- is half the thing that makes the curve.
--
-- ---------------------------------------------------------------------------
-- THIS FLIGHT MEASURES THREE THINGS THAT HAVE NEVER BEEN MEASURED
--
--   1. THE PITCH AUTHORITY -- deg/s^2 per rpm of fore/aft differential.
--      Predicted at 0.0493 from the measured roll authority over the unit-free
--      geometric ratio (1.91). That prediction cancels the unexplained 2.9x
--      error in the force chain, so it is worth testing rather than a fresh
--      guess -- but it is still a prediction.
--
--   2. THE SIGN. Does raising the FORWARD corners raise the bow? The geometry
--      says yes. The geometry also said roll and pitch were the other way
--      round for weeks, and said the bearing coupling was positive on an axis
--      where it measured -0.82. A damper with its sign wrong DRIVES the
--      oscillation -- confidently, at the right magnitude.
--
--   3. THE PITCH SPRING. The hull's self-levelling stiffness, which sets
--      critical damping. Roll's is 0.0223 from a 42 s period. If the restoring
--      TORQUE per degree is the same on both axes then pitch springs at
--      0.00497 -- an 89 s period -- because pitch carries 4.49x the inertia.
--      Those two are far enough apart that one window cannot confuse them.
--
-- PHASE A MEASURES ALL THREE FROM ONE PULSE, and phase B refuses to run if it
-- did not get them. Nothing here damps pitch from a predicted number.
--
-- ---------------------------------------------------------------------------
-- THE ROLL DAMPER RUNS THROUGHOUT, INCLUDING PHASE A
--
-- It is proven, it keeps the craft inside its envelope while an unmeasured
-- axis is being poked, and the two sign patterns are ORTHOGONAL -- port against
-- starboard, fore against aft -- so it cannot contaminate the pitch rate being
-- measured. The two differentials superpose per corner and the SUM is clamped
-- at 6 rpm, which is what stops a saturated roll damper eating the 3 rpm
-- measurement pulse.
--
-- SAFETY, all of it inherited from the roll flight and all of it in HANDOFF:
--   - props are NEVER left asymmetric; every exit path restores the base rpm
--   - props are NEVER cut in the air -- they carry ~52% of weight at 64 rpm
--   - shutdown runs UNDER THE LISTENER, or its commands cannot be acked
--   - divergence aborts an octave before the generic 20 degree limit, and says
--     that it is a SIGN error rather than leaving it to be worked out later

if package then
    package.path = "/?.lua;/?/init.lua;" .. package.path
end

local config = require("fcs.config")
local banks = require("fcs.banks")
local flight = require("fcs.flight")
local profile = require("fcs.mixer_profile")
local atmosphere = require("fcs.atmosphere")
local rolldamp = require("fcs.rolldamp")
local pitchdamp = require("fcs.pitchdamp")

local plan = {
    propRpm = 64,
    holdGain = 12,
    climbTimeout = 90,
    pulseRpm = 3,
    pulseSeconds = 3.0,

    -- LONGER THAN THE ROLL FLIGHT'S 40 s, and that is the whole design
    -- question of this tool. The pitch period is unknown and may be 89 s. A
    -- window shorter than one period cannot produce a period at all, and half
    -- a period of a sinusoid averages to anything -- the same trap that had
    -- trimflight reading a standing pitch of +2.404 on a craft whose standing
    -- pitch is -0.638.
    --
    -- The cost is flight time. crossingsWanted buys most of it back when the
    -- axis turns out to be fast: the window ends early once the oscillation
    -- has shown enough crossings to time.
    windowSeconds = 120,
    crossingsWanted = 4,
    -- A QUIET WINDOW BEFORE THE PULSE, so "did the angle come back" has
    -- something to come back TO. Run 1 could not answer the most important
    -- question it raised -- whether the hull returns to level in pitch or
    -- simply parks at whatever attitude it is left in -- because it never
    -- recorded where the axis started.
    baselineSeconds = 12,
    -- THE REVERSE HALF. A short window, because it exists only to measure the
    -- authority -- the spring and the classification come from the long +P
    -- window. Costs about 30 s of flight and it is what turns a number that
    -- flipped sign between two runs into one that does not.
    reverseWindowSeconds = 25,

    settleRate = 0.05,
    settleTimeout = 120,

    divergePitch = 8.0,
    divergeGrowth = 2.5,
    divergeFloor = 0.08,
    -- Pitch is the SLUGGISH axis: 4.49x the inertia, and a predicted authority
    -- half of roll's. So the bar for "the pulse did something" is lower than
    -- the roll flight's 0.05, or a real but weak response reads as nothing.
    minimumDisturbance = 0.03,
    -- How far past release to look for the impulse peak. Run 1 of the roll
    -- flight kept accelerating for 1.4 s after the command stopped, while the
    -- RSC spun down, so this must be several seconds -- and it must NOT be the
    -- whole window. See analysePhaseA.
    authoritySearchSeconds = 5.0,
    loopSeconds = 0.15,
    groundedGain = 0.6,
}

local args = { ... }
local groundOnly, measureOnly = false, false
for index = 1, #args do
    local argument = args[index]
    if argument == "--ground-only" then groundOnly = true
    elseif argument == "--measure-only" then measureOnly = true
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
    local ok, file = pcall(fs.open, "/fcs/pitchdampflight_result.txt", "w")
    if ok and file then
        file.write(table.concat(lines, "\n"))
        file.close()
        print("")
        print("Saved to /fcs/pitchdampflight_result.txt")
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
-- What phase A measures, and what phase B is allowed to use
-- ---------------------------------------------------------------------------

-- Held here rather than written back into pitchdamp.MEASURED. A module-level
-- constant that appears mid-flight is exactly the kind of state that makes a
-- later run's numbers impossible to attribute -- and pitchdamp deliberately
-- ships with those fields nil so that nothing can command from them by
-- accident.
local measured = {
    authorityPerRpm = nil,   -- SIGNED
    springPerDegree = nil,
    period = nil,
}

-- ---------------------------------------------------------------------------
-- Rates. TWO estimators, one per axis, both fed from the same read.
-- ---------------------------------------------------------------------------

local rollRate = rolldamp.newRateEstimator({ windowSeconds = 0.6 })
-- PITCH GETS A LONGER WINDOW. The rate being estimated is smaller -- a
-- sluggish axis on a craft whose angles quantise -- so 0.6 s of samples gives
-- a slope that is mostly quantisation noise. 1.0 s against a period that is at
-- worst 42 s and probably 89 is still under 2.4% of a cycle, so the phase lag
-- a damper must not have is not bought at any real price.
local pitchRate = rolldamp.newRateEstimator({ windowSeconds = 1.0 })
local startedAt = os.epoch("utc")
local commandedProps = false

local function feed(state, now)
    if state and state.valid then
        local t = (now - startedAt) / 1000
        if state.roll then rollRate:push(t, state.roll) end
        if state.pitch then pitchRate:push(t, state.pitch) end
    end
    return rollRate:rate(), pitchRate:rate()
end

local function rollCommand(rate)
    return rate and rolldamp.differentialFor(rate) or 0
end

-- The pitch damper, which returns 0 AND A REASON until phase A has run.
local function pitchCommand(rate)
    if not measured.authorityPerRpm then return 0, "not measured yet" end
    return pitchdamp.differentialFor(rate, {
        authorityPerRpm = measured.authorityPerRpm,
        springPerDegree = measured.springPerDegree,
    })
end

local clippedEver = false

local function commandDifferentials(rollDifferential, pitchDifferential)
    local rpms, clipped = pitchdamp.combinedCornerRpm(plan.propRpm,
        rollDifferential or 0, pitchDifferential or 0,
        { minimumRpm = config.propeller.minimumRpm })
    if clipped then clippedEver = true end
    session:sendProps(rpms)
    commandedProps = true
    return rpms, clipped
end

-- ---------------------------------------------------------------------------
-- Divergence
-- ---------------------------------------------------------------------------

local function divergence(pitch, rate, baseline)
    if math.abs(pitch or 0) > plan.divergePitch then
        return string.format("pitch reached %.1f deg while DAMPING", pitch)
    end
    if baseline and baseline > plan.divergeFloor and rate
        and math.abs(rate) > baseline * plan.divergeGrowth then
        return string.format("pitch rate GREW from %.3f to %.3f deg/s while damping",
            baseline, math.abs(rate))
    end
    return nil
end

local function signWarning(reason)
    note("")
    note("  ** " .. reason)
    note("  ** THE DAMPER IS DRIVING THE OSCILLATION, and on this axis that")
    note("  ** should be impossible: phase A MEASURED the sign and phase B")
    note("  ** commands through it. If this fires, the thing that is wrong is")
    note("  ** not the sign table -- it is that the pitch rate the damper sees")
    note("  ** does not match the pitch the craft is doing. Check the estimator")
    note("  ** window and attitude.lua's pitch convention.")
    note("")
end

-- ---------------------------------------------------------------------------
-- Ground mode
-- ---------------------------------------------------------------------------

local function groundCheck()
    note("GROUND CHECK -- commanding nothing")
    note("")

    local predicted, ratio, source = pitchdamp.predictedAuthority()
    note(string.format("  measured ROLL authority   %.4f deg/s^2 per rpm",
        rolldamp.MEASURED.flightAuthorityPerRpm))
    note(string.format("  roll/pitch ratio          %.3f   (%s)", ratio, source))
    note(string.format("  PREDICTED pitch authority %.4f deg/s^2 per rpm", predicted))
    note("  (unit-free: the force chain's unexplained 2.9x cancels in the ratio,")
    note("   which is why this is worth testing rather than modelling afresh.)")
    note("")

    local hypothetical = pitchdamp.springIfTorqueMatchesRoll()
    note(string.format("  roll spring   %.4f -> period %.1f s   MEASURED once",
        rolldamp.MEASURED.springPerDegree,
        rolldamp.periodFromSpring(rolldamp.MEASURED.springPerDegree)))
    note(string.format("  pitch spring  %.4f -> period %.1f s   IF the restoring",
        hypothetical, rolldamp.periodFromSpring(hypothetical)))
    note("  torque per degree matches roll's. NOT measured. This flight measures it.")
    note(string.format("  window is %.0f s, so a %.0f s period is one full cycle.",
        plan.windowSeconds, rolldamp.periodFromSpring(hypothetical)))
    note("")

    note("  the fore/aft pattern (a HYPOTHESIS until phase A):")
    note("    positive differential -> FL +, FR +, RL -, RR -  -> bow UP")
    local rpms = pitchdamp.cornerRpm(plan.propRpm, plan.pulseRpm,
        { minimumRpm = config.propeller.minimumRpm })
    note(string.format("    +%d rpm -> FL %d  FR %d  RL %d  RR %d",
        plan.pulseRpm, rpms.FL, rpms.FR, rpms.RL, rpms.RR))
    note("")

    -- THE REFUSAL, demonstrated rather than described. A reader should see
    -- that the damper will not command before phase A, because that is the
    -- single most important property of this file.
    local differential, reason = pitchdamp.differentialFor(0.5)
    note(string.format("  pitch damper asked for 0.5 deg/s of rate -> %d rpm",
        differential))
    note("    reason: " .. tostring(reason))
    if differential ~= 0 then
        note("  ** IT COMMANDED. It must not: nothing has measured this axis.")
    end
    note("")

    -- And what it WILL command once phase A has filled the numbers in, at the
    -- predicted authority and the hypothetical spring.
    note("  what it would command at the PREDICTED numbers:")
    note("    rate (deg/s)  ->  differential")
    for _, rate in ipairs({ -1.0, -0.4, -0.1, 0, 0.1, 0.4, 1.0 }) do
        local rpm = pitchdamp.differentialFor(rate, {
            authorityPerRpm = predicted, springPerDegree = hypothetical,
        })
        note(string.format("    %+6.2f        ->  %+3d", rate, rpm))
    end
    note(string.format("    critical damping %.4f deg/s^2, arriving at %.1f rpm",
        pitchdamp.criticalDamping(hypothetical),
        pitchdamp.criticalDamping(hypothetical) / predicted))
    note("")

    local state = session:read()
    if state and state.valid then
        note(string.format("  live attitude: roll %+.2f  pitch %+.2f deg",
            state.roll or 0, state.pitch or 0))
        for _ = 1, 8 do
            local live = session:readCheap()
            feed(live, os.epoch("utc"))
            sleep(plan.loopSeconds)
        end
        local live = pitchRate:rate()
        if live then
            note(string.format("  live pitch rate: %+.3f deg/s over %d samples",
                live, pitchRate:count()))
        else
            note("  ** no pitch rate after 8 samples -- the estimator is not being")
            note("  ** fed, and the damper would command zero all flight.")
        end
    else
        note("  no valid attitude sample")
    end
end

-- ---------------------------------------------------------------------------
-- One half of the A/B
-- ---------------------------------------------------------------------------

local function recordWindow(label, damped, options)
    options = options or {}
    local pulseRpm = options.pulseRpm or plan.pulseRpm
    local windowSeconds = options.windowSeconds or plan.windowSeconds
    local samples = {}
    session.cheapRead = true

    -- WHERE THE AXIS SAT BEFORE ANYTHING WAS COMMANDED. A mean over a quiet
    -- window, not a reading: the standing pitch offset is a few tenths and the
    -- hull moves either side of it.
    local baselineTotal, baselineCount = 0, 0
    session:hold(plan.baselineSeconds, function(state, now)
        session:trim(plan.holdGain, flight.MAX_CLIMB_RATE, 0, state)
        local roll = feed(state, now)
        commandDifferentials(rollCommand(roll), 0)
        if state and state.valid and state.pitch then
            baselineTotal = baselineTotal + state.pitch
            baselineCount = baselineCount + 1
        end
    end)
    local baselinePitch = baselineCount > 0 and (baselineTotal / baselineCount) or nil

    -- THE PRE-PULSE RATE, which is the number run 1 needed and did not have.
    -- What a pulse produces is a CHANGE in rate; the craft was already doing
    -- something, and out of a climb that something is as large as the signal.
    -- Run 1 read -0.0440 off its own leftover climb motion -- its "peak" was
    -- the first sample of the window -- where run 2, after sitting quiet,
    -- read +0.0237. Opposite signs from the same command.
    local initialRate = pitchRate:rate() or 0

    note(string.format("  %s: baseline pitch %s deg, rate %+.3f deg/s (%d samples)",
        label, baselinePitch and string.format("%+.3f", baselinePitch) or "?",
        initialRate, baselineCount))

    note(string.format("  %s: pulsing %+d rpm fore/aft for %.1f s",
        label, pulseRpm, plan.pulseSeconds))

    commandDifferentials(0, pulseRpm)
    local pulseStop = session:hold(plan.pulseSeconds, function(state, now)
        session:trim(plan.holdGain, flight.MAX_CLIMB_RATE, 0, state)
        local roll = feed(state, now)
        -- The roll damper rides through the pulse. Orthogonal pattern, so it
        -- cannot add or subtract from the pitch torque being applied.
        commandDifferentials(rollCommand(roll), pulseRpm)
    end)
    if pulseStop then
        note("  " .. label .. ": " .. tostring(pulseStop))
        commandDifferentials(0, 0)
        return samples, pulseStop
    end

    local releasedAt = os.epoch("utc")
    local baseline = nil
    note(string.format("  %s: released, logging up to %.0f s", label, windowSeconds))

    local stop = session:hold(windowSeconds, function(state, now)
        session:trim(plan.holdGain, flight.MAX_CLIMB_RATE, 0, state)
        local roll, pitch = feed(state, now)

        local commanded = 0
        if damped and pitch then
            commanded = pitchCommand(pitch)
            baseline = baseline or math.abs(pitch)
            local diverging = divergence(state and state.pitch, pitch, baseline)
            if diverging then
                commandDifferentials(rollCommand(roll), 0)
                signWarning(diverging)
                return "DIVERGING: " .. diverging
            end
        end
        commandDifferentials(rollCommand(roll), commanded)

        if pitch then
            samples[#samples + 1] = {
                t = (now - releasedAt) / 1000,
                pitch = state.pitch,
                pitchRate = pitch,
                roll = state.roll,
                commanded = commanded,
            }

            -- EARLY EXIT, and only in the undamped half. Once the oscillation
            -- has crossed zero enough times to be timed, the rest of the
            -- window is flight time spent learning nothing. In the DAMPED half
            -- there is no such thing as enough crossings -- the whole hope is
            -- that there are none -- so it always runs full length.
            if not damped then
                local crossings = rolldamp.zeroCrossings(samples,
                    rolldamp.DEFAULTS.deadbandRate, "pitchRate")
                if crossings >= plan.crossingsWanted then
                    return "measured"
                end
            end
        end
    end)

    commandDifferentials(0, 0)
    if stop and stop ~= "measured" then
        note("  " .. label .. ": " .. tostring(stop))
    elseif stop == "measured" then
        note(string.format("  %s: %d crossings seen, window ended early at %.0f s",
            label, plan.crossingsWanted,
            samples[#samples] and samples[#samples].t or 0))
    end
    samples.baselinePitch = baselinePitch
    samples.initialRate = initialRate
    samples.pulseRpm = pulseRpm
    return samples, (stop ~= "measured") and stop or nil
end

-- ---------------------------------------------------------------------------
-- Settle. Runs BOTH dampers -- see rolldampflight for why using the actuator
-- to reach the start line biases nothing that is measured after it.
-- ---------------------------------------------------------------------------

local function settle(label)
    note(string.format("  damping to quiet (|pitch rate| < %.2f deg/s)",
        plan.settleRate))
    session.cheapRead = true
    local quietSince, baseline = nil, nil

    local stop = session:hold(plan.settleTimeout, function(state, now)
        session:trim(plan.holdGain, flight.MAX_CLIMB_RATE, 0, state)
        local roll, pitch = feed(state, now)
        commandDifferentials(rollCommand(roll), pitchCommand(pitch))

        if pitch then
            baseline = baseline or math.abs(pitch)
            local diverging = divergence(state and state.pitch, pitch, baseline)
            if diverging then
                signWarning(diverging)
                return "DIVERGING: " .. diverging
            end
            if math.abs(pitch) < plan.settleRate then
                quietSince = quietSince or now
                if now - quietSince > 3000 then
                    note(string.format("  %s: quiet at %.3f deg/s", label, pitch))
                    return "quiet"
                end
            else
                quietSince = nil
            end
        end
    end)

    commandDifferentials(0, 0)
    if stop == "quiet" then return true end
    note("  " .. label .. ": " .. (stop and tostring(stop)
        or ("could not quiet the pitch axis within " .. plan.settleTimeout
            .. " s -- which is itself a result")))
    return false
end

-- ---------------------------------------------------------------------------
-- Phase A: the three unknowns
-- ---------------------------------------------------------------------------

local function peakAbsPitch(samples)
    local peak = 0
    for _, sample in ipairs(samples) do
        local magnitude = math.abs(sample.pitch or 0)
        if magnitude > peak then peak = magnitude end
    end
    return peak
end

local function analysePhaseA(samples, reverse)
    note("")
    note("== A: what the pulse measured ==")
    note("")

    -- BOUNDED. Searching the whole window for a peak works on a 40 s roll
    -- flight and is nonsense here: with a 120 s window and a period that may
    -- be 89 s, the largest rate in the window is the spring's own swing half a
    -- minute later, pointing the other way. The harness read -0.0015 -- 3% of
    -- prediction, backwards -- off a peak at t = 46.5 s. The impulse peak
    -- arrives within a second or two of release, while the props spin down.
    local magnitude, peak, seconds, signed = rolldamp.authorityFromPulse(
        samples, plan.pulseRpm, plan.pulseSeconds, "pitchRate",
        plan.authoritySearchSeconds, samples.initialRate)

    if not magnitude or peak < plan.minimumDisturbance then
        note(string.format("  NO DISTURBANCE. Peak pitch rate %.4f deg/s, below the"
            .. " %.2f needed.", peak or 0, plan.minimumDisturbance))
        note("  The fore/aft differential did not move the craft, so nothing here")
        note("  is about damping. Check, in this order: are all four props at the")
        note("  commanded rpm (prop.controllerRpm, not targetRpm)? Is the craft")
        note("  airborne -- a grounded hull carries the moment? Did the RL/RR")
        note("  corners actually go DOWN, or did the 8 rpm floor eat the")
        note("  differential?")
        return false
    end

    local predicted, ratio = pitchdamp.predictedAuthority()

    note(string.format("  +%d rpm half   %+.4f deg/s^2 per rpm  (peak %.3f deg/s over %.1f s)",
        plan.pulseRpm, signed, peak, seconds))

    -- THE REVERSE PAIR IS THE ANSWER WHEN THERE IS ONE. Any drift common to
    -- both halves appears with the same sign in each and cancels in the
    -- difference, while the response reverses and adds. Same reasoning as
    -- trim.staticGain, and the same reason it was needed: on this craft the
    -- thing being measured is smaller than the thing it sits on top of.
    if reverse then
        local paired, plusHalf, minusHalf = rolldamp.authorityFromReversePair(
            samples, reverse, plan.pulseRpm, plan.pulseSeconds, "pitchRate",
            plan.authoritySearchSeconds, samples.initialRate, reverse.initialRate)
        if paired then
            note(string.format("  -%d rpm half   %+.4f deg/s^2 per rpm",
                plan.pulseRpm, minusHalf))
            note(string.format("  REVERSE PAIR  %+.4f deg/s^2 per rpm", paired))
            local spread = math.abs(plusHalf - minusHalf)
            local mean = (math.abs(plusHalf) + math.abs(minusHalf)) / 2
            if mean > 0 then
                note(string.format("  the two halves are %.0f%% apart", spread / mean * 100))
                if spread / mean > 0.5 then
                    note("  ** THAT IS TOO FAR APART. The halves are not measuring the")
                    note("  ** same response, so their difference is not one either.")
                end
            end
            measured.authorityPerRpm = paired
            signed = paired
            magnitude = math.abs(paired)
        else
            note("  the reverse half produced nothing usable; using the +rpm half alone")
            measured.authorityPerRpm = signed
        end
    else
        note("  NO REVERSE HALF -- this is a single pulse, and a single pulse")
        note("  measures the pulse PLUS whatever the craft was already doing.")
        measured.authorityPerRpm = signed
    end

    note(string.format("  predicted     %+.4f  -- measured is %.0f%% of it",
        predicted, magnitude / predicted * 100))
    note("")

    -- THE SIGN, said in words. A minus sign in a number is not a finding until
    -- somebody reads it as one, and this is the finding most likely to matter
    -- to whoever comes next.
    if signed > 0 then
        note("  SIGN POSITIVE: raising the FORWARD corners raises the bow, which is")
        note("  what the geometry predicted. pitchdamp.CORNER_SIGNS is correct.")
    else
        note("  ** SIGN NEGATIVE: raising the FORWARD corners DROPS the bow. That is")
        note("  ** OPPOSITE to the geometry, and to pitchdamp.CORNER_SIGNS as")
        note("  ** written. The damper below handles it -- the authority is signed")
        note("  ** and the command divides by it -- but anything that assumed the")
        note("  ** predicted sign would DRIVE this axis. Record it.")
    end
    note("")

    -- THE SPRING, from the free oscillation.
    local period, intervals, spread = rolldamp.measurePeriod(samples,
        rolldamp.DEFAULTS.deadbandRate, "pitchRate")
    local crossings = rolldamp.zeroCrossings(samples,
        rolldamp.DEFAULTS.deadbandRate, "pitchRate")

    if period then
        measured.period = period
        measured.springPerDegree = rolldamp.springFromPeriod(period)
        note(string.format("  PERIOD     %.1f s   from %d interval%s%s", period,
            intervals, intervals == 1 and "" or "s",
            spread and string.format(", spread %.0f%%", spread * 100) or ""))
        note(string.format("  SPRING     %.5f deg/s^2 per degree", measured.springPerDegree))
        note(string.format("  critical damping %.4f deg/s^2, arriving at %.1f rpm",
            pitchdamp.criticalDamping(measured.springPerDegree),
            math.abs(pitchdamp.criticalDamping(measured.springPerDegree) / signed)))
        note("")

        local hypothetical = pitchdamp.springIfTorqueMatchesRoll()
        local rollPeriod = rolldamp.periodFromSpring(rolldamp.MEASURED.springPerDegree)
        note(string.format("  against the two hypotheses: roll's own period %.1f s,"
            .. " equal-torque %.1f s", rollPeriod,
            rolldamp.periodFromSpring(hypothetical)))
        if math.abs(period - rollPeriod) < math.abs(period
            - rolldamp.periodFromSpring(hypothetical)) then
            note("  -> nearer ROLL'S period. The restoring torque is NOT the same on")
            note("     both axes; it scales with the inertia, so the hull levels both")
            note("     axes at about the same rate.")
        else
            note("  -> nearer the EQUAL-TORQUE period. The restoring torque per degree")
            note("     is the same on both axes, so pitch springs 4.49x slower.")
        end
        if intervals == 1 then
            note("")
            note("  ONE interval is a measurement with no error bar. Worth repeating")
            note("  before this number is written down as the craft's.")
        end
        if spread and spread > 0.3 then
            note("")
            note(string.format("  ** the intervals disagree by %.0f%%. That is not one",
                spread * 100))
            note("  ** frequency ringing down -- treat the period as provisional.")
        end
    else
        note(string.format("  NO PERIOD. %d crossing%s in the window -- the axis did"
            .. " not ring.", crossings, crossings == 1 and "" or "s"))
    end
    note("")

    local decay = rolldamp.decayTime(samples, "pitchRate")
    note(string.format("  peak |pitch| %.2f deg, time to 1/e %s, %d crossings",
        peakAbsPitch(samples),
        decay and string.format("%.1f s", decay) or "never", crossings))

    -- ---------------------------------------------------------------------
    -- WHAT KIND OF AXIS IS THIS? Run 1 made this the important question.
    --
    -- The premise of this tool was that pitch is underdamped like roll. The
    -- craft said otherwise: 0 crossings in 120 s and the rate down to 1/e in
    -- 1.6 s. An axis that arrests itself in under two seconds does not want a
    -- rate damper. But "it did not oscillate" splits two ways, and the split
    -- is the whole finding -- so it is measured rather than argued.
    -- ---------------------------------------------------------------------
    local baseline = samples.baselinePitch
    local peakSigned, finalPitch = nil, nil
    for _, sample in ipairs(samples) do
        if sample.pitch then
            if not peakSigned
                or math.abs(sample.pitch - (baseline or 0))
                    > math.abs(peakSigned - (baseline or 0)) then
                peakSigned = sample.pitch
            end
        end
    end
    -- The FINAL attitude is a mean over the last stretch, not the last
    -- reading: a single sample carries whatever the hull was doing at that
    -- instant, and the number being computed is a difference of tenths.
    local tailTotal, tailCount = 0, 0
    local lastAt = samples[#samples] and samples[#samples].t or 0
    for _, sample in ipairs(samples) do
        if sample.pitch and sample.t >= lastAt - 20 then
            tailTotal = tailTotal + sample.pitch
            tailCount = tailCount + 1
        end
    end
    if tailCount > 0 then finalPitch = tailTotal / tailCount end

    local verdict, returned = pitchdamp.classify({
        crossings = crossings, baseline = baseline,
        peak = peakSigned, final = finalPitch,
    })

    note("")
    note(string.format("  baseline %s -> peak %s -> settled %s deg",
        baseline and string.format("%+.3f", baseline) or "?",
        peakSigned and string.format("%+.3f", peakSigned) or "?",
        finalPitch and string.format("%+.3f", finalPitch) or "?"))
    if returned then
        note(string.format("  the hull gave back %.0f%% of the excursion", returned * 100))
    end
    note(string.format("  VERDICT: %s", verdict))

    if verdict == pitchdamp.OVERDAMPED then
        note("  There IS a restoring moment and enough damping that the axis")
        note("  creeps home without overshooting. Pitch is the healthy axis.")
    elseif verdict == pitchdamp.NO_SPRING then
        note("  ** THE HULL DID NOT COME BACK. Pitch has damping but little or no")
        note("  ** restoring moment -- it STAYS where it is left. That is a bigger")
        note("  ** finding than a missing damper: it means every standing pitch")
        note("  ** offset in this project is a PARKED ATTITUDE, not an equilibrium,")
        note("  ** and the velocity loop gets no self-levelling help on this axis.")
    elseif verdict == pitchdamp.UNCLEAR then
        note("  Neither clearly home nor clearly parked. Re-fly with a larger")
        note("  pulse before drawing anything from it.")
    end

    if not pitchdamp.worthDamping(verdict, decay) then
        note("")
        note(string.format("  A RATE DAMPER IS NOT WORTH ADDING HERE. The axis arrests"
            .. " itself in %s,", decay and string.format("%.1f s", decay) or "?"))
        note("  against roll's 4.6 s and 5 zero crossings. The premise this tool was")
        note("  built on -- that half the drift curve's oscillation is undamped pitch")
        note("  -- does not survive this measurement. Whatever rotates the tilt")
        note("  vector, it is not an undamped pitch axis.")
    end

    return measured.authorityPerRpm ~= nil and measured.springPerDegree ~= nil
        and pitchdamp.worthDamping(verdict, decay)
end

-- ---------------------------------------------------------------------------
-- Verdict
-- ---------------------------------------------------------------------------

local function report(off, on)
    note("")
    note("== RESULT ==")
    note("")

    local offCrossings = rolldamp.zeroCrossings(off,
        rolldamp.DEFAULTS.deadbandRate, "pitchRate")
    local onCrossings = rolldamp.zeroCrossings(on,
        rolldamp.DEFAULTS.deadbandRate, "pitchRate")
    local offDecay, offPeak = rolldamp.decayTime(off, "pitchRate")
    local onDecay, onPeak = rolldamp.decayTime(on, "pitchRate")

    note("                        DAMPER OFF     DAMPER ON")
    note(string.format("  samples               %8d      %8d", #off, #on))
    note(string.format("  peak pitch rate       %8.3f      %8.3f  deg/s",
        offPeak or 0, onPeak or 0))
    note(string.format("  peak |pitch|          %8.2f      %8.2f  deg",
        peakAbsPitch(off), peakAbsPitch(on)))
    note(string.format("  zero crossings        %8d      %8d", offCrossings, onCrossings))
    note(string.format("  time to 1/e           %8s      %8s  s",
        offDecay and string.format("%.1f", offDecay) or "never",
        onDecay and string.format("%.1f", onDecay) or "never"))
    note("")
    note("      (crossings are AMPLITUDE-BLIND: a damper that arrests the big")
    note("       swing early then drifts across zero at a tenth the amplitude")
    note("       scores WORSE here. Peak excursion and decay carry the result.)")
    note("")

    -- THE COMPARISON IS ONLY FAIR IF BOTH HALVES STARTED ALIKE. Said before
    -- the verdict, because a verdict drawn from unequal starts is worse than
    -- no verdict -- it is a number that will be quoted.
    if offPeak and onPeak and offPeak > 0 then
        local apart = math.abs(onPeak / offPeak - 1)
        note(string.format("  the two pulses started %.1f%% apart in peak rate.", apart * 100))
        if apart > 0.25 then
            note("  ** THAT IS TOO FAR APART TO COMPARE. The same pulse produced")
            note("  ** materially different disturbances, so the difference below is")
            note("  ** not the damper. Re-fly before believing it.")
            note("")
        end
    end

    local excursionOff, excursionOn = peakAbsPitch(off), peakAbsPitch(on)
    if excursionOff > 0 then
        local change = (1 - excursionOn / excursionOff) * 100
        if change > 10 then
            note(string.format("  DAMPED. Peak pitch excursion %.2f -> %.2f deg, %.0f%% less.",
                excursionOff, excursionOn, change))
            if offDecay and onDecay then
                note(string.format("  Decay %.1f -> %.1f s, %.0f%% faster.",
                    offDecay, onDecay, (1 - onDecay / offDecay) * 100))
            end
            note("")
            note("  For comparison, the ROLL damper's first flight: 5.58 -> 3.43 deg")
            note("  (39% less) and 4.6 -> 2.8 s (40% faster).")
        elseif change > -10 then
            note(string.format("  NO CLEAR EFFECT. Peak excursion %.2f -> %.2f deg.",
                excursionOff, excursionOn))
            note("  The likeliest causes, in order: the authority is too small for")
            note("  the 4 rpm clamp to matter, the spring measurement is wrong so the")
            note("  gain is wrong, or the two halves did not start alike.")
        else
            note(string.format("  WORSE. Peak excursion %.2f -> %.2f deg, %.0f%% MORE.",
                excursionOff, excursionOn, -change))
            note("  With a measured sign this should not happen. Suspect the pitch")
            note("  rate estimator before the sign table.")
        end
    end
    note("")

    note(string.format("  MEASURED THIS FLIGHT:  authority %+.4f deg/s^2 per rpm",
        measured.authorityPerRpm or 0))
    if measured.period then
        note(string.format("                         period %.1f s -> spring %.5f",
            measured.period, measured.springPerDegree))
    end
    note("")
    note("  Write these into fcs/pitchdamp.lua's MEASURED block ONLY after a")
    note("  second flight agrees with them -- that is the standard rolldamp's")
    note("  three paired steps set, and it is why its number is trusted.")
    if clippedEver then
        note("")
        note("  NOTE: the combined differential clipped at least once. The roll and")
        note("  pitch demands together exceeded the 6 rpm sum clamp, so for those")
        note("  samples neither axis got exactly what it asked for.")
    end
end

-- ---------------------------------------------------------------------------

local function mainLoop()
    note("PITCH DAMPING -- measure the axis, then damp it")
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
    note("== A: pitch UNDAMPED -- authority, sign and spring ==")
    note("  (the roll damper runs throughout; the patterns are orthogonal)")
    local off, offStop = recordWindow("A", false)
    if offStop then
        note("")
        note("== descend and land ==")
        session:descend()
        return
    end

    -- THE REVERSE HALF. Short, and only for the authority: the spring and the
    -- classification came from the long window above. Settle first so it
    -- starts from the same kind of quiet the +rpm half did.
    note("")
    note("== A2: the reverse pulse, for the authority ==")
    settle("A2 settle")
    local reverse, reverseStop = recordWindow("A2", false, {
        pulseRpm = -plan.pulseRpm,
        windowSeconds = plan.reverseWindowSeconds,
    })
    if reverseStop then
        note("  the reverse half stopped early: " .. tostring(reverseStop))
        reverse = nil
    end

    local usable = analysePhaseA(off, reverse)

    if measureOnly or not usable then
        if not usable then
            note("")
            note("  NOT RUNNING THE A/B. Either phase A did not produce both an")
            note("  authority and a spring -- a damper built on half of them is a")
            note("  gain derived from a guess -- or it measured an axis that does")
            note("  not need damping. The verdict above says which.")
        else
            note("")
            note("  --measure-only: not running the A/B.")
        end
        note("")
        note("== descend and land ==")
        session:descend()
        return
    end

    note("")
    note("== settling before B ==")
    settle("settle")

    note("")
    note("== B: pitch DAMPED, with the numbers phase A measured ==")
    local on, onStop = recordWindow("B", true)
    if onStop then
        note("")
        note("== descend and land ==")
        session:descend()
        return
    end

    report(off, on)

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
    if not commandedProps then
        note("")
        note("  nothing was commanded; props untouched.")
        pcall(session.finish, session)
        return
    end

    -- Symmetric first, whatever else happens.
    session:sendProps(pitchdamp.combinedCornerRpm(plan.propRpm, 0, 0,
        { minimumRpm = config.propeller.minimumRpm }))

    local state = session:read()
    local altitude = state and session:craftY(state)
    local gain = (altitude and session.groundY) and (altitude - session.groundY) or nil

    if gain and gain > plan.groundedGain then
        note("")
        note(string.format("  STILL AIRBORNE at +%.1f -- leaving props at %d rpm.",
            gain, plan.propRpm))
        note("  Cutting them here removes ~52% of the lift. Land with")
        note("  /fcs/bankctl.lua; the props are symmetric.")
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
