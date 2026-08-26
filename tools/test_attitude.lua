-- Attitude round-trip: does the axis mapping actually hold?
--
-- This test exists because the project ran for weeks on "+X forward, +Y up,
-- +Z right" and it was WRONG -- the bow is +Z and port is +X, so every logged
-- roll and pitch was transposed. Nothing caught it, because cc_harness.lua
-- built its quaternions from the same mistaken labels: the harness and the
-- flight code agreed with each other and both disagreed with the craft.
--
--     luajit tools/test_attitude.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local attitude = require("fcs.attitude")
local harness = require("tools.cc_harness")
local config = require("fcs.config")

local passed, failed = 0, 0
local function check(label, got, want, tolerance)
    if math.abs(got - want) <= (tolerance or 1e-9) then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL %-46s got %.6f want %.6f", label, got, want))
    end
end

local axes = config.axes

-- The deployed config must carry the MEASURED mapping.
check("config bowAxis is z", axes.bowAxis == "z" and 1 or 0, 1)
check("config portAxis is x", axes.portAxis == "x" and 1 or 0, 1)

local function q(ax, ay, az, degrees)
    local s = math.sin(math.rad(degrees) / 2)
    return { x = ax * s, y = ay * s, z = az * s, w = math.cos(math.rad(degrees) / 2) }
end

-- A rotation about the BOW axis is pure roll and must not leak into pitch.
local a = attitude.fromQuaternion(q(0, 0, 1, 10), axes)
check("roll about bow(+Z) -> roll", a.roll, 10, 1e-6)
check("roll about bow(+Z) -> no pitch", a.pitch, 0, 1e-6)

-- A rotation about the PORT axis is pure pitch and must not leak into roll.
a = attitude.fromQuaternion(q(1, 0, 0, -10), axes)
check("pitch about port(-X) -> pitch", a.pitch, 10, 1e-6)
check("pitch about port(-X) -> no roll", a.roll, 0, 1e-6)

-- The harness must agree with the flight code across combined angles. The
-- composition ORDER matters: the reverse order is off by 4.75 deg at 35/-25.
local function convert(o) return { x = o.v.x, y = o.v.y, z = o.v.z, w = o.a } end
for _, case in ipairs({
    { 0, 0 }, { 10, 0 }, { 0, 10 }, { -7, 3 }, { 5, -12 },
    { 20, 15 }, { -3, -8 }, { 35, -25 }, { -18, 22 },
}) do
    harness.craft.roll, harness.craft.pitch = case[1], case[2]
    local read = attitude.fromQuaternion(convert(harness.orientation()), axes)
    check(string.format("harness round-trip roll %+.0f/%+.0f", case[1], case[2]),
        read.roll, case[1], 1e-6)
    check(string.format("harness round-trip pitch %+.0f/%+.0f", case[1], case[2]),
        read.pitch, case[2], 1e-6)
end
harness.craft.roll, harness.craft.pitch = 0, 0

-- YAW INVARIANCE. A Sable craft rotates, so world X and Z are not a stable
-- reference -- roll and pitch must not move when the craft merely turns.
--
-- They do not, and the reason is structural: bow/port/up are BODY axes
-- expressed in world coordinates, and roll and pitch read only their WORLD .y
-- components. A yaw rotation is a rotation about world Y, which leaves the .y
-- component of every vector untouched. Only `yaw` itself is world-referenced,
-- which is what a heading is for.
--
-- This is also why config.axes names BODY axes ("the bow is body +Z") rather
-- than a world direction: the body mapping is fixed by how the hull was built
-- and does not change as the craft turns.
local function quatMul(a, b)
    return {
        w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
        x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
    }
end

for _, attitudeCase in ipairs({ { 12, -7 }, { -20, 15 }, { 5, 5 } }) do
    local roll, pitch = attitudeCase[1], attitudeCase[2]
    -- Build the attitude, then spin it through a full turn of yaw.
    local base = quatMul(q(1, 0, 0, -pitch), q(0, 0, 1, roll))
    local firstYaw
    for heading = 0, 330, 30 do
        local spun = quatMul(q(0, 1, 0, heading), base)
        local read = attitude.fromQuaternion(spun, axes)
        check(string.format("yaw %3d deg leaves roll %+.0f unchanged", heading, roll),
            read.roll, roll, 1e-6)
        check(string.format("yaw %3d deg leaves pitch %+.0f unchanged", heading, pitch),
            read.pitch, pitch, 1e-6)
        -- And yaw itself must track the turn -- DECREASING, because
        -- yaw = atan2(bow.z, bow.x) increases from +X toward +Z while a
        -- right-handed rotation about world +Y carries +Z toward +X. The two
        -- run opposite. That is a convention, not a bug, and config.axes
        -- carries yawSign for it -- but anyone wiring a yaw controller must
        -- know the sign before closing a loop on it.
        if heading == 0 then firstYaw = read.yaw end
        local expected = (firstYaw - heading) % 360
        local delta = math.abs((read.yaw - expected + 180) % 360 - 180)
        check(string.format("yaw %3d deg is reported", heading), delta, 0, 1e-6)
    end
end

-- Guard the transposition directly: under the OLD mapping a bow-axis rotation
-- would land on pitch. If this ever passes again, the bug is back.
local old = { bowAxis = "x", portAxis = "z", rollSign = 1, pitchSign = 1,
              yawSign = 1, yawOffsetDegrees = 0 }
local wrong = attitude.fromQuaternion(q(0, 0, 1, 10), old)
check("old mapping DID transpose (regression guard)",
    math.abs(wrong.pitch) > 9 and 1 or 0, 1)

print("")
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
