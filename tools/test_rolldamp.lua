-- Differential-RPM roll damping: is it the right size, and does it oppose?
--
-- The prediction this rests on is worth stating, because two previous
-- actuators were talked up and then failed in flight:
--
--   ions          predicted 28x too coarse -> confirmed useless
--   bearing tilt  predicted a strong pure couple -> rolled 0.07 deg in 3 s,
--                 because its torque needs a VERTICAL moment arm nobody had
--                 measured
--   differential  makes a VERTICAL force at a LATERAL arm -- the geometry
--   RPM           craftgeom already solves, validated by runs 9 and 10 at
--                 97% and 102% of its ceiling
--
-- So these assertions are checking arithmetic over measured inputs, not a
-- guess about where something is mounted.
--
--     luajit tools/test_rolldamp.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local rolldamp = require("fcs.rolldamp")
local craftgeom = require("fcs.craftgeom")
local config = require("fcs.config")

local passed, failed = 0, 0
local function check(label, got, want, tolerance)
    if type(got) == "number" and math.abs(got - want) <= (tolerance or 1e-9) then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL %-56s got %s want %.4f", label, tostring(got), want))
    end
end
local function checkTrue(label, condition)
    if condition then passed = passed + 1 else
        failed = failed + 1
        print(string.format("FAIL %-56s (expected true)", label))
    end
end

-- --------------------------------------------------------------------------
-- The arm must be the SAME one craftgeom derives -- not a second, drifting copy.
-- --------------------------------------------------------------------------
local TENSOR = {
    { 389383646.66189605, 2818192.7656108057, -4641931.7102072081 },
    { 2818192.7656108057, 435883852.97585285, 28031283.72369967 },
    { -4641931.7102072081, 28031283.72369967, 86772714.934104145 },
    rows = 3, columns = 3,
}
local box = craftgeom.solveBox(TENSOR, 105299.4, config.axes)
local arms = craftgeom.armBound(box)
check("the lateral arm matches craftgeom's hull box",
    rolldamp.MEASURED.lateralArm, arms.lateral, 0.01)
check("the roll inertia is the tensor's bow axis t[3][3]",
    rolldamp.MEASURED.rollInertia, TENSOR[3][3], 1)

-- --------------------------------------------------------------------------
-- Authority. The headline: one RPM is about critical damping.
-- --------------------------------------------------------------------------
local perRpm, perCorner = rolldamp.authorityPerRpm()
check("2357 per RPM per corner after the density correction", perCorner, 2357.0, 0.5)
check("+/-1 RPM gives 0.2712 deg/s^2", perRpm, 0.2712, 0.001)

local critical = rolldamp.criticalDamping()
check("critical damping for the measured spring", critical, 0.2987, 0.001)
checkTrue("one RPM is at least 85% of critical damping", perRpm / critical > 0.85)
checkTrue("...and does not wildly exceed it (which would mean 1 bit is too big)",
    perRpm / critical < 1.5)

-- Against the actuator it replaces: one ion level is 7.42 deg/s^2.
checkTrue("differential RPM is at least 20x finer than one ion level",
    7.42 / perRpm > 20)

-- --------------------------------------------------------------------------
-- Direction. Getting this backwards is the runaway, twice over.
-- --------------------------------------------------------------------------
checkTrue("rolling one way commands the opposite differential",
    rolldamp.differentialFor(1.0) < 0)
checkTrue("rolling the other way commands the other differential",
    rolldamp.differentialFor(-1.0) > 0)
check("a still craft commands nothing", rolldamp.differentialFor(0), 0)
check("inside the deadband commands nothing", rolldamp.differentialFor(0.01), 0)

-- THE DEFAULT IS THE MEASURED AUTHORITY, NOT THE MODEL.
--
-- This assertion used to read "the 0.90 deg/s peak asks for 1 RPM", which was
-- the answer the thrust-model prediction gives. The model reads 2.9x high, so
-- a damper defaulting to it asks for ONE rpm where THREE are needed and
-- under-damps by that factor -- silently, with a number that looks reasonable.
-- The measured authority is now what differentialFor uses when no option is
-- passed, and these pin that so it cannot quietly revert.
check("the strafe's 0.90 deg/s peak asks for 3 RPM by DEFAULT",
    math.abs(rolldamp.differentialFor(0.90)), 3)
