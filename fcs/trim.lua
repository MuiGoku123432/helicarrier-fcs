-- Cancelling the craft's STANDING tilt with bearing tilt.
--
-- WHY THIS IS WORTH DOING, in one number: the standing offsets alone explain
-- 94% of the craft's drift.
--
--     standing roll   +0.368 deg  ->  0.785 blocks/s
--     standing pitch  -0.638 deg  ->  1.361 blocks/s
--     vector sum                      1.571 blocks/s
--     MEASURED mean ground speed      1.670 blocks/s
--
-- The drift is not mysterious and it is not, in its SPEED, an oscillation. A
-- hull that sits 0.7 degrees off level points its lift 0.7 degrees off vertical
-- and slides until drag balances it. That is a DC problem with a DC fix.
--
-- WHAT THIS DOES NOT FIX, so nobody expects it to. The measured drift is a
-- CURVE -- the velocity heading swept -225 degrees in 47 s -- because roll and
-- pitch oscillate out of phase and the tilt VECTOR rotates. Trim cannot touch
-- that; only damping can, and that is what differential propeller RPM is for.
-- Trim removes the SPEED, damping removes the CURVING, and the craft needs
-- both. Every single-actuator design in this project's history failed on
-- exactly this point.
--
-- PITCH IS THE BIGGER HALF. 1.361 blocks/s against roll's 0.785. Work that
-- trims only roll -- which is where this project's attention has always gone,
-- because the repaired RR deficit was a roll torque -- collects 31% of the
-- available improvement.
--
-- THE ACTUATOR, and its catch. Bearing tilt is the only actuator with the
-- resolution to trim: it is continuous, where one rpm of differential shifts
-- the equilibrium 4.14 degrees against an offset of 0.31. But the two props of
-- a corner sit at the SAME HEIGHT, so there is no pure attitude channel --
-- the same command makes lateral force AND roll, through that force's moment
-- about the centre of mass. Using it to trim therefore BUYS BACK some drift:
-- 0.63 and 1.16 degrees of tilt cost 0.272 blocks/s against the 1.571 they
-- remove. A 5.8x improvement, not a cure.
--
-- AND THE SIGN OF THAT COUPLING HAS NEVER BEEN MEASURED. It is the reason a
-- saturated 12 degree command once ran the craft from 1.76 to 11.5 blocks/s.
-- So nothing here assumes it: staticGain() measures it in flight, from reverse
-- pairs, and a trim computed from an unmeasured gain is refused.

local trim = {}

trim.MEASURED = {
    -- Create's universal drag. A tilt-implied acceleration reaches terminal
    -- velocity rather than integrating, which is why the craft cruises at
    -- 1.67 blocks/s instead of accelerating away.
    universalDrag = 0.09,
    gravity = 11.0,
    weight = 1158293.4,
    -- Per bearing, the constant the MEASURED lateral force uses:
    -- lateral = 2 * T * sin(tilt) per corner, linear to 0.06% over 4/6/8
    -- degrees, and 8 degrees on four corners came to 1.34% of weight. The same
    -- value lateralhold.terminalSpeed defaults to; do not "helpfully" rescale
    -- it by rpm, which multiplies the answer by four and was caught here by
    -- the test pinning 0.63 deg to 0.130 blocks/s.
    --
    -- (It sits oddly against the harness's vertical prop thrust, which DOES
    -- scale with rpm from a 16 rpm base. Whether the lateral constant should
    -- too is unresolved -- but 13960.98 is what the craft measured.)
    thrustPerBearing = 13960.98,

    -- The hull's self-levelling spring, from the 42 s oscillation period.
    -- NOTE: run 1 of the damper flight suggests the hull damps itself rather
    -- more than the 42 s figure implies -- roll fell 87% in its first half
    -- cycle, at a period nearer 35 s. Worth re-deriving; it changes the
    -- PREDICTED gain below but not the measured one.
    springPerDegree = 0.0223,
    -- Bearing roll authority, measured: 0.011 deg/s^2 per degree of tilt.
    -- MAGNITUDE only. The sign is what staticGain measures.
    bearingRollPerDegree = 0.011,

    -- The standing offsets themselves, from the passive rolldrift flight.
    standingRoll = 0.368,
    standingPitch = -0.638,
}

-- Terminal ground speed from a HULL tilt: lift leans, drag balances.
function trim.driftSpeed(hullTiltDegrees, options)
    options = options or {}
    local gravity = options.gravity or trim.MEASURED.gravity
    local drag = options.universalDrag or trim.MEASURED.universalDrag
    if drag <= 0 then return nil end
    local acceleration = gravity * math.tan(math.rad(hullTiltDegrees or 0))
    return acceleration / drag, acceleration
end

