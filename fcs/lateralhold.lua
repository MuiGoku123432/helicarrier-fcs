-- Hold station by controlling ROLL, with the bearings as the torque source.
--
-- THE PLAN CHANGED TWICE, AND BOTH TURNS WERE MEASUREMENTS.
--
-- First: damp roll RATE with differential ion thrust. Dead. One ion level is
-- 7.42 deg/s^2 of attitude command against the 0.268 damping needs -- 28x too
-- coarse, and 166-333x too coarse to hold a small tilt.
--
-- Second: forget attitude, oppose the translation directly with bearing tilt.
-- The lateral force is real and was measured (2*T*sin(tilt), linear to 0.06%),
-- but this flew and ran away. Lateral thrust acts at the BEARINGS, about 8.6
-- blocks ABOVE the centre of mass, so it is mostly a roll command:
--
--     tilt -> roll     ~0.011 deg/s^2 per degree of tilt
--     roll -> lateral   0.19 blocks/s^2 per DEGREE
--     tilt -> lateral   0.0185 blocks/s^2 per degree, directly
--
-- The roll path is TEN TIMES the direct one, and it compounds: pushing
-- starboard rolls starboard-low, the lift vector tilts starboard, the craft
-- accelerates starboard. Commanding tilt without attitude feedback is positive
-- feedback, and the craft went 1.76 -> 11.5 blocks/s in ten seconds with roll
-- climbing the whole way.
--
-- So, third and current: ROLL IS THE CONTROLLED VARIABLE. The outer loop picks
-- a small roll target from the velocity error; the inner loop uses tilt to
-- hold that roll, with a rate term for the damping the hull has never had.
-- The strong coupling that caused the runaway is the thing doing the work --
-- it just has to be inside the loop rather than outside it.

local attitude = require("fcs.attitude")

local lateralhold = {}

-- MEASURED ON FL ONLY, AND THAT IS THE PROBLEM. The ground runs reported
-- "AZIMUTH 0 DEGREES PUSHES TOWARD 90 deg = STARBOARD" -- from FL, three times,
-- and FL's own numbers are unambiguous (-13958.80 x +0.1392 = -1943 in X, and
-- -X is starboard).
--
-- But the hover runaway rolled POSITIVE while opposing the drift required
-- NEGATIVE, which cannot happen if all four corners push the way FL does. So
-- the corners very likely DISAGREE, and this single offset is a placeholder
-- until /fcs/vectorprobe.lua has swept all four. Do not close a loop on it.
--
-- The maths behind it, which the measurement anchors: a bearing's lateral
-- target is {sin(t)cos(az), _, sin(t)sin(az)} and bearing 1 carries NEGATIVE
-- thrust, so its force runs along {-cos(az), -sin(az)} in (x, z). At azimuth 0
-- that is -X, and -X is starboard because +X is port. Stepping azimuth then
-- walks the force starboard -> stern -> port -> bow.
--
--     azimuth 0 -> starboard (heading 90)      azimuth 90  -> stern (180)
--     azimuth 180 -> port    (heading 270)     azimuth 270 -> bow   (0)
--
-- so heading = azimuth + 90, and the inverse is what a controller needs.
lateralhold.AZIMUTH_HEADING_OFFSET = 90

function lateralhold.azimuthForHeading(headingDegrees)
    if type(headingDegrees) ~= "number" then return nil end
    return (headingDegrees - lateralhold.AZIMUTH_HEADING_OFFSET) % 360
end

function lateralhold.headingForAzimuth(azimuthDegrees)
    if type(azimuthDegrees) ~= "number" then return nil end
    return (azimuthDegrees + lateralhold.AZIMUTH_HEADING_OFFSET) % 360
end

-- Horizontal velocity in BODY axes.
--
-- getLinearVelocity is world-frame, and the bearings are bolted to the hull, so
-- a controller that skips this conversion steers by whatever heading the craft
-- happened to be pointing when it launched. Both calls are pure arithmetic on
-- the quaternion the cheap read already carries -- no extra Sable call, so this
-- costs nothing against the pods' 750 ms command timeout.
function lateralhold.bodyVelocity(state)
    if not state or not state.quaternion or not state.linearVelocityWorld then
        return nil
    end
    local matrix = attitude.rotationMatrix(state.quaternion)
    if not matrix then return nil end
    return attitude.worldToBody(matrix, state.linearVelocityWorld)
