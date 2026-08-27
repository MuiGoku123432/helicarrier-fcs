-- What is a degree of bearing tilt worth AT FLIGHT RPM? Measured on the
-- ground, in about two minutes, without flying.
--
--     /fcs/bearingsweep.lua              sweep 16 -> 64 rpm and report
--     /fcs/bearingsweep.lua --no-tilt    thrust only, bearings never tilted
--     /fcs/bearingsweep.lua --top 48     stop the sweep below 64
--
-- Run it in the FCS-DEV "Flight Tools" tab, not the telemetry tab.
--
-- ---------------------------------------------------------------------------
-- WHAT IS BEING ANSWERED
--
-- The velocity loop -- the whole plan for the drift -- scales with one number:
-- how much lateral force a degree of common-mode bearing tilt makes. Two files
-- carry it as a CONSTANT, 13960.98 per bearing, and that is the reading at
-- 16 RPM taken ON THE GROUND. The craft flies at 64. HANDOFF called this
-- "uncertain by a factor of four" and listed a flight to settle it.
--
-- IT DOES NOT NEED A FLIGHT. The lateral force is built out of getThrust, and
-- getThrust is a live telemetry reading the pods already push every second. So
-- the honest measurement is: step the props through the flight range and READ
-- IT. Four rpms, on the ground, nothing armed.
--
-- WHY THE CRAFT STAYS DOWN. 64 rpm is 52.1% of craft weight and props-only
-- hover is bracketed at 122-124 rpm. The sweep never arms the ions, so there
-- is no path to lift -- and it checks the altitude anyway, because "cannot
-- lift" is exactly the kind of belief this project has been wrong about.
--
-- THE RULE, which four separate "findings" in HANDOFF were wrecked by: an
-- INACTIVE bearing reports a stored target it is ignoring. Every reading here
-- is gated on prop.active first, and an rpm where any corner went inactive is
-- dropped rather than averaged in.
--
-- WHAT IT CANNOT SETTLE. getThrust is reported BEFORE the air-density factor,
-- and whether the lateral component takes that factor is not separately
-- measured. The sweep reports the uncorrected gain and states the corrected
-- one alongside it; a flight cross-check (known tilt, terminal net drift,
-- bearinggain.impliedThrust) is what closes that, and it is now a check of a
-- known number rather than a hunt for an unknown one.

if package then
    package.path = "/?.lua;/?/init.lua;" .. package.path
end

local config = require("fcs.config")
local banks = require("fcs.banks")
local flight = require("fcs.flight")
local profile = require("fcs.mixer_profile")
local atmosphere = require("fcs.atmosphere")
local vectoring = require("fcs.vectoring")
local bearinggain = require("fcs.bearinggain")
local trim = require("fcs.trim")

local plan = {
    -- Four rpms, evenly spaced, spanning ground calibration to flight. THREE
    -- IS THE MINIMUM that can tell a linear law from a square one; four gives
    -- the fit something to disagree with.
    rpms = { 16, 32, 48, 64 },
    -- The bearings need a moment to reach the commanded speed, and a reading
    -- taken during the ramp is a reading of an rpm nobody chose.
    settleSeconds = 6.0,
    samples = 5,
    sampleSeconds = 0.6,

    -- The lateral coherence check, at the TOP rpm only. 8 degrees is what
    -- vectorprobe swept at 16, so the two are directly comparable.
    tiltDegrees = 8.0,
    tiltAzimuth = 0,
    tiltCorner = "FL",
    tiltSettleSeconds = 3.0,

    -- If the hull rises this far the premise is wrong and the sweep stops.
    liftAbort = 0.5,
}

