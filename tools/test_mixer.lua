-- Offline tests for fcs/mixer.lua.
--
-- The mixer has no ComputerCraft surface -- no peripherals, no rednet, no
-- clock, no coroutines -- so tools/cc_harness.lua is the wrong tool here.
-- That harness exists to reproduce CC's event scheduling, and there is no
-- scheduling to reproduce. Plain Lua runs these in milliseconds, which is what
-- makes them cheap enough to run on every edit.
--
--     luajit tools/test_mixer.lua          (from the repo root)

package.path = "./?.lua;" .. package.path

local mixer = require("fcs.mixer")
local baseProfile = require("fcs.mixer_profile")

-- ---------------------------------------------------------------------------
-- Test scaffolding
-- ---------------------------------------------------------------------------

local CORNERS = { "FL", "FR", "RL", "RR" }
local EPSILON = 1e-9

local passed, failed = 0, 0
local currentTest = "<none>"

local function fail(message)
    failed = failed + 1
    print(string.format("  FAIL  %s: %s", currentTest, message))
end

local function ok()
    passed = passed + 1
end

local function check(condition, message)
    if condition then ok() else fail(message) end
end

local function near(actual, expected, message)
    if type(actual) ~= "number" then
        fail(string.format("%s: expected a number, got %s", message, tostring(actual)))
        return
    end
    if math.abs(actual - expected) > 1e-9 then
        fail(string.format("%s: expected %.12f, got %.12f", message, expected, actual))
        return
    end
    ok()
end

local function test(name, body)
    currentTest = name
    local succeeded, err = pcall(body)
    if not succeeded then
        fail("threw: " .. tostring(err))
    end
end

-- Deep-copy the shipped profile so a test can vary one field without leaking
-- that change into the next test.
local function profileWith(overrides)
    local copy = {
        corners = {},
        props = { rpm = baseProfile.props.rpm },
        ion = {
            minimumPower = baseProfile.ion.minimumPower,
            maximumPower = baseProfile.ion.maximumPower,
            forcePerPower = baseProfile.ion.forcePerPower,
            quantumKN = baseProfile.ion.quantumKN,
        },
        authority = {
            roll = baseProfile.authority.roll,
            pitch = baseProfile.authority.pitch,
        },
        reference = { hoverCollective = baseProfile.reference.hoverCollective },
    }
    for _, corner in ipairs(CORNERS) do
        local source = baseProfile.corners[corner]
        copy.corners[corner] = {
            roll = source.roll,
            pitch = source.pitch,
            bias = source.bias,
        }
    end

    overrides = overrides or {}
    if overrides.symmetric then
        for _, corner in ipairs(CORNERS) do
            copy.corners[corner].bias = 0.0
        end
    end
    if overrides.authority then
        copy.authority.roll = overrides.authority.roll or copy.authority.roll
        copy.authority.pitch = overrides.authority.pitch or copy.authority.pitch
    end
    if overrides.forcePerPower ~= nil then
        copy.ion.forcePerPower = overrides.forcePerPower
    end
    return copy
end

local function demand(collective, roll, pitch, yaw)
    return { collective = collective, roll = roll or 0, pitch = pitch or 0, yaw = yaw or 0 }
end

-- ---------------------------------------------------------------------------
-- 1. Neutral demand
-- ---------------------------------------------------------------------------

test("neutral: all four corners equal (RR bias is now zero)", function()
    local profile = profileWith()
    local plan = mixer.allocate(profile, demand(0.5))

    near(plan.ions.FL, 0.5, "FL")
    near(plan.ions.FR, 0.5, "FR")
    near(plan.ions.RL, 0.5, "RL")
    near(plan.ions.RR, 0.5 + profile.corners.RR.bias, "RR")

    near(plan.props.rpm, profile.props.rpm, "prop rpm")
    check(plan.saturated == false, "should not be saturated")
    near(plan.attitudeScale, 1.0, "attitude scale")
    check(plan.collectiveClamped == false, "collective should not be clamped")
end)

-- ---------------------------------------------------------------------------
-- 2. Pure roll
-- ---------------------------------------------------------------------------

test("pure roll: port gains, starboard loses, by equal amounts", function()
    local profile = profileWith({ symmetric = true })
    local step = profile.authority.roll * 0.4
    local plan = mixer.allocate(profile, demand(0.5, 0.4, 0))

    -- Positive roll is starboard-low, so the port corners (FL, RL) push harder.
    near(plan.ions.FL, 0.5 + step, "FL")
    near(plan.ions.RL, 0.5 + step, "RL")
    near(plan.ions.FR, 0.5 - step, "FR")
    near(plan.ions.RR, 0.5 - step, "RR")

    check(plan.ions.FL > plan.ions.FR, "port must exceed starboard on positive roll")
end)

