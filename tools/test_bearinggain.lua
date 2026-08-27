-- Does the bearing gain track the craft, or does it store a number?
--
-- The bug this pins is not an arithmetic slip. `fcs/trim.lua` and
-- `lateralhold.terminalSpeed` both carry thrustPerBearing = 13960.98 -- the
-- reading at 16 RPM, on the ground, at the mass the craft had that day -- and
-- then use it to cost a manoeuvre flown at 64 rpm on a heavier hull. So the
-- tests below are in two halves:
--
--   1. AT THE CALIBRATION POINT it must reproduce the old numbers exactly.
--      3886.3 N at 8 degrees on one corner (vectorprobe), 0.205 blocks/s per
--      degree craft-wide (trim.lua). If it does not, the replacement is not a
--      replacement.
--
--   2. AWAY FROM IT the answer must MOVE -- with rpm, with mass, with air
--      density -- and by the right factor. A gain that survives a 4x thrust
--      change unchanged is the bug, not the fix.
--
--     luajit tools/test_bearinggain.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local bearinggain = require("fcs.bearinggain")
local trim = require("fcs.trim")

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
-- 1. THE CALIBRATION POINT. Reproduce what was measured, or this is a rewrite
--    with a different answer rather than the same answer computed honestly.
-- --------------------------------------------------------------------------

-- vectorprobe, on the ground at 16 rpm: ONE corner, TWO bearings, 8 degrees.
local onePair = bearinggain.lateralForce(8.0, { corners = 1 })
check("one corner at 8 deg is vectorprobe's 3886.3 N", onePair, 3886.3, 0.5)

-- trim.lua, craft-wide. The whole existing drift model, at its own constant.
local perDegree = bearinggain.perDegree()
check("craft-wide, 1 deg of tilt drifts 0.2057 blocks/s", perDegree, 0.2057, 0.001)
check("...which is what trim.bearingDrift says at the same constant",
    perDegree, trim.bearingDrift(1.0), 1e-6)

-- And the inverse closes on itself, which is what a flight cross-check needs.
check("impliedThrust inverts driftFor", bearinggain.impliedThrust(perDegree),
    bearinggain.REFERENCE.thrustPerBearing, 1.0)

-- --------------------------------------------------------------------------
-- 2. AWAY FROM IT. The gain must MOVE, and by the measured factor.
-- --------------------------------------------------------------------------

-- getThrust is exactly linear in rpm (r^2 = 1.000000, 8 to 96 RPM), so the
-- bearing thrust at flight rpm is 4x its 16 rpm value. This is the factor the
-- handoff called "uncertain by 4x" -- it was never uncertain, it was unread.
local flightThrust = bearinggain.REFERENCE.thrustPerBearing * (64 / 16)
local flightPerDegree = bearinggain.perDegree({ thrustPerBearing = flightThrust })
check("at 64 rpm a degree is worth 0.823 blocks/s", flightPerDegree, 0.8228, 0.001)
check("...exactly 4x the ground-rpm figure", flightPerDegree / perDegree, 4.0, 1e-6)
checkEqual("and the reference ratio reports it", 
    string.format("%.2f", bearinggain.driftFromReference(flightThrust)), "4.00")

-- THE CONSEQUENCE, stated as a number because it is the reason the trim
-- flights failed: a 1 degree trim was costed at 0.205 and really costs 0.823.
checkTrue("a trim costed at the ground constant is 4x optimistic",
    flightPerDegree > 4 * perDegree - 1e-6)

-- MASS. Bolting machines to the hull must lower the gain, and by the ratio of
-- the weights -- this is what makes the calibration survive a changing craft.
local heavier = bearinggain.perDegree({
    thrustPerBearing = flightThrust,
    weight = bearinggain.ENVIRONMENT.weight * 1.25,
})
check("25% more weight gives 80% of the gain", heavier / flightPerDegree, 0.8, 1e-9)
check("weightFromMass is mass x gravity",
    bearinggain.weightFromMass(1000, 11.0), 11000, 1e-9)

