-- Does the trim maths cancel a standing offset, or drive it?
--
-- The sign of the bearing roll coupling has NEVER been measured on this craft,
-- and getting it wrong is not a small error: a saturated 12 degree command with
-- the sign wrong ran the craft from 1.76 to 11.5 blocks/s. So the sign is
-- measured in flight rather than assumed, and what is pinned here is that the
-- maths built on that measurement cancels rather than reinforces -- FOR EITHER
-- SIGN, because which one the craft has is still unknown.
--
-- The drift numbers are pinned to the passive rolldrift flight, so a passing
-- test says something about this carrier and not about an invented one.
--
--     luajit tools/test_trim.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local trim = require("fcs.trim")

local passed, failed = 0, 0
local function check(label, got, want, tolerance)
    if type(got) == "number" and math.abs(got - want) <= (tolerance or 1e-9) then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL %-56s got %s want %.6f",
            label, tostring(got), want))
    end
end
local function checkTrue(label, condition)
    if condition then passed = passed + 1 else
        failed = failed + 1
        print("FAIL " .. label)
    end
end

-- --------------------------------------------------------------------------
-- THE CASE FOR DOING THIS AT ALL, pinned to the measured flight.
-- --------------------------------------------------------------------------

local rollDrift = trim.driftSpeed(trim.MEASURED.standingRoll)
local pitchDrift = trim.driftSpeed(trim.MEASURED.standingPitch)
check("standing roll 0.368 deg drifts 0.785 blocks/s", rollDrift, 0.785, 0.005)
check("standing pitch -0.638 deg drifts -1.361 blocks/s", pitchDrift, -1.361, 0.005)

local combined = trim.combinedDrift(trim.MEASURED.standingRoll,
    trim.MEASURED.standingPitch)
check("together they imply 1.571 blocks/s", combined, 1.571, 0.005)
-- Against the MEASURED mean ground speed of the passive drift flight.
check("...which is 94% of the measured 1.670", combined / 1.670, 0.941, 0.005)

-- PITCH IS THE BIGGER HALF. This project has always looked at roll, because
-- the repaired RR deficit was a roll torque. Trimming roll alone leaves most
-- of the drift on the table.
checkTrue("pitch drift exceeds roll drift",
    math.abs(pitchDrift) > math.abs(rollDrift))
check("roll alone is only 31% of the total", math.abs(rollDrift) / combined, 0.50, 0.01)

-- The price of the actuator: trimming with bearings buys back some drift.
local rollCost = trim.bearingDrift(0.63)
local pitchCost = trim.bearingDrift(1.16)
local cost = math.sqrt(rollCost * rollCost + pitchCost * pitchCost)
check("0.63 deg of bearing tilt costs 0.130 blocks/s", rollCost, 0.130, 0.005)
check("1.16 deg costs 0.239", pitchCost, 0.239, 0.005)
check("the trim's own drift totals 0.272", cost, 0.272, 0.005)
checkTrue("which is still a 5x improvement", combined / cost > 5)

-- --------------------------------------------------------------------------
-- THE GAIN, measured by reverse pairs.
--
-- The standing offset and the hull's own oscillation are both LARGER than the
-- signal. Both cancel in the difference; neither cancels in an average of
-- single-sided steps.
-- --------------------------------------------------------------------------

-- A craft with a +0.4 standing offset and a true gain of 0.5 hull deg per
-- commanded deg: at +2 it sits at 0.4 + 1.0, at -2 at 0.4 - 1.0.
local gain = trim.staticGain(2.0, 0.4 + 1.0, -2.0, 0.4 - 1.0)
check("reverse pairs recover the gain through a standing offset", gain, 0.5, 1e-9)

-- The same craft with the OPPOSITE coupling sign.
local negativeGain = trim.staticGain(2.0, 0.4 - 1.0, -2.0, 0.4 + 1.0)
check("...and recover a NEGATIVE gain just as cleanly", negativeGain, -0.5, 1e-9)

-- A single-sided step measures the offset, not the gain. This is the mistake.
local naive = (0.4 + 1.0) / 2.0
checkTrue("a single-sided step gets the gain wrong", math.abs(naive - 0.5) > 0.1)

checkTrue("no gain from a zero span", trim.staticGain(2, 1, 2, 1) == nil)
checkTrue("no gain from missing samples", trim.staticGain(2, 1, nil, 1) == nil)

-- --------------------------------------------------------------------------
-- THE TRIM ITSELF: it must CANCEL, for either sign of the coupling.
-- --------------------------------------------------------------------------

for _, signedGain in ipairs({ 0.5, -0.5, 0.493, -1.2 }) do
    local offset = 0.368
    local tilt = trim.tiltFor(offset, signedGain)
    -- What the craft would then sit at: the offset plus the response.
    local resulting = offset + tilt * signedGain
    checkTrue(string.format("gain %+0.3f: the trim cancels the offset", signedGain),
        math.abs(resulting) < 1e-9)
    checkTrue(string.format("gain %+0.3f: it does not make it worse", signedGain),
        math.abs(resulting) < math.abs(offset))
end

-- A negative offset trims the other way.
local upTilt = trim.tiltFor(-0.638, 0.5)
checkTrue("a negative offset commands the opposite tilt", upTilt > 0)
check("...by the matching amount", upTilt, 1.276, 1e-9)

-- --------------------------------------------------------------------------
-- AND IT REFUSES rather than guessing. A gain too small to trust divides into
-- a large command derived from nothing, which is the shape of the runaway.
-- --------------------------------------------------------------------------

local refused, why = trim.tiltFor(0.368, 0.001)
checkTrue("a tiny gain is REFUSED, not divided by", refused == nil)
checkTrue("...and says why", type(why) == "string" and why:find("below"))
checkTrue("a nil gain is refused", trim.tiltFor(0.368, nil) == nil)

local inside = trim.tiltFor(0.01, 0.5)
check("an offset inside the deadband commands nothing", inside, 0)

-- A large POSITIVE offset with a positive gain wants a large NEGATIVE tilt --
-- it cancels. The clamp is symmetric; the first version of this test asserted
-- +4 and was simply wrong about the direction.
local clamped = trim.tiltFor(20.0, 0.5)
check("a huge offset clamps to the trim limit, in the CANCELLING direction",
    clamped, -trim.DEFAULTS.maxTiltDegrees)
check("...and the other way for a negative offset", trim.tiltFor(-20.0, 0.5),
    trim.DEFAULTS.maxTiltDegrees)
checkTrue("the trim clamp is far below the 15 degree hardware clamp",
    trim.DEFAULTS.maxTiltDegrees < 15)
checkTrue("...and below the 12 degrees that ran the craft away",
    trim.DEFAULTS.maxTiltDegrees < 12)

-- --------------------------------------------------------------------------
-- The offset is a MEAN over a window. The hull swings either side of it by
-- several times its size, so a single reading is not the offset.
-- --------------------------------------------------------------------------

local window = { { roll = 2.0 }, { roll = -1.2 }, { roll = 1.5 }, { roll = -0.9 } }
local mean = trim.mean(window, "roll")
check("the standing offset is the mean of the window", mean, 0.35, 1e-9)
checkTrue("no samples, no mean", trim.mean({}, "roll") == nil)

-- The prediction, kept only for comparison.
check("the torque model predicts 0.49 hull deg per commanded deg",
    trim.predictedGain(), 0.4933, 0.001)

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