check("the default equals the flight-measured authority, explicitly passed",
    rolldamp.differentialFor(0.90),
    rolldamp.differentialFor(0.90,
        { authorityPerRpm = rolldamp.MEASURED.flightAuthorityPerRpm }))
checkTrue("...and is NOT the model's answer",
    rolldamp.differentialFor(0.90)
        ~= rolldamp.differentialFor(0.90, { authorityPerRpm = perRpm }))
check("the model would have asked for 1", 
    math.abs(rolldamp.differentialFor(0.90, { authorityPerRpm = perRpm })), 1)
check("the measured authority is the three-flight figure",
    rolldamp.MEASURED.flightAuthorityPerRpm, 0.0941, 1e-9)

-- Clamped, symmetrically.
check("a violent rate clamps", rolldamp.differentialFor(-99),
    rolldamp.DEFAULTS.maxDifferentialRpm)
check("...and the other way", rolldamp.differentialFor(99),
    -rolldamp.DEFAULTS.maxDifferentialRpm)

-- INTEGER, always. A fractional command would be rounded away pod-side and the
-- caller would be reasoning about a torque the craft is not making.
for _, rate in ipairs({ 0.1, 0.37, 0.5, 0.9, 1.4, 2.2, -0.6, -1.9 }) do
    local value = rolldamp.differentialFor(rate)
    check(string.format("differential for %.2f deg/s is an integer", rate),
        value - math.floor(value + 0.5), 0)
end

-- --------------------------------------------------------------------------
-- Per-corner RPM.
-- --------------------------------------------------------------------------
local corners = rolldamp.cornerRpm(64, 2)
check("positive differential raises FL (port)", corners.FL, 66)
check("...and RL (port)", corners.RL, 66)
check("...and lowers FR (starboard)", corners.FR, 62)
check("...and RR (starboard)", corners.RR, 62)
check("the corner mean is unchanged, so total lift holds",
    (corners.FL + corners.FR + corners.RL + corners.RR) / 4, 64, 1e-9)

-- The floor. A corner losing its props is not a small event: the last hover
-- run had FR drop to 0 and the craft rolled past 28 degrees.
local starved = rolldamp.cornerRpm(9, 4)
checkTrue("a corner is never commanded below the floor", starved.FR >= 8)
checkTrue("...on either starboard corner", starved.RR >= 8)

-- --------------------------------------------------------------------------
-- MEASURED IN FLIGHT, 2026-08-26. Two paired levels, linear to 2%:
--     2 rpm  alpha 0.1820  ->  0.0910 per rpm
--     3 rpm  alpha 0.2793  ->  0.0931 per rpm
--     staircase through the origin: 0.0924 per rpm, 34% of prediction
-- --------------------------------------------------------------------------
local MEASURED_PER_RPM = 0.0924
check("the measured staircase is linear across its two levels",
    (0.1820 / 2) / (0.2793 / 3), 1.0, 0.03)

-- What matters is the CLAMP against critical damping, not one rpm. A verdict
-- that tests one rpm calls 31% "too weak" and throws away a working damper.
local reachable = MEASURED_PER_RPM * rolldamp.DEFAULTS.maxDifferentialRpm
checkTrue("the clamp reaches critical damping at the MEASURED authority",
    reachable >= critical)
check("critical damping arrives at about 3.2 rpm",
    critical / MEASURED_PER_RPM, 3.2, 0.1)

-- Coming in under prediction buys resolution. At the predicted value one rpm
-- would be 91% of critical -- a nearly one-bit actuator.
checkTrue("the measured authority gives at least 3 usable steps",
    critical / MEASURED_PER_RPM >= 3)
checkTrue("...where the prediction would have given barely one",
    critical / perRpm < 1.5)

-- And the damper asks for something inside the clamp at the strafe's peak.
local asked = math.abs(rolldamp.differentialFor(0.90,
    { authorityPerRpm = MEASURED_PER_RPM }))
checkTrue("at the 0.90 deg/s peak it asks for a differential inside the clamp",
    asked <= rolldamp.DEFAULTS.maxDifferentialRpm)
check("...specifically 3 rpm", asked, 3)

-- --------------------------------------------------------------------------
-- The rate estimator.
--
-- The damper needs a roll RATE and the craft will not give it one: Session:rates
-- reads 0.0000 in a third of samples and readCheap omits angular velocity
-- entirely. So the rate is a least-squares slope over angles, and it has to be
-- right -- a rate estimate with the wrong SIGN turns the damper into a driver,
-- and one with too much lag does the same at the frequencies that matter.
-- --------------------------------------------------------------------------

