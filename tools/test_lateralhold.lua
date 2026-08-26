-- Does the lateral-hold law push AGAINST the drift, in BODY axes?
--
-- Two ways to get this catastrophically wrong, and both are quiet:
--
--   1. Push WITH the motion instead of against it. The craft accelerates away
--      and the loop commands more tilt as it goes. There is a test for each
--      cardinal direction below because a sign error that happens to be right
--      on one axis can be wrong on the other.
--   2. Steer in WORLD axes. The bearings are bolted to the hull, so a world
--      frame command works only while the craft points the way it launched --
--      and the strafe flight yawed 3.87 degrees while sweeping -225 of
--      velocity heading. The yawed test below is the guard.
--
--     luajit tools/test_lateralhold.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local lateralhold = require("fcs.lateralhold")
local config = require("fcs.config")

local passed, failed = 0, 0
local function check(label, got, want, tolerance)
    if type(got) == "number" and math.abs(got - want) <= (tolerance or 1e-9) then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL %-56s got %s want %.4f", label, tostring(got), want))
    end
end
local function checkTrue(label, condition)
    if condition then passed = passed + 1 else
        failed = failed + 1
        print(string.format("FAIL %-56s (expected true)", label))
    end
end

local axes = config.axes

-- Level craft, bow along world +Z (identity attitude).
local function level(vx, vz)
    return {
        quaternion = { x = 0, y = 0, z = 0, w = 1 },
        linearVelocityWorld = { x = vx, y = 0, z = vz },
    }
end

-- --------------------------------------------------------------------------
-- The azimuth mapping, anchored on the MEASURED ground result:
-- "AZIMUTH 0 DEGREES PUSHES TOWARD 90 deg = STARBOARD".
-- --------------------------------------------------------------------------
check("azimuth 0 pushes starboard (MEASURED)",
    lateralhold.headingForAzimuth(0), 90)
check("azimuth 90 pushes stern", lateralhold.headingForAzimuth(90), 180)
check("azimuth 180 pushes port", lateralhold.headingForAzimuth(180), 270)
check("azimuth 270 pushes bow", lateralhold.headingForAzimuth(270), 0)
check("to push at the bow, command azimuth 270",
    lateralhold.azimuthForHeading(0), 270)
check("mapping round-trips",
    lateralhold.headingForAzimuth(lateralhold.azimuthForHeading(137)), 137, 1e-9)

-- --------------------------------------------------------------------------
-- Direction. Drifting one way must command force the OTHER way.
-- --------------------------------------------------------------------------
-- Bow is +Z, so drifting +Z is drifting forward -> push at the stern (180).
local forward = lateralhold.command(level(0, 1.0), axes)
check("drifting bow-ward is heading 0", forward.heading, 0, 1e-6)
check("...so push toward the stern", forward.opposing, 180, 1e-6)
check("...which is azimuth 90", forward.azimuth, 90, 1e-6)

-- Port is +X, so drifting +X -> push starboard (90).
local portward = lateralhold.command(level(1.0, 0), axes)
check("drifting to port is heading 270", portward.heading, 270, 1e-6)
check("...so push to starboard", portward.opposing, 90, 1e-6)
check("...which is azimuth 0 (the MEASURED anchor)", portward.azimuth, 0, 1e-6)

local astern = lateralhold.command(level(0, -1.0), axes)
check("drifting astern -> push at the bow", astern.opposing, 0, 1e-6)
local starboardward = lateralhold.command(level(-1.0, 0), axes)
check("drifting starboard -> push to port", starboardward.opposing, 270, 1e-6)

-- The general guard: opposing must be 180 from heading, every time.
for _, velocity in ipairs({ { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 },
                           { 0.7, 0.7 }, { -0.3, 0.9 }, { 0.5, -1.2 } }) do
    local command = lateralhold.command(level(velocity[1], velocity[2]), axes)
    -- Normalised into [-180, 180] then made positive, so a correct opposition
    -- reads 180 -- NOT 0. Checking for 0 here asserts the loop pushes ALONG
    -- the drift, which is the runaway this test exists to catch.
    local separation = math.abs((command.opposing - command.heading + 540) % 360 - 180)
    check(string.format("push is opposite drift {%.1f, %.1f}",
        velocity[1], velocity[2]), separation, 180, 1e-6)
end

-- --------------------------------------------------------------------------
-- BODY frame. Yaw the craft 90 degrees and the same WORLD drift must produce a
-- different azimuth -- otherwise the loop is steering in world axes.
-- --------------------------------------------------------------------------
local function yawed(degrees, vx, vz)
    local half = math.rad(degrees) / 2
    return {
        -- Rotation about world +Y (up).
        quaternion = { x = 0, y = math.sin(half), z = 0, w = math.cos(half) },
        linearVelocityWorld = { x = vx, y = 0, z = vz },
    }
end

local levelDrift = lateralhold.command(level(0, 1.0), axes)
local yawedDrift = lateralhold.command(yawed(90, 0, 1.0), axes)
checkTrue("yawing 90 deg changes the commanded azimuth (BODY frame)",
    math.abs((yawedDrift.azimuth - levelDrift.azimuth + 540) % 360 - 180) > 45)
-- ...and by the full 90, since the drift is unchanged in the world.
check("...by exactly 90 degrees",
    math.abs((yawedDrift.azimuth - levelDrift.azimuth + 540) % 360 - 180), 90, 1e-6)

-- --------------------------------------------------------------------------
-- Deadband and clamp.
-- --------------------------------------------------------------------------
local still = lateralhold.command(level(0.01, 0), axes)
check("below the deadband commands ZERO tilt", still.tilt, 0)
local justOver = lateralhold.command(level(0.5, 0), axes)
check("0.5 blocks/s -> 3 deg at the default gain", justOver.tilt, 3.0, 1e-9)
checkTrue("...and is not saturated", not justOver.saturated)

local fast = lateralhold.command(level(0, 5.0), axes)
check("a fast drift clamps to the max tilt", fast.tilt,
    lateralhold.DEFAULTS.maxTiltDegrees, 1e-9)
checkTrue("...and says it saturated", fast.saturated)
checkTrue("the clamp stays under props.lua's own 15 degree limit",
    lateralhold.DEFAULTS.maxTiltDegrees < 15)

-- A state with no velocity or no attitude must command zero, not nil: a nil
-- would leave whatever tilt was last sent standing.
local blind = lateralhold.command({ quaternion = { x = 0, y = 0, z = 0, w = 1 } }, axes)
check("a state with no velocity commands zero tilt", blind.tilt, 0)

-- --------------------------------------------------------------------------
-- Authority, against the disturbance actually measured.
-- --------------------------------------------------------------------------
local terminal8, accel8 = lateralhold.terminalSpeed(8)
check("8 deg gives the measured 0.148 blocks/s^2", accel8, 0.1476, 1e-3)
check("...holding against 1.64 blocks/s", terminal8, 1.64, 0.01)
local terminal12 = lateralhold.terminalSpeed(lateralhold.DEFAULTS.maxTiltDegrees)
checkTrue("the 12 deg clamp beats the 1.67 blocks/s mean strafe",
    terminal12 > 1.67)
checkTrue("...and the 2.27 blocks/s peak", terminal12 > 2.27)

print("")
print(string.format("clamp %.0f deg -> holds against %.2f blocks/s (strafe: 1.67 mean, 2.27 peak)",
    lateralhold.DEFAULTS.maxTiltDegrees, terminal12))
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
