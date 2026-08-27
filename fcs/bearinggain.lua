-- What a degree of bearing tilt is WORTH, at the rpm and the mass the craft
-- actually has right now.
--
-- ---------------------------------------------------------------------------
-- WHY THIS EXISTS: the number it replaces was a CONSTANT, and it was measured
-- under conditions the craft never flies in.
--
-- `fcs/trim.lua` and `lateralhold.terminalSpeed` both carry
-- thrustPerBearing = 13960.98. That figure is real -- it reproduces
-- vectorprobe's 3886.3 N at 8 degrees exactly -- but it is the reading at
-- 16 RPM, taken ON THE GROUND, on the craft as it was massed that day. The
-- craft flies at 64 rpm, above the ground, and gains mass every time a machine
-- is bolted to the hull. Every drift figure built on that constant is
-- therefore wrong by a factor nobody had bounded, which is what blocked the
-- velocity loop.
--
-- THE MEASUREMENT WAS ALREADY IN THE FILE. getThrust is exactly LINEAR in rpm
-- -- r^2 = 1.000000 across 8 to 96 RPM, which brackets both 16 and 64 -- so
-- the bearing thrust at flight rpm is not a mystery to be flown for. It is
-- 4x, and the lateral force built from it is 4x with it. What was missing was
-- not data; it was that two files stored a number instead of reading one.
--
-- SO NOTHING HERE IS STORED. Every function takes the live inputs:
--
--     thrustPerBearing   getThrust, pushed by the pods every ~1 s
--     weight             getMass * gravity, read per flight
--     pressure           air density at the propellers' altitude
--
-- and the reference constants below exist ONLY to check a live reading against
-- the day it was calibrated. Nothing in a control path should use them.
--
-- THAT IS ALSO THE ANSWER TO A MOVING CRAFT. As machines are added the mass
-- rises and the centre of mass shifts, so a stored gain silently decays and a
-- stored trim becomes a standing error. A gain computed from live telemetry
-- tracks the craft instead: same code, heavier hull, correct number.
--
-- ---------------------------------------------------------------------------
-- THE PRESSURE FACTOR, and the honest doubt about it.
--
-- getThrust reports the value BEFORE the air-density factor; the real force is
-- getThrust x pressure at the PROPELLER's altitude (x1.353 at the usual hover,
-- per /fcs/airprofile.lua). Vertical lift is measured to obey that exactly.
--
-- Whether the LATERAL component takes the same factor is not separately
-- measured -- it is the same force vector, so it should, but "should" is what
-- this project keeps being wrong about. So pressure is a PARAMETER here,
-- defaulting to 1.0 (uncorrected), and every caller says what it is assuming.
-- Passing 1.0 reproduces the old model exactly at 16 rpm, which is what the
-- tests pin.

local bearinggain = {}

-- The calibration day, for comparison ONLY. A control path that reads these
-- has reintroduced the bug this file exists to remove.
bearinggain.REFERENCE = {
    thrustPerBearing = 13960.98,   -- getThrust, per bearing, at 16 rpm, ground
    rpm = 16,
    -- Craft-wide: 4 corners x 2 counter-rotating bearings.
    bearingsPerCorner = 2,
    corners = 4,
    -- Craft-wide getThrust per rpm, from the 8-96 rpm sweep. 6968.34 / 8
    -- bearings = 871.04 per bearing per rpm, against 13960.98 / 16 = 872.56 --
    -- 0.17% apart, which is how we know the two measurements are of the same
    -- quantity.
    craftThrustPerRpm = 6968.34,
}

bearinggain.ENVIRONMENT = {
    gravity = 11.0,
    universalDrag = 0.09,
    -- The weight on the calibration day. A DEFAULT, not a constant: pass the
    -- live getMass x gravity whenever there is one.
    weight = 1158293.4,
}

local function option(options, key, fallback)
    local value = options and options[key]
    if type(value) == "number" then return value end
    return fallback
end

