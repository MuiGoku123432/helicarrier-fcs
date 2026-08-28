-- Fly /fcs/tiltcheck.lua against the CC harness.
--
--   luajit tools/run_tiltcheck_harness.lua works        every corner answers
--   luajit tools/run_tiltcheck_harness.lua ground       the ground half alone
--   luajit tools/run_tiltcheck_harness.lua deadbearings pod accepts, bearing
--                                                       never moves  (row 3)
--   luajit tools/run_tiltcheck_harness.lua lost         set_tilt never arrives
--                                                       (row 1)
--   luajit tools/run_tiltcheck_harness.lua rejected     the pod refuses it
--                                                       (row 2)
--   luajit tools/run_tiltcheck_harness.lua airborne     answers on the ground,
--                                                       stops in the air --
--                                                       THE HYPOTHESIS
--   luajit tools/run_tiltcheck_harness.lua notarget     setManualTarget never
--                                                       takes -- getManualTarget
--                                                       reads nothing back
--   luajit tools/run_tiltcheck_harness.lua once         --once, the shape
--                                                       bearingsweep sends
--   luajit tools/run_tiltcheck_harness.lua slew         bearings take seconds
--                                                       to reach the angle --
--                                                       must still PASS and
--                                                       report the time
--   luajit tools/run_tiltcheck_harness.lua shortsettle  the same craft read
--                                                       too early: must FAIL
--                                                       and say the settle was
--                                                       short, not blame the
--                                                       bearings
--   luajit tools/run_tiltcheck_harness.lua wiredbus     FR and RR on the wired
--                                                       bus, uplink dies in the
--                                                       air -- the wired pair
--                                                       must survive and the
--                                                       report must SAY SO
--   luajit tools/run_tiltcheck_harness.lua lostinair    the ground confirm
--                                                       succeeds, then the link
--                                                       eats every airborne
--                                                       set_tilt
--   luajit tools/run_tiltcheck_harness.lua all
--
-- WHAT THIS CAN AND CANNOT PROVE. The harness cannot tell anyone why the real
-- craft's bearings stop answering -- that is what the flight is for. What it
-- proves is that the tool SEQUENCES (ground, climb, alternating air confirms,
-- land, ground), that it reads the pod's own commandedTilt rather than only
-- the bearing angle, that each of the three failure rows produces the RIGHT
-- diagnosis rather than a generic "did not work", that a failing ground check
-- refuses to fly, and that the craft is never left tilted or with its props
-- cut in the air.
--
-- The three failure modes are the point. A tool that says "0 of 4 answered"
-- for a lost command, a refused command and a dead bearing has not narrowed
-- anything, and narrowing is the entire reason this tool exists.
package.path = "./?.lua;./?/init.lua;" .. package.path
local harness = require("tools.cc_harness")

local ONCE, SLEW = false, nil
local MODES = { "works", "ground", "deadbearings", "lost", "rejected",
    "airborne", "lostinair", "notarget", "once", "slew", "shortsettle",
    "wiredbus" }
local mode = arg[1] or "works"

if mode == "all" then
    local failures = 0
    for _, each in ipairs(MODES) do
        io.write(("="):rep(72), "\nMODE: ", each, "\n", ("="):rep(72), "\n")
        io.flush()
        local ok = os.execute(("luajit %s %s"):format(arg[0], each))
        if ok ~= true and ok ~= 0 then failures = failures + 1 end
    end
    os.exit(failures == 0 and 0 or 1)
end

harness.root = "/tmp/cc_harness_tiltcheck"
os.execute("rm -rf /tmp/cc_harness_tiltcheck")

harness.model.exponent = 1.0
harness.model.propRollScale = 0.347
harness.model.rollRestoring = 0.0223
harness.model.rollDamping = 0
harness.model.pitchRestoring = 0.0223
harness.model.pitchDamping = 0.30

-- The craft as measured: the lateral force scales with rpm, and the hull
-- coupling is the bigger half with the other sign. tiltcheck measures none of
-- this -- it is here so the craft the tool flies is the craft that produced
-- the fault, drift and all.
harness.model.bearingLateralScalesWithRpm = true
harness.model.bearingTiltRollPerDegree = 0.8205 * 0.0223
harness.model.bearingTiltPitchPerDegree = 0.5588 * 0.0223
harness.model.bearingCouplingSign = -1
harness.model.bearingCouplingSignPitch = 1

