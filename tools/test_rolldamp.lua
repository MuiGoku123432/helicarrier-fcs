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

-- The strafe's peak rate is 0.90 deg/s. Critical damping there wants 0.268
-- deg/s^2, which is one RPM -- so the damper should ask for exactly that.
check("the strafe's 0.90 deg/s peak asks for 1 RPM",
    math.abs(rolldamp.differentialFor(0.90)), 1)

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

print("")
print(string.format("one RPM differential = %.4f deg/s^2 = %.0f%% of critical damping",
    perRpm, perRpm / critical * 100))
print(string.format("(one ion level, for comparison, is 7.42 -- %.0fx coarser)", 7.42 / perRpm))
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
