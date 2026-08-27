-- Pitch damping from DIFFERENTIAL PROPELLER RPM, fore against aft.
--
-- HALF THE OSCILLATION THAT MAKES THE DRIFT CURVE IS THIS AXIS, AND NOTHING
-- DAMPS IT. The craft's heading swept -225 degrees in 47 s not because it is
-- being pushed round but because roll and pitch oscillate OUT OF PHASE, so the
-- tilt vector rotates. `rolldamp` arrested the roll half on 2026-08-27 -- 39%
-- less excursion, 40% faster decay. The pitch half has never been touched.
--
-- ---------------------------------------------------------------------------
-- WHAT IS UNKNOWN HERE, STATED FIRST, BECAUSE IT IS MOST OF THE FILE
--
-- TWO quantities this axis needs are UNMEASURED, and neither may be assumed
-- from roll:
--
--   1. THE AUTHORITY. deg/s^2 of pitch per rpm of fore/aft differential.
--   2. THE SPRING. The hull's self-levelling stiffness in pitch. Roll's is
--      0.0223, from a 42 s period observed once.
--
-- AND THE SIGN OF THE CORNER PATTERN IS A HYPOTHESIS. `CORNER_SIGNS` below
-- says raising FL and FR raises the bow. That is what the geometry says and it
-- is NOT what this craft has been measured to do -- the same reasoning about
-- roll was transposed for weeks, and the bearing coupling sign came back
-- opposite to prediction on one axis and not the other. A damper with its sign
-- inverted DRIVES the oscillation, confidently and at the right magnitude.
--
-- SO NOTHING HERE COMMANDS FROM A PREDICTION. `differentialFor` refuses -- it
-- returns 0 -- unless it is handed an authority and a spring that came from a
-- measurement. /fcs/pitchdampflight.lua measures all three in its first phase
-- and only then damps with them.
--
-- ---------------------------------------------------------------------------
-- WHAT CAN HONESTLY BE PREDICTED, AND WHY IT IS THE RATIO
--
-- The from-scratch thrust model predicted roll authority at 2.9x the measured
-- value and nobody has found the error; it lives somewhere in the propeller
-- force-per-RPM chain. Predicting pitch the same way inherits that error whole.
--
-- The ROLL/PITCH RATIO does not. It is unit-free:
--
--     ratio = (lateral arm / longitudinal arm) x (I_pitch / I_roll)
--
-- The force, the mass and the density correction all cancel, so whatever is
-- wrong in the force chain cancels with them. craftgeom solves it from the
-- LIVE inertia tensor: 1.91 on this hull. Applied to the MEASURED roll
-- authority of 0.0941 that gives
--
--     pitch authority ~ 0.0941 / 1.91 = 0.0493 deg/s^2 per rpm
--
-- which is a real prediction with a real basis, and the flight is a test of it
-- rather than a hunt. Pitch is weaker because 4.49x the inertia beats 2.35x
-- the arm.
--
-- THE SPRING HAS NO SUCH SHORTCUT. If the restoring TORQUE per degree were
-- equal on both axes then k_pitch = k_roll / 4.49 = 0.00497 -- an 89 second
-- period, twice roll's -- and critical damping would be 0.141 rather than
-- 0.299. Assuming roll's number would set the gain 2.1x too high, which on a
-- rate loop is how a damper starts ringing. It is a guess either way, so the
-- flight measures the period and derives the spring from it.

local rolldamp = require("fcs.rolldamp")
local craftgeom = require("fcs.craftgeom")

local pitchdamp = {}

-- POSITIVE DIFFERENTIAL RAISES THE BOW -- a hypothesis, not a measurement.
--
-- Positive pitch is bow-high (attitude.lua), so raising the forward corners
-- should give a positive pitch. The flight tool measures the sign it actually
-- gets and flips this if the craft disagrees; it does not assume it was right.
pitchdamp.CORNER_SIGNS = { FL = 1, FR = 1, RL = -1, RR = -1 }

pitchdamp.MEASURED = {
    -- getInertiaTensor t[1][1], the PORT axis -- pitch is rotation about it.
    -- 4.49x the roll inertia, which is why this axis is the sluggish one.
    pitchInertia = 389383646.66,
    -- From craftgeom's hull box: half the 205.1 block length.
    longitudinalArm = 102.55,

    -- NOT MEASURED. Left nil deliberately rather than filled with roll's
    -- values: a number here would be commanded, and a wrong one commanded
    -- confidently is this project's most expensive failure mode. The flight
    -- fills them in and reports them; when they have flown twice and agree,
    -- write them here with their evidence, the way rolldamp records its three
    -- paired steps.
    flightAuthorityPerRpm = nil,
    springPerDegree = nil,
}

-- The unit-free geometric ratio, from the LIVE tensor when there is one.
--
-- Falls back to the recorded hull only when no tensor is available, and says
-- which it used -- the craft gains mass and shifts its centre of mass every
-- time a machine is bolted on, and this ratio moves with it.
pitchdamp.RECORDED_RATIO = 1.908

