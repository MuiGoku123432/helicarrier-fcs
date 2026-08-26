-- Axis response: calibrate the mixer's Aroll / Apitch, and resolve
-- force-per-power along the way.
--
--     /fcs/axisresponse.lua [--ground-only]
--
-- WILL FLY THE CRAFT. Phases B onward take the carrier to +30 blocks and
-- deliberately rotate it. --ground-only stops after phase A, which never lifts.
--
-- MIGRATED ONTO fcs/flight.lua. The hold loop, altitude trim, descent and
-- abort handling live there and are shared with fcs/rolldrift.lua. This file
-- used to carry its own copies -- which is exactly how one gets fixed and the
-- other does not. The descent in particular was rewritten after it was found
-- to walk power down through the ion levels and arrive at 17.8 blocks/s.
--
-- ---------------------------------------------------------------------------
-- WHAT IT MEASURES AND WHY
--
-- fcs/mixer_profile.lua carries authority.roll and authority.pitch as
-- PLACEHOLDERS (0.25). They absorb the moment arms, which nobody has measured.
-- Until they are calibrated, a roll demand of 1.0 means an unknown number of
-- degrees per second, and no attitude controller can be built on the mixer.
--
-- Phase A resolves force-per-power from SETTLED points. The ionsweep CSVs
-- cannot: thrust and power are not synchronised within a row.
--
-- ---------------------------------------------------------------------------
-- PULSE SIZE IS NOT FREE -- ion power is quantised
--
-- applied = floor(commanded * 15) / 15. A pulse whose per-corner differential
-- is below 1/15 does one of two things depending on where collective sits on
-- the level grid: NOTHING, or a full one-level step (5.57% of craft weight).
-- Neither is a proportional response, and a slope fitted to either is
-- meaningless -- yet it would still return a number nobody had reason to
-- doubt. phaseC refuses in that case.
--
-- With authority 0.25 the demand must exceed (1/15)/0.25 = 0.267, so
-- pulseDemand is 0.30. The original 0.15 would have measured nothing.
--
-- ---------------------------------------------------------------------------
-- THE HULL SELF-LEVELS, which is what makes this run reasonable at all
--
-- Measured by /fcs/rolldrift.lua, re-flown 2026-08-26 AFTER the bearing_5
-- repair, so on the symmetric craft: roll bounded within -2.42..+4.63 deg over
-- 105.3 s, crossing zero 5 times. Equilibrium offset +0.311 deg (was 1.23).
-- Restoring stiffness ~0.0223 deg/s^2 per degree, period ~42 s.
--
-- That is still far SLOWER than a pulse, so each pulse must be actively
-- cancelled -- self-levelling will not null a rate inside 2.5 seconds.
--
-- This is the condition that makes the run safe, and it is NOT the repair:
-- with no restoring moment the harness still ends at roll 115 deg on a
-- perfectly symmetric craft, because nothing cancels the pulse's own rate.
-- ---------------------------------------------------------------------------

package.path = "/?.lua;/?/init.lua;" .. package.path

local config = require("fcs.config")
local banks = require("fcs.banks")
local profile = require("fcs.mixer_profile")
local atmosphere = require("fcs.atmosphere")
local flight = require("fcs.flight")

local plan = {
    groundPowers = { 0.00, 0.03, 0.06, 0.09, 0.12, 0.15 },
    settleSeconds = 12.0,
    powerTolerance = 0.004,
    minSettledSamples = 3,

    propRpm = 64,
    -- 22, not 30. MEASURED: the craft cannot hold +30 with this controller.
    --
    -- Lift is set by the level-2/level-3 DUTY CYCLE, and that duty balances
    -- craft weight at about +23 blocks. Reaching +30 needs level 4 in the mix,
    -- which needs a commanded collective >= 4/15 = 0.2667; the 2026-08-26 run
    -- peaked at 0.2450 and never crossed it. Everything between 0.2000 and
    -- 0.2667 is level 3, so the integrator winds through that whole span and
    -- changes nothing -- it is not saturated at the 0.60 clamp, it is parked.
    --
    -- At +21..25 the craft holds beautifully: 20-s mean vertical rates of
    -- -0.005, -0.008, +0.009, -0.014 blocks/s across many windows. That is the
    -- stable platform phase C needs, and ion pulse response does not depend on
    -- altitude (ions are unaffected by air pressure), so the measurement is
    -- the same. This matches the experiment to the hardware rather than
    -- widening a tolerance until a failure passes.
    climbGain = 22,
    -- 90 s was not enough. The 2026-08-26 run spent ~75 s just reaching
    -- altitude, leaving no room for the 20 s window that now proves a stable
    -- hold. Climb + settle + window needs headroom, not a tight budget.
    climbTimeoutSeconds = 180,
    -- Ceiling on the angle a single pulse may sweep.
    --
    -- BUDGET THE WHOLE MANEUVER, not just the pulse. The cancel undoes the
    -- same rate at the same alpha, so it sweeps roughly AS FAR AGAIN. Total
    -- excursion is about 2x this plus a sample of lag at peak rate:
    --
    --     cap 10 deg -> ~23 deg total   MARGINAL against the 28 deg abort
    --     cap  6 deg -> ~15 deg total   comfortable
    --
    -- 10 was never safe. On 2026-08-26 10:35 the pulse reached 12.9 deg and
    -- even a WORKING cancel would have put the total near 29 -- it would have
    -- aborted on geometry alone, quite apart from the cancel being starved.
    --
    -- 6 deg still yields ~5 samples at the measured 8.3 deg/s^2, comfortably
    -- above the 3 the quadratic fit needs, and a short pulse measures exactly
    -- as well as a long one (verified: 11.92 vs 12.00).
    pulseMaxAngle = 6.0,
    -- Ceiling on the cancel, which now ends when the rate is arrested. Longer
    -- than the pulse because the cancel has to undo whatever the pulse built
    -- up, and a cancel cut short by a timer is how the craft keeps rotating.
    cancelTimeoutSeconds = 6.0,
    -- A pulse must start from a genuinely level, still craft. The hull
    -- self-levels with a ~42 s period, so a residual bank does not merely
    -- offset the measurement -- the restoring moment ACCELERATES the craft
    -- throughout it, and 32% axis coupling puts that on the other channel.
    settleAngle = 2.0,             -- degrees, both axes
    settleRate = 0.5,              -- deg/s, both axes, angle-differenced
    -- 90 s, because settling here is PASSIVE and the hull is underdamped.
    -- The cancel nulls the RATE, which leaves the craft parked at whatever
    -- bank it had reached -- 6.89 deg on the run that exposed this. Only the
    -- self-levelling brings that back, and the measured decay was 6.2 -> 1.5
    -- deg over 47 s with a ~42 s period. Worse, being underdamped, the angle
    -- and the rate peak in antiphase: at the zero crossing the rate is
    -- MAXIMUM, so "level and still" needs more than one period to coincide.
    --
    -- 30 s was never enough and would have flagged every run suspect.
    -- The real fix is ACTIVE damping -- a rate term using the authority this
    -- tool measures -- which is the next piece of work and the thing this
    -- whole calibration exists to enable.
    settleTimeoutSeconds = 90.0,
    holdSeconds = 6,

    pulseDemand = 0.30,
    pulseSeconds = 2.0,
    recoverSeconds = 8,
}

