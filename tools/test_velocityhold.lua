-- Does the velocity loop hold, and does it refuse when it does not know how?
--
-- THE PLANT IS INVERTED AND SLOW, and both facts are measured:
--
--   direct bearing force   +0.8165 blocks/s per commanded degree, FAST
--   through the hull       -1.751 (roll axis) / -1.192 (pitch), SLOW and BIGGER
--   NET                    -0.934 / -0.376
--
-- A tilt commanded to push starboard moves the craft PORT once the hull has
-- caught up -- after moving it starboard for the first few seconds. That sign
-- change between fast and slow is the 1.76 -> 11.5 blocks/s runaway.
--
-- So the two properties pinned hardest here are:
--
--   1. THE COMMAND OPPOSES THE VELOCITY FOR EITHER SIGN OF GAIN. The loop
--      divides by a measured, signed gain and never reasons about which way
--      the bearings "should" push.
--
--   2. THE COMMAND CANNOT MOVE FAST. The rate limit is what keeps the loop on
--      the slow, stable half of a plant whose fast half has the other sign.
--
--     luajit tools/test_velocityhold.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local velocityhold = require("fcs.velocityhold")
local bearinggain = require("fcs.bearinggain")

local passed, failed = 0, 0
local function check(label, got, want, tolerance)
    if type(got) == "number" and math.abs(got - want) <= (tolerance or 1e-9) then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL %-58s got %s want %.6f",
            label, tostring(got), want))
    end
end
local function checkEqual(label, got, want)
    if got == want then passed = passed + 1 else
        failed = failed + 1
        print(string.format("FAIL %-58s got %s want %s",
            label, tostring(got), tostring(want)))
    end
end
local function checkTrue(label, condition)
    if condition then passed = passed + 1 else
        failed = failed + 1
        print("FAIL " .. label)
    end
end

-- --------------------------------------------------------------------------
-- 1. THE PLANT, pinned to the three measurements it is built from.
-- --------------------------------------------------------------------------

check("a hull degree is worth 2.133 blocks/s",
    velocityhold.hullDriftPerDegree(), 2.1334, 0.001)

local direct = bearinggain.perDegree({
    thrustPerBearing = 55420.5,
    weight = bearinggain.weightFromMass(105296.4),
})
check("the ground sweep's direct gain", direct, 0.8165, 0.001)

-- Positive roll is starboard-low so it drifts to starboard: sense +1.
local rollNet, rollHull = velocityhold.predictNet(direct, -0.8205, 1)
check("roll axis hull term", rollHull, -1.7505, 0.002)
check("roll axis NET", rollNet, -0.9339, 0.002)
-- Positive pitch is bow-high so it drifts aft: sense -1.
local pitchNet = velocityhold.predictNet(direct, 0.5588, -1)
check("pitch axis NET", pitchNet, -0.3756, 0.002)

checkTrue("the net is INVERTED against the direct force on roll",
    rollNet * direct < 0)
checkTrue("...and on pitch", pitchNet * direct < 0)
checkTrue("the hull term is the bigger half",
    math.abs(rollHull) > math.abs(direct))

-- --------------------------------------------------------------------------
-- 2. THE REFUSAL.
-- --------------------------------------------------------------------------

local tilt, why = velocityhold.tiltFor(1.5, nil)
checkEqual("an unmeasured axis commands ZERO", tilt, 0)
checkTrue("...and says why", type(why) == "string" and why:find("measured") ~= nil)

checkEqual("a gain below the floor refuses",
    (velocityhold.tiltFor(1.5, 0.01)), 0)
checkTrue("usable() agrees", not velocityhold.usable(0.01))
checkTrue("usable() passes a real gain", velocityhold.usable(-0.93))

-- --------------------------------------------------------------------------
-- 3. IT OPPOSES THE VELOCITY, FOR EITHER SIGN OF GAIN.
--
-- Checked as a product against the PLANT, which cannot be argued with by
-- rearranging a sign convention: commanded tilt x net gain is the drift the
-- command will produce, and it must oppose the drift the craft has.
-- --------------------------------------------------------------------------

for _, gain in ipairs({ -0.9339, -0.3756, 0.9339, 0.42 }) do
    for _, velocity in ipairs({ -1.7, -0.4, 0.4, 1.7 }) do
        local command = velocityhold.tiltFor(velocity, gain)
        local produced = command * gain
        checkTrue(string.format("gain %+.2f, drifting %+.1f: the command opposes it",
            gain, velocity), produced * velocity < 0)
    end
