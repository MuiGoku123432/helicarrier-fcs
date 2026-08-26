-- Can the vectoring maths tell an ADDING bearing pair from a CANCELLING one?
--
-- That single distinction gates position hold, the strafe fix and yaw, and it
-- has never been measured on the craft. So it gets tested against BOTH
-- synthetic cases here, before the tool that measures it is believed:
-- a tool that cannot tell the two apart offline will not tell them apart
-- in-world, it will just print something.
--
-- The numbers are the craft's real ones -- thrust +/-13960.98 per bearing,
-- neutral vectors {0,1,0} and {0,-1,0} -- so a passing test says something
-- about this carrier and not about an invented one.
--
--     luajit tools/test_vectoring.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local vectoring = require("fcs.vectoring")
local craftgeom = require("fcs.craftgeom")
local config = require("fcs.config")

local passed, failed = 0, 0
local function check(label, got, want, tolerance)
    if type(got) == "number" and math.abs(got - want) <= (tolerance or 1e-9) then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL %-54s got %s want %.6f",
            label, tostring(got), want))
    end
end
local function checkEqual(label, got, want)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL %-54s got %s want %s",
            label, tostring(got), tostring(want)))
    end
end

local THRUST = 13960.98
local axes = config.axes

-- --------------------------------------------------------------------------
-- Shape handling. getThrustVector is an ARRAY; reading .x/.y/.z gives nil.
-- --------------------------------------------------------------------------
local asArray = vectoring.toXYZ({ 0.5, 1, -0.25 })
check("array {1,2,3} reads as x", asArray.x, 0.5)
check("array {1,2,3} reads as y", asArray.y, 1)
check("array {1,2,3} reads as z", asArray.z, -0.25)
local asNamed = vectoring.toXYZ({ x = 0.5, y = 1, z = -0.25 })
check("named {x=,y=,z=} still reads", asNamed.x, 0.5)
checkEqual("a non-vector is refused", vectoring.toXYZ(42), nil)

-- --------------------------------------------------------------------------
-- The neutral pair. Opposite vectors AND opposite thrusts -> both push UP.
-- --------------------------------------------------------------------------
local neutralPair = {
    { thrustVector = { 0, 1, 0 }, thrust = THRUST },
    { thrustVector = { 0, -1, 0 }, thrust = -THRUST },
}
local neutral = vectoring.cornerForce(neutralPair)
check("neutral pair lifts with both bearings", neutral.vertical, 2 * THRUST, 1e-6)
check("neutral pair has no lateral force", neutral.lateralOfSum, 0, 1e-9)
checkEqual("neutral pair reports NO_TILT", vectoring.verdict(neutral), vectoring.NO_TILT)

-- Taking |thrust| instead of the signed value is the easy mistake: it turns
-- the lifting pair into a cancelling one and inverts every answer below.
local unsigned = vectoring.cornerForce({
    { thrustVector = { 0, 1, 0 }, thrust = THRUST },
    { thrustVector = { 0, -1, 0 }, thrust = THRUST },
})
check("UNSIGNED thrust would cancel the lift (regression guard)",
    unsigned.vertical, 0, 1e-9)

-- --------------------------------------------------------------------------
-- CASE 1: the pair ADDS. Both bearings' lateral components point the same way.
-- --------------------------------------------------------------------------
local tilt = math.rad(5)
local addingPair = {
    { thrustVector = { math.sin(tilt), math.cos(tilt), 0 }, thrust = THRUST },
    { thrustVector = { -math.sin(tilt), -math.cos(tilt), 0 }, thrust = -THRUST },
}
local adding = vectoring.cornerForce(addingPair)
check("adding pair coherence is 1.0", adding.coherence, 1.0, 1e-9)
checkEqual("adding pair reports ADDS", vectoring.verdict(adding), vectoring.ADDS)
check("adding pair lateral force", adding.lateralOfSum,
    2 * THRUST * math.sin(tilt), 1e-6)
check("adding pair keeps its lift", adding.vertical,
    2 * THRUST * math.cos(tilt), 1e-6)

-- --------------------------------------------------------------------------
-- CASE 2: the pair CANCELS. The partner mirrors the tilt, so lift survives and
-- the lateral components annihilate. THIS IS THE OUTCOME THAT KILLS THE PLAN,
-- and the tool has to be able to say so.
-- --------------------------------------------------------------------------
local cancellingPair = {
    { thrustVector = { math.sin(tilt), math.cos(tilt), 0 }, thrust = THRUST },
    { thrustVector = { math.sin(tilt), -math.cos(tilt), 0 }, thrust = -THRUST },
}
local cancelling = vectoring.cornerForce(cancellingPair)
check("cancelling pair coherence is 0.0", cancelling.coherence, 0, 1e-9)
checkEqual("cancelling pair reports CANCELS",
    vectoring.verdict(cancelling), vectoring.CANCELS)
check("cancelling pair still lifts", cancelling.vertical,
    2 * THRUST * math.cos(tilt), 1e-6)
check("cancelling pair produces NO lateral force",
    cancelling.lateralOfSum, 0, 1e-9)

-- The two cases must not be confusable by lift alone -- lift is IDENTICAL in
-- both. Only the lateral sum separates them, which is why the tool measures it.
check("both cases lift identically (so lift cannot decide it)",
    adding.vertical - cancelling.vertical, 0, 1e-9)