local estimator = rolldamp.newRateEstimator({ windowSeconds = 0.6 })
checkTrue("a fresh estimator has no rate", estimator:rate() == nil)
estimator:push(0.0, 0.0)
checkTrue("one sample is not a rate", estimator:rate() == nil)
estimator:push(0.15, 0.15)
checkTrue("two samples is still not a rate", estimator:rate() == nil)
estimator:push(0.30, 0.30)
check("a clean 1.0 deg/s ramp reads 1.0", estimator:rate(), 1.0, 1e-6)

-- Sign, which is the one that turns a damper into a driver.
local falling = rolldamp.newRateEstimator()
for index = 0, 5 do falling:push(index * 0.15, -0.5 * index * 0.15) end
checkTrue("a falling angle gives a NEGATIVE rate", falling:rate() < 0)
check("...of the right size", falling:rate(), -0.5, 1e-6)

-- The window really does slide, or the estimate becomes an average over the
-- whole run and the damper responds to history rather than to now.
local sliding = rolldamp.newRateEstimator({ windowSeconds = 0.6 })
for index = 0, 20 do sliding:push(index * 0.15, 0) end          -- flat, then
for index = 21, 30 do sliding:push(index * 0.15, (index - 20) * 0.15 * 2) end
checkTrue("the window slides: an old flat stretch is forgotten",
    math.abs(sliding:rate() - 2.0) < 0.2)
checkTrue("...and the window is bounded", sliding:count() <= 6)

-- Quantised angles: the craft reports to limited precision, and a first
-- difference of two quantised samples is mostly noise. The slope over a window
-- should still find the trend.
local noisy = rolldamp.newRateEstimator({ windowSeconds = 0.6 })
local quantum = 0.01
for index = 0, 5 do
    local trueAngle = 0.9 * index * 0.15
    noisy:push(index * 0.15, math.floor(trueAngle / quantum + 0.5) * quantum)
end
checkTrue("a quantised 0.9 deg/s ramp still reads about 0.9",
    math.abs(noisy:rate() - 0.9) < 0.15)

-- A stalled clock is meaningless, not infinite.
local stalled = rolldamp.newRateEstimator()
for _ = 1, 5 do stalled:push(1.0, 0.5) end
checkTrue("every sample at one instant has no rate", stalled:rate() == nil)

-- And the whole chain end to end: a craft rolling positive must be answered
-- with a negative differential, computed from angles alone.
local chain = rolldamp.newRateEstimator()
for index = 0, 5 do chain:push(index * 0.15, 0.9 * index * 0.15) end
checkTrue("angles -> rate -> differential opposes the motion",
    rolldamp.differentialFor(chain:rate()) < 0)
check("...and asks for the full 3 rpm at the strafe's peak rate",
    math.abs(rolldamp.differentialFor(chain:rate())), 3)


-- --------------------------------------------------------------------------
-- THE REAL TRACE, run 1, 2026-08-27 (flight-logs/rolldampflight_run1.txt).
--
-- Every sample below was logged by the craft. The analysis that reads a flight
-- back is pinned to it, because run 1 proved the analysis can be wrong in ways
-- the flight is not: the naive crossing count reported the damped half as
-- WORSE than the undamped one, purely by tallying sign flips of a trace that
-- had finished and was sitting at zero.
-- --------------------------------------------------------------------------