end

-- Heading of the horizontal part of a body-frame vector, degrees clockwise from
-- the bow. Same convention as fcs.vectoring.headingFromBow.
function lateralhold.headingOf(bodyVector, axes)
    axes = axes or {}
    if not bodyVector then return nil, 0 end
    local alongBow = bodyVector[axes.bowAxis or "z"] or 0
    local alongPort = bodyVector[axes.portAxis or "x"] or 0
    local speed = math.sqrt(alongBow ^ 2 + alongPort ^ 2)
    if speed < 1e-9 then return nil, 0 end
    local degrees = math.deg(math.atan2(-alongPort, alongBow)) % 360
    return degrees, speed
end

-- The control law: proportional, with a deadband and a clamp.
--
-- Proportional and nothing more, deliberately. An integral term against a
-- disturbance that is itself oscillating at a 42 s period would wind up and
-- fight the next half-cycle, and there is no rate signal here worth
-- differentiating -- speed is already the derivative of the thing being held.
--
-- The DEADBAND matters more than the gain. Below it the tilt is commanded to
-- zero rather than to something small: every tilt costs lift as cos(angle), and
-- chattering the bearings around neutral to chase 0.05 blocks/s would trade
-- altitude for nothing. It also stops the loop fighting sensor noise.
--
-- The CLAMP sits below props.lua's own 15 degree limit. Being clamped
-- pod-side would mean the commanded and actual tilt silently disagree, and
-- every measurement taken afterwards would be of an unknown angle -- which is
-- exactly how the 12 degree ground step came back reading 10.84.
lateralhold.DEFAULTS = {
    gainDegreesPerSpeed = 6.0,
    deadbandSpeed = 0.08,
    maxTiltDegrees = 12.0,

    -- ATTITUDE FEEDBACK. Everything below exists because the first hover
    -- attempt ran away, and the flight log says why.
    --
    -- Lateral thrust acts at the BEARINGS, which sit about 8.6 blocks above
    -- the centre of mass (solved from the observed 0.132 deg/s^2 of roll at
    -- the 12 degree clamp against I_roll = 86.77e6). So a lateral command is
    -- mostly a ROLL command:
    --
    --     tilt  ->  roll at ~0.011 deg/s^2 per degree of tilt
    --     roll  ->  lateral at 0.19 blocks/s^2 per DEGREE
    --     tilt  ->  lateral at 0.0185 blocks/s^2 per degree, directly
    --
    -- The roll path is TEN TIMES the direct path per degree, and it compounds:
    -- pushing starboard rolls starboard-low, which tilts the lift vector
    -- starboard, which accelerates the craft starboard. Commanding tilt with no
    -- attitude feedback is positive feedback. Measured: 1.76 -> 11.5 blocks/s
    -- in ten seconds, roll climbing monotonically the whole way.
    --
    -- So roll is now the controlled variable and tilt is what controls it.
    -- rollLimit is deliberately tiny: 0.19 blocks/s^2 per degree means 2
    -- degrees already holds against 4.2 blocks/s of drift, against a strafe
    -- that peaks at 2.27. There is no reason to ever ask for more, and every
    -- degree past it buys acceleration the loop then has to undo.
    rollLimitDegrees = 2.0,
    rollGainTiltPerDegree = 4.0,
    rollRateGainTiltPerRate = 8.0,
    rollAbortDegrees = 6.0,
}

-- Roll a level craft needs in order to accelerate laterally at `wanted`.
-- 0.19 blocks/s^2 per degree, from the strafe measurement: 0.0706 blocks/s^2
-- at 0.368 deg of mean roll, and 0.1225 at 0.638 deg -- 0.192 and 0.192.
lateralhold.LATERAL_PER_ROLL_DEGREE = 0.19

function lateralhold.rollForLateral(wanted, options)
    options = options or {}
    local limit = options.rollLimitDegrees or lateralhold.DEFAULTS.rollLimitDegrees
    local perDegree = options.lateralPerRollDegree
        or lateralhold.LATERAL_PER_ROLL_DEGREE
    local roll = wanted / perDegree
    if roll > limit then roll = limit end
    if roll < -limit then roll = -limit end
    return roll
end

