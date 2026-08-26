-- Roll damping from DIFFERENTIAL PROPELLER RPM.
--
-- The third actuator tried, and the first whose prediction does not rest on an
-- unmeasured quantity.
--
--   IONS            one level is 7.42 deg/s^2 of attitude command against the
--                   0.268 damping needs. 28x too coarse. Dead.
--   BEARING TILT    makes a HORIZONTAL force, so its roll torque depends on
--                   how far the bearings sit above or below the centre of
--                   mass. Nobody has measured that. The sign surprised us
--                   (craft ran 1.76 -> 11.5 blocks/s) and then the magnitude
--                   did (a "pure couple" rolled 0.07 deg in 3 seconds).
--   DIFFERENTIAL    makes a VERTICAL force at a LATERAL arm. That is the
--   RPM             geometry craftgeom already solves from the inertia tensor,
--                   and which runs 9 and 10 validated at 97% and 102% of its
--                   ceiling. The unknown that broke the other two does not
--                   appear here at all.
--
-- The number that makes it worth doing:
--
--     2357 per RPM per corner (6968.34 craft-wide / 4, x1.353 air density)
--     +/-1 RPM differential -> torque 410785 -> 0.2712 deg/s^2
--     critical damping wants                    0.2987 deg/s^2   (91%)
--
-- ONE RPM of differential is 91% of critical damping. The coarsest step this
-- actuator has lands almost exactly on the number needed.
--
-- WHICH IS ALSO THE CATCH, stated plainly so nobody designs past it: RPM is an
-- integer (props.setRpm rounds), so at the damping scale this is roughly a
-- ONE-BIT actuator. It can kill an oscillation bang-bang or by duty cycle. It
-- cannot trim. Fine trim, if it is ever wanted, is a different problem and
-- probably belongs on the bearings, which resolve continuously.

local rolldamp = {}

-- Everything measured, and every default here is a MEASUREMENT, not a tuning.
rolldamp.MEASURED = {
    -- Craft-wide propeller thrust per RPM. Linear to r^2 = 1.000000 from 8 to
    -- 96 RPM, so extrapolating a couple of RPM either side of 64 is safe.
    thrustPerRpmCraft = 6968.34,
    -- getThrust reports BEFORE the air-density factor; 1.353 is the correction
    -- at the propellers' actual altitude (+14 blocks above the craft origin).
    densityCorrection = 1.353,
    corners = 4,
    -- From craftgeom's hull box: half the 87.1 block beam.
    lateralArm = 43.57,
    -- getInertiaTensor t[3][3], the bow axis -- roll is rotation about the bow.
    rollInertia = 86772714.93,
    -- Self-levelling spring, from the 42 s oscillation period.
    springPerDegree = 0.0223,
}

function rolldamp.criticalDamping(options)
    options = options or {}
    local spring = options.springPerDegree or rolldamp.MEASURED.springPerDegree
    return 2 * math.sqrt(spring)
end

-- Roll acceleration produced by commanding +rpm on the port corners and -rpm
-- on the starboard ones.
--
-- Four corners each shift by `thrustPerRpmCorner * rpm`, two up and two down,
-- all at the same lateral arm -- so the torque is 4 * arm * force, the same
-- shape craftgeom uses for the ion authority ceiling.
function rolldamp.authorityPerRpm(options)
    options = options or {}
    local measured = rolldamp.MEASURED
    local perCorner = (options.thrustPerRpmCraft or measured.thrustPerRpmCraft)
        / (options.corners or measured.corners)
        * (options.densityCorrection or measured.densityCorrection)
    local arm = options.lateralArm or measured.lateralArm
    local inertia = options.rollInertia or measured.rollInertia
    if inertia <= 0 then return nil end

    local torque = (options.corners or measured.corners) * arm * perCorner
    return math.deg(torque / inertia), perCorner
end

-- The damper: oppose the roll RATE.
--
-- Returns an INTEGER differential, because props.setRpm rounds and a
-- fractional command would be silently truncated -- the caller would then be
-- reasoning about a torque the craft is not producing. Rounding here makes the
-- quantisation visible at the point of decision.
--
-- No angle term. This damps; it does not level. The hull already has a
-- restoring spring (0.0223 deg/s^2 per degree) and what it lacks is damping --
-- 5 zero crossings over 105 s. Adding a second angle term would fight the
-- spring for authority this actuator does not have to spare.
rolldamp.DEFAULTS = {
    maxDifferentialRpm = 4,
    deadbandRate = 0.05,
}

function rolldamp.differentialFor(rollRate, options)
    options = options or {}
    local maxRpm = options.maxDifferentialRpm or rolldamp.DEFAULTS.maxDifferentialRpm
    local deadband = options.deadbandRate or rolldamp.DEFAULTS.deadbandRate
    local perRpm = options.authorityPerRpm or rolldamp.authorityPerRpm(options)
    if not perRpm or perRpm <= 0 then return 0 end

    rollRate = rollRate or 0
    if math.abs(rollRate) < deadband then return 0 end

    -- Torque wanted, in deg/s^2, then converted to RPM and rounded.
    local wanted = -(options.dampingGain or rolldamp.criticalDamping(options)) * rollRate
    local rpm = wanted / perRpm

    local rounded = rpm >= 0 and math.floor(rpm + 0.5) or -math.floor(-rpm + 0.5)
    if rounded > maxRpm then rounded = maxRpm end
    if rounded < -maxRpm then rounded = -maxRpm end
    return rounded
end

-- Per-corner RPM for a base setting and a differential.
--
-- Positive differential raises the PORT corners, which is a positive roll
-- demand -- the same convention as mixer_profile's corner map, and
-- hull-relative so turning the ship cannot reintroduce it.
--
-- Clamped to a floor: dropping a corner's props toward zero sheds the lift
-- that corner is carrying, and the last hover run showed what one corner
-- losing its props does -- FR went to 0 and the craft rolled past 28 degrees.
function rolldamp.cornerRpm(baseRpm, differential, options)
    options = options or {}
    local floor = options.minimumRpm or 8
    local signs = { FL = 1, FR = -1, RL = 1, RR = -1 }

    local result = {}
    for corner, sign in pairs(signs) do
        local rpm = (baseRpm or 0) + sign * (differential or 0)
        if rpm < floor then rpm = floor end
        result[corner] = math.floor(rpm + 0.5)
    end
    return result
end

return rolldamp
