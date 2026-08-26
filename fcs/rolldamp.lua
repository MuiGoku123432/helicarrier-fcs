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
-- THEN IT WAS MEASURED, and came in at 0.0941 -- 35% of that prediction, for
-- reasons nobody has found (HANDOFF open question 4). The block above is left
-- because it is how the actuator was CHOSEN, and because the discrepancy is
-- itself a live problem; but every number the damper commands comes from
-- MEASURED.flightAuthorityPerRpm below, never from authorityPerRpm().
--
-- Coming in low is the good direction. At the predicted value one rpm would be
-- 91% of critical damping -- a near one-bit actuator. At the measured value
-- critical damping is 3.2 rpm against a clamp of 4, so there are three or four
-- usable steps instead of one.
--
-- It still cannot TRIM: RPM is an integer (props.setRpm rounds), and one rpm
-- held constantly shifts the equilibrium 4.14 degrees against a standing
-- offset of 0.31. Damping and trimming want opposite resolutions. Trim belongs
-- on the bearings, which resolve continuously.

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

    -- THE NUMBER THE DAMPER ACTUALLY USES, measured in flight 2026-08-26:
    -- three paired reverse steps, two flights, two rpm levels, spread 7.7%.
    --
    --     2 rpm pair               0.0910   -3.3%
    --     3 rpm pair               0.0931   -1.1%
    --     3 rpm pair, next flight  0.0983   +4.4%
    --
    -- (An earlier two-measurement figure of 0.0924 appears in
    -- tools/test_rolldamp.lua's staircase check. 1.8% apart; this is the one
    -- with three measurements behind it.)
    --
    -- It is 35% of what authorityPerRpm() predicts from the thrust model, and
    -- NOBODY KNOWS WHY -- see HANDOFF's open question 4. It is not the moment
    -- arm: ion authority validated against the same craftgeom arm at 97% and
    -- 102%. Something in the propeller force-per-RPM chain is off by ~3x.
    --
    -- Which way that error runs matters enormously here, so the measured value
    -- is what commands the craft and the model is kept only for comparison. A
    -- damper defaulting to the prediction asks for ONE rpm where three are
    -- needed -- under-damping by 2.9x, silently, with a plausible number.
    flightAuthorityPerRpm = 0.0941,
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
    -- MEASURED by default, never the model. See MEASURED.flightAuthorityPerRpm:
    -- the model reads 2.9x high and would under-damp by the same factor. A
    -- caller that genuinely wants the prediction passes it explicitly.
    local perRpm = options.authorityPerRpm or rolldamp.MEASURED.flightAuthorityPerRpm
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

-- ---------------------------------------------------------------------------
-- Roll RATE, from angles.
--
-- The damper needs a rate and the craft will not give it one. Session:rates
-- reads angularVelocityBody, which "read exactly 0.0000 in a third of samples"
-- (flight.lua), and Session:readCheap -- the only read fast enough for a
-- control loop at 0.15 s -- deliberately omits it altogether. That is why the
-- axis-response pulse fits ANGLES rather than trusting reported rates.
--
-- So: least-squares slope over a short window of angle samples. A single first
-- difference would be a rate estimate built on two quantised angles a tenth of
-- a second apart, which is mostly noise; a heavy filter would add phase lag,
-- and phase lag in a damper is how a damper becomes a driver. A ~0.6 s window
-- against a 42 s oscillation is 1.4% of a cycle -- lag small enough to ignore,
-- averaging long enough to matter.
-- ---------------------------------------------------------------------------

function rolldamp.newRateEstimator(options)
    options = options or {}
    local estimator = {
        windowSeconds = options.windowSeconds or 0.6,
        minimumSamples = options.minimumSamples or 3,
        samples = {},
    }

    function estimator:push(t, angle)
        if not t or not angle then return end
        self.samples[#self.samples + 1] = { t = t, angle = angle }
        -- Drop anything older than the window. Keeps the estimate local in
        -- time, which is what makes it a RATE rather than an average slope
        -- across the whole run.
        while #self.samples > 1
            and (t - self.samples[1].t) > self.windowSeconds do
            table.remove(self.samples, 1)
        end
    end

    function estimator:rate()
        local n = #self.samples
        if n < self.minimumSamples then return nil end

        local sumT, sumA, sumTT, sumTA = 0, 0, 0, 0
        for _, sample in ipairs(self.samples) do
            sumT = sumT + sample.t
            sumA = sumA + sample.angle
            sumTT = sumTT + sample.t * sample.t
            sumTA = sumTA + sample.t * sample.angle
        end

        local denominator = n * sumTT - sumT * sumT
        -- Every sample at the same instant. Possible if a loop stalls and the
        -- clock does not advance between reads; a slope there is meaningless
        -- rather than infinite.
        if math.abs(denominator) < 1e-9 then return nil end
        return (n * sumTA - sumT * sumA) / denominator
    end

    function estimator:count()
        return #self.samples
    end

    function estimator:reset()
        self.samples = {}
    end

    return estimator
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