-- Terminal ground speed from a BEARING tilt: the price of trimming.
function trim.bearingDrift(tiltDegrees, options)
    options = options or {}
    local gravity = options.gravity or trim.MEASURED.gravity
    local drag = options.universalDrag or trim.MEASURED.universalDrag
    local weight = options.weight or trim.MEASURED.weight
    local thrust = options.thrustPerBearing or trim.MEASURED.thrustPerBearing
    if drag <= 0 or weight <= 0 then return nil end
    local force = 4 * 2 * thrust * math.sin(math.rad(tiltDegrees or 0))
    local acceleration = (force / weight) * gravity
    return acceleration / drag, acceleration
end

-- Combine two axes into the speed that actually gets measured.
function trim.combinedDrift(rollDegrees, pitchDegrees, options)
    local acrossRoll = trim.driftSpeed(rollDegrees, options) or 0
    local acrossPitch = trim.driftSpeed(pitchDegrees, options) or 0
    return math.sqrt(acrossRoll * acrossRoll + acrossPitch * acrossPitch)
end

-- What the torque model PREDICTS for hull degrees per degree of bearing tilt:
-- the bearing torque against the hull's restoring spring, at equilibrium.
--
-- Kept for comparison only. The prediction for the ROLL authority of
-- differential RPM came in 2.9x high, so a prediction here is a hypothesis,
-- not a gain to command with.
function trim.predictedGain(options)
    options = options or {}
    local bearing = options.bearingRollPerDegree or trim.MEASURED.bearingRollPerDegree
    local spring = options.springPerDegree or trim.MEASURED.springPerDegree
    if spring <= 0 then return nil end
    return bearing / spring
end

-- MEASURE the gain from a reverse pair: hull tilt at +T and at -T.
--
-- Reverse pairs, not a single step, and this is the technique that finally
-- worked on this craft: the standing offset and the hull's own oscillation are
-- both LARGER than the signal being measured, and both cancel in the
-- difference. Averaging single-sided steps does not work here -- it measures
-- the offset.
--
-- Returns hull degrees per degree of commanded bearing tilt, SIGNED. A
-- positive gain means a positive commanded tilt produced a positive hull
-- angle; the trim below inverts it, whatever it turns out to be.
function trim.staticGain(positiveTilt, positiveHull, negativeTilt, negativeHull)
    if not (positiveTilt and positiveHull and negativeTilt and negativeHull) then
        return nil
    end
    local span = positiveTilt - negativeTilt
    if math.abs(span) < 1e-6 then return nil end
    return (positiveHull - negativeHull) / span
end

trim.DEFAULTS = {
    -- The trim command clamp. Deliberately far below the 15 degree hardware
    -- clamp: the trims wanted are 0.63 and 1.16 degrees, and the runaway that
    -- makes this dangerous happened at a saturated 12.
    maxTiltDegrees = 4.0,
    -- Below this the gain is not distinguishable from noise and a trim
    -- computed from it would be a large command derived from nothing.
    minimumUsableGain = 0.05,
    -- Do not chase an offset smaller than the craft's own angular resolution.
    deadbandDegrees = 0.05,
}

-- The trim command: the bearing tilt that cancels a standing hull offset.
--
-- Refuses rather than guesses. A gain too small to trust produces a division
-- that blows up into a large tilt command, which is precisely the shape of the
-- runaway this tool exists to avoid.
function trim.tiltFor(offsetDegrees, gain, options)
    options = options or {}
    local maxTilt = options.maxTiltDegrees or trim.DEFAULTS.maxTiltDegrees
    local minimumGain = options.minimumUsableGain or trim.DEFAULTS.minimumUsableGain
    local deadband = options.deadbandDegrees or trim.DEFAULTS.deadbandDegrees

    if not gain or math.abs(gain) < minimumGain then
        return nil, string.format("gain %s is below the %.2f needed to trust it",
            gain and string.format("%.4f", gain) or "nil", minimumGain)
    end
    offsetDegrees = offsetDegrees or 0
    if math.abs(offsetDegrees) < deadband then
        return 0, "inside the deadband"
    end

    -- Cancel it: command the tilt whose hull response is the negative of the
    -- offset we have.
    local tilt = -offsetDegrees / gain
    if tilt > maxTilt then
        return maxTilt, "clamped"
    elseif tilt < -maxTilt then
        return -maxTilt, "clamped"
    end
    return tilt, nil
end

-- Mean of a sample list, ignoring nils. The standing offset is a MEAN over a
-- window, never a single reading: the hull oscillates either side of it by
-- several times its size.
function trim.mean(samples, field)
    local total, n = 0, 0
    for _, sample in ipairs(samples or {}) do
        local value = field and sample[field] or sample
        if type(value) == "number" then
            total = total + value
            n = n + 1
        end
    end
    if n == 0 then return nil end
    return total / n, n
end

return trim