-- Only ONE bearing tilted is genuinely coherent, not partial: there is nothing
-- for its lateral component to disagree with, and the craft really does feel
-- the whole of it. Pinned so the verdict band is not "fixed" into calling it
-- PARTIAL later.
local oneTilted = vectoring.cornerForce({
    { thrustVector = { math.sin(tilt), math.cos(tilt), 0 }, thrust = THRUST },
    { thrustVector = { 0, -1, 0 }, thrust = -THRUST },
})
checkEqual("one bearing tilted still ADDS", vectoring.verdict(oneTilted), vectoring.ADDS)
check("one bearing tilted gives HALF the lateral force",
    oneTilted.lateralOfSum, THRUST * math.sin(tilt), 1e-6)

-- PARTIAL is for laterals that point in DIFFERENT directions -- here 90 deg
-- apart, so the sum is 1/sqrt(2) of what perfect agreement would give.
local partial = vectoring.cornerForce({
    { thrustVector = { math.sin(tilt), math.cos(tilt), 0 }, thrust = THRUST },
    { thrustVector = { 0, -math.cos(tilt), -math.sin(tilt) }, thrust = -THRUST },
})
checkEqual("laterals 90 deg apart report PARTIAL",
    vectoring.verdict(partial), vectoring.PARTIAL)
check("...with coherence 1/sqrt(2)", partial.coherence, 1 / math.sqrt(2), 1e-9)

-- --------------------------------------------------------------------------
-- Heading naming. +Z is the BOW and +X is PORT -- NOT what props.lua's
-- tiltTarget comment claims. These pin the corrected convention.
-- --------------------------------------------------------------------------
check("force along +Z reads as 0 deg (bow)",
    vectoring.headingFromBow({ x = 0, y = 0, z = 1 }, axes), 0, 1e-6)
check("force along -X reads as 90 deg (starboard)",
    vectoring.headingFromBow({ x = -1, y = 0, z = 0 }, axes), 90, 1e-6)
check("force along -Z reads as 180 deg (stern)",
    vectoring.headingFromBow({ x = 0, y = 0, z = -1 }, axes), 180, 1e-6)
check("force along +X reads as 270 deg (PORT, not bow)",
    vectoring.headingFromBow({ x = 1, y = 0, z = 0 }, axes), 270, 1e-6)
checkEqual("+X is named PORT", vectoring.describeHeading(270), "PORT")
checkEqual("+Z is named BOW", vectoring.describeHeading(0), "BOW")

-- The regression guard for the sixth instance of this project's signature bug:
-- props.lua's comment says azimuth 0 (which produces +X) points at the bow.
-- If +X ever reads as the bow again, the old convention is back.
local plusXHeading = vectoring.headingFromBow({ x = 1, y = 0, z = 0 }, axes)
checkEqual("+X must NOT be the bow (regression guard)",
    math.abs(plusXHeading) < 1 or math.abs(plusXHeading - 360) < 1, false)

-- --------------------------------------------------------------------------
-- Torque from corner forces, using the arms craftgeom derives.
-- --------------------------------------------------------------------------
local TENSOR = {
    { 389383646.66189605, 2818192.7656108057, -4641931.7102072081 },
    { 2818192.7656108057, 435883852.97585285, 28031283.72369967 },
    { -4641931.7102072081, 28031283.72369967, 86772714.934104145 },
    rows = 3, columns = 3,
}
local box = craftgeom.solveBox(TENSOR, 105299.4, axes)
local arms = craftgeom.armBound(box)

-- Port corners up, starboard corners down: a pure roll couple, no pitch.
local rollCouple = {
    FL = { vertical = 1000 }, RL = { vertical = 1000 },
    FR = { vertical = -1000 }, RR = { vertical = -1000 },
}
local torque = vectoring.attitudeTorque(rollCouple, arms)
check("pure roll couple makes roll torque",
    torque.roll, 4 * arms.lateral * 1000, 1e-6)
check("pure roll couple makes NO pitch torque", torque.pitch, 0, 1e-6)

-- Forward corners up, aft down: pure pitch, no roll.
local pitchCouple = {
    FL = { vertical = 1000 }, FR = { vertical = 1000 },
    RL = { vertical = -1000 }, RR = { vertical = -1000 },
}
local pitchOnly = vectoring.attitudeTorque(pitchCouple, arms)
check("pure pitch couple makes pitch torque",
    pitchOnly.pitch, 4 * arms.longitudinal * 1000, 1e-6)
check("pure pitch couple makes NO roll torque", pitchOnly.roll, 0, 1e-6)

-- Uniform lift is no couple at all.
local uniform = vectoring.attitudeTorque({
    FL = { vertical = 1000 }, FR = { vertical = 1000 },
    RL = { vertical = 1000 }, RR = { vertical = 1000 },
}, arms)
check("uniform lift makes no roll torque", uniform.roll, 0, 1e-6)
check("uniform lift makes no pitch torque", uniform.pitch, 0, 1e-6)

-- --------------------------------------------------------------------------
-- The staircase fit.
-- --------------------------------------------------------------------------
local slope, worst = vectoring.fitThroughOrigin({
    { x = 1, y = 2.0 }, { x = 2, y = 4.0 }, { x = 4, y = 8.0 },
})
check("clean staircase fits its slope", slope, 2.0, 1e-9)
check("clean staircase has no residual", worst, 0, 1e-9)
checkEqual("a single point is not a fit",
    vectoring.fitThroughOrigin({ { x = 1, y = 2 } }), nil)

print("")
print(string.format("arms from tensor: lateral %.2f  longitudinal %.2f blocks",
    arms.lateral, arms.longitudinal))
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