end

-- The inverted craft: drifting starboard, the loop commands a STARBOARD tilt,
-- because on this craft a starboard tilt is what moves it port.
local command = velocityhold.tiltFor(1.5, -0.9339)
checkTrue("drifting starboard, it commands a positive (starboard) tilt", command > 0)
check("...at half strength, per the relaxation", command,
    (1.5 / 0.9339) * velocityhold.DEFAULTS.relaxation, 1e-6)

-- Deadband and clamp.
checkEqual("inside the deadband commands zero",
    (velocityhold.tiltFor(0.05, -0.9339)), 0)
checkEqual("saturates at the clamp",
    (velocityhold.tiltFor(50, -0.9339)), velocityhold.DEFAULTS.maxTiltDegrees)
checkEqual("...and the other way",
    (velocityhold.tiltFor(-50, -0.9339)), -velocityhold.DEFAULTS.maxTiltDegrees)
checkTrue("the clamp is well below the 12 deg that ran the craft away",
    velocityhold.DEFAULTS.maxTiltDegrees <= 4.0)

-- --------------------------------------------------------------------------
-- 4. THE RATE LIMIT. The single thing standing between this loop and the
--    runaway, so it is tested as behaviour over time, not as a formula.
-- --------------------------------------------------------------------------

check("one step of slew is rate x dt",
    velocityhold.slew(0, 4.0, 1.0), velocityhold.DEFAULTS.slewPerSecond, 1e-12)
check("it slews DOWN the same way",
    velocityhold.slew(0, -4.0, 1.0), -velocityhold.DEFAULTS.slewPerSecond, 1e-12)
check("a target inside one step is reached exactly",
    velocityhold.slew(0, 0.01, 1.0), 0.01, 1e-12)
checkEqual("no time, no movement", velocityhold.slew(1.0, 4.0, 0), 1.0)

-- The property that matters: a full command takes far longer to build than the
-- hull takes to answer (about 30 s). If this ever inverts, the loop is chasing
-- the fast half of the plant, which has the wrong sign.
local current, dt, elapsed = 0, 0.15, 0
while current < velocityhold.DEFAULTS.maxTiltDegrees - 1e-9 and elapsed < 1000 do
    current = velocityhold.slew(current, velocityhold.DEFAULTS.maxTiltDegrees, dt)
    elapsed = elapsed + dt
end
check("a full 4 degree command takes 80 s to build", elapsed, 80, 1)
checkTrue("which is well over the hull's ~30 s response", elapsed > 60)

-- --------------------------------------------------------------------------
-- 5. MEASURING THE GAIN, and judging the result.
-- --------------------------------------------------------------------------

-- A reverse pair on a craft with a standing drift: the drift cancels, the
-- response reverses and adds.
check("the reverse pair recovers the gain",
    velocityhold.netGain(2.0, -1.868 + 0.7, -2.0, 1.868 + 0.7), -0.934, 0.001)
checkEqual("a degenerate pair refuses",
    velocityhold.netGain(2.0, 1.0, 2.0, 1.0), nil)

-- NET DISPLACEMENT, not mean speed. An oscillating craft that ends where it
-- started has drifted nowhere, and mean speed cannot say so.
check("net drift is displacement over time",
    velocityhold.netDrift(0, 0, 30, 40, 50), 1.0, 1e-9)
check("a craft that came back has drifted nowhere",
    velocityhold.netDrift(0, 0, 0, 0, 50), 0.0, 1e-9)

-- --------------------------------------------------------------------------
-- 6. BODY FRAME. A loop that skips this steers by whatever heading the craft
--    happened to launch on.
-- --------------------------------------------------------------------------

-- Identity attitude: body axes are world axes, bow is +Z, port is +X.
local level = {
    quaternion = { x = 0, y = 0, z = 0, w = 1 },
    linearVelocityWorld = { x = 3, y = 0, z = 4 },
}
local body = velocityhold.components(level, { bowAxis = "z", portAxis = "x" })
checkTrue("components resolve", body ~= nil)
check("bow is +Z", body.bow, 4, 1e-6)
check("starboard is -X", body.starboard, -3, 1e-6)
checkEqual("no quaternion, no components",
    velocityhold.components({ linearVelocityWorld = { x = 1, y = 0, z = 0 } }), nil)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