local RUN1_OFF = {
    { t = 0.00, rollRate = 0.810 },
    { t = 0.75, rollRate = 1.037 },
    { t = 1.40, rollRate = 1.184 },
    { t = 2.10, rollRate = 1.163 },
    { t = 2.75, rollRate = 1.009 },
    { t = 3.46, rollRate = 0.763 },
    { t = 4.15, rollRate = 0.535 },
    { t = 4.80, rollRate = 0.347 },
    { t = 5.50, rollRate = 0.139 },
    { t = 6.15, rollRate = -0.044 },
    { t = 6.85, rollRate = -0.200 },
    { t = 7.55, rollRate = -0.323 },
    { t = 8.30, rollRate = -0.426 },
    { t = 9.05, rollRate = -0.539 },
    { t = 9.65, rollRate = -0.534 },
    { t = 10.30, rollRate = -0.578 },
    { t = 11.00, rollRate = -0.575 },
    { t = 11.70, rollRate = -0.571 },
    { t = 12.35, rollRate = -0.598 },
    { t = 13.00, rollRate = -0.564 },
    { t = 13.75, rollRate = -0.528 },
    { t = 14.40, rollRate = -0.529 },
    { t = 15.05, rollRate = -0.526 },
    { t = 15.75, rollRate = -0.440 },
    { t = 16.46, rollRate = -0.412 },
    { t = 17.15, rollRate = -0.420 },
    { t = 17.75, rollRate = -0.358 },
    { t = 18.50, rollRate = -0.314 },
    { t = 19.20, rollRate = -0.273 },
    { t = 19.85, rollRate = -0.210 },
    { t = 20.65, rollRate = -0.153 },
    { t = 21.30, rollRate = -0.115 },
    { t = 22.01, rollRate = -0.064 },
    { t = 22.82, rollRate = -0.015 },
    { t = 23.45, rollRate = 0.016 },
    { t = 24.10, rollRate = 0.045 },
    { t = 24.80, rollRate = 0.075 },
    { t = 25.45, rollRate = 0.094 },
    { t = 26.15, rollRate = 0.116 },
    { t = 26.80, rollRate = 0.125 },
    { t = 27.45, rollRate = 0.119 },
    { t = 28.15, rollRate = 0.128 },
    { t = 28.83, rollRate = 0.126 },
    { t = 29.45, rollRate = 0.141 },
    { t = 30.20, rollRate = 0.132 },
    { t = 30.80, rollRate = 0.113 },
    { t = 31.50, rollRate = 0.108 },
    { t = 32.30, rollRate = 0.094 },
    { t = 32.95, rollRate = 0.077 },
    { t = 33.65, rollRate = 0.068 },
    { t = 34.35, rollRate = 0.051 },
    { t = 35.05, rollRate = 0.038 },
    { t = 35.80, rollRate = 0.027 },
    { t = 36.45, rollRate = 0.014 },
    { t = 37.20, rollRate = 0.004 },
    { t = 37.85, rollRate = -0.004 },
    { t = 38.50, rollRate = -0.011 },
    { t = 39.20, rollRate = -0.020 },
    { t = 39.80, rollRate = -0.026 },
}

local RUN1_ON = {
    { t = 0.00, rollRate = 0.764 },
    { t = 0.65, rollRate = 1.096 },
    { t = 1.36, rollRate = 0.995 },
    { t = 2.05, rollRate = 0.724 },
    { t = 2.75, rollRate = 0.352 },
    { t = 3.40, rollRate = -0.004 },
    { t = 4.11, rollRate = -0.322 },
    { t = 4.91, rollRate = -0.527 },
    { t = 5.60, rollRate = -0.542 },
    { t = 6.35, rollRate = -0.445 },
    { t = 6.95, rollRate = -0.276 },
    { t = 7.60, rollRate = -0.146 },
    { t = 8.25, rollRate = -0.036 },
    { t = 8.95, rollRate = 0.044 },
    { t = 9.70, rollRate = 0.072 },
    { t = 10.45, rollRate = 0.063 },
    { t = 11.05, rollRate = 0.038 },
    { t = 11.75, rollRate = 0.002 },
    { t = 12.45, rollRate = -0.040 },
    { t = 13.15, rollRate = -0.083 },
    { t = 13.85, rollRate = -0.122 },
    { t = 14.55, rollRate = -0.145 },
    { t = 15.20, rollRate = -0.179 },
    { t = 15.85, rollRate = -0.160 },
    { t = 16.51, rollRate = -0.104 },
    { t = 17.15, rollRate = -0.076 },
    { t = 17.80, rollRate = -0.059 },
    { t = 18.45, rollRate = -0.059 },
    { t = 19.10, rollRate = -0.068 },
    { t = 19.80, rollRate = -0.071 },
    { t = 20.45, rollRate = -0.082 },
    { t = 21.10, rollRate = -0.099 },
    { t = 21.80, rollRate = -0.117 },
    { t = 22.55, rollRate = -0.127 },
    { t = 23.20, rollRate = -0.123 },
    { t = 23.90, rollRate = -0.129 },
    { t = 24.60, rollRate = -0.138 },
    { t = 25.30, rollRate = -0.120 },
    { t = 25.95, rollRate = -0.117 },
    { t = 26.60, rollRate = -0.120 },
    { t = 27.30, rollRate = -0.114 },
    { t = 27.95, rollRate = -0.113 },
    { t = 28.61, rollRate = -0.092 },
    { t = 29.30, rollRate = -0.074 },
    { t = 30.00, rollRate = -0.066 },
    { t = 30.70, rollRate = -0.054 },
    { t = 31.40, rollRate = -0.038 },
    { t = 32.00, rollRate = -0.027 },
    { t = 32.70, rollRate = -0.019 },
    { t = 33.35, rollRate = -0.008 },
    { t = 34.05, rollRate = 0.000 },
    { t = 34.70, rollRate = 0.009 },
    { t = 35.40, rollRate = 0.017 },
    { t = 36.09, rollRate = 0.021 },
    { t = 36.75, rollRate = 0.030 },
    { t = 37.45, rollRate = 0.033 },
    { t = 38.10, rollRate = 0.035 },
    { t = 38.80, rollRate = 0.036 },
    { t = 39.50, rollRate = 0.035 },
}