-- ---------------------------------------------------------------------------
-- 3. Pure pitch
-- ---------------------------------------------------------------------------

-- THIS TEST USED TO ASSERT THE BUG. It required "aft must exceed forward on
-- positive pitch", which is bow-DOWN, and so it passed happily against an
-- inverted sign table for the life of the project. The in-flight measurement
-- (+0.3 demand -> -2.12 deg/s^2) is what caught it, not this test.
--
-- Stated physically now: a positive pitch demand must raise the BOW, so the
-- FORWARD corners push harder. That is a hull-relative claim and holds
-- whichever way the craft is pointing.
test("pure pitch: FORWARD gains, aft loses, by equal amounts", function()
    local profile = profileWith({ symmetric = true })
    local step = profile.authority.pitch * 0.4
    local plan = mixer.allocate(profile, demand(0.5, 0, 0.4))

    near(plan.ions.FL, 0.5 + step, "FL")
    near(plan.ions.FR, 0.5 + step, "FR")
    near(plan.ions.RL, 0.5 - step, "RL")
    near(plan.ions.RR, 0.5 - step, "RR")

    check(plan.ions.FL > plan.ions.RL,
        "forward must exceed aft on positive pitch (bow-high)")
    check(plan.ions.FR > plan.ions.RR,
        "forward must exceed aft on positive pitch (bow-high)")
end)

-- ---------------------------------------------------------------------------
-- 4. Axis independence
--
-- This is the test that catches a sign-table error which tests 2 and 3 both
-- pass individually: a wrong coefficient can still be antisymmetric on each
-- axis alone and only show up when the two axes are combined.
-- ---------------------------------------------------------------------------

test("axis independence: roll+pitch equals roll alone plus pitch alone", function()
    local profile = profileWith({ symmetric = true })
    local collective = 0.5

    local both = mixer.allocate(profile, demand(collective, 0.3, -0.2))
    local rollOnly = mixer.allocate(profile, demand(collective, 0.3, 0))
    local pitchOnly = mixer.allocate(profile, demand(collective, 0, -0.2))

    check(both.saturated == false, "combined demand must stay unsaturated for this test to mean anything")

    for _, corner in ipairs(CORNERS) do
        local expected = rollOnly.ions[corner] + pitchOnly.ions[corner] - collective
        near(both.ions[corner], expected, corner)
    end
end)

-- ---------------------------------------------------------------------------
-- 5. Saturation is exact
-- ---------------------------------------------------------------------------

test("saturation: one corner lands exactly on a limit, none outside", function()
    local profile = profileWith({ symmetric = true })
    local plan = mixer.allocate(profile, demand(0.9, 1.0, 0))

    check(plan.saturated == true, "should report saturated")
    check(plan.attitudeScale < 1.0, "attitude scale should be reduced")

    local onLimit = false
    for _, corner in ipairs(CORNERS) do
        local power = plan.ions[corner]
        check(power >= profile.ion.minimumPower - EPSILON, corner .. " below minimum")
        check(power <= profile.ion.maximumPower + EPSILON, corner .. " above maximum")
        if math.abs(power - profile.ion.maximumPower) < 1e-9
            or math.abs(power - profile.ion.minimumPower) < 1e-9 then
            onLimit = true
        end
    end
    check(onLimit, "at least one corner must sit exactly on a limit")
end)

test("saturation is exact on an asymmetric craft: the output clamp never bites", function()
    -- The real profile, not the symmetric one, and a demand that saturates on
    -- RR -- the corner carrying the bias. Negative roll puts
    -- RR on the rising side.
    --
    -- The design's claim is that attitudeScale is solved exactly, so the
    -- defensive clamp inside allocate() is dead code in normal operation. If
    -- the scale solver forgets the effectiveness factor, the returned scale is
    -- too generous, RR overshoots the limit, and the clamp quietly rescues it
    -- -- clipping ONE corner instead of scaling the whole attitude, which
    -- distorts the commanded attitude direction. Every other saturation test
    -- misses this because it runs on a symmetric profile.
    --
    -- So: recompute each corner from the returned scale and require an exact
    -- match. A clamp that did anything shows up as a mismatch.
    local profile = profileWith()
    local demandVector = demand(0.9, -1.0, 0)
    local plan = mixer.allocate(profile, demandVector)

    check(plan.saturated == true, "precondition: demand must saturate")

    for _, corner in ipairs(CORNERS) do
        local coefficients = profile.corners[corner]
        local contribution = demandVector.roll * profile.authority.roll * coefficients.roll
            + demandVector.pitch * profile.authority.pitch * coefficients.pitch
        local raw = 0.9 + (coefficients.bias or 0) + contribution * plan.attitudeScale

        near(plan.ions[corner], raw, corner .. " was clipped rather than scaled")
        check(raw <= profile.ion.maximumPower + EPSILON,
            corner .. " unclamped command exceeded the maximum: " .. tostring(raw))
        check(raw >= profile.ion.minimumPower - EPSILON,
            corner .. " unclamped command fell below the minimum: " .. tostring(raw))
    end
end)