local args = { ... }
local groundOnly = false
for _, argument in ipairs(args) do
    if argument == "--ground-only" then groundOnly = true end
end

local report = {}
local function note(text)
    report[#report + 1] = text
    print(text)
end

local function writeReport()
    local file = fs.open("/fcs/axisresponse_result.txt", "w")
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
    maxTiltDegrees = 28,
    maxAltitudeGain = 60,
    minAltitudeGain = -5,
})

local phaseA = {}
local results = {}

-- Inertia tensor samples, taken at DIFFERENT ATTITUDES, to settle whether
-- getInertiaTensor is body-frame or world-frame.
--
-- This lives here rather than relying on main.lua's flight log because
-- main.lua is not reliably running -- launching a flight tool in the same
-- shell tab replaces it, and two runs in a row produced no CSV at all. This
-- tool is also the RIGHT place for it: the pulses deliberately tilt the craft,
-- which is precisely the attitude spread the comparison needs. Two extra Sable
-- calls per axis is nothing next to a flight.
local tensorSamples = {}

-- Axes whose measurement began from an unsettled craft. Their numbers are
-- reported but flagged, rather than quietly mixed in with good ones.
local unsettled = {}

-- Hold until the craft is genuinely settled: BOTH axes, angle AND rate.
--
-- Returns settled(boolean), state. Rate is differenced from the angle rather
-- than read from Session:rates, whose Sable channel reports exactly 0.0000 in
-- roughly a third of samples at this loop period -- it will happily certify a
-- moving craft as still.
local function waitUntilSettled(axis)
    local previous, settled = nil, false

    session.cheapRead = true
    session:hold(plan.settleTimeoutSeconds, function(state, now)
        session:trim(plan.climbGain, flight.MAX_CLIMB_RATE, 0, state)
        if not state or not state.roll or not state.pitch then return nil end

        local current = { t = now / 1000, roll = state.roll, pitch = state.pitch }
        if previous then
            local dt = current.t - previous.t
            if dt > 0.05 then
                local rollRate = (current.roll - previous.roll) / dt
                local pitchRate = (current.pitch - previous.pitch) / dt
                if math.abs(current.roll) <= plan.settleAngle
                    and math.abs(current.pitch) <= plan.settleAngle
                    and math.abs(rollRate) <= plan.settleRate
                    and math.abs(pitchRate) <= plan.settleRate then
                    settled = true
                    return "settled"
                end
                previous = current
            end
        else
            previous = current
        end
        return nil
    end)
    session.cheapRead = false

    return settled, session:read()
end

local function sampleTensor(label)
    if not sublevel or type(sublevel.getInertiaTensor) ~= "function" then return end
    local ok, tensor = pcall(sublevel.getInertiaTensor)
    if not ok or type(tensor) ~= "table" or type(tensor[1]) ~= "table" then return end
    -- CHEAP read: this runs between the pulse and its cancel, so a full
    -- ~1.6 s sample here leaves the craft rotating uncancelled. That is
    -- exactly what took the 2026-08-26 10:23 run to 44 deg of roll.
    local state = session:readCheap()
    tensorSamples[#tensorSamples + 1] = {
        label = label,
        roll = state and state.roll or 0,
        pitch = state and state.pitch or 0,
        -- rows/columns are dimension counts, not containers: index t[i][j].
        xx = tensor[1][1], yy = tensor[2] and tensor[2][2],
        zz = tensor[3] and tensor[3][3],
        xy = tensor[1][2], xz = tensor[1][3],
        yz = tensor[2] and tensor[2][3],
    }
end

-- ---------------------------------------------------------------------------
-- Phase A: settled ion force against power, on the ground
-- ---------------------------------------------------------------------------

