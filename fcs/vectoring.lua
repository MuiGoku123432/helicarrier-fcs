-- Thrust vectoring maths: what a tilted bearing pair actually does to the craft.
--
-- Pure functions, no peripherals, no rednet -- so the reasoning that decides
-- whether vectoring is viable at all can be tested offline, and the in-world
-- tool (/fcs/vectorprobe.lua) stays thin enough to read in one sitting. Same
-- split as fcs/craftgeom.lua, for the same reason.
--
-- THE QUESTION THIS EXISTS TO ANSWER. Each corner carries a COUNTER-ROTATING
-- PAIR. At rest they report thrust vectors {0,1,0} and {0,-1,0} with thrusts
-- +13960.98 and -13960.98 -- opposite directions AND opposite signs, which
-- multiply out to both pushing the craft UP. That is why the craft flies.
--
-- Tilt them both and the vertical components keep agreeing, but the LATERAL
-- components may add or may cancel, depending on how the partner's own normal
-- mirrors the tilt. props.lua says as much and stops there:
--
--     "WHAT IS NOT YET KNOWN: which way the resulting FORCE points ... the
--      mapping from a commanded tilt to a lateral force direction is
--      UNVERIFIED."
--
-- If they CANCEL, common-mode tilt produces no translation and the whole
-- vectoring plan -- position hold, the strafe fix, yaw -- needs another route.
-- Nobody has checked. It is one subtraction, and it gates everything.

local vectoring = {}

-- Body convention, from fcs/config.lua: +X port, +Y up, +Z bow.
--
-- NOT the convention props.lua's tiltTarget comment claims ("azimuth 0 is
-- toward +X (bow), 90 toward +Z (starboard)"). That comment predates the axis
-- correction and is wrong in exactly the way attitude.lua was wrong: it has
-- the bow on +X. The MATHS there is self-consistent -- azimuth 0 does produce
-- +X -- so what is wrong is the label, and +X is PORT.
--
-- This module therefore does not assume what an azimuth means. It reports the
-- direction it measures, in named terms, and the probe writes down the mapping.
local function axisComponent(vector, axis)
    if type(vector) ~= "table" then return nil end
    local byName = vector[axis]
    if type(byName) == "number" then return byName end
    -- getThrustVector is an ARRAY indexed 1/2/3, not {x=,y=,z=}. Reading .x/.y/.z
    -- off it yields three nils, which is how it came to be recorded as "returns
    -- nil" in HANDOFF for weeks. Accept both shapes so a caller cannot repeat it.
    local index = ({ x = 1, y = 2, z = 3 })[axis]
    local byIndex = index and vector[index]
    if type(byIndex) == "number" then return byIndex end
    return nil
end

function vectoring.toXYZ(vector)
    local x, y, z = axisComponent(vector, "x"), axisComponent(vector, "y"),
        axisComponent(vector, "z")
    if not x or not y or not z then return nil end
    return { x = x, y = y, z = z }
end

-- Force contributed by one bearing.
--
-- getThrust is SIGNED BY HANDEDNESS, not by world direction, and
-- getThrustVector is the bearing's own axis. Their product is the force, and
-- that product is why a pair reading {0,1,0}/{0,-1,0} with thrusts +T/-T both
-- lift: (+T)*{0,1,0} = up, and (-T)*{0,-1,0} = up as well.
--
-- Multiplying the magnitudes and ignoring the signs -- or taking |thrust| --
-- silently turns the pair into a cancelling one and inverts the answer this
-- module exists to give.
function vectoring.bearingForce(bearing)
    if type(bearing) ~= "table" then return nil end
    local direction = vectoring.toXYZ(bearing.thrustVector)
    local thrust = tonumber(bearing.thrust)
    if not direction or not thrust then return nil end
    return {
        x = direction.x * thrust,
        y = direction.y * thrust,
        z = direction.z * thrust,
    }
end

-- Vector sum of every bearing on a corner, plus what is needed to tell an
-- adding pair from a cancelling one.
--
-- `lateralOfSum`   -- the lateral magnitude the craft actually feels
-- `sumOfLaterals`  -- what it would feel if the bearings agreed perfectly
--
-- Their ratio is the whole answer: 1.0 is a perfectly adding pair, 0.0 a
-- perfectly cancelling one. Comparing the SUM against the SUM OF MAGNITUDES is
-- what distinguishes them; comparing either against a single bearing does not.
function vectoring.cornerForce(bearings)
    if type(bearings) ~= "table" or #bearings == 0 then return nil end

    local sum = { x = 0, y = 0, z = 0 }
    local sumOfLaterals = 0
    local counted = 0

    for _, bearing in ipairs(bearings) do
        local force = vectoring.bearingForce(bearing)
        if force then
            sum.x, sum.y, sum.z = sum.x + force.x, sum.y + force.y, sum.z + force.z
            sumOfLaterals = sumOfLaterals + math.sqrt(force.x ^ 2 + force.z ^ 2)
            counted = counted + 1
        end
    end
    if counted == 0 then return nil end

    local lateralOfSum = math.sqrt(sum.x ^ 2 + sum.z ^ 2)
    return {
        force = sum,
        bearings = counted,
        lateralOfSum = lateralOfSum,
        sumOfLaterals = sumOfLaterals,
        vertical = sum.y,
        -- Guarded: an untilted pair has no lateral component at all, and 0/0
        -- must not read as "cancelling".
        coherence = sumOfLaterals > 1e-9 and (lateralOfSum / sumOfLaterals) or nil,
    }
