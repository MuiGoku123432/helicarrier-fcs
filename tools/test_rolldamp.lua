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

print("")
print(string.format("one RPM differential = %.4f deg/s^2 = %.0f%% of critical damping",
    perRpm, perRpm / critical * 100))
print(string.format("(one ion level, for comparison, is 7.42 -- %.0fx coarser)", 7.42 / perRpm))
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