-- Hysteresis. The floor is the damper's own deadband: motion below it is not
-- oscillation the damper is failing to stop.
local naiveOff, naiveOn = 0, 0
for _, half in ipairs({ { RUN1_OFF, "off" }, { RUN1_ON, "on" } }) do
    local previous = nil
    for _, sample in ipairs(half[1]) do
        if previous and (previous > 0) ~= (sample.rollRate > 0) then
            if half[2] == "off" then naiveOff = naiveOff + 1 else naiveOn = naiveOn + 1 end
        end
        previous = sample.rollRate
    end
end
checkTrue("the NAIVE count called the damped half worse (this is the bug)",
    naiveOn > naiveOff)

local offCross = rolldamp.zeroCrossings(RUN1_OFF)
local onCross = rolldamp.zeroCrossings(RUN1_ON)
check("run 1 undamped crossings, above the deadband", offCross, 2)
check("run 1 damped crossings, above the deadband", onCross, 3)
checkTrue("hysteresis removes the noise crossings", offCross < naiveOff and onCross < naiveOn)

-- HONEST LIMIT, stated as a test so nobody reads the metric for more than it
-- is worth: crossings are AMPLITUDE-BLIND. The damped half still crosses more
-- often, because it arrests the big swing early and then drifts slowly across
-- zero at a tenth of the amplitude. Peak excursion and decay time are the
-- metrics that carry the result; this one is a diagnostic.
checkTrue("crossings alone do NOT show the damper working", onCross >= offCross)

-- Decay, which does.
local offDecay = rolldamp.decayTime(RUN1_OFF)
local onDecay = rolldamp.decayTime(RUN1_ON)
checkTrue("run 1: the damped half decayed faster", onDecay < offDecay)
check("run 1 undamped decay", offDecay, 4.6, 0.4)
check("run 1 damped decay", onDecay, 2.8, 0.4)

-- THE AUTHORITY, re-measured from run 1's undamped pulse: 3 rpm, 3.0 s.
local authority, peak, seconds =
    rolldamp.authorityFromPulse(RUN1_OFF, 3, 3.0)
check("run 1 re-measures the authority at 0.0897", authority, 0.0897, 0.002)
check("...from a peak of 1.184 deg/s", peak, 1.184, 0.001)
check("...over 3.0 s of pulse plus 1.4 s of prop spin-down", seconds, 4.4, 0.01)

-- Which is the point: an INDEPENDENT measurement, from a different manoeuvre,
-- agreeing with the three that set the stored value.
local drift = (authority - rolldamp.MEASURED.flightAuthorityPerRpm)
    / rolldamp.MEASURED.flightAuthorityPerRpm
checkTrue("run 1 agrees with the stored authority within 10%", math.abs(drift) < 0.10)

-- A pulse that did nothing has no authority to report, rather than a division
-- by a peak of zero.
checkTrue("a flat trace yields no authority",
    rolldamp.authorityFromPulse({ { t = 0, rollRate = 0 } }, 3, 3.0) == nil)
checkTrue("no samples yields no authority",
    rolldamp.authorityFromPulse({}, 3, 3.0) == nil)
checkTrue("a zero pulse yields no authority",
    rolldamp.authorityFromPulse(RUN1_OFF, 0, 3.0) == nil)

print("")
print(string.format("one RPM differential = %.4f deg/s^2 = %.0f%% of critical damping",
    perRpm, perRpm / critical * 100))
print(string.format("(one ion level, for comparison, is 7.42 -- %.0fx coarser)", 7.42 / perRpm))
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