-- Total bearings making lateral force. Eight on this craft, but read from the
-- telemetry rather than assumed -- a corner whose bearings are not assembled
-- contributes nothing, and a probe that tilts ONE corner is counting two.
function bearinggain.bearingCount(options)
    local corners = option(options, "corners", bearinggain.REFERENCE.corners)
    local perCorner = option(options, "bearingsPerCorner",
        bearinggain.REFERENCE.bearingsPerCorner)
    return corners * perCorner
end

-- The lateral force a commanded tilt produces, in the same units getThrust
-- reports. This is the measured law -- 2*T*sin(tilt) per corner, linear to
-- 0.06% over 4/6/8 degrees -- with the count and the thrust both live.
function bearinggain.lateralForce(tiltDegrees, options)
    local thrust = option(options, "thrustPerBearing",
        bearinggain.REFERENCE.thrustPerBearing)
    local pressure = option(options, "pressure", 1.0)
    local count = bearinggain.bearingCount(options)
    return count * thrust * pressure * math.sin(math.rad(tiltDegrees or 0))
end

-- Terminal ground speed a commanded tilt buys, against Create's universal drag.
--
-- Returns speed and the acceleration behind it. Same shape as
-- trim.bearingDrift, which it is meant to replace: that one hard-codes the
-- 16 rpm thrust and the calibration-day weight.
function bearinggain.driftFor(tiltDegrees, options)
    local gravity = option(options, "gravity", bearinggain.ENVIRONMENT.gravity)
    local drag = option(options, "universalDrag",
        bearinggain.ENVIRONMENT.universalDrag)
    local weight = option(options, "weight", bearinggain.ENVIRONMENT.weight)
    if drag <= 0 or weight <= 0 then return nil end

    local force = bearinggain.lateralForce(tiltDegrees, options)
    local acceleration = (force / weight) * gravity
    return acceleration / drag, acceleration
end

-- The slope the velocity loop needs: blocks/s of terminal drift per DEGREE of
-- commanded tilt. Taken at 1 degree rather than differentiated, because sin is
-- linear to 0.005% there and the loop never commands a large tilt anyway.
function bearinggain.perDegree(options)
    return (bearinggain.driftFor(1.0, options))
end

-- Weight from a live getMass, so callers do not have to remember which way
-- round it goes.
function bearinggain.weightFromMass(mass, gravity)
    if type(mass) ~= "number" or mass <= 0 then return nil end
    return mass * (gravity or bearinggain.ENVIRONMENT.gravity)
end

-- The inverse: what per-bearing thrust a MEASURED drift implies. This is how a
-- flight cross-check is scored against the telemetry -- if the craft drifts
-- less than getThrust says it should, the gap is real and it is the pressure
-- factor or the lateral law, not the rpm.
function bearinggain.impliedThrust(driftPerDegree, options)
    if type(driftPerDegree) ~= "number" then return nil end
    local gravity = option(options, "gravity", bearinggain.ENVIRONMENT.gravity)
    local drag = option(options, "universalDrag",
        bearinggain.ENVIRONMENT.universalDrag)
    local weight = option(options, "weight", bearinggain.ENVIRONMENT.weight)
    local pressure = option(options, "pressure", 1.0)
    local count = bearinggain.bearingCount(options)
    local denominator = count * pressure * math.sin(math.rad(1.0)) * gravity
    if denominator == 0 or drag <= 0 then return nil end
    return driftPerDegree * drag * weight / denominator
end

-- ---------------------------------------------------------------------------
-- The scaling law, fitted rather than assumed
-- ---------------------------------------------------------------------------