local args = { ... }
local skipTilt = false
for index = 1, #args do
    local argument = args[index]
    if argument == "--no-tilt" then skipTilt = true
    elseif argument == "--top" then
        local top = tonumber(args[index + 1])
        if top then
            local kept = {}
            for _, rpm in ipairs(plan.rpms) do
                if rpm <= top then kept[#kept + 1] = rpm end
            end
            plan.rpms = kept
        end
    end
end

local lines = {}
local function note(text)
    lines[#lines + 1] = text
    print(text)
end

local function save()
    local ok, file = pcall(fs.open, "/fcs/bearingsweep_result.txt", "w")
    if ok and file then
        file.write(table.concat(lines, "\n"))
        file.close()
        print("")
        print("Saved to /fcs/bearingsweep_result.txt")
    end
end

local session = flight.new({
    config = config,
    profile = profile,
    atmosphere = atmosphere,
    note = note,
})

local commandedProps, commandedTilt = false, false
local baseY

-- Waiting is where the craft would get away from you, so the altitude gate
-- lives HERE rather than after the window. The first version checked only once
-- the rpm had been sampled, and a harness craft that lifted at 48 rpm was 84
-- blocks up by the time it said so.
local lifted = false
local function waitSeconds(seconds)
    local deadline = os.epoch("utc") + seconds * 1000
    while os.epoch("utc") < deadline and not lifted do
        session:hold(0.25, function(state)
            local y = state and session:craftY(state)
            if not y then return nil end
            if baseY == nil then baseY = y end
            if (y - baseY) > plan.liftAbort then
                lifted = true
                return "lifted"
            end
        end)
    end
    return lifted
end

-- ---------------------------------------------------------------------------
-- Reading the bearings. Same shape as vectorprobe's readCorner, and gated the
-- same way: an inactive bearing is not a small error, it is a stored number.
-- ---------------------------------------------------------------------------

local function readCorner(corner)
    local pod = banks.getState()[corner]
    local prop = pod and pod.prop
    if not prop then return nil, "no prop telemetry" end
    if not prop.active then return nil, "bearings not active" end
    if prop.bearingsAssembled == false then return nil, "bearings not assembled" end

    local perBearing = prop.perBearing
    if type(perBearing) ~= "table" or #perBearing == 0 then
        return nil, "no per-bearing data"
    end

    local bearings, total = {}, 0
    for index, bearing in ipairs(perBearing) do
        if type(bearing.thrust) == "number" and type(bearing.vy) == "number" then
            bearings[#bearings + 1] = {
                name = bearing.name or ("bearing " .. index),
                thrust = bearing.thrust,
                thrustVector = { bearing.vx or 0, bearing.vy, bearing.vz or 0 },
            }
            -- MAGNITUDES. getThrust is signed by HANDEDNESS, so the raw sum of
            -- a counter-rotating pair is ~0 -- which is what once made three
            -- corners look dead.
            total = total + math.abs(bearing.thrust)
        end
    end
    if #bearings == 0 then return nil, "no bearing reported thrust and a vector" end

    return {
        bearings = bearings,
        count = #bearings,
        thrustTotal = total,
        thrustPerBearing = total / #bearings,
        rpm = prop.bearingRpm,
        controllerRpm = prop.controllerRpm,
        tiltAngle = prop.tiltAngle,
        force = vectoring.cornerForce(bearings),
    }, nil
end

-- One rpm: read every corner several times and average. Returns nil if any
-- corner could not be read -- a sweep point missing a corner is not a sweep
-- point at three quarters strength, it is a different craft.
local function measureRpm(rpm)
    local set, err = session:setAllProps(rpm)
    commandedProps = true
    if not set then
        note(string.format("  %3d rpm  FAILED to command: %s", rpm, tostring(err)))
        return nil
    end
    waitSeconds(plan.settleSeconds)

    local totals, counts, bearings = {}, {}, {}
    local reportedRpm, reportedSamples = 0, 0
    local failure

    for _ = 1, plan.samples do
        for _, corner in ipairs(flight.CORNERS) do
            local reading, reason = readCorner(corner)
            if reading then
                totals[corner] = (totals[corner] or 0) + reading.thrustPerBearing
                counts[corner] = (counts[corner] or 0) + 1
                bearings[corner] = reading.count
                if type(reading.rpm) == "number" and reading.rpm ~= 0 then
                    reportedRpm = reportedRpm + math.abs(reading.rpm)
                    reportedSamples = reportedSamples + 1
                end
            else
                failure = failure or (corner .. ": " .. tostring(reason))
            end
        end
        waitSeconds(plan.sampleSeconds)
    end

    -- The premise is that this rpm cannot lift the craft. If it did, everything
    -- after it is a flight nobody asked for -- and the props go to zero here
    -- rather than at the end of the sweep.
    if lifted then
        local state = session:read()
        local y = state and session:craftY(state)
        note(string.format("  %3d rpm  ABORT: the hull rose %.2f blocks. It LIFTS at"
            .. " this rpm.", rpm, (y and baseY) and (y - baseY) or 0))
        session:setAllProps(0)
        return nil, "lifted"
    end

    local perCorner, totalThrust, cornerCount, totalBearings = {}, 0, 0, 0
    for _, corner in ipairs(flight.CORNERS) do
        if counts[corner] and counts[corner] > 0 then
            local mean = totals[corner] / counts[corner]
            perCorner[corner] = mean
            totalThrust = totalThrust + mean
            cornerCount = cornerCount + 1
            totalBearings = totalBearings + (bearings[corner] or 0)
        end
    end

    if cornerCount < #flight.CORNERS then
        note(string.format("  %3d rpm  only %d of %d corners readable  (%s)",
            rpm, cornerCount, #flight.CORNERS, tostring(failure)))
        if cornerCount == 0 then return nil end
    end

    local mean = totalThrust / cornerCount
    local spread = 0
    for _, value in pairs(perCorner) do
        spread = math.max(spread, math.abs(value / mean - 1))
    end

    -- ALTITUDE ON EVERY ROW. Run 2 lifted at 48 rpm where run 1 had held the
    -- ground all the way to 64, on the same thrust and the same mass -- so the
    -- craft was not resting the way it had been, and there was no way to see
    -- that coming in the log because only the abort reported height.
    local nowState = session:read()
    local nowY = nowState and session:craftY(nowState)
    local gain = (nowY and baseY) and (nowY - baseY) or nil

    note(string.format("  %3d rpm  thrust/bearing %10.1f   per rpm %7.2f"
        .. "   corners %d  spread %4.1f%%  y %5s",
        rpm, mean, mean / rpm, cornerCount, spread * 100,
        gain and string.format("%+.2f", gain) or "?"))

    return {
        rpm = rpm,
        thrust = mean,
        perCorner = perCorner,
        corners = cornerCount,
        bearingsPerCorner = cornerCount > 0 and (totalBearings / cornerCount) or 2,
        spread = spread,
    }
end

-- ---------------------------------------------------------------------------
-- The lateral check, at the top rpm
-- ---------------------------------------------------------------------------

-- Does the pair still ADD at flight rpm? Verified at 16 and never above it,
-- and a pair that started cancelling would make every number in this file a
-- description of a force the craft does not feel.
local function lateralCheck(rpm)
    local corner = plan.tiltCorner
    note("")
    note(string.format("== lateral coherence at %d rpm (%s, %.1f deg) ==",
        rpm, corner, plan.tiltDegrees))
    note("  vectorprobe measured ADDS at 16 rpm. It has never been checked above it.")

    -- FIRE AND FORGET, and the flag goes up BEFORE the send. actuators.setTilt
    -- blocks up to 1000 ms waiting for an ack and then reports failure for a
    -- tilt that WAS applied -- which in the first run of this tool left FL
    -- standing at 8 degrees after the sweep "failed" to command it. set_tilt is
    -- set-and-hold; the confirmation comes from telemetry, not from an ack.
    commandedTilt = true
    banks.send(corner, "set_tilt", {
        angle = plan.tiltDegrees, azimuth = plan.tiltAzimuth,
        bearing = nil, mirror = true,
    })
    waitSeconds(plan.tiltSettleSeconds)

    local reading, reason = readCorner(corner)
    banks.send(corner, "set_tilt",
        { angle = 0, azimuth = 0, bearing = nil, mirror = true })
    waitSeconds(0.5)
    commandedTilt = false

    -- CONFIRMED FROM TELEMETRY, the same rule the RPM path learned the hard
    -- way: a corner that reports 0.00 degrees did not tilt, whatever was sent.
    if reading and (not reading.tiltAngle
        or math.abs(reading.tiltAngle) < plan.tiltDegrees * 0.5) then
        note(string.format("  the corner reports %s deg against %.1f commanded --"
            .. " it did not tilt.",
            reading.tiltAngle and string.format("%.2f", reading.tiltAngle) or "nil",
            plan.tiltDegrees))
        return nil
    end

    if not reading or not reading.force then
        note("  cannot read " .. corner .. ": " .. tostring(reason))
        return nil
    end

    local verdict = vectoring.verdict(reading.force)
    local heading = vectoring.headingFromBow(reading.force.force, config.axes)
    note(string.format("  reported tilt %s   lift %10.1f   lateral %9.1f   coherence %s   %s",
        reading.tiltAngle and string.format("%.2f", reading.tiltAngle) or "--",
        reading.force.vertical, reading.force.lateralOfSum,
        reading.force.coherence and string.format("%.3f", reading.force.coherence) or "--",
        verdict))
    if heading then
        note(string.format("  pushes toward %3.0f deg -- %s", heading,
            vectoring.describeHeading(heading)))
    end

    -- The geometric prediction, from THIS rpm's measured thrust: one corner,
    -- two bearings, 2*T*sin(tilt).
    local predicted = bearinggain.lateralForce(plan.tiltDegrees, {
        corners = 1,
        bearingsPerCorner = reading.count,
        thrustPerBearing = reading.thrustPerBearing,
    })
    note(string.format("  geometry predicts %9.1f from the live thrust  (%.1f%% of measured)",
        predicted, reading.force.lateralOfSum > 0
            and (predicted / reading.force.lateralOfSum * 100) or 0))
    if verdict ~= vectoring.ADDS then
        note("  ** NOT ADDING at flight rpm. Every gain below describes a force")
        note("  ** the craft does not feel. Stop and re-run vectorprobe.")
    end
    return reading
end

-- ---------------------------------------------------------------------------
-- The report
-- ---------------------------------------------------------------------------

local function report(samples, mass, intendedTop)
    local fit, why = bearinggain.fitScaling(samples)
    note("")
    note("== RESULT ==")
    note("")
    if not fit then
        note("  no usable fit: " .. tostring(why))
        return
    end

    local verdict = bearinggain.scalingVerdict(fit)
    note(string.format("  thrust vs rpm: %.2f per rpm, exponent %s, r2 %s, spread %s"
        .. "  -> %s",
        fit.perRpm,
        fit.exponent and string.format("%.3f", fit.exponent) or "--",
        fit.r2 and string.format("%.6f", fit.r2) or "--",
        fit.spread and string.format("%.4f", fit.spread) or "--",
        verdict))
    if fit.slope then
        note(string.format("  as a straight line:   %.2f per rpm %s %.1f   (r2 %s)",
            fit.slope, fit.offset and fit.offset < 0 and "-" or "+",
            math.abs(fit.offset or 0),
            fit.affineR2 and string.format("%.6f", fit.affineR2) or "--"))
    end
    note(string.format("  the recorded craft-wide figure is %.2f per rpm over 8 bearings"
        .. " = %.2f each",
        bearinggain.REFERENCE.craftThrustPerRpm,
        bearinggain.REFERENCE.craftThrustPerRpm / 8))
    if fit.slope then
        note(string.format("  the SLOPE is that figure to %+.2f%%, which is what says the two"
            .. " measurements", (fit.slope / (bearinggain.REFERENCE.craftThrustPerRpm / 8) - 1)
            * 100))
        note("  are of the same quantity. A constant offset does not change a gain read")
        note("  AT an rpm; it only matters extrapolating down toward zero.")
    end
    note("")

    local flightRpm = samples[#samples].rpm
    local thrust = samples[#samples].thrust

    -- TWO WAYS THIS ANSWER IS NOT THE ONE THAT WAS ASKED FOR, said before the
    -- numbers rather than after them.
    if intendedTop and flightRpm < intendedTop then
        note(string.format("  ** THE SWEEP STOPPED AT %d rpm, SHORT OF %d. Everything below"
            .. " is the gain", flightRpm, intendedTop))
        note("  ** at the rpm reached, not at flight rpm. Do not extrapolate it by hand --")
        note("  ** re-run once the reason it stopped is understood.")
        note("")
    end
    if not bearinggain.usableAtMeasuredRpm(verdict) then
        note(string.format("  ** THE SCALING IS NOT LINEAR (%s), so the reading at one rpm"
            .. " says nothing", verdict))
        note("  ** about another. The gain below is good AT THE RPM IT WAS MEASURED AT")
        note("  ** and nowhere else.")
        note("")
    end
    local weight = bearinggain.weightFromMass(mass) or bearinggain.ENVIRONMENT.weight
    local options = { thrustPerBearing = thrust, weight = weight }

    note(string.format("  at %d rpm the bearings report %.1f each, which is %.2fx the"
        .. " 13960.98 that", flightRpm, thrust,
        bearinggain.driftFromReference(thrust) or 0))
    note("  fcs/trim.lua and lateralhold.terminalSpeed both store.")
    note("")
    note(string.format("  craft weight: %s  (%s)",
        string.format("%.1f", weight),
        mass and "live getMass" or "NO LIVE MASS -- the calibration-day default"))
    note("")
    note("  a degree of common-mode tilt is worth, in terminal drift:")
    note(string.format("    stored constant, 16 rpm      %.4f blocks/s   <- what the code uses",
        trim.bearingDrift(1.0)))
    note(string.format("    measured, %2d rpm, no density %.4f blocks/s",
        flightRpm, bearinggain.perDegree(options)))
    note(string.format("    measured, %2d rpm, x1.353     %.4f blocks/s   <- if lateral takes"
        .. " the air-density factor",
        flightRpm, bearinggain.perDegree({ thrustPerBearing = thrust,
            weight = weight, pressure = 1.353 })))
    note("")

    -- WHAT IT MEANS FOR THE TRIM FLIGHTS, because this is the number that
    -- explains why they failed and it should be said in the same breath.
    local perDegree = bearinggain.perDegree(options)
    note(string.format("  THE TRIM FLIGHTS. A 1 degree trim was costed at %.3f blocks/s and",
        trim.bearingDrift(1.0)))
    note(string.format("  really costs %.3f. Trim removed %.0f%% of the standing tilt and did",
        perDegree, 74))
    note("  not reduce the drift -- which is exactly what a cost this size predicts.")
    note("")
    note("  FOR THE VELOCITY LOOP: the tilt that holds against a drift is")
    note(string.format("  drift / %.4f deg per block/s. At the measured 1.2-1.7 blocks/s that",
        perDegree))
    note(string.format("  is %.2f to %.2f degrees -- %s", 1.2 / perDegree, 1.7 / perDegree,
        (1.7 / perDegree) < 4.0
            and "well inside the 4 degree trim clamp."
            or "and that is past the 4 degree clamp: check it."))
    note("")
    note("  The flight cross-check that remains: hold a known tilt at flight rpm,")
    note("  read terminal NET drift, and put it through bearinggain.impliedThrust.")
    note("  If it comes back near the reading above, the density question is")
    note("  closed too. That is now a CHECK of a known number, not a hunt.")
end

-- ---------------------------------------------------------------------------

local function mainLoop()
    note("BEARING GAIN SWEEP -- ground, will not fly")
    note("utc_ms=" .. tostring(os.epoch("utc")))
    note("")
    note(string.format("  props %s rpm; 64 rpm is 52.1%% of weight and hover is 122-124.",
        table.concat(plan.rpms, "/")))
    note("  the ions are never armed. nothing here can lift the craft.")
    note("")

    local mass
    if sublevel and type(sublevel.getMass) == "function" then
        local ok, value = pcall(sublevel.getMass)
        if ok and type(value) == "number" then mass = value end
    end
    if mass then
        note(string.format("  live mass %.1f  (calibration day: %.1f, %+.1f%%)",
            mass, bearinggain.ENVIRONMENT.weight / bearinggain.ENVIRONMENT.gravity,
            (mass / (bearinggain.ENVIRONMENT.weight / bearinggain.ENVIRONMENT.gravity) - 1)
                * 100))
        note("  every gain below is computed from THIS mass, so bolting machines to")
        note("  the hull and re-running is all the recalibration there is.")
    else
        note("  NO LIVE MASS -- falling back to the calibration-day weight. Every")
        note("  gain below is then only as current as that day.")
    end
    note("")

    note("== sweep ==")
    local samples = {}
    for _, rpm in ipairs(plan.rpms) do
        local sample, stop = measureRpm(rpm)
        if sample then samples[#samples + 1] = sample end
        if stop then break end
    end

    if #samples == 0 then
        note("")
        note("  nothing readable. Are the bearings assembled and the props sourced?")
        return
    end

    -- THE TILT CHECK IS THE MORE IMPORTANT HALF, so a lift abort must not
    -- silently skip it. Run 2 aborted at 48 rpm and returned no tilt readback
    -- at all -- and the readback was the whole reason that run was flown, after
    -- the velocity flight measured a craft whose bearings never moved.
    --
    -- So: cut the props, let the hull come back down, and do the check at the
    -- highest rpm that DID hold the ground.
    if not skipTilt and lifted and #samples > 0 then
        local safeRpm = samples[#samples].rpm
        note("")
        note(string.format("  it lifted, so the tilt check runs at %d rpm -- the highest"
            .. " that held", safeRpm))
        note("  the ground. Cutting props and waiting for the hull to settle.")
        session:setAllProps(0)

        -- CLEAR THE FLAG BEFORE WAITING. waitSeconds returns immediately while
        -- `lifted` is set -- that is what stops the sweep -- so waiting for the
        -- descent with it still true spins without ever advancing the clock.
        -- It hung the harness. The flag has done its job by here: the props are
        -- off and the sweep is over.
        lifted = false

        -- WAIT FOR IT TO COME DOWN, rather than for a fixed count. A craft that
        -- has just lifted is still moving upward when the props stop, and a
        -- fixed 8 s wait declared a harness craft "not resting on the ground"
        -- while it was halfway through falling back to it.
        -- BOUNDED BY ITERATIONS, not by the clock. A wall-clock deadline here
        -- hung the harness: if time does not advance the way the loop assumes,
        -- a `while os.epoch() < deadline` never exits. A fixed number of waits
        -- always terminates, whatever the clock is doing.
        local gain, y
        for _ = 1, 12 do
            waitSeconds(1.0)
            local state = session:read()
            y = state and session:craftY(state)
            gain = (y and baseY) and (y - baseY) or nil
            if gain and gain <= plan.liftAbort then break end
        end
        if gain and gain > plan.liftAbort then
            note(string.format("  ** STILL %+.2f BLOCKS UP with the props stopped. The hull"
                .. " is not", gain))
            note("  ** resting on the ground, and nothing measured here can be trusted")
            note("  ** as a ground reading. Land it and re-run.")
        else
            local set = session:setAllProps(safeRpm)
            commandedProps = true
            if set then
                waitSeconds(plan.settleSeconds)
                lateralCheck(safeRpm)
            else
                note("  could not re-command the props for the tilt check")
            end
        end
    elseif not skipTilt and not lifted then
        lateralCheck(samples[#samples].rpm)
    end

    report(samples, mass, plan.rpms[#plan.rpms])
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
    if commandedTilt then
        for _, corner in ipairs(flight.CORNERS) do
            banks.send(corner, "set_tilt",
                { angle = 0, azimuth = 0, bearing = nil, mirror = true })
        end
    end
    if commandedProps then
        local stopped, why = session:setAllProps(0)
        if not stopped then
            note("  WARNING: could not stop all props -- " .. tostring(why))
        end
    end
    pcall(session.finish, session)
end

pcall(parallel.waitForAny, shutdown, listenLoop)
save()