-- ---------------------------------------------------------------------------
-- 6. Collective is protected under saturation
-- ---------------------------------------------------------------------------

test("saturation: collective survives untouched", function()
    local profile = profileWith({ symmetric = true })
    local collective = 0.9
    local plan = mixer.allocate(profile, demand(collective, 1.0, 0))

    check(plan.saturated == true, "precondition: demand must saturate")

    -- With a symmetric profile and a pure roll demand, the attitude terms are
    -- equal and opposite, so the mean of the four commands IS the collective
    -- that was honoured. Any policy that sacrificed lift would move it.
    local total = 0
    for _, corner in ipairs(CORNERS) do
        total = total + plan.ions[corner]
    end
    near(total / 4, collective, "mean command must equal the demanded collective")
end)

-- ---------------------------------------------------------------------------
-- 7. Collective clamp
-- ---------------------------------------------------------------------------

test("collective above what the banks can deliver clamps and flags", function()
    local profile = profileWith({ symmetric = true })
    local plan = mixer.allocate(profile, demand(1.5))

    check(plan.collectiveClamped == true, "should flag the clamp")
    for _, corner in ipairs(CORNERS) do
        near(plan.ions[corner], profile.ion.maximumPower, corner)
    end
end)

test("collective clamp accounts for the corner bias", function()
    -- The shipped profile now has every bias at zero, so construct one to keep
    -- the clamp logic covered: a biased corner must reach the limit first.
    local profile = profileWith()
    profile.corners.RR.bias = 0.05
    local plan = mixer.allocate(profile, demand(1.0))

    check(plan.collectiveClamped == true, "should flag the clamp")
    near(plan.ions.RR, profile.ion.maximumPower, "RR must land on the limit, not past it")
    check(plan.ions.FL < profile.ion.maximumPower, "FL should sit below the limit")
end)

test("a sub-quantum bias is rejected as a modelling error", function()
    -- Guards the finding rather than merely commenting it: any bias smaller
    -- than one ion level (1/15) cannot deliver its intended correction and can
    -- only ever push a corner across a boundary by a whole level.
    local quantum = 1 / 15
    for _, corner in ipairs(CORNERS) do
        local bias = math.abs(baseProfile.corners[corner].bias or 0)
        check(bias == 0 or bias >= quantum,
            corner .. " has a sub-quantum bias " .. tostring(bias)
                .. " -- it cannot correct anything and will overshoot by ~76x")
    end
end)

test("collective below minimum clamps upward", function()
    local profile = profileWith({ symmetric = true })
    local plan = mixer.allocate(profile, demand(-0.4))

    check(plan.collectiveClamped == true, "should flag the clamp")
    for _, corner in ipairs(CORNERS) do
        near(plan.ions[corner], profile.ion.minimumPower, corner)
    end
end)

-- ---------------------------------------------------------------------------
-- 8. Attitude crushed to nothing
--
-- The dangerous case: the call returns cleanly, every field looks ordinary,
-- and the commanded roll has been scaled entirely away.
-- ---------------------------------------------------------------------------

test("attitude can be scaled to zero, and says so", function()
    local profile = profileWith({ symmetric = true })
    local plan = mixer.allocate(profile, demand(profile.ion.maximumPower, 1.0, 0))

    near(plan.attitudeScale, 0.0, "attitude scale")
    check(plan.saturated == true, "must flag saturated even though the call succeeded")
    for _, corner in ipairs(CORNERS) do
        near(plan.ions[corner], profile.ion.maximumPower, corner .. " should be pure collective")
    end
end)

-- ---------------------------------------------------------------------------
-- 9. Yaw is accepted, reported, and does nothing
-- ---------------------------------------------------------------------------