local function runGroundStaircase()
    note("")
    note("== PHASE A: ion force vs power (ground, props stopped) ==")
    note("  props at 0 so the ion force is unconfounded; every power is capped")
    note("  below the 0.195 hover, so this cannot lift.")
    note("")

    for _, corner in ipairs(flight.CORNERS) do
        local ok, err = session:setProps(corner, 0)
        if not ok then note("  WARNING: could not stop " .. corner .. " props: " .. tostring(err)) end
    end

    if not session:arm(12) then
        note("  FAILED: banks would not arm")
        return false
    end

    note(string.format("  %8s %10s %6s %14s %10s", "cmd", "applied", "level", "thrust_kN", "samples"))

    for _, power in ipairs(plan.groundPowers) do
        session.commanded.collective = power
        session.commanded.roll, session.commanded.pitch = 0, 0

        local commandAt = os.epoch("utc")
        local samples = {}
        local rejected = { stale = 0, notReached = 0, moving = 0 }
        local previousThrust = nil

        session:hold(plan.settleSeconds, function(state, now)
            -- THREE conditions, not one. The first ground-only run used only
            -- the first and produced residuals from -100% to +32%:
            --
            --   1. telemetry newer than the command (it is not about a past
            --      power),
            --   2. the pod has actually REACHED the commanded power -- it
            --      walks there at maximumChangePerCommand = 0.05, so "newer
            --      than the command" can still be mid-ramp. The very first
            --      step read applied = 0.1575 while commanded 0.000, because
            --      the banks were holding commsLossPower and ramping down,
            --   3. the thrust reading has stopped changing. It is quantised at
            --      25,804.8 kN across 128 thrusters and updates on the mod's
            --      own tick, so it lags the power that produced it.
            local total, commanded, seen = 0, 0, 0
            for _, corner in ipairs(flight.CORNERS) do
                local pod = banks.getState()[corner]
                if pod and pod.receivedAt and pod.receivedAt > commandAt
                    and pod.totalThrustKN then
                    total = total + pod.totalThrustKN
                    commanded = commanded + (pod.currentPower or 0)
                    seen = seen + 1
                end
            end
            if seen < #flight.CORNERS then
                rejected.stale = rejected.stale + 1
                return nil
            end

            commanded = commanded / #flight.CORNERS
            if math.abs(commanded - power) > plan.powerTolerance then
                rejected.notReached = rejected.notReached + 1
                previousThrust = nil
                return nil
            end

            if previousThrust == nil or math.abs(total - previousThrust) > 1.0 then
                rejected.moving = rejected.moving + 1
                previousThrust = total
                return nil
            end

            -- QUANTISE. pod.currentPower is the COMMANDED hold value; the
            -- thrusters apply floor(commanded * 15) / 15. Fitting force
            -- against commanded power is precisely the mistake that produced
            -- HANDOFF.md's ~2.4x, and it recurred here as 2.30x with
            -- residuals of -100%..+29% -- on data that is in fact exact.
            samples[#samples + 1] = {
                thrust = total,
                applied = flight.appliedPower(commanded),
                commanded = commanded,
            }
            return nil
        end)

        if session.aborted then return false end

        -- Take the MODE, not the mean. Thrust here is quantised -- every
        -- settled sample must read one of a handful of exact values -- so the
        -- mean of a contaminated row is a number the hardware cannot produce.
        --
        -- The 2026-08-26 10:03 run averaged a row to 248,619.3 kN, which is
        -- 3.854 pods' worth of a level. No such reading exists; it came from
        -- averaging across samples where one pod was still a level behind. It
        -- dragged the fit from 3.34x to 3.32x with a 3.1% residual on data
        -- whose good samples were exact.
        local tally, best, bestCount = {}, nil, 0
        local appliedSum = 0
        for _, sample in ipairs(samples) do
            local key = string.format("%.3f", sample.thrust)
            tally[key] = (tally[key] or 0) + 1
            if tally[key] > bestCount then
                bestCount, best = tally[key], sample.thrust
            end
            appliedSum = appliedSum + sample.applied
        end
        local count = #samples
        local distinctThrusts = 0
        for _ in pairs(tally) do distinctThrusts = distinctThrusts + 1 end

        local row = {
            power = power,
            thrust = best,
            applied = count > 0 and appliedSum / count or nil,
            samples = count,
            agreed = bestCount,
            distinct = distinctThrusts,
        }
        phaseA[#phaseA + 1] = row

        -- Commanded, applied and LEVEL side by side. Two different commands
        -- landing on the SAME level is the most important thing in this table
        -- and printing a single power column hid it completely.
        note(string.format("  %8.3f %10s %6s %14s %10d   (rejected: %d stale, %d not-reached, %d moving)",
            power,
            row.applied and string.format("%.4f", row.applied) or "-",
            row.applied and tostring(flight.levelFor(row.power)) or "-",
            row.thrust and string.format("%.1f", row.thrust) or "no data",
            count, rejected.stale, rejected.notReached, rejected.moving))
        if count < plan.minSettledSamples then
            note("           ^ FEWER THAN " .. plan.minSettledSamples
                .. " SETTLED SAMPLES -- treat this row as unreliable")
        end
        if row.distinct and row.distinct > 1 then
            note(string.format(
                "           ^ %d DISTINCT thrust values across %d samples (%d agreed)",
                row.distinct, count, row.agreed))
            note("             Quantised thrust should be identical when settled;")
            note("             a spread means a pod was still a level behind.")
            note("             Using the mode -- the mean would be unphysical.")
        end
    end

    -- Least squares through the settled points, forced through the origin:
    -- zero power must mean zero thrust, and letting the intercept float would
    -- absorb exactly the systematic error this phase exists to remove.
    -- Fit ONLY rows that produced enough settled samples, and report how well
    -- the line actually fits. A slope quoted without its residuals is how the
    -- first run produced a confident 2.24x from data containing a -100%
    -- outlier.
    -- Two DIFFERENT exclusions, counted separately. Reporting them as one
    -- number said "3 of 6 rows had >= 3 settled samples" about rows that each
    -- had 46 -- the other three were dropped for applying zero power, which is
    -- not a data-quality problem at all.
    local used, sxy, sxx = {}, 0, 0
    local zeroLevel, tooFew = 0, 0
    local levels = {}
    for _, row in ipairs(phaseA) do
        if not row.thrust or not row.applied then
            tooFew = tooFew + 1
        elseif row.applied <= 0 then
            zeroLevel = zeroLevel + 1
        elseif row.samples < plan.minSettledSamples then
            tooFew = tooFew + 1
        else
            used[#used + 1] = row
            levels[flight.levelFor(row.power)] = true
            sxy = sxy + row.applied * row.thrust
            sxx = sxx + row.applied * row.applied
        end
    end

    local distinct = 0
    for _ in pairs(levels) do distinct = distinct + 1 end

    note("")
    note(string.format("  %d of %d rows usable for the fit", #used, #phaseA))
    if zeroLevel > 0 then
        note(string.format("    %d dropped: applied power is exactly 0 (below one level)", zeroLevel))
        note("      -- commanded below 1/15 applies NOTHING. Not a bad reading.")
    end
    if tooFew > 0 then
        note(string.format("    %d dropped: fewer than %d settled samples",
            tooFew, plan.minSettledSamples))
    end
    note(string.format("    %d DISTINCT ion levels among the usable rows", distinct))
    if distinct < 3 then
        note("      Ground powers are capped below the 0.195 hover, so only")
        note("      levels 0-2 are reachable and the fit rests on few points.")
        note("      Treat the slope as a CHECK on the quantisation-derived")
        note("      3.342x, not as an independent measurement of it.")
    end

    if #used < 3 or sxx <= 0 then
        note("  NOT ENOUGH SETTLED DATA TO FIT. Do not quote a coefficient from")
        note("  this run -- lengthen settleSeconds and repeat.")
        return true
    end

    local perPower = sxy / sxx
    local weight = 1158293.4
    local worst = 0
    note("")
    note(string.format("  %10s %14s %14s %10s", "applied", "measured", "predicted", "residual"))
    for _, row in ipairs(used) do
        local predicted = perPower * row.applied
        local residual = predicted ~= 0 and (row.thrust - predicted) / predicted or 0
        if math.abs(residual) > worst then worst = math.abs(residual) end
        note(string.format("  %10.4f %14.1f %14.1f %9.1f%%",
            row.applied, row.thrust, predicted, residual * 100))
    end

    note("")
    note(string.format("  ion force at full power = %.1f kN  (%.2fx craft weight)",
        perPower, perPower / weight))
    note(string.format("  worst residual = %.1f%%", worst * 100))
    if worst > 0.10 then
        note("  RESIDUALS TOO LARGE -- this is not a usable coefficient.")
        note("  If the residuals look like -100% on the low rows, suspect the")
        note("  QUANTISATION, not the data: rows below one level apply exactly")
        note("  zero power and cannot sit on a line through the origin.")
        note("  The quantisation-derived value is 3.342x (thrustprobe_FL.txt).")
    else
        note("  Fitted against APPLIED power. Dividing by COMMANDED power is how")
        note("  this came out ~2.4x once and 2.30x again; the true value is")
        note("  3.342x and agrees with thrustprobe_FL.txt.")
        phaseA.forcePerPower = perPower
    end

    return true
end

-- ---------------------------------------------------------------------------
-- Phase C: the pulses
-- ---------------------------------------------------------------------------

local function pulseAxis(axis)
    note("")
    note("== PHASE C: " .. axis .. " pulse, demand " .. plan.pulseDemand
        .. " for " .. plan.pulseSeconds .. "s ==")

    local differential = plan.pulseDemand * profile.authority[axis]
    local quantum = 1 / flight.ION_LEVELS
    if differential < quantum then
        note(string.format("  REFUSING: demand %.3f x authority %.3f = %.4f power,",
            plan.pulseDemand, profile.authority[axis], differential))
        note(string.format("  which is below the ion quantum %.4f (1/%d).",
            quantum, flight.ION_LEVELS))
        note("  The pulse would produce either no torque at all or a full")
        note("  one-level step. Neither measures a response. Raise pulseDemand")
        note("  above " .. string.format("%.3f", quantum / profile.authority[axis]) .. ".")
        results[axis] = { refused = true }
        return
    end

    -- Measure the ANGLE, not the rate.
    --
    -- Two facts force this. Quantisation puts a FLOOR on pulse size: the
    -- smallest meaningful differential is one ion level, worth ~3.4 deg/s^2,
    -- so a pulse cannot be made gentle. And the loop runs ~950 ms, so a pulse
    -- short enough to keep the excursion small yields only 2-3 samples --
    -- while the rate channel reads exactly 0.0000 in roughly a third of
    -- samples at this period (seen in the roll-drift run).
    --
    -- Angle is measured directly and reliably. Under constant torque from
    -- rest, theta = theta0 + omega0*t + 0.5*alpha*t^2, so two good angle
    -- samples and a near-zero starting rate are enough -- and any extra
    -- samples improve it via a quadratic fit.
    -- WAIT FOR A GENUINELY SETTLED CRAFT, on BOTH axes, in angle AND rate.
    --
    -- The old gate checked only the commanded axis, only its RATE, took that
    -- rate from Session:rates -- the Sable channel that reads exactly 0.0000
    -- in about a third of samples -- and then waited a fixed 8 s once and
    -- proceeded regardless.
    --
    -- On 2026-08-26 10:52 the pitch pulse therefore began with the craft
    -- BANKED -6.89 deg and still moving. The hull self-levels, so a 6.9 deg
    -- bank means a restoring moment is actively accelerating the craft in roll
    -- throughout the measurement, and with t[2][3] coupling the axes at 32%
    -- that leaks straight into pitch. The result was a roll/pitch ratio of
    -- 11.02 when the inertia tensor caps it at 4.49 -- not merely high, but on
    -- the wrong side of a hard physical bound.
    --
    -- Rate here is differenced from the ANGLE, for the same reason the cancel
    -- is: a channel that reports "stopped" when it is not must not be allowed
    -- to gate a measurement.
    local settled, settleState = waitUntilSettled(axis)
    local startRate = session:rates(settleState)
    local startAngle = settleState and settleState[axis]
    if not startAngle then
        note("  no attitude available; skipping")
        return
    end
    if not settled then
        note(string.format("  NOT SETTLED after %.0f s -- measurement is SUSPECT.",
            plan.settleTimeoutSeconds))
        unsettled[axis] = true
    end

    -- Record BOTH axes, not just the commanded one.
    --
    -- The 2026-08-26 run measured only the commanded axis and reported roll
    -- response 0.4993 deg/s^2 -- from a roll angle that moved 0.05 deg while
    -- PITCH moved 3.76 deg under the same pulse. Measuring one channel cannot
    -- tell "the craft barely responded" from "the craft responded on the OTHER
    -- axis", and those demand opposite conclusions.
    local OTHER = { roll = "pitch", pitch = "roll" }
    local other = OTHER[axis]
    sampleTensor(axis .. "-before")

    local samples = {}
    local startAt = os.epoch("utc")
    local startOther = settleState and settleState[other]

    -- CHEAP READS FOR THE PULSE. This is the measurement window and it was
    -- collecting two samples in 3.3 s; attitude is all that is needed here.
    -- Restored immediately after, because the hold and descent phases DO want
    -- the full telemetry.
    session.cheapRead = true
    session.commanded[axis] = plan.pulseDemand
    session:hold(plan.pulseSeconds, function(state, now)
        session:trim(plan.climbGain, flight.MAX_CLIMB_RATE, 0, state)
        if state and state[axis] then
            samples[#samples + 1] = {
                t = (now - startAt) / 1000,
                angle = state[axis],
                otherAngle = state[other],
            }
            -- STOP ON ANGLE, not just on time.
            --
            -- A fixed duration assumes you already know the authority, which
            -- is the thing being measured. When the real roll authority turned
            -- out to be 8.5 deg/s^2 rather than the 1.2 the starved runs
            -- suggested, the same 2 s pulse swept 33 deg instead of 9 and
            -- tripped the 28 deg abort.
            --
            -- Ending on angle is self-limiting at any authority, and it costs
            -- nothing: alpha comes from the angle swept and the time taken, so
            -- a short pulse measures exactly as well as a long one. It needs
            -- enough samples to fit, so it will not stop before three.
            -- Stop on the PROJECTED angle, not the current one. The check
            -- can only run when a sample arrives, and the craft keeps
            -- rotating in between -- at peak rate that is several degrees per
            -- sample, which is why run 10 overshot a 10 deg cap to 12.9.
            -- Projecting one sample ahead removes most of that lag.
            local swept = math.abs(state[axis] - startAngle)
            local projected = swept
            local previousSample = samples[#samples - 1]
            if previousSample then
                local dt = samples[#samples].t - previousSample.t
                if dt > 0.01 then
                    local rate = (state[axis] - previousSample.angle) / dt
                    projected = swept + math.abs(rate) * dt
                end
            end
            if projected >= plan.pulseMaxAngle and #samples >= 3 then
                return "pulse angle reached"
            end
        end
        return nil
    end)
    session.commanded[axis] = 0

    -- MEASURE FIRST, then everything else. `elapsed` and `endAngle` must be
    -- taken the instant the pulse ends: they used to be read after a tensor
    -- sample and a full telemetry read, roughly 3 s during which the craft
    -- kept rotating with nothing cancelling it. That inflated `elapsed`,
    -- contaminated alpha, and drove a 17 deg pulse to a 44 deg abort.
    local endState = session:readCheap()
    local endAngle = endState and endState[axis]
    local elapsed = (os.epoch("utc") - startAt) / 1000

    -- Peak tilt, for the tensor frame comparison. Cheap, and now off the
    -- critical path between pulse and cancel.
    sampleTensor(axis .. "-peak")
    -- cheapRead deliberately STAYS ON through the cancel below. See there.

    if session.aborted then
        note("  ABORTED during pulse: " .. tostring(session.aborted))
        -- Even an aborted pulse carries a measurement: the excursion and the
        -- time it took are exactly what alpha is computed from.
        if endAngle and elapsed > 0.5 then
            local swept = endAngle - startAngle
            local alpha = 2 * swept / (elapsed * elapsed)
            note(string.format("  partial: swept %.2f deg in %.2f s -> alpha ~ %.4f deg/s^2",
                swept, elapsed, alpha))
            note(string.format("  per unit demand ~ %.4f deg/s^2", alpha / plan.pulseDemand))
            results[axis] = { alpha = alpha, perDemand = alpha / plan.pulseDemand,
                              samples = #samples, partial = true }
        end
        return
    end

    local alpha
    local omega0 = (startRate and startRate[axis]) or 0

    if #samples >= 3 then
        -- Quadratic least squares on (t, angle - theta0 - omega0*t): the
        -- residual should be 0.5*alpha*t^2, so fit a single coefficient.
        local num, den = 0, 0
        for _, sample in ipairs(samples) do
            local basis = 0.5 * sample.t * sample.t
            local target = sample.angle - startAngle - omega0 * sample.t
            num = num + basis * target
            den = den + basis * basis
        end
        if den > 0 then alpha = num / den end
    end

    if not alpha and endAngle and elapsed > 0.5 then
        local swept = endAngle - startAngle - omega0 * elapsed
        alpha = 2 * swept / (elapsed * elapsed)
    end

    -- Same fit on the OTHER axis, so cross-coupling is measured not guessed.
    local alphaOther
    local omegaOther = (startRate and startRate[other]) or 0
    local endOther = endState and endState[other]
    if #samples >= 3 then
        local num, den = 0, 0
        for _, sample in ipairs(samples) do
            if sample.otherAngle and startOther then
                local basis = 0.5 * sample.t * sample.t
                local target = sample.otherAngle - startOther - omegaOther * sample.t
                num = num + basis * target
                den = den + basis * basis
            end
        end
        if den > 0 then alphaOther = num / den end
    end
    if not alphaOther and endOther and startOther and elapsed > 0.5 then
        alphaOther = 2 * (endOther - startOther - omegaOther * elapsed) / (elapsed * elapsed)
    end

    if alpha then
        note(string.format("  angle %.2f -> %.2f deg over %.2f s (%d samples, start rate %.3f deg/s)",
            startAngle, endAngle or startAngle, elapsed, #samples, omega0))
        note(string.format("  %-5s (commanded) acceleration = %.4f deg/s^2", axis, alpha))
        if alphaOther then
            note(string.format("  %-5s (cross)     acceleration = %.4f deg/s^2", other, alphaOther))
            local ratio = math.abs(alpha) > 1e-9 and math.abs(alphaOther / alpha) or nil
            if ratio and ratio > 2.0 then
                note("")
                note(string.format("  *** THE %s CHANNEL MOVED %.0fx MORE THAN THE COMMANDED %s ***",
                    string.upper(other), ratio, string.upper(axis)))
                note("  A demand on one axis is rotating the craft about the OTHER.")
                note("  Either the corner labels are rotated relative to the hull,")
                note("  or attitude.lua's roll/pitch are swapped. Cross-check the")
                note("  response ratio against the inertia tensor before changing")
                note("  any sign: the cheap axis (index 3) must respond MORE.")
            end
        end
        note(string.format("  per unit demand      = %.4f deg/s^2", alpha / plan.pulseDemand))
        results[axis] = { alpha = alpha, perDemand = alpha / plan.pulseDemand,
                          samples = #samples, alphaOther = alphaOther, other = other }
    else
        note(string.format("  could not measure: %d samples, elapsed %.2f s", #samples, elapsed))
        results[axis] = { samples = #samples }
    end

    -- Cancel the rate. The hull self-levels, but at ~0.0091 deg/s^2 per degree
    -- with a ~66 s period -- far slower than a 2.5 s pulse, so the rate has to
    -- be actively nulled rather than left to settle.
    -- THE CANCEL IS THE SAFETY ACTION AND IT WAS THE STARVED ONE.
    --
    -- cheapRead was being switched off just above, so this loop ran on ~1.6 s
    -- telemetry reads -- longer than the pods' 750 ms COMMAND_TIMEOUT. The
    -- watchdog therefore forced every bank to a UNIFORM commsLossPower, which
    -- applies no differential at all, so the reversed pulse was substantially
    -- never applied. On 2026-08-26 10:35 that left 5.75 deg/s of roll rate
    -- still running after the "cancel" and the craft rolled on to a 40 deg
    -- abort. The pulse had worked; the thing meant to undo it had not.
    --
    -- Stop on RATE, not on a fixed duration. Equal-and-opposite for the same
    -- time only nulls the rate if the torque actually applied for that time,
    -- which is precisely the assumption that just failed. Rate comes from
    -- differencing the angle rather than from Session:rates -- the Sable
    -- angular channel reads exactly 0.0000 in about a third of samples at this
    -- loop period, and a cancel must not be steered by a channel that reports
    -- "stopped" when it is not.
    note("  cancelling with a reversed pulse")
    local direction = plan.pulseDemand >= 0 and 1 or -1
    local previous = nil
    local arrested = false

    session.commanded[axis] = -plan.pulseDemand
    session:hold(plan.cancelTimeoutSeconds, function(state, now)
        session:trim(plan.climbGain, flight.MAX_CLIMB_RATE, 0, state)
        if not state or not state[axis] then return nil end

        local current = { t = now / 1000, angle = state[axis] }
        if previous then
            local dt = current.t - previous.t
            if dt > 0.05 then
                local rate = (current.angle - previous.angle) / dt
                -- Arrested when the rate has come back through zero.
                if rate * direction <= 0 then
                    arrested = true
                    return "rate arrested"
                end
                previous = current
            end
        else
            previous = current
        end
        return nil
    end)
    session.commanded[axis] = 0

    if not arrested then
        note(string.format("  WARNING: rate not arrested within %.1f s -- the cancel",
            plan.cancelTimeoutSeconds))
        note("  did not take. Expect the recovery descent to catch it.")
    end

    session:hold(plan.recoverSeconds, function(state)
        session:trim(plan.climbGain, flight.MAX_CLIMB_RATE, 0, state)
        return nil
    end)
    session.cheapRead = false

    local after = session:rates(session:read())
    if after then
        note(string.format("  residual %s rate after cancel: %.4f deg/s", axis, after[axis]))
    end
end

-- ---------------------------------------------------------------------------

local function listenLoop()
    while true do
        banks.listen(1)
    end
end

local function mainLoop()
    note("=== axis response run ===")
    note("started " .. tostring(os.epoch("utc")))
    note(groundOnly and "MODE: --ground-only (phase A only, will not fly)"
        or "MODE: full run -- WILL FLY THE CRAFT")

    local ok, reason = session:preflight()
    if not ok then
        note("PREFLIGHT FAILED: " .. tostring(reason))
        return
    end
    note(string.format("preflight: 4/4 pods online, ground y = %.4f", session.groundY))
    if atmosphereModel then
        note(string.format("atmosphere: %d points, pressure here %.6f, at +%d %.6f",
            #atmosphereModel.points, atmosphereModel.pressureAt(session.groundY),
            plan.climbGain, atmosphereModel.pressureAt(session.groundY + plan.climbGain)))
    end

    if not runGroundStaircase() then
        note("phase A did not complete")
    end

    if groundOnly then
        note("")
        note("--ground-only: stopping before flight")
        session.commanded.collective = 0
        session:send()
        return
    end

    note("")
    note("== PHASE B: climb to +" .. plan.climbGain .. " and hold ==")
    local set, err = session:setAllProps(plan.propRpm)
    if not set then
        note("  FAILED to park props: " .. tostring(err))
        session:descend()
        return
    end
    note("  props parked at " .. plan.propRpm .. " rpm")

    local climbed, why = session:climb(plan.climbGain, plan.climbTimeoutSeconds)
    if not climbed then
        note("  climb did not complete: " .. tostring(why))
        session:descend()
        return
    end
    note(string.format("  holding at +%.1f, collective %.3f (ion level %d)",
        (session:craftY(session:read()) or session.groundY) - session.groundY,
        session.commanded.collective, flight.levelFor(session.commanded.collective)))

    session:hold(plan.holdSeconds, function()
        session:trim(plan.climbGain, flight.MAX_CLIMB_RATE, 0)
        return nil
    end)

    pulseAxis("roll")
    if not session.aborted then pulseAxis("pitch") end

    note("")
    note("== PHASE D: descend and land ==")
    if session.aborted then
        note("  RECOVERY descent after abort: " .. tostring(session.aborted))
    end
    local landed = session:descend()
    note(landed and "  grounded" or "  did not confirm grounding -- CHECK THE CRAFT")
end

parallel.waitForAny(mainLoop, listenLoop)

session:finish()

note("")
note("=== SUMMARY ===")
if phaseA.forcePerPower then
    note(string.format("force at full power : %.1f kN  (%.2fx weight)",
        phaseA.forcePerPower, phaseA.forcePerPower / 1158293.4))
end
for _, axis in ipairs({ "roll", "pitch" }) do
    local result = results[axis]
    if result and result.perDemand then
        note(string.format("%-6s response      : %.4f deg/s^2 per unit demand (%d samples)",
            axis, result.perDemand, result.samples))
    elseif result and result.refused then
        note(string.format("%-6s response      : REFUSED (pulse below the ion quantum)", axis))
    end
end
if results.roll and results.pitch and results.roll.perDemand and results.pitch.perDemand
    and results.pitch.perDemand ~= 0 then
    -- The full 2x2 response matrix. A single roll/pitch ratio of the
    -- commanded channels is meaningless when the response lands on the other
    -- axis -- the 2026-08-26 run printed "roll/pitch ratio: -1.51" from two
    -- numbers that were both cross-talk.
    if unsettled.roll or unsettled.pitch then
        note("")
        local which = {}
        for _, axis in ipairs({ "roll", "pitch" }) do
            if unsettled[axis] then which[#which + 1] = axis end
        end
        note("*** SUSPECT: " .. table.concat(which, " and ")
            .. " pulsed from an UNSETTLED craft. ***")
        note("    A residual bank means the self-levelling restoring moment is")
        note("    accelerating the craft throughout the measurement, and axis")
        note("    coupling puts part of that on the other channel. Re-run.")
    end

    note("")
    note("RESPONSE MATRIX (deg/s^2 per unit demand):")
    note(string.format("  %-14s %14s %14s", "demand", "roll resp", "pitch resp"))
    for _, axis in ipairs({ "roll", "pitch" }) do
        local r = results[axis]
        if r and r.alpha then
            local own = r.alpha / plan.pulseDemand
            local cross = r.alphaOther and (r.alphaOther / plan.pulseDemand) or nil
            local rollResp = axis == "roll" and own or cross
            local pitchResp = axis == "roll" and cross or own
            note(string.format("  %-14s %14s %14s", axis,
                rollResp and string.format("%.4f", rollResp) or "-",
                pitchResp and string.format("%.4f", pitchResp) or "-"))
        end
    end

    -- Diagonal-dominant means the axes are mapped correctly.
    local rr = results.roll and results.roll.alpha
    local rc = results.roll and results.roll.alphaOther
    local pp = results.pitch and results.pitch.alpha
    local pc = results.pitch and results.pitch.alphaOther
    if rr and rc and pp and pc then
        local diagonal = math.abs(rr) + math.abs(pp)
        local offDiagonal = math.abs(rc) + math.abs(pc)
        note("")
        if offDiagonal > diagonal then
            note("*** THE AXES ARE TRANSPOSED. Off-diagonal response exceeds the")
            note("    diagonal: a roll demand pitches the craft and vice versa.")
            note("    Do NOT quote these as authority.roll / authority.pitch.")
            note("")
            note("    Cross-check before changing any sign -- the CHEAP inertia")
            note("    axis (index 3, 4.49x cheaper than index 1) must be the one")
            note("    that responds more:")
            local ratio = math.abs(pc) > 1e-9 and math.abs(rc / pc) or nil
            if ratio then
                note(string.format("      measured off-diagonal ratio = %.2f", ratio))
                note("      inertia t[1][1]/t[3][3]     = 4.49")
                if math.abs(ratio - 4.49) < 1.0 then
                    note("      AGREES -- attitude.lua is right and the CORNER LABELS")
                    note("      are rotated relative to the hull. Fix the mixer's")
                    note("      corner map, not the attitude code.")
                end
            end
        else
            local ratio = results.roll.perDemand / results.pitch.perDemand
            note(string.format("roll/pitch ratio     : %.2f", ratio))

            -- HARD BOUND. alpha = torque/I and torque = arm x the same
            -- one-level force, so ratio = arm_ratio x t[1][1]/t[3][3].
            -- t[3][3] (the bow axis) is the SMALLEST of the three, so the
            -- craft is long and narrow, the lateral arm is the shorter one,
            -- and arm_ratio < 1. The ratio therefore cannot exceed 4.49.
            --
            -- The 2026-08-26 10:52 run reported 11.02 and nothing objected.
            -- A number on the wrong side of a physical bound is not a
            -- calibration, and it must not be quoted as one.
            local BOUND = 389348390.47 / 86744908.79
            if math.abs(ratio) > BOUND then
                note("")
                note(string.format("*** RATIO %.2f EXCEEDS THE PHYSICAL BOUND %.2f ***",
                    math.abs(ratio), BOUND))
                note("    alpha = torque/I with a common force, so the ratio is")
                note("    arm_ratio x t[1][1]/t[3][3]. The bow axis has the")
                note("    SMALLEST inertia, so the craft is long and narrow and")
                note("    arm_ratio < 1 -- the ratio cannot exceed the tensor's.")
                note("    One of these two numbers is wrong. The usual cause is a")
                note("    pulse that began before the craft settled.")
            end
            -- Under the CORRECTED convention (bow = +Z) the cheap tensor axis
            -- index 3 IS the bow axis, and roll is rotation about the bow --
            -- so ROLL is the cheap one. This line said PITCH while the code
            -- still believed the bow was +X.
            note("getInertiaTensor's cheap axis is index 3 = +Z = the BOW axis.")
            note("Roll is rotation about the bow, so expect ROLL to respond")
            note(string.format("more, by about t[1][1]/t[3][3] = %.2f.", 389348390.47 / 86744908.79))
        end
    end
end
-- ---------------------------------------------------------------------------
-- Is getInertiaTensor body-frame or world-frame?
--
-- A BODY-frame tensor is constant however the craft is tilted. A WORLD-frame
-- one rotates with it. The craft tilts several degrees during the pulses,
-- which mixes t[1][1] and t[2][2] -- they differ by 46 million -- by roughly
-- sin^2(tilt). At 5 degrees that is 0.8%, about 350,000 units, while two reads
-- at the SAME attitude have agreed to 0.00015%. The signal sits far above the
-- noise floor, so this is decidable from a handful of samples.
--
-- It matters because "index 3 is the cheap axis" and "the axes are coupled at
-- 32%" are both BODY-frame statements, and a controller needs to know which.
if #tensorSamples >= 2 then
    note("")
    note("=== INERTIA TENSOR FRAME ===")
    note(string.format("  %-14s %7s %7s %16s %16s %16s",
        "sample", "roll", "pitch", "t[1][1]", "t[2][2]", "t[3][3]"))
    for _, sample in ipairs(tensorSamples) do
        note(string.format("  %-14s %7.2f %7.2f %16.2f %16.2f %16.2f",
            sample.label, sample.roll, sample.pitch,
            sample.xx or 0, sample.yy or 0, sample.zz or 0))
    end

    local minTilt, maxTilt
    local worstSpread, worstName = 0, nil
    for _, key in ipairs({ "xx", "yy", "zz", "xy", "xz", "yz" }) do
        local low, high
        for _, sample in ipairs(tensorSamples) do
            local value = sample[key]
            if value then
                if not low or value < low then low = value end
                if not high or value > high then high = value end
            end
        end
        if low and high then
            local scale = math.max(math.abs(low), math.abs(high))
            local spread = scale > 0 and (high - low) / scale * 100 or 0
            if spread > worstSpread then worstSpread, worstName = spread, key end
        end
    end
    for _, sample in ipairs(tensorSamples) do
        local tilt = math.sqrt(sample.roll * sample.roll + sample.pitch * sample.pitch)
        if not minTilt or tilt < minTilt then minTilt = tilt end
        if not maxTilt or tilt > maxTilt then maxTilt = tilt end
    end

    note("")
    note(string.format("  attitude spread sampled: tilt %.2f .. %.2f deg", minTilt or 0, maxTilt or 0))
    note(string.format("  largest component spread: %.4f%%%s", worstSpread,
        worstName and (" (t." .. worstName .. ")") or " (all components identical)"))

    if (maxTilt or 0) - (minTilt or 0) < 2.0 then
        note("  INCONCLUSIVE -- too little attitude spread. The pulses must")
        note("  actually tilt the craft for this comparison to mean anything.")
    elseif worstSpread > 0.1 then
        note("  WORLD-FRAME -- the tensor rotates with the craft.")
        note("  t[i][j] then indexes WORLD axes at the instant of the read, so")
        note("  'index 3 is the cheap axis' is only true at that attitude, and")
        note("  the 32% coupling figure must be re-derived in the body frame.")
    else
        note("  BODY-FRAME -- constant across attitude.")
        note("  t[i][j] indexes BODY axes, so 'index 3 (+Z, the bow) is the")
        note("  cheap axis' and the 32% coupling figure both hold as written.")
    end
end

if session.aborted then
    note("")
    note("ABORTED: " .. tostring(session.aborted))
end

writeReport()
print("")
print("Report written to /fcs/axisresponse_result.txt")