harness.model.rollEquilibrium = 0.30
harness.model.pitchEquilibrium = -0.55
harness.craft.roll = 0.30
harness.craft.pitch = -0.55

if mode == "deadbearings" then
    harness.model.bearingsIgnoreTilt = true
elseif mode == "lost" then
    harness.model.tiltCommandsLost = true
elseif mode == "rejected" then
    harness.model.tiltCommandsRejected = true
elseif mode == "airborne" then
    -- THE WHOLE POINT. The ground confirms must pass and every air confirm
    -- must fail, and the report must say the fault is being airborne rather
    -- than shrugging at five failed corners.
    harness.model.tiltFailsAboveY = harness.craft.y + 2.0
elseif mode == "slew" or mode == "shortsettle" then
    -- 2.0 deg/s quoted at 32 rpm, so 8 degrees takes 4 s there and 6.7 s at 48
    -- -- which is the shape the 2026-08-28 ground evidence implies. Nothing
    -- about the craft is broken in either mode; only the settle differs.
    harness.model.bearingSlewDegPerSecond = 2.0
    harness.model.bearingSlewRpmReference = 32
    SLEW = mode
elseif mode == "notarget" then
    -- The mod refuses the target outright. Distinct from deadbearings, where
    -- the target IS stored and the bearing still does not move -- and no tool
    -- could tell those apart before per-bearing rows were read.
    harness.model.bearingsIgnoreTilt = true
    harness.model.bearingsRefuseTarget = true
elseif mode == "once" then
    -- Nothing wrong with the craft; just the one-shot send shape. Must still
    -- pass -- if --once fails on a healthy harness the flag is broken, not the
    -- craft, and that would poison the whole ground matrix.
    ONCE = true
elseif mode == "wiredbus" then
    -- THE EXPERIMENT, offline. Every airborne set_tilt is eaten on the radio
    -- and delivered on the wire. The tool must report 2/4 with the split
    -- attributed to the transport rather than to the corners.
    harness.model.wiredCorners = { FR = true, RR = true }
    harness.model.tiltCommandsLostAboveY = harness.craft.y + 2.0
elseif mode == "lostinair" then
    -- THE CASE THE AZIMUTH CHECK EXISTS FOR. The ground confirm succeeds and
    -- leaves commandedTilt = 1.00 on all four pods. Every airborne set_tilt is
    -- then eaten, and the STALE 1.00 would read as "the pod saw it" on an
    -- angle-only test -- diagnosing a dead bearing when the truth is a dead
    -- link. The verdict must be NEVER ARRIVED, not BEARING IGNORED IT.
    harness.model.tiltCommandsLostAboveY = harness.craft.y + 2.0
elseif mode ~= "works" and mode ~= "ground" then
    error("unknown mode " .. tostring(mode))
end

for _, pod in pairs(harness.pods()) do
    pod.targetRpm = 0
    pod.armed = false
    pod.currentPower = 0
end

harness.install(_G)
_G.package = package
package.path = "./?.lua;./?/init.lua;" .. package.path

print(("harness: mode=%s"):format(mode))
print(("-"):rep(72))

local ok, err = pcall(function()
    harness.run({ function()
        local chunk = assert(loadfile("fcs/tiltcheck.lua"))
        if mode == "ground" then chunk("--ground-only")
        elseif ONCE then chunk("--ground-only", "--once", "--tilt", "8")
        elseif SLEW == "slew" then
            chunk("--ground-only", "--tilt", "8", "--rpm", "48", "--settle", "12")
        elseif SLEW == "shortsettle" then
            chunk("--ground-only", "--tilt", "8", "--rpm", "48", "--settle", "3")
        else chunk() end
    end }, true)
end)

print(("-"):rep(72))
if not ok then print("raised: " .. tostring(err)) end

local rpms, tilts = {}, {}
for corner, pod in pairs(harness.pods()) do
    rpms[#rpms + 1] = corner .. "=" .. tostring(pod.targetRpm)
    tilts[#tilts + 1] = corner .. "=" .. string.format("%.2f", pod.tiltAngle or 0)
end
table.sort(rpms); table.sort(tilts)
print("harness: props " .. table.concat(rpms, " "))
print("harness: bearing tilt " .. table.concat(tilts, " "))
print(("harness: roll=%.2f pitch=%.2f speed=%.3f y=%.1f"):format(
    harness.craft.roll, harness.craft.pitch, harness.groundSpeed(), harness.craft.y))
