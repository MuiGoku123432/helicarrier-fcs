-- Does anything stop the carrier rolling over?
--
--     /fcs/rolldrift.lua [seconds] [altitude]
--
-- WILL FLY THE CRAFT -- but passively. It hovers low, commands all four
-- corners IDENTICALLY, and simply watches what the craft does on its own.
-- No pulses, no attitude demand, no manoeuvre.
--
-- ---------------------------------------------------------------------------
-- THE QUESTION
--
-- HISTORICAL, kept because the arithmetic is what the tool was built around:
-- RR's bearing_5 WAS 1.121% down, a STANDING roll torque of ~0.073% of craft
-- weight. Ion power quantises to 15 levels, so the finest trim available on a
-- corner is 5.57% of weight -- 76x too coarse to cancel it. If nothing else
-- resists, that torque integrates:
--
--     0.0112 deg/s^2  ->   5 deg at 30 s,  20 deg at 60 s,  80 deg at 120 s
--
-- getStabilizationStrength reads 1.0 on every bearing when active (0.0 when
-- inactive -- an inactive bearing reading proves nothing on this mod). But
-- that is a BEARING method: it plausibly means the bearing holds its own
-- angle, not that the hull returns to level. No getter answers the hull
-- question, so it has to be flown.
--
-- WHY THIS IS SAFE, in a way the axis-response run is not:
--
--   * Nothing is commanded to rotate. (Pre-repair the RR deficit supplied the
--     tilt, gently and for free.) The craft is left alone and watched.
--   * All four corners get the identical command. mixer_profile.lua's RR bias
--     is now 0 -- it was 0.001276, which is 1.9% of an ion quantum, and rather
--     than correcting anything it intermittently pushed RR a WHOLE LEVEL up
--     whenever collective sat just below a boundary: 0.852 deg/s^2 of roll to
--     fix a 0.0112 deg/s^2 defect. This harness caught it.
--   * +5 blocks. A total loss of control is a 5-block drop onto flat
--     superflat terrain, with an expendable craft in a creative world.
--   * Aborts at 10 degrees, far short of anything dramatic, and lands via the
--     rate-controlled descent in fcs/flight.lua.
--
-- THE PREDICTION, which is what makes this worth flying:
--
--   no hull stabilization -> roll accelerates at ~0.0112 deg/s^2, reaching
--                            ~5 deg by 30 s and ~20 deg by 60 s
--   damping only          -> roll rate rises then PLATEAUS; angle grows
--                            linearly rather than quadratically
--   hull stabilization    -> roll stays bounded near zero
--
-- Those are three distinguishable shapes, and the tool fits for them rather
-- than eyeballing a number.
-- ---------------------------------------------------------------------------

package.path = "/?.lua;/?/init.lua;" .. package.path

local config = require("fcs.config")
local banks = require("fcs.banks")
local profile = require("fcs.mixer_profile")
local atmosphere = require("fcs.atmosphere")
local flight = require("fcs.flight")

local args = { ... }
local OBSERVE_SECONDS = tonumber(args[1]) or 60
local ALTITUDE = tonumber(args[2]) or 5