function pitchdamp.rollPitchRatio(tensor, mass, axes)
    if tensor and mass then
        local ratio = craftgeom.expectedRatio(tensor, mass, axes)
        if ratio and ratio > 0 then return ratio, "live tensor" end
    end
    return pitchdamp.RECORDED_RATIO, "recorded hull"
end

-- The prediction worth flying against: measured roll authority over the ratio.
--
-- NOT the from-scratch thrust model. That route reads 2.9x high on roll for
-- reasons nobody has found, and the ratio cancels exactly that error.
function pitchdamp.predictedAuthority(options)
    options = options or {}
    local roll = options.rollAuthorityPerRpm
        or rolldamp.MEASURED.flightAuthorityPerRpm
    local ratio, source = pitchdamp.rollPitchRatio(options.tensor, options.mass,
        options.axes)
    if not roll or not ratio or ratio <= 0 then return nil end
    return roll / ratio, ratio, source
end

-- What the spring would be if the restoring TORQUE per degree matched roll's.
--
-- A HYPOTHESIS, and the flight exists to replace it. Reported so the measured
-- period has something to be surprising against: this says 89 s, roll's own
-- number says 42 s, and those are far enough apart that the measurement cannot
-- be ambiguous about which world the craft is in.
function pitchdamp.springIfTorqueMatchesRoll(options)
    options = options or {}
    local rollSpring = options.rollSpringPerDegree
        or rolldamp.MEASURED.springPerDegree
    local rollInertia = options.rollInertia or rolldamp.MEASURED.rollInertia
    local pitchInertia = options.pitchInertia or pitchdamp.MEASURED.pitchInertia
    if not rollSpring or not rollInertia or not pitchInertia
        or pitchInertia <= 0 then
        return nil
    end
    return rollSpring * (rollInertia / pitchInertia)
end

-- ---------------------------------------------------------------------------
-- WHAT KIND OF AXIS IS THIS?
--
-- Written after run 1, which answered a question nobody had asked and left the
-- one everybody had assumed. The premise of this whole file was that pitch is
-- underdamped like roll -- roll rings through 5 zero crossings over 105 s -- and
-- that damping it would arrest half the oscillation that makes the drift curve.
--
-- THE CRAFT DISAGREED. A 3 rpm pulse produced 0.396 deg/s and 1.80 degrees of
-- pitch, and then: ZERO zero crossings in 120 seconds, rate down to 1/e in
-- 1.6 s. That is not an underdamped oscillator. Something arrests pitch rate
-- hard and fast, and a rate damper added to an axis that already stops itself
-- in under two seconds buys nothing.
--
-- But "it did not oscillate" has TWO very different explanations and they lead
-- opposite ways:
--
--   OVERDAMPED   there is a restoring spring, and enough damping that the hull
--                creeps back to level without overshooting. The axis is
--                healthy and needs no damper.
--
--   NO SPRING    there is damping but little or no restoring moment, so the
--                hull STAYS at whatever pitch it is left at. That is a much
--                bigger finding than a missing damper: it means pitch has no
--                self-levelling to help the velocity loop, and every standing
--                pitch offset in this project's history is a parked attitude
--                rather than an equilibrium.
--
-- They are told apart by ONE number: did the angle come back? Hence the
-- baseline window in the flight tool, and this classifier.
-- ---------------------------------------------------------------------------

pitchdamp.UNDERDAMPED = "UNDERDAMPED"
pitchdamp.OVERDAMPED = "OVERDAMPED"
pitchdamp.NO_SPRING = "NO SPRING"
pitchdamp.UNCLEAR = "UNCLEAR"

-- Returns verdict, returnedFraction.
--
-- `returned` is how much of the excursion the hull gave back: 1.0 is all the
-- way home, 0.0 is parked where the pulse left it. The thresholds are wide
-- because the standing offset drifts between flights and the measurement is a
-- difference of angles a few tenths of a degree apart.
function pitchdamp.classify(options)
    options = options or {}
    local crossings = options.crossings or 0
    local baseline, peak, final = options.baseline, options.peak, options.final

    if crossings >= 2 then return pitchdamp.UNDERDAMPED, nil end
    if not baseline or not peak or not final then
        return pitchdamp.UNCLEAR, nil
    end

    local excursion = peak - baseline
    -- An excursion smaller than the noise cannot be divided by. The pulse is
    -- supposed to move the craft more than a tenth of a degree; if it did not,
    -- the disturbance check upstream should already have said so.
    if math.abs(excursion) < 0.15 then return pitchdamp.UNCLEAR, nil end

    local returned = (peak - final) / excursion
    if returned >= 0.6 then return pitchdamp.OVERDAMPED, returned end
    if returned <= 0.25 then return pitchdamp.NO_SPRING, returned end
    return pitchdamp.UNCLEAR, returned
end

-- Is a rate damper worth adding to this axis at all?
--
-- The honest answer for an axis that arrests itself in 1.6 s is NO, and this
-- file should say so rather than damping because it was built to damp.
function pitchdamp.worthDamping(verdict, decaySeconds)
    if verdict == pitchdamp.UNDERDAMPED then return true end
    if decaySeconds and decaySeconds <= 5.0 then return false end
    -- NO SPRING with a slow decay still wants damping -- the hull will wander
    -- otherwise -- even though there is no oscillation to arrest.
    return verdict == pitchdamp.NO_SPRING
