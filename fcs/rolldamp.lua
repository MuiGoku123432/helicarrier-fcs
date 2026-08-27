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

-- ---------------------------------------------------------------------------
-- Reading a flight back
-- ---------------------------------------------------------------------------

-- WITH HYSTERESIS, and the first flight is why.
--
-- The naive version counted every sign flip. A damped trace ENDS near zero and
-- jitters across it -- -0.00, 0.01, 0.03 -- so run 1 reported 4 crossings
-- damped against 3 undamped, which reads as "the damper made it worse" when
-- what it actually measured was the damper having finished. A crossing only
-- counts once the rate has genuinely gone somewhere since the last one.
--
-- The floor is the damper's own deadband: below that the damper is not acting,
-- so motion below it is not oscillation the damper is failing to stop.
function rolldamp.zeroCrossings(samples, floor, field)
    floor = floor or rolldamp.DEFAULTS.deadbandRate
    field = field or "rollRate"
    local crossings, armedSign = 0, nil
    for _, sample in ipairs(samples) do
        local rate = sample[field]
        if rate and math.abs(rate) >= floor then
            local sign = rate > 0 and 1 or -1
            if armedSign and sign ~= armedSign then
                crossings = crossings + 1
            end
            armedSign = sign
        end
    end
    return crossings
end

-- Re-measure the authority from the pulse that started the UNDAMPED half.
--
-- A clean measurement falls out of the disturbance for free: a known
-- differential held for a known time from rest, and the rate it produced. The
-- header of this file claimed it did this from the day it was written and it
-- did not -- run 1's 0.0900 was worked out by hand afterwards, which is exactly
-- the sort of thing that stops happening the moment nobody remembers to.
--
-- Peak rate rather than rate at release, because the props do not stop the
-- instant the command does: run 1 kept accelerating for 1.4 s after release
-- while the RSC spun down. Measuring to the peak captures the whole impulse;
-- using the release instant alone understates the time and so overstates the
-- authority.
--
-- SEARCHSECONDS BOUNDS THE HUNT, and on a slow axis it is not optional.
--
-- "Peak over the window" is only the impulse response while the window is
-- short compared with the spring. Give the same code a 120 s window on an axis
-- whose period is 89 s and the largest rate in it is the oscillation's own
-- swing half a minute later -- which has nothing to do with the pulse and
-- carries the OPPOSITE sign. Measured in the harness: the pitch flight read
-- -0.0015 deg/s^2 per rpm, 3% of prediction and backwards, off a peak found at
-- t = 46.5 s. Nothing was wrong with the craft or the pulse.
--
-- Default nil keeps the whole window, which is what the roll flight measured
-- at and what its recorded numbers mean. Any caller with a window longer than
-- a few seconds should pass a bound.
--
-- INITIALRATE IS SUBTRACTED, and without it the reverse pair below cannot
-- work. What the pulse produced is a CHANGE in rate, not a rate: the craft was
-- already doing something, and on this craft that something is comparable to
-- the signal. Peak-of-magnitude is also a nonlinear operator -- it picks
-- whichever feature happens to be largest -- so two halves of a reverse pair
-- can end up measuring different features entirely and their difference
-- cancels nothing. Subtracting the pre-pulse rate first makes the measurement
-- linear, which is what makes differencing mean anything.
function rolldamp.authorityFromPulse(samples, pulseRpm, pulseSeconds, field,
    searchSeconds, initialRate)
    field = field or "rollRate"
    initialRate = initialRate or 0
    if #samples == 0 or not pulseRpm or pulseRpm == 0 then return nil end

    -- SIGNED peak, because the pitch damper does not know its sign yet. The
    -- roll pattern was measured long ago and this function only ever needed a
    -- magnitude; on a fresh axis, WHICH WAY the craft went is the whole point,
    -- and a magnitude-only answer is how a damper gets built backwards.
    local peak, peakAt, signedPeak = 0, 0, 0
    for _, sample in ipairs(samples) do
        if searchSeconds and sample.t and sample.t > searchSeconds then break end
        local value = (sample[field] or 0) - initialRate
        local magnitude = math.abs(value)
        if magnitude > peak then
            peak, peakAt, signedPeak = magnitude, sample.t, value
        end
    end
    if peak <= 0 then return nil end

    -- t is measured from release, so the impulse ran for the pulse itself plus
    -- however long the rate kept climbing afterwards.
    local effectiveSeconds = pulseSeconds + math.max(peakAt, 0)
    if effectiveSeconds <= 0 then return nil end
    -- Magnitude first (every existing caller wants that), then the signed
    -- authority: positive means a positive differential produced a positive
    -- rate on this axis.
    local magnitude = (peak / effectiveSeconds) / math.abs(pulseRpm)
    local signed = (signedPeak / effectiveSeconds) / pulseRpm
    return magnitude, peak, effectiveSeconds, signed