test("yaw leaves the corners alone and reports itself unmet", function()
    local profile = profileWith()
    local without = mixer.allocate(profile, demand(0.5, 0.2, -0.1, 0))
    local with = mixer.allocate(profile, demand(0.5, 0.2, -0.1, 0.8))

    for _, corner in ipairs(CORNERS) do
        near(with.ions[corner], without.ions[corner], corner .. " must not respond to yaw")
    end

    check(with.yawAvailable == false, "yawAvailable must be false")
    near(with.unmet.yaw, 0.8, "unmet yaw must echo the demand")
    near(without.unmet.yaw, 0.0, "no yaw demanded, none unmet")
end)

-- ---------------------------------------------------------------------------
-- 10. Property sweep
--
-- Catches saturation algebra that is wrong in a case nobody thought to write
-- a named test for.
-- ---------------------------------------------------------------------------

test("property sweep: no command ever escapes the power limits", function()
    local profile = profileWith()
    local minimum, maximum = profile.ion.minimumPower, profile.ion.maximumPower

    -- Fixed seed: a failure has to be reproducible to be debuggable.
    math.randomseed(20260825)

    local violations, scaleViolations = 0, 0
    for _ = 1, 5000 do
        local plan = mixer.allocate(profile, demand(
            math.random() * 1.4 - 0.2,   -- deliberately overruns both limits
            math.random() * 2 - 1,
            math.random() * 2 - 1,
            math.random() * 2 - 1))

        for _, corner in ipairs(CORNERS) do
            local power = plan.ions[corner]
            if power < minimum - EPSILON or power > maximum + EPSILON then
                violations = violations + 1
            end
        end
        if plan.attitudeScale < -EPSILON or plan.attitudeScale > 1 + EPSILON then
            scaleViolations = scaleViolations + 1
        end
    end

    check(violations == 0, violations .. " commands fell outside the power limits")
    check(scaleViolations == 0, scaleViolations .. " attitude scales fell outside [0, 1]")
end)

-- ---------------------------------------------------------------------------
-- 11. Hover regression
-- ---------------------------------------------------------------------------

test("hover point reproduces the measured configuration", function()
    local profile = profileWith()
    local plan = mixer.allocate(profile, demand(profile.reference.hoverCollective))

    near(plan.props.rpm, 64, "props must sit at the measured hover RPM")
    near(plan.ions.FL, 0.195, "FL")
    near(plan.ions.RR, 0.195 + profile.corners.RR.bias, "RR")
    check(plan.saturated == false, "hover must not saturate")
end)

-- ---------------------------------------------------------------------------
-- Expected-thrust reporting is advisory and opt-in
-- ---------------------------------------------------------------------------

test("expected thrust is absent unless the profile supplies a coefficient", function()
    local profile = profileWith({ forcePerPower = false })
    local plan = mixer.allocate(profile, demand(0.5))
    check(plan.expected == nil, "expected must be nil when forcePerPower is unset")
end)

test("expected thrust, when supplied, is quantised and does not alter commands", function()
    local withCoefficient = profileWith({ forcePerPower = 2400000 })
    local without = profileWith({ forcePerPower = false })

    local a = mixer.allocate(withCoefficient, demand(0.5, 0.3, 0))
    local b = mixer.allocate(without, demand(0.5, 0.3, 0))

    check(a.expected ~= nil, "expected should be populated")
    for _, corner in ipairs(CORNERS) do
        near(a.ions[corner], b.ions[corner], corner .. " command must not depend on forcePerPower")
        -- Assert on the multiple rather than a modulo: n*q %% q is not reliably
        -- zero in floating point, and a spurious failure here would send
        -- someone hunting a bug in the mixer that lives in the test.
        local multiple = a.expected[corner] / withCoefficient.ion.quantumKN
        check(math.abs(multiple - math.floor(multiple + 0.5)) < 1e-6,
            corner .. " expected thrust must be a whole quantum")
    end
end)

-- ---------------------------------------------------------------------------
-- Input validation
-- ---------------------------------------------------------------------------

test("out-of-range attitude demands are clamped, not obeyed", function()
    local profile = profileWith({ symmetric = true })
    local clamped = mixer.allocate(profile, demand(0.5, 5.0, 0))
    local atLimit = mixer.allocate(profile, demand(0.5, 1.0, 0))

    for _, corner in ipairs(CORNERS) do
        near(clamped.ions[corner], atLimit.ions[corner], corner)
    end
end)

test("a missing demand field is treated as zero", function()
    local profile = profileWith()
    local plan = mixer.allocate(profile, { collective = 0.5 })
    near(plan.ions.FL, 0.5, "FL")
    near(plan.attitudeScale, 1.0, "attitude scale")
end)

-- ---------------------------------------------------------------------------

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