-- Fit thrust against rpm from a sweep: { { rpm = 16, thrust = ... }, ... }.
--
-- Returns { perRpm, exponent, r2, samples, spread }.
--
--   perRpm    the linear slope through the origin -- the useful number
--   exponent  the log-log slope: 1.0 linear, 2.0 the classic square law
--   spread    max/min of thrust/rpm across the sweep, which is the honest
--             linearity check on four points and does not flatter itself the
--             way r^2 does
--
-- WHY BOTH. This project has been burned by a fit that agreed with a wrong
-- model (the 4.49 ratio bound that passed run 18). A square law and a linear
-- law both fit two points perfectly; the exponent is what tells them apart,
-- and it needs at least three rpms to mean anything.
function bearinggain.fitScaling(samples)
    if type(samples) ~= "table" then return nil, "no samples" end

    local usable = {}
    for _, sample in ipairs(samples) do
        local rpm = sample.rpm or sample[1]
        local thrust = sample.thrust or sample[2]
        if type(rpm) == "number" and type(thrust) == "number"
            and rpm > 0 and math.abs(thrust) > 0 then
            usable[#usable + 1] = { rpm = rpm, thrust = math.abs(thrust) }
        end
    end
    if #usable < 2 then return nil, "need two rpms with thrust" end

    -- Slope through the origin: sum(x*y) / sum(x*x). Through the origin
    -- because zero rpm makes zero thrust -- an intercept here would be fitting
    -- noise into a physical impossibility.
    local sxy, sxx = 0, 0
    local minRatio, maxRatio = math.huge, -math.huge
    for _, sample in ipairs(usable) do
        sxy = sxy + sample.rpm * sample.thrust
        sxx = sxx + sample.rpm * sample.rpm
        local ratio = sample.thrust / sample.rpm
        if ratio < minRatio then minRatio = ratio end
        if ratio > maxRatio then maxRatio = ratio end
    end
    local perRpm = sxx > 0 and (sxy / sxx) or nil

    -- r^2 of that fit, against the mean.
    local mean, total = 0, 0
    for _, sample in ipairs(usable) do mean = mean + sample.thrust end
    mean = mean / #usable
    local residual = 0
    for _, sample in ipairs(usable) do
        local predicted = perRpm * sample.rpm
        residual = residual + (sample.thrust - predicted) ^ 2
        total = total + (sample.thrust - mean) ^ 2
    end
    local r2 = total > 0 and (1 - residual / total) or nil

    -- Log-log slope: thrust = k * rpm^n.
    local exponent
    if #usable >= 2 then
        local n = #usable
        local sx, sy, sxxLog, sxyLog = 0, 0, 0, 0
        for _, sample in ipairs(usable) do
            local x, y = math.log(sample.rpm), math.log(sample.thrust)
            sx, sy = sx + x, sy + y
            sxxLog = sxxLog + x * x
            sxyLog = sxyLog + x * y
        end
        local denominator = n * sxxLog - sx * sx
        if math.abs(denominator) > 1e-12 then
            exponent = (n * sxyLog - sx * sy) / denominator
        end
    end

    -- AFFINE: thrust = slope * rpm + offset, fitted WITHOUT forcing the
    -- origin. The craft needed this on its first real sweep. Proportional
    -- fitting made thrust/rpm climb 844.95 -> 865.94 across 16-64 and the
    -- verdict came out NONLINEAR, which read as "this reading says nothing
    -- about another rpm" -- alarming, and wrong. The data is a straight line
    -- with a small NEGATIVE offset: 872.49 per rpm less 442.6, r^2 = 0.999997,
    -- every point inside 0.11%.
    --
    -- And that slope is the recorded 872.56 to 0.0085%. The offset is what a
    -- through-the-origin fit has to absorb by bending, and it is only 0.8% of
    -- the thrust at 64 rpm against 3.3% at 16 -- which is exactly the shape
    -- that makes a low-rpm calibration read high per rpm.
    local slope, offset, affineR2
    if #usable >= 3 then
        local n = #usable
        local meanX, meanY = 0, 0
        for _, sample in ipairs(usable) do
            meanX, meanY = meanX + sample.rpm, meanY + sample.thrust
        end
        meanX, meanY = meanX / n, meanY / n
        local covariance, variance = 0, 0
        for _, sample in ipairs(usable) do
            covariance = covariance + (sample.rpm - meanX) * (sample.thrust - meanY)
            variance = variance + (sample.rpm - meanX) ^ 2
        end
        if variance > 0 then
            slope = covariance / variance
            offset = meanY - slope * meanX
            local affineResidual, affineTotal = 0, 0
            for _, sample in ipairs(usable) do
                affineResidual = affineResidual
                    + (sample.thrust - (slope * sample.rpm + offset)) ^ 2
                affineTotal = affineTotal + (sample.thrust - meanY) ^ 2
            end
            if affineTotal > 0 then affineR2 = 1 - affineResidual / affineTotal end
        end
    end

    return {
        perRpm = perRpm,
        exponent = exponent,
        r2 = r2,
        samples = #usable,
        spread = minRatio > 0 and (maxRatio / minRatio) or nil,
        slope = slope,
        offset = offset,
        affineR2 = affineR2,
        -- How much of the top reading the offset accounts for. Small means the
        -- straight line is the whole story; large means it is a threshold
        -- effect that a proportional model would misread badly.
        offsetShare = (slope and offset and maxRatio > 0)
            and math.abs(offset) / math.abs(slope * usable[#usable].rpm + offset)
            or nil,
    }
end

-- What the fit says the thrust is at some other rpm. Extrapolation is stated
-- as such: the sweep that produced the fit is the only range it is entitled to.
function bearinggain.thrustAtRpm(fit, rpm)
    if not fit or not fit.perRpm or type(rpm) ~= "number" then return nil end
    return fit.perRpm * rpm
end

bearinggain.LINEAR_SPREAD_LIMIT = 1.02
bearinggain.AFFINE_R2_LIMIT = 0.999
-- An offset worth more than a tenth of the top reading is not a straight line
-- with a quirk, it is a threshold, and extrapolating through it is a mistake.
bearinggain.OFFSET_SHARE_LIMIT = 0.10

-- Is the sweep linear enough to extrapolate from? A verdict rather than a
-- number, because the caller has to decide whether to trust a gain built on it.
--
-- THREE ANSWERS, NOT TWO, because the craft turned out to be the third. A
-- proportional fit bends to absorb a constant offset and the spread test then
-- reports NONLINEAR on data that is a textbook straight line. LINEAR+OFFSET is
-- as good as LINEAR for reading a gain AT a measured rpm, and it is the
-- warning you want when extrapolating DOWN toward zero rpm, where the offset
-- is the whole signal.
function bearinggain.scalingVerdict(fit)
    if not fit then return "NO FIT" end
    if fit.samples < 3 then return "TOO FEW RPMS" end
    if fit.spread and fit.spread <= bearinggain.LINEAR_SPREAD_LIMIT then
        return "LINEAR"
    end
    if fit.affineR2 and fit.affineR2 >= bearinggain.AFFINE_R2_LIMIT
        and fit.offsetShare
        and fit.offsetShare <= bearinggain.OFFSET_SHARE_LIMIT then
        return "LINEAR+OFFSET"
    end
    if fit.exponent and fit.exponent > 1.6 then return "SUPERLINEAR" end
    return "NONLINEAR"
end

-- Does a verdict entitle the caller to read a gain at the rpm it measured?
-- Both linear answers do; a curved or truncated sweep does not.
function bearinggain.usableAtMeasuredRpm(verdict)
    return verdict == "LINEAR" or verdict == "LINEAR+OFFSET"
end

-- How far a live reading has moved from the calibration day, as a ratio. This
-- is the number that says whether a stored gain is still safe to use -- and on
-- this craft at flight rpm it is about 4.
function bearinggain.driftFromReference(thrustPerBearing)
    if type(thrustPerBearing) ~= "number" then return nil end
    local reference = bearinggain.REFERENCE.thrustPerBearing
    if reference == 0 then return nil end
    return math.abs(thrustPerBearing) / reference
end

return bearinggain
