-- Cancel horizontal motion by pointing the propeller bearings against it.
--
-- WHY THIS AND NOT ATTITUDE DAMPING. The plan was: damp roll/pitch rate, the
-- tilt vector stops rotating, the craft stops carving its spiral. Measurement
-- on 2026-08-26 inverted that.
--
-- Roll torque from the bearings is marginal. It has to come from differential
-- tilt MAGNITUDE -- one side shedding more lift as cos(tilt) -- which yields
-- 0.084 deg/s^2 at 8 degrees and 0.295 at the 15 degree clamp, against the
-- 0.268 that critical damping needs. Only just enough, at the mechanical limit.
--
-- Lateral FORCE from the same bearings is strong and was measured directly:
--
--     lateral = 2 * T * sin(tilt) per corner, linear to 0.06% over 4/6/8 deg
--     8 deg, four corners  -> 1.34% of weight -> terminal 1.64 blocks/s
--     15 deg, four corners -> 2.49% of weight -> terminal 3.05 blocks/s
--
-- against a measured strafe of 1.67 blocks/s mean, 2.27 peak. The actuator is
-- matched to the disturbance it has to cancel, on the axis where it is strong.
--
-- So this does not fix the attitude oscillation. It cancels the oscillation's
-- CONSEQUENCE -- the translation -- which is what "hold X and Z" actually
-- asks for. The hull can keep rocking; the craft stays put.

local attitude = require("fcs.attitude")

local lateralhold = {}

-- Measured, not assumed: /fcs/vectorprobe.lua ground run reported
-- "AZIMUTH 0 DEGREES PUSHES TOWARD 90 deg = STARBOARD".
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
}

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

return lateralhold