end

function pitchdamp.criticalDamping(springPerDegree)
    if type(springPerDegree) ~= "number" or springPerDegree <= 0 then return nil end
    return 2 * math.sqrt(springPerDegree)
end

pitchdamp.DEFAULTS = {
    maxDifferentialRpm = 4,
    deadbandRate = 0.05,
    -- Below this an authority is indistinguishable from the craft drifting,
    -- and dividing a wanted torque by it produces a saturated command built
    -- out of noise. Same guard, and the same reasoning, as trim.tiltFor.
    minimumUsableAuthority = 0.005,
    maxCombinedRpm = 6,
}

-- The damper: oppose the pitch RATE. Refuses rather than guesses.
--
-- Returns differential, reason. A zero with a reason is not a failure -- it is
-- this file declining to command an axis whose response it has not been told.
-- Every other damper in this project defaults to a stored constant; this one
-- cannot, because there is no honest constant to store yet.
function pitchdamp.differentialFor(pitchRate, options)
    options = options or {}
    local perRpm = options.authorityPerRpm or pitchdamp.MEASURED.flightAuthorityPerRpm
    local spring = options.springPerDegree or pitchdamp.MEASURED.springPerDegree
    local minimum = options.minimumUsableAuthority
        or pitchdamp.DEFAULTS.minimumUsableAuthority

    if not perRpm then
        return 0, "no measured pitch authority -- fly /fcs/pitchdampflight.lua"
    end
    if math.abs(perRpm) < minimum then
        return 0, string.format("authority %.4f is below the %.4f needed to trust it",
            perRpm, minimum)
    end

    local gain = options.dampingGain
    if not gain then
        if not spring then
            return 0, "no measured pitch spring -- critical damping is unknown"
        end
        gain = pitchdamp.criticalDamping(spring)
    end
    if not gain then return 0, "no damping gain" end

    local maxRpm = options.maxDifferentialRpm or pitchdamp.DEFAULTS.maxDifferentialRpm
    local deadband = options.deadbandRate or pitchdamp.DEFAULTS.deadbandRate
    pitchRate = pitchRate or 0
    if math.abs(pitchRate) < deadband then return 0, "inside the deadband" end

    -- SIGNED authority throughout. If the flight measured a NEGATIVE authority
    -- -- a positive differential dropping the bow -- the division flips the
    -- command with it, and the damper still damps. That is the whole reason
    -- the measurement is signed: the alternative is a tool that works on the
    -- sign its author guessed and drives the craft on the other.
    local wanted = -gain * pitchRate
    local rpm = wanted / perRpm

    local rounded = rpm >= 0 and math.floor(rpm + 0.5) or -math.floor(-rpm + 0.5)
    if rounded > maxRpm then rounded = maxRpm end
    if rounded < -maxRpm then rounded = -maxRpm end
    return rounded, nil
end

-- Per-corner rpm for a fore/aft differential. rolldamp.cornerRpm does the
-- clamping and the rounding; only the sign pattern differs between the axes.
function pitchdamp.cornerRpm(baseRpm, differential, options)
    options = options or {}
    options.signs = options.signs or pitchdamp.CORNER_SIGNS
    return rolldamp.cornerRpm(baseRpm, differential, options)
end

-- COMBINED: one set of four rpms carrying both dampers at once.
--
-- The two patterns are orthogonal -- port/starboard against fore/aft -- so
-- they superpose, and the corner floor applies once at the end rather than
-- twice. This is what a craft with both axes damped actually sends.
--
-- Reported saturation matters: if the sum clips, the two demands are no longer
-- being delivered in the proportion they were asked for, and a caller reading
-- back "4 rpm of roll damping" would be wrong about which axis got it.
function pitchdamp.combinedCornerRpm(baseRpm, rollDifferential, pitchDifferential,
    options)
    options = options or {}
    local floor = options.minimumRpm or 8
    -- The SUM's clamp, which is deliberately not the per-axis one. Each damper
    -- is clamped to 4 and the patterns are orthogonal, so a corner can be asked
    -- for 8 -- 12.5% of the base rpm, a lift asymmetry nobody sized for. 6 is
    -- the compromise that lets a 3 rpm measurement pulse coexist with a fully
    -- saturated roll damper instead of being eaten by it.
    local maxRpm = options.maxCombinedRpm or pitchdamp.DEFAULTS.maxCombinedRpm

    local result, clipped = {}, false
    for _, corner in ipairs({ "FL", "FR", "RL", "RR" }) do
        local combined = rolldamp.ROLL_SIGNS[corner] * (rollDifferential or 0)
            + pitchdamp.CORNER_SIGNS[corner] * (pitchDifferential or 0)
        if combined > maxRpm then combined, clipped = maxRpm, true end
        if combined < -maxRpm then combined, clipped = -maxRpm, true end
        local rpm = (baseRpm or 0) + combined
        if rpm < floor then rpm = floor end
        result[corner] = math.floor(rpm + 0.5)
    end
    return result, clipped
end

return pitchdamp