end

-- ADD or CANCEL, with a band of "neither" between them rather than a threshold
-- that turns a 0.5 into a confident wrong answer.
vectoring.ADDS = "ADDS"
vectoring.CANCELS = "CANCELS"
vectoring.PARTIAL = "PARTIAL"
vectoring.NO_TILT = "NO_TILT"

function vectoring.verdict(corner)
    if not corner or not corner.coherence then return vectoring.NO_TILT end
    if corner.coherence >= 0.90 then return vectoring.ADDS end
    if corner.coherence <= 0.10 then return vectoring.CANCELS end
    return vectoring.PARTIAL
end

-- Where a lateral force points, named in hull terms rather than axis letters.
--
-- Returned as degrees clockwise from the BOW when viewed from above, because
-- that is what a pilot and a controller both want, and because naming it this
-- way makes an azimuth convention error visible instead of arithmetic.
function vectoring.headingFromBow(force, axes)
    axes = axes or {}
    local bowAxis = axes.bowAxis or "z"
    local portAxis = axes.portAxis or "x"

    local vector = vectoring.toXYZ(force)
    if not vector then return nil end

    local alongBow = vector[bowAxis]
    local alongPort = vector[portAxis]
    if not alongBow or not alongPort then return nil end
    if math.abs(alongBow) < 1e-9 and math.abs(alongPort) < 1e-9 then return nil end

    -- Starboard is the negative of port, and clockwise-from-bow runs toward
    -- starboard, so the sideways term is negated.
    local degrees = math.deg(math.atan2(-alongPort, alongBow))
    if degrees < 0 then degrees = degrees + 360 end
    return degrees
end

function vectoring.describeHeading(degrees)
    if not degrees then return "none" end
    local names = {
        [0] = "BOW", [45] = "bow-starboard", [90] = "STARBOARD",
        [135] = "stern-starboard", [180] = "STERN", [225] = "stern-port",
        [270] = "PORT", [315] = "bow-port",
    }
    local nearest = math.floor((degrees % 360) / 45 + 0.5) * 45
    if nearest >= 360 then nearest = 0 end
    return names[nearest] or "?"
end

-- Roll and pitch torque from a set of corner forces, using the moment arms
-- fcs/craftgeom.lua derives from the inertia tensor.
--
-- Only the VERTICAL component of each corner's force makes a roll or pitch
-- moment about a horizontal axis -- the lateral part pushes the craft sideways
-- and, acting at hull level, contributes no roll about the centre of mass to
-- first order. Treating the whole force magnitude as a lifting force is the
-- easy mistake and it inflates the torque by 1/cos(tilt).
function vectoring.attitudeTorque(cornerForces, arms)
    if type(cornerForces) ~= "table" or not arms then return nil end

    local rollTorque, pitchTorque = 0, 0
    local counted = 0
    -- Port corners raise for positive roll; forward corners raise for positive
    -- pitch. Same relationships as mixer_profile's corner map, which is
    -- hull-relative and yaw-invariant.
    local signs = {
        FL = { roll = 1, pitch = 1 },
        FR = { roll = -1, pitch = 1 },
        RL = { roll = 1, pitch = -1 },
        RR = { roll = -1, pitch = -1 },
    }

    for corner, force in pairs(cornerForces) do
        local sign = signs[corner]
        local vertical = force and (force.vertical or (force.force and force.force.y))
        if sign and type(vertical) == "number" then
            rollTorque = rollTorque + sign.roll * arms.lateral * vertical
            pitchTorque = pitchTorque + sign.pitch * arms.longitudinal * vertical
            counted = counted + 1
        end
    end
    if counted == 0 then return nil end
    return { roll = rollTorque, pitch = pitchTorque, corners = counted }
end

-- Slope through the origin, for a staircase of tilt against measured response.
--
-- Through the origin deliberately: zero tilt must produce zero torque, so a
-- free intercept would spend a degree of freedom fitting the offset that a
-- drifting craft injects, which is exactly the contamination the axis-response
-- tool spent nine flights removing.
function vectoring.fitThroughOrigin(points)
    if type(points) ~= "table" or #points < 2 then return nil end
    local sxy, sxx = 0, 0
    for _, point in ipairs(points) do
        local x, y = tonumber(point.x), tonumber(point.y)
        if x and y then
            sxy = sxy + x * y
            sxx = sxx + x * x
        end
    end
    if sxx <= 0 then return nil end

    local slope = sxy / sxx
    local worst = 0
    for _, point in ipairs(points) do
        local x, y = tonumber(point.x), tonumber(point.y)
        if x and y and math.abs(y) > 1e-9 then
            local residual = math.abs((slope * x - y) / y)
            if residual > worst then worst = residual end
        end
    end
    return slope, worst
end

return vectoring
