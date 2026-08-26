local attitude = {}

-- Two-argument math.atan is Lua 5.3+. Under Lua 5.1 semantics -- LuaJIT, and
-- CC's Cobalt -- math.atan takes ONE argument and SILENTLY IGNORES the second,
-- so `math.atan(y, x)` quietly degrades to `math.atan(y)`.
--
-- That is not a rounding difference. It drops the denominator and the
-- quadrant: roll reads 4.98 for a true 5 degrees, 18.88 for 20, 35.26 for 45,
-- and cannot exceed +/-90 at all. Yaw, which is atan(forward.z, forward.x),
-- loses its quadrant entirely.
--
-- math.atan2 exists in 5.1 and was removed in 5.3, while 5.3 gained the
-- two-argument math.atan -- so this picks the correct one on either.
--
-- Beware of "verifying" this with atan(1, 1): atan(1) and atan2(1, 1) are BOTH
-- pi/4, so that test passes under the bug.
local atan2 = math.atan2 or math.atan


local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

function attitude.rotationMatrix(q)
    local length = math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w)
    if length == 0 then
        error("orientation quaternion has zero length", 0)
    end

    local x, y, z, w = q.x / length, q.y / length, q.z / length, q.w / length

    return {
        1 - 2 * (y * y + z * z),
        2 * (x * y - z * w),
        2 * (x * z + y * w),

        2 * (x * y + z * w),
        1 - 2 * (x * x + z * z),
        2 * (y * z - x * w),

        2 * (x * z - y * w),
        2 * (y * z + x * w),
        1 - 2 * (x * x + y * y),
    }
end

-- Convert a world-frame vector to the carrier body frame using R transpose.
-- This avoids quaternion libraries which may normalize vector magnitudes.
function attitude.worldToBody(matrix, vectorValue)
    return {
        x = matrix[1] * vectorValue.x + matrix[4] * vectorValue.y + matrix[7] * vectorValue.z,
        y = matrix[2] * vectorValue.x + matrix[5] * vectorValue.y + matrix[8] * vectorValue.z,
        z = matrix[3] * vectorValue.x + matrix[6] * vectorValue.y + matrix[9] * vectorValue.z,
    }
end

-- Matrix columns are the body axes expressed in world coordinates.
local COLUMN = {
    x = function(m) return { x = m[1], y = m[4], z = m[7] } end,
    y = function(m) return { x = m[2], y = m[5], z = m[8] } end,
    z = function(m) return { x = m[3], y = m[6], z = m[9] } end,
}

-- roll: positive when starboard is low
-- pitch: positive when the bow is high
-- yaw: zero at world +X, positive toward world +Z
--
-- WHICH body axis is the bow is NOT assumed here any more. It was, as
-- "+X forward, +Y up, +Z right", and it was wrong: this carrier's bow is +Z
-- and its port side is +X. The consequence was that roll and pitch came out
-- TRANSPOSED -- a port/starboard thrust split, physically a roll, was reported
-- as 3.76 degrees of pitch against 0.05 of roll.
--
-- Nothing above this line was wrong; the axis LABELS were. See
-- config.axes.bowAxis for the three lines of evidence.
function attitude.fromQuaternion(q, axes)
    local matrix = attitude.rotationMatrix(q)

    local bowAxis = (axes and axes.bowAxis) or "z"
    local portAxis = (axes and axes.portAxis) or "x"

    local bow = COLUMN[bowAxis](matrix)
    local up = COLUMN.y(matrix)
    local port = COLUMN[portAxis](matrix)

    -- roll is rotation about the LONGITUDINAL (bow) axis, so it is measured
    -- from how far the lateral axis has tipped out of horizontal. Starboard is
    -- -port, and roll is positive when starboard is LOW, so -starboard.y is
    -- +port.y.
    local roll = math.deg(atan2(port.y, up.y)) * axes.rollSign

    -- pitch is how far the BOW points out of horizontal.
    local pitch = math.deg(math.asin(clamp(bow.y, -1, 1))) * axes.pitchSign

    -- yaw is the bow's heading in the world horizontal plane.
    local yaw = math.deg(atan2(bow.z, bow.x))
    yaw = (yaw * axes.yawSign + axes.yawOffsetDegrees) % 360

    return {
        roll = roll,
        pitch = pitch,
        yaw = yaw,
        matrix = matrix,
    }
end

return attitude