-- Returns { tilt, azimuth, speed, heading } -- or a zero command with a reason
-- when it cannot or should not act. Never returns nil for a live state, so a
-- caller cannot accidentally leave the last tilt standing.
function lateralhold.command(state, axes, options)
    options = options or {}
    local gain = options.gainDegreesPerSpeed
        or lateralhold.DEFAULTS.gainDegreesPerSpeed
    local deadband = options.deadbandSpeed or lateralhold.DEFAULTS.deadbandSpeed
    local maxTilt = options.maxTiltDegrees or lateralhold.DEFAULTS.maxTiltDegrees

    local body = lateralhold.bodyVelocity(state)
    if not body then
        return { tilt = 0, azimuth = 0, speed = nil, reason = "no body velocity" }
    end

    local heading, speed = lateralhold.headingOf(body, axes)
    if not heading or speed < deadband then
        return { tilt = 0, azimuth = 0, speed = speed, reason = "within deadband" }
    end

    -- Push OPPOSITE the way the craft is moving.
    local opposing = (heading + 180) % 360
    local tilt = gain * speed
    if tilt > maxTilt then tilt = maxTilt end

    return {
        tilt = tilt,
        azimuth = lateralhold.azimuthForHeading(opposing),
        speed = speed,
        heading = heading,
        opposing = opposing,
        saturated = (gain * speed) > maxTilt,
    }
end

-- What steady speed a given tilt can hold against, from the measured force and
-- the dimension's linear drag. Used to say plainly whether the craft is being
-- asked to cancel more drift than the bearings can produce.
--
--   lateral force  = 4 corners * 2 * T * sin(tilt)
--   acceleration   = force / mass, in blocks/s^2 with gravity 11
--   terminal speed = acceleration / universalDrag
function lateralhold.terminalSpeed(tiltDegrees, options)
    options = options or {}
    local thrustPerBearing = options.thrustPerBearing or 13960.98
    local weight = options.weight or 1158293.4
    local drag = options.universalDrag or 0.09
    local gravity = options.gravity or 11.0

    local force = 4 * 2 * thrustPerBearing * math.sin(math.rad(tiltDegrees))
    local acceleration = (force / weight) * gravity
    return acceleration / drag, acceleration
end

-- ---------------------------------------------------------------------------
-- SUPERPOSITION: one bearing, two demands
--
-- Each corner carries a prop facing UP and a prop facing DOWN, straddling the
-- centre of mass at +ha and -hb. That gives two independent channels, and the
-- ground sweep measured both:
--
--   both bearings pushed the SAME way  -> lateral 2F, torque as (ha - hb)
--   both bearings pushed OPPOSITE ways -> lateral 0.0 (measured, exactly),
--                                         torque as (ha + hb)
--
-- The second is a PURE ROLL COUPLE with no translation, and it is the strong
-- one: a sum where the other is a difference. |ha - hb| solves to 8.6 blocks
-- from the observed coupling, so if ha + hb is 20 blocks the couple delivers
-- 0.307 deg/s^2 at 12 degrees -- past the 0.268 critical damping needs. The
-- zeta = 0.5 ceiling was an artefact of using the weak channel.
--
-- It also explains the sign that caused the runaway: (ha - hb) is a difference
-- of two similar numbers, so which way it rolls depends on which prop sits
-- further from the COM. Not derivable. Only measurable.
--
-- A bearing can only point one way, so the two demands SUPERPOSE as 2D vectors
-- in force-heading space, magnitudes in degrees of tilt:
--
--     upper bearing  <-  L + A
--     lower bearing  <-  L - A
--
-- A = 0 reproduces the mirrored command exactly, so "mirrored" stops being a
-- mode and becomes a special case.
--
-- POLARITY IS READ, NEVER ASSUMED. Commanding azimuth phi to an UP-facing
-- bearing produces force at heading phi + 90; to a DOWN-facing one, phi + 270.
-- Which physical bearing faces which way DIFFERS BY CORNER -- FL's bearing_1
-- faces up, RL's bearing_7 faces down -- so it comes from the telemetry vy
-- sign, the same thing props.lua keys its own vertical sign off.
-- ---------------------------------------------------------------------------

local function toVector(headingDegrees, magnitude)
    local radians = math.rad(headingDegrees or 0)
    return {
        bow = (magnitude or 0) * math.cos(radians),
        starboard = (magnitude or 0) * math.sin(radians),
    }