end

-- REVERSE PAIRS, which is the technique that finally worked on the bearings.
--
-- A single pulse measures the pulse PLUS whatever the craft was already doing,
-- and on this craft the second term is not small. Run 1 of the pitch flight
-- pulsed straight out of the climb and read -0.0440 deg/s^2 per rpm; run 2 sat
-- quiet for 12 s first and read +0.0237. OPPOSITE SIGNS, same command, same
-- code. Run 1's "peak" was its very first sample -- residual climb motion,
-- caught by a peak search that had nothing better to find yet.
--
-- A quiet baseline fixes most of it. Differencing a +P pulse against a -P one
-- fixes the rest, and for the same reason trim.staticGain does it: any drift
-- common to both halves appears with the SAME sign in each peak and cancels in
-- the difference, while the response reverses and adds.
--
--     a = (peak(+P) - peak(-P)) / (2 * P * seconds)
--
-- Takes the two halves' SIGNED peaks and their effective durations. Returns the
-- signed authority, and the two halves' individual values so a caller can see
-- whether they agreed -- if they disagree wildly the difference is not
-- measuring a response either.
function rolldamp.authorityFromReversePair(plusSamples, minusSamples, pulseRpm,
    pulseSeconds, field, searchSeconds, plusInitial, minusInitial)
    if not pulseRpm or pulseRpm == 0 then return nil end

    local _, _, plusSeconds, plusSigned = rolldamp.authorityFromPulse(
        plusSamples, pulseRpm, pulseSeconds, field, searchSeconds, plusInitial)
    local _, _, minusSeconds, minusSigned = rolldamp.authorityFromPulse(
        minusSamples, -pulseRpm, pulseSeconds, field, searchSeconds, minusInitial)
    if not plusSigned or not minusSigned then return nil end

    -- Each half already divides its peak by its own duration and its own
    -- signed rpm, so both are authorities in the same units and the same sign
    -- convention. The pair average IS the difference, halved.
    local combined = (plusSigned + minusSigned) / 2
    return combined, plusSigned, minusSigned, plusSeconds, minusSeconds
end

-- ---------------------------------------------------------------------------
-- The SPRING, from the free oscillation
--
-- The hull levels itself, and how hard is a physical constant of the craft:
-- alpha = -k * angle, so it oscillates at omega = sqrt(k) and a period of
-- 2*pi/sqrt(k). Roll's k = 0.0223 came from a 42 s period observed once.
-- PITCH'S HAS NEVER BEEN MEASURED AT ALL, and it is not safe to assume the two
-- are equal: if the restoring TORQUE per degree were the same on both axes,
-- pitch would spring at k/4.49 -- a 89 s period, twice roll's -- because pitch
-- carries 4.49x the inertia. Assuming roll's number for pitch would set
-- critical damping 2.1x too high.
--
-- These two are the whole conversion, kept in one place so a period measured
-- in flight becomes a damping gain without anybody doing it by hand.
-- ---------------------------------------------------------------------------

function rolldamp.springFromPeriod(seconds)
    if type(seconds) ~= "number" or seconds <= 0 then return nil end
    local omega = 2 * math.pi / seconds
    return omega * omega
end

function rolldamp.periodFromSpring(spring)
    if type(spring) ~= "number" or spring <= 0 then return nil end
    return 2 * math.pi / math.sqrt(spring)
end

