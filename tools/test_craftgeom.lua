-- Does the geometry derived from the inertia tensor actually describe this
-- craft, and does it sort the flight record correctly?
--
-- This test exists because axisresponse.lua checked its measured ratio against
-- 4.49 -- the value for a SQUARE craft -- and this hull is 2.35x longer than
-- wide. Run 18 measured 4.07, passed that check, and was about twice too high.
--
-- The strong assertion here is the last block: the analytic UPPER BOUND must
-- separate the runs that are physically possible from the ones that are not.
-- If a future change makes run 19's 75.29 admissible, the bound has stopped
-- meaning anything.
--
--     luajit tools/test_craftgeom.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local craftgeom = require("fcs.craftgeom")
local config = require("fcs.config")

local passed, failed = 0, 0
local function check(label, got, want, tolerance)
    if got and math.abs(got - want) <= (tolerance or 1e-9) then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL %-52s got %s want %.4f",
            label, tostring(got), want))
    end
end
local function checkTrue(label, condition)
    if condition then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL %-52s (expected true)", label))
    end
end

-- Read straight off the live craft, flight-logs/airprofile.txt. Not a fixture
-- invented to make the test pass -- these are the numbers Sable returned.
local TENSOR = {
    { 389383646.66189605, 2818192.7656108057, -4641931.7102072081 },
    { 2818192.7656108057, 435883852.97585285, 28031283.72369967 },
    { -4641931.7102072081, 28031283.72369967, 86772714.934104145 },
    rows = 3, columns = 3,
}
local MASS = 105299.39999999988
local GRAVITY = 11.0                 -- aero.getGravity() -> {x=0, y=-11, z=0}
local ION_FORCE_FULL = 3870720.2     -- Phase A, 0.0% residual, every run
local axes = config.axes

-- --------------------------------------------------------------------------
-- The axis mapping. Roll is about the BOW, which is the CHEAP tensor axis.
-- --------------------------------------------------------------------------
local indices = craftgeom.axisIndices(axes)
check("roll uses the bow index (3 = +Z)", indices.roll, 3)
check("pitch uses the port index (1 = +X)", indices.pitch, 1)
check("yaw uses the remaining index (2 = +Y)", indices.yaw, 2)

-- --------------------------------------------------------------------------
-- The box solve.
-- --------------------------------------------------------------------------
local box = craftgeom.solveBox(TENSOR, MASS, axes)
checkTrue("box solves", box ~= nil)
check("beam (port-starboard)", box.beam, 87.1, 0.1)
check("length (stern-bow)", box.length, 205.1, 0.1)
check("height", box.height, 47.9, 0.1)
checkTrue("craft is longer than it is wide", box.length > box.beam)
check("length/beam", box.length / box.beam, 2.35, 0.01)

-- The solve must round-trip: rebuild the diagonals from the edges it found.
local function diagonal(a, b) return MASS * (a * a + b * b) / 12 end
check("t[1][1] round-trips", diagonal(box.y, box.z), TENSOR[1][1], 1)
check("t[2][2] round-trips", diagonal(box.x, box.z), TENSOR[2][2], 1)
check("t[3][3] round-trips", diagonal(box.x, box.y), TENSOR[3][3], 1)

-- A tensor that is not a physical box must be refused, not approximated.
-- Here t[3][3] is far too large for the other two to accommodate.
local impossible = {
    { 1e6, 0, 0 }, { 0, 1e6, 0 }, { 0, 0, 9e9 }, rows = 3, columns = 3,
}
checkTrue("non-physical tensor is refused",
    craftgeom.solveBox(impossible, MASS, axes) == nil)

-- --------------------------------------------------------------------------
-- The unit chain. If this closes, torque/I lands in rad/s^2 with no fudge.
-- --------------------------------------------------------------------------
check("ion force is 3.342x craft weight",
    ION_FORCE_FULL / (MASS * GRAVITY), 3.342, 0.001)

-- --------------------------------------------------------------------------
-- The predicted ratio -- the unit-free number, and the one that matters.
-- --------------------------------------------------------------------------
local ratio = craftgeom.expectedRatio(TENSOR, MASS, axes)
check("expected roll/pitch ratio", ratio, 1.91, 0.01)

-- The value the old check used, and why it was wrong: 4.49 is what you get
-- when the arms are equal. Guard it directly -- if this ever matches again,
-- the square-craft assumption is back.
local tensorOnly = TENSOR[1][1] / TENSOR[3][3]
check("square-craft ratio is 4.49 (the OLD, wrong bound)", tensorOnly, 4.49, 0.01)
checkTrue("expected ratio is far below the square-craft value",
    ratio < tensorOnly / 2)

-- --------------------------------------------------------------------------
-- The authority bound, and the flight record it has to sort.
-- --------------------------------------------------------------------------
local bound = craftgeom.authorityBound({
    tensor = TENSOR, mass = MASS, axes = axes,
    ionForceFull = ION_FORCE_FULL, authority = 0.25,
})
checkTrue("authority bound computes", bound ~= nil)
check("roll bound", bound.roll, 27.84, 0.05)
check("pitch bound", bound.pitch, 14.60, 0.05)
check("bound ratio matches expectedRatio", bound.ratio, ratio, 1e-9)

-- THE POINT OF THE WHOLE FILE. A pod cannot sit outboard of the hull, so no
-- honest measurement can exceed these. Runs 9 and 10 sit just under; runs 18
-- and 19 are impossible and must be seen to be impossible.
local record = {
    { run = "9", roll = 28.33, admissible = true },
    { run = "10", roll = 26.93, admissible = true },
    { run = "18", roll = 46.69, admissible = false },
    { run = "19", roll = 75.29, admissible = false },
}
-- 5% of slack for the uniform-mass assumption, no more. Run 9's 28.33 is
-- 1.8% over the bound and is meant to pass; run 18's 46.69 is 68% over.
for _, entry in ipairs(record) do
    local within = entry.roll <= bound.roll * 1.05
    checkTrue(string.format("run %s roll %.2f is %s", entry.run, entry.roll,
        entry.admissible and "admissible" or "IMPOSSIBLE"),
        within == entry.admissible)
end

-- Pitch, the well-sampled axis, must sit UNDER the bound in both clean runs.
checkTrue("run 18 pitch 11.47 is under the bound", 11.47 < bound.pitch)
checkTrue("run 19 pitch 13.47 is under the bound", 13.47 < bound.pitch)

print("")
print(string.format("box: beam %.1f  length %.1f  height %.1f blocks",
    box.beam, box.length, box.height))
print(string.format("bound: roll %.2f  pitch %.2f  ratio %.2f deg/s^2 per unit demand",
    bound.roll, bound.pitch, bound.ratio))
print("")
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