end

local function toPolar(vector)
    local magnitude = math.sqrt(vector.bow ^ 2 + vector.starboard ^ 2)
    if magnitude < 1e-9 then return 0, 0 end
    return math.deg(math.atan2(vector.starboard, vector.bow)) % 360, magnitude
end

-- Azimuth that makes ONE bearing push toward `heading`, given which way it
-- faces. facingUp is the sign of the bearing's own thrust vector y component.
function lateralhold.azimuthFor(heading, facingUp)
    local offset = facingUp and 90 or 270
    return (heading - offset) % 360
end

-- Per-bearing commands for a translation demand and an attitude demand.
--
-- `translation` and `attitude` are { heading, tilt } -- a direction in
-- force-heading space and a magnitude in DEGREES OF TILT. `bearings` is the
-- corner's telemetry, each entry carrying a thrustVector whose y component
-- says which way that bearing faces.
--
-- Returns one entry per bearing: { index, tilt, azimuth, facingUp }.
function lateralhold.bearingCommands(translation, attitude, bearings, options)
    options = options or {}
    local maxTilt = options.maxTiltDegrees or lateralhold.DEFAULTS.maxTiltDegrees
    if type(bearings) ~= "table" then return nil end

    local L = toVector(translation and translation.heading,
        translation and translation.tilt)
    local A = toVector(attitude and attitude.heading, attitude and attitude.tilt)

    local commands = {}
    for index, bearing in ipairs(bearings) do
        local vector = bearing.thrustVector
        local vy = vector and (vector[2] or vector.y)
        if type(vy) == "number" and math.abs(vy) > 1e-6 then
            local facingUp = vy > 0
            local sign = facingUp and 1 or -1
            local combined = {
                bow = L.bow + sign * A.bow,
                starboard = L.starboard + sign * A.starboard,
            }
            local heading, tilt = toPolar(combined)
            -- Clamped per bearing. Clamping the DEMAND instead would silently
            -- rotate the resultant, turning a saturated roll command into a
            -- translation command pointing somewhere nobody asked for.
            if tilt > maxTilt then tilt = maxTilt end
            commands[#commands + 1] = {
                index = index,
                tilt = tilt,
                azimuth = lateralhold.azimuthFor(heading, facingUp),
                facingUp = facingUp,
                saturated = tilt >= maxTilt,
            }
        end
    end
    if #commands == 0 then return nil end
    return commands
end

-- The INNER loop: hold a roll angle, using tilt as the torque source.
--
-- Proportional on the angle error plus a rate term, and the rate term is the
-- whole point -- it is the damping the craft has never had. The hull's own
-- restoring spring is underdamped (5 zero crossings, 42 s period); this adds
-- the missing half.
--
-- HONEST LIMIT, so nobody expects more than it can give: at the 12 degree tilt
-- clamp the available roll torque is 0.132 deg/s^2, against the 0.268 that
-- critical damping wants at the strafe's 0.90 deg/s peak rate. So this reaches
-- about zeta = 0.5 when saturated, and true critical damping below roughly
-- 0.44 deg/s where it is not. Better than underdamped, not dead-beat.
function lateralhold.rollTilt(rollDegrees, rollRate, targetRoll, options)
    options = options or {}
    local angleGain = options.rollGainTiltPerDegree
        or lateralhold.DEFAULTS.rollGainTiltPerDegree
    local rateGain = options.rollRateGainTiltPerRate
        or lateralhold.DEFAULTS.rollRateGainTiltPerRate
    local maxTilt = options.maxTiltDegrees or lateralhold.DEFAULTS.maxTiltDegrees

    local error = (targetRoll or 0) - (rollDegrees or 0)
    local tilt = angleGain * error - rateGain * (rollRate or 0)
    if tilt > maxTilt then tilt = maxTilt end
    if tilt < -maxTilt then tilt = -maxTilt end
    return tilt
end

-- Is the attitude outside the envelope this loop is allowed to operate in?
-- Separate from the drift abort: a craft can be rolling past the limit while
-- still near its station, and that is the more dangerous of the two.
function lateralhold.rollAbort(rollDegrees, options)
    options = options or {}
    local limit = options.rollAbortDegrees or lateralhold.DEFAULTS.rollAbortDegrees
    return math.abs(rollDegrees or 0) > limit
end

return lateralhold
