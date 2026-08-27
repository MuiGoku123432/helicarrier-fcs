-- Does the pitch damper damp, and does it REFUSE when it does not know how?
--
-- Two properties matter more than any number here, and both are about a craft
-- nobody has measured yet:
--
--   1. IT MUST NOT COMMAND FROM A PREDICTION. Every other damper in this
--      project defaults to a stored constant. This axis has none -- not the
--      authority, not the spring, not even the SIGN -- so differentialFor
--      returns 0 and a reason until a flight hands it real numbers.
--
--   2. IT MUST DAMP FOR EITHER SIGN. Whether raising the forward corners
--      raises or drops the bow is a hypothesis. The bearing coupling came back
--      opposite to prediction on one axis and not the other, and the roll and
--      pitch labels themselves were transposed for weeks. So the tests below
--      run the damper on BOTH signs and require opposition in both.
--
--     luajit tools/test_pitchdamp.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local pitchdamp = require("fcs.pitchdamp")
local rolldamp = require("fcs.rolldamp")

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
-- 1. THE REFUSAL. This is the property, not a guard clause.
-- --------------------------------------------------------------------------

local differential, reason = pitchdamp.differentialFor(0.9)
checkEqual("un-measured axis commands ZERO", differential, 0)
checkTrue("...and says why", type(reason) == "string" and #reason > 0)
checkTrue("...naming the flight that fixes it", reason:find("pitchdampflight") ~= nil)

checkEqual("MEASURED.flightAuthorityPerRpm ships nil",
    pitchdamp.MEASURED.flightAuthorityPerRpm, nil)
checkEqual("MEASURED.springPerDegree ships nil",
    pitchdamp.MEASURED.springPerDegree, nil)

-- An authority but no spring is half an answer, and critical damping cannot be
-- computed from half.
local half, halfWhy = pitchdamp.differentialFor(0.9, { authorityPerRpm = 0.05 })
checkEqual("authority without a spring still refuses", half, 0)
checkTrue("...saying the spring is what is missing",
    halfWhy and halfWhy:find("spring") ~= nil)

-- An authority too small to trust would divide into a saturated command built
-- from noise -- the same failure trim.tiltFor guards against.
local tiny = pitchdamp.differentialFor(0.9,
    { authorityPerRpm = 0.0001, springPerDegree = 0.005 })
checkEqual("an authority below the floor refuses", tiny, 0)

-- --------------------------------------------------------------------------
-- 2. IT DAMPS, AND FOR EITHER SIGN.
-- --------------------------------------------------------------------------

local SPRING = 0.00497          -- the equal-torque hypothesis, 89 s period
local POSITIVE = { authorityPerRpm = 0.0493, springPerDegree = SPRING }
local NEGATIVE = { authorityPerRpm = -0.0493, springPerDegree = SPRING }

local up = pitchdamp.differentialFor(0.5, POSITIVE)
local down = pitchdamp.differentialFor(-0.5, POSITIVE)
checkTrue("positive authority: a bow-rising rate is answered NEGATIVE", up < 0)
checkTrue("positive authority: a bow-dropping rate is answered POSITIVE", down > 0)

local upFlipped = pitchdamp.differentialFor(0.5, NEGATIVE)
local downFlipped = pitchdamp.differentialFor(-0.5, NEGATIVE)
checkTrue("NEGATIVE authority: the command flips with it", upFlipped > 0)
checkTrue("NEGATIVE authority: and flips the other way too", downFlipped < 0)
checkEqual("the two signs are mirror images", up, -upFlipped)

-- OPPOSITION IS THE WHOLE JOB. Whatever the sign, the resulting angular
-- acceleration must oppose the rate -- that is what makes it a damper rather
-- than a driver. Checked as a product, which cannot be fooled by a sign
-- convention argument.
for _, case in ipairs({ { POSITIVE, "positive" }, { NEGATIVE, "negative" } }) do
    local options, name = case[1], case[2]
    for _, rate in ipairs({ -1.2, -0.4, 0.4, 1.2 }) do
        local rpm = pitchdamp.differentialFor(rate, options)
        local acceleration = rpm * options.authorityPerRpm
        checkTrue(string.format("%s authority, rate %+.1f: acceleration opposes it",
            name, rate), acceleration * rate < 0)
    end
end

-- Deadband and clamp.
checkEqual("inside the deadband commands zero",
    pitchdamp.differentialFor(0.01, POSITIVE), 0)
checkEqual("saturates at the clamp",
    pitchdamp.differentialFor(50, POSITIVE), -pitchdamp.DEFAULTS.maxDifferentialRpm)
checkTrue("and returns an INTEGER, because setRpm rounds",
    pitchdamp.differentialFor(0.5, POSITIVE) % 1 == 0)

-- --------------------------------------------------------------------------
-- 3. THE PREDICTION, which is the ratio and not the thrust model.
-- --------------------------------------------------------------------------

local predicted, ratio, source = pitchdamp.predictedAuthority()
check("predicted pitch authority", predicted, 0.0493, 0.0005)
check("from the recorded roll/pitch ratio", ratio, 1.908, 0.005)
checkEqual("and it says where the ratio came from", source, "recorded hull")
check("...which is measured roll over that ratio",
    predicted, rolldamp.MEASURED.flightAuthorityPerRpm / ratio, 1e-9)
checkTrue("pitch is the WEAKER axis", predicted < rolldamp.MEASURED.flightAuthorityPerRpm)

-- The live tensor must win when there is one. The craft gains mass and shifts
-- its centre of mass every time a machine is bolted on, and this ratio moves.
local TENSOR = {
    { 389383646.66189605, 2818192.7656108057, -4641931.7102072081 },
    { 2818192.7656108057, 435883852.97585285, 28031283.72369967 },
    { -4641931.7102072081, 28031283.72369967, 86772714.934104145 },
    rows = 3, columns = 3,
}
local _, liveRatio, liveSource = pitchdamp.predictedAuthority({
    tensor = TENSOR, mass = 105299.39999999988,
})
checkEqual("a live tensor is used when offered", liveSource, "live tensor")
check("...and reproduces the recorded ratio", liveRatio, 1.908, 0.005)

-- --------------------------------------------------------------------------
-- 4. THE SPRING, and the two worlds the flight has to tell apart.
-- --------------------------------------------------------------------------

local hypothetical = pitchdamp.springIfTorqueMatchesRoll()
check("equal restoring torque implies spring 0.00497", hypothetical, 0.004969, 1e-5)
check("...which is an 89 s period",
    rolldamp.periodFromSpring(hypothetical), 89.1, 0.2)
check("roll's own 0.0223 is a 42 s period",
    rolldamp.periodFromSpring(rolldamp.MEASURED.springPerDegree), 42.1, 0.2)
checkTrue("the two hypotheses are far enough apart to be told apart",
    rolldamp.periodFromSpring(hypothetical)
        > 2 * rolldamp.periodFromSpring(rolldamp.MEASURED.springPerDegree) - 5)

check("springFromPeriod inverts periodFromSpring",
    rolldamp.springFromPeriod(rolldamp.periodFromSpring(0.0223)), 0.0223, 1e-12)

-- Critical damping is 2*sqrt(k), and on the slow axis it is much gentler --
-- which is exactly why assuming roll's spring would set the gain 2.1x high.
check("critical damping at the hypothetical spring",
    pitchdamp.criticalDamping(hypothetical), 0.1410, 0.001)
check("...against roll's 0.2987", rolldamp.criticalDamping(), 0.2987, 0.001)

-- --------------------------------------------------------------------------
-- 5. READING A PERIOD OFF A TRACE.
-- --------------------------------------------------------------------------

-- A synthetic ring-down: 89 s period, decaying. The period must come back
-- whatever the amplitude is doing.
local samples = {}
for step = 0, 1200 do
    local t = step * 0.15
    samples[#samples + 1] = {
        t = t,
        pitchRate = 0.9 * math.exp(-t / 200)
            * math.cos(2 * math.pi * t / 89),
    }
end
local period, intervals, spread = rolldamp.measurePeriod(samples, 0.05, "pitchRate")
check("an 89 s ring-down reads back as 89 s", period, 89, 1.5)
checkTrue("from more than one interval", intervals >= 2)
checkTrue("with the intervals agreeing", spread and spread < 0.1)

-- Too short a window cannot produce a period, and must say so rather than
-- inventing one from a single crossing.
local short = {}
for step = 0, 100 do
    local t = step * 0.15
    short[#short + 1] = { t = t, pitchRate = 0.9 * math.cos(2 * math.pi * t / 89) }
end
checkEqual("a window shorter than half a period returns no period",
    (rolldamp.measurePeriod(short, 0.05, "pitchRate")), nil)

-- SIGNED authority from a pulse. The magnitude was all roll ever needed; a
-- fresh axis needs to know which way it went.
local pulse = {}
for step = 0, 40 do
    pulse[#pulse + 1] = { t = step * 0.15, pitchRate = -0.02 * step }
end
local magnitude, peak, seconds, signed = rolldamp.authorityFromPulse(
    pulse, 3, 3.0, "pitchRate")
checkTrue("pulse authority magnitude is positive", magnitude > 0)
checkTrue("...and the signed value is NEGATIVE for a bow-dropping pulse", signed < 0)
check("magnitudes agree", math.abs(signed), magnitude, 1e-9)
check("peak is the last sample", peak, 0.8, 1e-9)
checkTrue("effective seconds includes the pulse", seconds > 3.0)

-- --------------------------------------------------------------------------
-- 6. THE CORNERS.
-- --------------------------------------------------------------------------

local fore = pitchdamp.cornerRpm(64, 3, { minimumRpm = 8 })
checkEqual("FL rises", fore.FL, 67)
checkEqual("FR rises with it", fore.FR, 67)
checkEqual("RL drops", fore.RL, 61)
checkEqual("RR drops with it", fore.RR, 61)
checkTrue("the pattern is FORE/AFT, not port/starboard", fore.FL == fore.FR)

local roll = rolldamp.cornerRpm(64, 3, { minimumRpm = 8 })
checkTrue("roll's pattern is still port/starboard", roll.FL == roll.RL
    and roll.FL ~= roll.FR)

-- SUPERPOSITION. Orthogonal patterns, so both dampers can run at once.
local both = pitchdamp.combinedCornerRpm(64, 2, 3, { minimumRpm = 8 })
checkEqual("FL gets +2 roll +3 pitch", both.FL, 69)
checkEqual("FR gets -2 roll +3 pitch", both.FR, 65)
checkEqual("RL gets +2 roll -3 pitch", both.RL, 63)
checkEqual("RR gets -2 roll -3 pitch", both.RR, 59)

-- The SUM is clamped, and the caller is told. Two dampers each clamped at 4
-- can ask one corner for 8 -- 12.5% of base rpm, a lift asymmetry nobody sized.
local clampedRpms, clipped = pitchdamp.combinedCornerRpm(64, 4, 4, { minimumRpm = 8 })
checkTrue("the combined demand clips", clipped)
checkEqual("...at the 6 rpm sum clamp", clampedRpms.FL, 70)
local _, quiet = pitchdamp.combinedCornerRpm(64, 2, 3, { minimumRpm = 8 })
checkTrue("and does not cry clip when it did not", not quiet)

-- The floor still applies: dropping a corner toward zero sheds the lift that
-- corner carries, and one corner losing its props rolled the craft past 28 deg.
local floored = pitchdamp.combinedCornerRpm(9, 0, 4, { minimumRpm = 8 })
checkEqual("the corner floor holds", floored.RL, 8)

-- --------------------------------------------------------------------------
-- 7. WHAT KIND OF AXIS IS IT? Pinned to run 1, which falsified the premise.
--
-- The tool was built believing pitch is underdamped like roll. The craft flew
-- on 2026-08-27 and produced ZERO zero crossings in 120 s with the rate down
-- to 1/e in 1.6 s. So the classifier exists to tell apart the two ways an axis
-- can fail to ring, because they lead opposite ways: a spring plus heavy
-- damping is a HEALTHY axis, while damping with no spring means the hull parks
-- wherever it is left and never levels itself.
-- --------------------------------------------------------------------------

checkEqual("two crossings is an oscillator",
    (pitchdamp.classify({ crossings = 3, baseline = 0, peak = 2.9, final = 2.7 })),
    pitchdamp.UNDERDAMPED)

checkEqual("came home = OVERDAMPED",
    (pitchdamp.classify({ crossings = 0, baseline = 0, peak = 1.8, final = 0.3 })),
    pitchdamp.OVERDAMPED)

checkEqual("parked = NO SPRING",
    (pitchdamp.classify({ crossings = 0, baseline = 0, peak = 1.8, final = 1.8 })),
    pitchdamp.NO_SPRING)

checkEqual("halfway home is not a finding",
    (pitchdamp.classify({ crossings = 0, baseline = 0, peak = 1.8, final = 1.0 })),
    pitchdamp.UNCLEAR)

-- The standing offset is a few tenths and it moves between flights, so the
-- classifier works on the DIFFERENCE from baseline rather than from zero.
checkEqual("a standing offset does not fool it",
    (pitchdamp.classify({ crossings = 0, baseline = -0.638, peak = 1.16,
        final = -0.5 })), pitchdamp.OVERDAMPED)

-- An excursion inside the noise cannot be divided by.
checkEqual("a pulse that did nothing is UNCLEAR, not a verdict",
    (pitchdamp.classify({ crossings = 0, baseline = 0, peak = 0.05, final = 0.0 })),
    pitchdamp.UNCLEAR)
checkEqual("missing numbers are UNCLEAR", (pitchdamp.classify({ crossings = 0 })),
    pitchdamp.UNCLEAR)

local _, returned = pitchdamp.classify({ crossings = 0, baseline = 0,
    peak = 2.0, final = 0.5 })
check("returned fraction is reported", returned, 0.75, 1e-9)

-- IS IT WORTH DAMPING AT ALL? The honest answer for an axis that arrests
-- itself in 1.6 s is no, and the tool has to be able to say so rather than
-- damping because it was built to damp.
checkTrue("an oscillator is worth damping",
    pitchdamp.worthDamping(pitchdamp.UNDERDAMPED, 15.9))
checkTrue("run 1's axis is NOT worth damping",
    not pitchdamp.worthDamping(pitchdamp.OVERDAMPED, 1.6))
checkTrue("...nor is a fast-arresting unsprung one",
    not pitchdamp.worthDamping(pitchdamp.NO_SPRING, 1.6))
checkTrue("but an unsprung axis that wanders IS",
    pitchdamp.worthDamping(pitchdamp.NO_SPRING, 40))

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