-- WHEN the rate crossed zero, not merely how often. Same hysteresis as
-- zeroCrossings -- a trace that has finished jitters across zero and every one
-- of those is a "crossing" to a naive counter -- but it hands back the times,
-- because half the interval between consecutive crossings is a period.
function rolldamp.crossingTimes(samples, floor, field)
    floor = floor or rolldamp.DEFAULTS.deadbandRate
    field = field or "rollRate"
    local times, armedSign, previous = {}, nil, nil
    for _, sample in ipairs(samples) do
        local rate = sample[field]
        if rate and math.abs(rate) >= floor then
            local sign = rate > 0 and 1 or -1
            if armedSign and sign ~= armedSign then
                -- Linear interpolation between the last armed sample and this
                -- one. At 0.15 s sampling against a 40-90 s period the
                -- correction is small, but it costs nothing and it stops the
                -- period estimate quantising to the loop rate.
                local crossing = sample.t
                if previous and previous.rate and previous.t then
                    local span = rate - previous.rate
                    if math.abs(span) > 1e-9 then
                        local fraction = -previous.rate / span
                        if fraction >= 0 and fraction <= 1 then
                            crossing = previous.t + fraction * (sample.t - previous.t)
                        end
                    end
                end
                times[#times + 1] = crossing
            end
            armedSign = sign
            previous = { t = sample.t, rate = rate }
        end
    end
    return times
end

-- The oscillation period, from the crossing times. A full period is TWO
-- crossings, so the period is twice the mean interval.
--
-- Returns period, the number of intervals behind it, and their spread as a
-- fraction of the mean. THE SPREAD IS THE POINT: one interval is not a
-- measurement, and a period whose intervals disagree by half is a craft doing
-- something other than ringing at a single frequency. Roll's recorded 42 s
-- came from a single observation and the damper flight suggests it is nearer
-- 35 -- exactly the kind of number that needs its own error bar.
function rolldamp.measurePeriod(samples, floor, field)
    local times = rolldamp.crossingTimes(samples, floor, field)
    if #times < 2 then return nil, #times end

    local intervals, total = {}, 0
    for index = 2, #times do
        local gap = times[index] - times[index - 1]
        intervals[#intervals + 1] = gap
        total = total + gap
    end
    local mean = total / #intervals

    local low, high = math.huge, -math.huge
    for _, gap in ipairs(intervals) do
        if gap < low then low = gap end
        if gap > high then high = gap end
    end
    local spread = mean > 0 and ((high - low) / mean) or nil

    return mean * 2, #intervals, spread
end

-- Time for |roll rate| to fall to 1/e of its starting value, read off the
-- running peak rather than fitted. A fit would imply a model of the decay
-- shape; this asks only "when did it get small", which is what the comparison
-- needs and is robust to the shape being wrong.
function rolldamp.decayTime(samples, field)
    field = field or "rollRate"
    if #samples == 0 then return nil end
    local peak = 0
    for _, sample in ipairs(samples) do
        local magnitude = math.abs(sample[field] or 0)
        if magnitude > peak then peak = magnitude end
    end
    if peak <= 0 then return nil, peak end

    local target = peak / math.exp(1)
    -- The first time it drops below the target AND STAYS below for a second:
    -- a single sample dipping through zero mid-oscillation is not decay.
    for index, sample in ipairs(samples) do
        if math.abs(sample[field] or 0) <= target then
            local stayed, checked = true, 0
            for ahead = index, #samples do
                if samples[ahead].t - sample.t > 1.0 then break end
                checked = checked + 1
                if math.abs(samples[ahead][field] or 0) > target then
                    stayed = false
                    break
                end
            end
            if stayed and checked > 1 then
                return sample.t - samples[1].t, peak
            end
        end
    end
    return nil, peak
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
--
-- `options.signs` overrides the pattern, which is how the PITCH damper uses
-- this same function: roll is port/starboard, pitch is fore/aft, and the only
-- difference between the two dampers is which four numbers go here.
rolldamp.ROLL_SIGNS = { FL = 1, FR = -1, RL = 1, RR = -1 }

function rolldamp.cornerRpm(baseRpm, differential, options)
    options = options or {}
    local floor = options.minimumRpm or 8
    local signs = options.signs or rolldamp.ROLL_SIGNS

    local result = {}
    for corner, sign in pairs(signs) do
        local rpm = (baseRpm or 0) + sign * (differential or 0)
        if rpm < floor then rpm = floor end
        result[corner] = math.floor(rpm + 0.5)
    end
    return result
end

return rolldamp