local report = {}
local function note(text)
    report[#report + 1] = text
    print(text)
end

local function writeReport()
    local file = fs.open("/fcs/rolldrift_result.txt", "w")
    if file then
        file.write(table.concat(report, "\n"))
        file.close()
    end
end

local atmosphereModel = atmosphere.load()

local session = flight.new({
    config = config,
    profile = profile,
    atmosphere = atmosphereModel,
    note = note,
    -- Tighter than the axis-response run: this is a passive observation, so
    -- any large excursion means the premise is wrong and it should come down.
    maxTiltDegrees = 10,
    maxAltitudeGain = 20,
    minAltitudeGain = -3,
})

local samples = {}

-- ---------------------------------------------------------------------------

local function analyse()
    note("")
    note("=== ANALYSIS ===")
    if #samples < 6 then
        note("only " .. #samples .. " samples -- too few to say anything.")
        note("The loop runs ~950 ms; give it a longer observation window.")
        return
    end

    local first = samples[1]
    local last = samples[#samples]
    local span = last.t - first.t
    note(string.format("%d samples over %.1f s", #samples, span))
    note("")
    note(string.format("  %8s %10s %12s %10s %12s", "t (s)", "roll", "rollRate", "pitch", "pitchRate"))
    local step = math.max(1, math.floor(#samples / 12))
    for index = 1, #samples, step do
        local sample = samples[index]
        note(string.format("  %8.1f %10.3f %12.4f %10.3f %12.4f  %s",
            sample.t, sample.roll, sample.rollRate, sample.pitch, sample.pitchRate,
            tostring(sample.phase)))
    end

    -- Classify on the ANGLE series, not the rate.
    --
    -- The first version fitted rollRate and returned AMBIGUOUS on a run that
    -- plainly showed self-levelling. Two reasons, both real:
    --
    --   1. rollRate read exactly 0.0000 in 5 of 12 samples. The ~950 ms loop
    --      cannot resolve it, so the rate channel is noise-dominated here.
    --      The angle is measured directly and is trustworthy.
    --   2. There was no category for BOUNDED OSCILLATION -- only diverging,
    --      plateauing, or held-within-a-degree. A craft swinging +/-2.8 deg
    --      through zero is none of those, and it is the single most important
    --      outcome to recognise.
    --
    -- The decisive signals are SIGN CHANGES and the observed peak against what
    -- free divergence would have produced by now.
    local minRoll, maxRoll = samples[1].roll, samples[1].roll
    local signChanges = 0
    for index, sample in ipairs(samples) do
        if sample.roll < minRoll then minRoll = sample.roll end
        if sample.roll > maxRoll then maxRoll = sample.roll end
        if index > 1 and samples[index - 1].roll * sample.roll < 0 then
            signChanges = signChanges + 1
        end
    end
    local peak = math.max(math.abs(minRoll), math.abs(maxRoll))

    -- The free-drift baseline needs a KNOWN standing torque to be meaningful.
    --
    -- This was hardcoded to 0.0112 deg/s^2 -- the RR bearing_5 deficit. That
    -- defect was repaired and verified 2026-08-26, so the craft is symmetric
    -- and there is no known standing torque left. Leaving the constant in
    -- place made the tool print "62.09 deg free-drift prediction" for a
    -- disturbance that does not exist, and then report the ratio to it as
    -- evidence. A baseline computed from a repaired defect is not a baseline.
    --
    -- Set this to the pre-repair 0.0112 only to re-check the old asymmetry.
    local KNOWN_STANDING_ACCEL = 0.0
    local freeDrift = 0.5 * KNOWN_STANDING_ACCEL * span * span
    local ratio = freeDrift > 0 and peak / freeDrift or nil

    -- The EQUILIBRIUM OFFSET is what matters on a symmetric craft: a restoring
    -- moment parks the hull where the residual torque balances the spring, so
    -- the MEAN angle -- not the peak -- measures whatever standing torque is
    -- left. Peak is oscillation amplitude and says nothing about it.
    --
    -- Measured over the observe phase only; the climb phase carries thrust
    -- transients that would drag the mean.
    local sum, count = 0, 0
    local pitchSum = 0
    for _, sample in ipairs(samples) do
        if sample.phase == "observe" then
            sum, pitchSum, count = sum + sample.roll, pitchSum + sample.pitch, count + 1
        end
    end
    -- Fall back to every sample rather than reporting nothing if the observe
    -- phase was never tagged.
    if count == 0 then
        for _, sample in ipairs(samples) do
            sum, pitchSum, count = sum + sample.roll, pitchSum + sample.pitch, count + 1
        end
    end
    local rollOffset = count > 0 and (sum / count) or nil
    local pitchOffset = count > 0 and (pitchSum / count) or nil

    note("")
    note(string.format("  roll range   : %.3f .. %.3f deg   (peak |%.2f|)", minRoll, maxRoll, peak))
    note(string.format("  sign changes : %d", signChanges))
    if rollOffset then
        note(string.format("  equilibrium  : roll %+.3f deg, pitch %+.3f deg  (observe-phase mean, n=%d)",
            rollOffset, pitchOffset, count))
    end
    if freeDrift > 0 then
        note(string.format("  free-drift prediction over %.0f s: %.2f deg", span, freeDrift))
    else
        note("  free-drift prediction: n/a -- no known standing torque (craft is symmetric)")
    end

    -- Half-period from zero crossings gives the spring stiffness directly.
    if signChanges >= 2 then
        local halfPeriod = span / signChanges
        local period = 2 * halfPeriod
        -- Simple harmonic: w = 2*pi/T, stiffness = w^2 in deg/s^2 per degree.
        local omega = (2 * math.pi) / period
        note(string.format("  oscillation  : period ~%.0f s -> stiffness ~%.4f deg/s^2 per deg",
            period, omega * omega))
    end

    note("")
    note("  VERDICT:")

    -- SIGN CHANGES are the primary discriminator, and deliberately so.
    --
    -- The old tree led on peak-vs-free-drift, which silently required a known
    -- standing torque. Zero crossings require no such assumption: damping
    -- bounds the RATE, it does not carry the angle back THROUGH zero. Only a
    -- restoring moment does that, so a crossing is direct evidence and needs
    -- no model of the disturbance.
    if signChanges >= 2 then
        note(string.format("  HELD -- the hull IS being held level. Roll crossed zero %d times,",
            signChanges))
        note("  so a RESTORING MOMENT is acting, not merely damping: damping")
        note("  bounds the rate, it does not bring the angle back through zero.")
        note(string.format("  Bounded within %.2f deg over %.0f s.", peak, span))
        if ratio then
            note(string.format("  (%.0f%% of the %.2f deg a free drift would have given.)",
                ratio * 100, freeDrift))
        end
        if rollOffset then
            note("")
            note(string.format("  Equilibrium offset is %+.3f deg of roll. That -- not the peak --", rollOffset))
            note("  is the residual standing torque. A craft parked off level")
            note("  TRANSLATES: lateral accel = g * tan(offset).")
            local lateral = 11 * math.tan(math.rad(math.abs(rollOffset)))
            note(string.format("  At %.3f deg that is %.4f blocks/s^2 -> %.0f blocks of drift in 60 s.",
                math.abs(rollOffset), lateral, 0.5 * lateral * 3600))
            if math.abs(rollOffset) < 0.5 then
                note("  Below 0.5 deg this is within the noise of this measurement;")
                note("  treat it as level unless a longer run reproduces the sign.")
            end
        end
    elseif peak < 1.0 then
        -- No crossings but the hull never left level. A craft that does not
        -- move is held, whether by a well-damped spring or because nothing
        -- disturbed it; either way it is not diverging. Dropping this branch
        -- made a dead-level run report "re-run longer to be sure".
        note(string.format("  HELD -- roll never left %.2f deg over %.0f s.", peak, span))
        note("  No zero crossings, so this is well damped rather than springy")
        note("  -- or nothing disturbed it. Both are safe; neither proves a")
        note("  restoring moment the way a crossing does.")
        if rollOffset then
            note(string.format("  Equilibrium offset %+.3f deg of roll.", rollOffset))
        end
    elseif ratio and ratio > 0.6 and signChanges == 0 then
        note("  DIVERGING -- nothing is resisting the roll.")
        note(string.format("  Peak %.2f deg against a free-drift prediction of %.2f, and",
            peak, freeDrift))
        note("  the angle never came back through zero.")
        note("  Fine attitude trim is REQUIRED before any longer flight, and ion")
        note("  power cannot supply it -- move fine control to the bearings.")
    elseif signChanges == 0 and peak > 1.0 then
        note(string.format("  DRIFTING ONE WAY -- peak %.2f deg, no zero crossings.", peak))
        note("  Consistent with damping and no restoring moment: the angle keeps")
        note("  growing. Estimate the time to reach an unsafe angle before")
        note("  flying longer. NOTE this is also what a well-damped craft with a")
        note("  standing torque looks like -- check the equilibrium offset above.")
    else
        note(string.format("  Roll stayed within %.2f deg with %d zero crossings, but the",
            peak, signChanges))
        note("  window was short. Re-run longer to be sure.")
    end
end

-- ---------------------------------------------------------------------------

local function listenLoop()
    -- CC delivers an event to a coroutine only when it matches that
    -- coroutine's filter and DROPS it otherwise. Every wait in the main loop
    -- is filtered, so without this the telemetry is silently discarded.
    while true do
        banks.listen(1)
    end
end

local function mainLoop()
    note("=== roll drift test ===")
    note("started " .. tostring(os.epoch("utc")))
    note(string.format("observing %.0f s at +%.0f blocks", OBSERVE_SECONDS, ALTITUDE))
    note("PASSIVE: all four corners commanded identically, nothing asked to rotate.")

    local ok, reason = session:preflight()
    if not ok then
        note("PREFLIGHT FAILED: " .. tostring(reason))
        return
    end
    note(string.format("preflight: 4/4 pods online, ground y = %.4f", session.groundY))

    local set, err = session:setAllProps(64)
    if not set then
        note("FAILED to park props: " .. tostring(err))
        return
    end
    note("props parked at 64 rpm")

    -- Record from the moment the props are turning, not from the top of the
    -- climb. The drift is present the whole time, and an abort on the way up
    -- would otherwise leave nothing to analyse.
    local startAt = os.epoch("utc")
    local function record(state, now)
        local rates = session:rates(state)
        if rates and state.roll and state.pitch then
            samples[#samples + 1] = {
                t = (now - startAt) / 1000,
                roll = state.roll,
                pitch = state.pitch,
                rollRate = rates.roll,
                pitchRate = rates.pitch,
                phase = session.phase or "climb",
            }
        end
    end

    session.phase = "climb"
    local climbed, why = session:climb(ALTITUDE, 90, record)
    if not climbed then
        note("climb did not complete: " .. tostring(why))
        note("Samples from the climb are still analysed below -- an abort on")
        note("the way up is itself evidence about what holds the craft level.")
        session:descend()
        return
    end
    note(string.format("holding at +%.1f, collective %.3f (ion level %d)",
        (session:craftY(session:read()) or session.groundY) - session.groundY,
        session.commanded.collective, flight.levelFor(session.commanded.collective)))

    note("")
    note("== OBSERVING ==")
    session.phase = "observe"
    session:hold(OBSERVE_SECONDS, function(state, now)
        -- Altitude only. Attitude is deliberately left alone -- that is the
        -- measurement.
        session:trim(ALTITUDE, flight.MAX_CLIMB_RATE, 0)
        record(state, now)
        return nil
    end)

    if session.aborted then
        note("ABORTED: " .. tostring(session.aborted))
        note("An abort here is itself a result: the craft reached the limit")
        note("on its own, which means nothing is holding it level.")
    end

    note("")
    note("== DESCENDING ==")
    local landed = session:descend()
    note(landed and "  grounded" or "  did not confirm grounding -- CHECK THE CRAFT")
end

parallel.waitForAny(mainLoop, listenLoop)

session:finish()
analyse()
writeReport()

print("")
print("Report written to /fcs/rolldrift_result.txt")