-- AIR DENSITY. getThrust reports before the density factor, so a caller that
-- believes the lateral force takes it too gets a bigger gain, not the same one.
local dense = bearinggain.perDegree({ thrustPerBearing = flightThrust,
    pressure = 1.353 })
check("the x1.353 pressure factor scales it through", dense / flightPerDegree,
    1.353, 1e-9)
-- Default is UNCORRECTED, so nothing silently acquires a factor that was never
-- measured on the lateral axis.
check("pressure defaults to 1.0", flightPerDegree,
    bearinggain.perDegree({ thrustPerBearing = flightThrust, pressure = 1.0 }), 1e-12)

-- BEARING COUNT is read, not assumed: a probe that tilts one corner is
-- counting two bearings, and calling that craft-wide overstates it 4x.
check("one corner is a quarter of the craft",
    bearinggain.perDegree({ corners = 1 }) / perDegree, 0.25, 1e-9)

-- --------------------------------------------------------------------------
-- 3. THE SCALING FIT, which is what the ground sweep produces.
-- --------------------------------------------------------------------------

local linear = {}
for _, rpm in ipairs({ 16, 32, 48, 64 }) do
    linear[#linear + 1] = { rpm = rpm, thrust = 872.56 * rpm }
end
local fit = bearinggain.fitScaling(linear)
check("linear sweep fits 872.56 per rpm", fit.perRpm, 872.56, 0.01)
check("...with exponent 1.0", fit.exponent, 1.0, 1e-6)
check("...and r2 1.000000", fit.r2, 1.0, 1e-9)
checkEqual("verdict LINEAR", bearinggain.scalingVerdict(fit), "LINEAR")
check("extrapolates to 55843.9 at 64 rpm",
    bearinggain.thrustAtRpm(fit, 64), 55843.9, 1.0)

-- A SQUARE LAW must NOT read as linear. Two points cannot tell them apart, so
-- the exponent is the discriminator and it needs three rpms -- which is why
-- the verdict refuses on two.
local square = {}
for _, rpm in ipairs({ 16, 32, 48, 64 }) do
    square[#square + 1] = { rpm = rpm, thrust = 54.535 * rpm * rpm }
end
local squareFit = bearinggain.fitScaling(square)
check("a square law reads exponent 2.0", squareFit.exponent, 2.0, 1e-6)
checkTrue("...and does NOT pass as linear",
    bearinggain.scalingVerdict(squareFit) ~= "LINEAR")
checkEqual("two rpms is too few to call it", bearinggain.scalingVerdict(
    bearinggain.fitScaling({ { rpm = 16, thrust = 13960.98 },
                             { rpm = 64, thrust = 55843.92 } })), "TOO FEW RPMS")

-- getThrust is signed by HANDEDNESS: a counter-rotating pair reports +x and
-- -x while pushing the same way. Summing raw values annihilates them, which is
-- what once made three corners look dead -- so the fit takes magnitudes.
local signed = bearinggain.fitScaling({
    { rpm = 16, thrust = -13960.98 }, { rpm = 32, thrust = 27921.96 },
    { rpm = 48, thrust = -41882.94 },
})
check("a handedness-signed sweep still fits", signed.perRpm, 872.56, 0.01)

-- Junk in, refusal out.
checkTrue("no samples refuses", bearinggain.fitScaling(nil) == nil)
checkTrue("one rpm refuses", bearinggain.fitScaling({ { rpm = 16, thrust = 1 } }) == nil)
checkTrue("zero rpm is dropped, not divided by",
    bearinggain.fitScaling({ { rpm = 0, thrust = 0 }, { rpm = 16, thrust = 13960.98 },
        { rpm = 32, thrust = 27921.96 }, { rpm = 48, thrust = 41882.94 } }).samples == 3)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
