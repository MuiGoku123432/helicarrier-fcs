-- Fly /fcs/velocityholdflight.lua against the CC harness.
--
--   luajit tools/run_velocityholdflight_harness.lua ground
--   luajit tools/run_velocityholdflight_harness.lua inverted   the craft as measured
--   luajit tools/run_velocityholdflight_harness.lua direct     hull and force AGREE
--   luajit tools/run_velocityholdflight_harness.lua cancelling the two halves
--                                                              nearly cancel
--   luajit tools/run_velocityholdflight_harness.lua all
--
-- WHAT THIS CAN AND CANNOT PROVE. The harness's coupling and drag are numbers
-- chosen here, so a HELD verdict is not evidence about the carrier. What it
-- proves is what has actually gone wrong on this project: that the phases
-- sequence, that phase A measures a SIGNED net gain by reverse pairs, that
-- phase B refuses when phase A did not produce one, that the command is rate
-- limited, that the abort paths fire, and that the craft is never left
-- asymmetric or with its props cut in the air.
--
-- THE MODES ARE THE POINT:
--
--   inverted   the craft as MEASURED. Bearing thrust scales with rpm (so the
--              direct force is 0.82 blocks/s per degree at 64), roll couples
--              -0.8205 and pitch +0.5588, and the hull term is therefore the
--              bigger half with the other sign. Phase A must come back with a
--              NEGATIVE net gain on both axes and the loop must still hold.
--
--   direct     the same craft with the coupling flipped, so the hull term and
--              the direct force AGREE and the net is positive. The loop must
--              work identically -- it divides by a measured signed gain and
--              never reasons about which way the bearings "should" push. A
--              tool that only holds on the sign its author expected is the
--              failure this file exists to avoid.
--
--   cancelling the coupling is tuned so the hull term nearly cancels the direct
--              force and the NET is a few hundredths of a block/s per degree.
--              Phase A must REFUSE: dividing a drift by a gain that small is a
--              saturated command derived from noise, which is exactly the
--              1.76 -> 11.5 blocks/s runaway. (An earlier version of this mode
--              turned the coupling OFF entirely and was not a refusal case at
--              all -- with no hull term the direct force alone is 0.2 per
--              degree, which is small but perfectly usable, and the tool
--              rightly closed the loop on it.)
package.path = "./?.lua;./?/init.lua;" .. package.path
local harness = require("tools.cc_harness")

local MODES = { "inverted", "direct", "cancelling" }
local mode = arg[1] or "inverted"

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

harness.root = "/tmp/cc_harness_velocityhold"
os.execute("rm -rf /tmp/cc_harness_velocityhold")

harness.model.exponent = 1.0
harness.model.propRollScale = 0.347
harness.model.rollRestoring = 0.0223
harness.model.rollDamping = 0

-- Pitch as measured: it does not ring. A restoring moment with enough damping
-- that it creeps home -- see THE PITCH FLIGHT.
harness.model.pitchRestoring = 0.0223
harness.model.pitchDamping = 0.30

-- THE LATERAL FORCE SCALES WITH RPM. Measured on the ground 2026-08-27:
-- getThrust is 3.97x its 16 rpm value at 64, and the lateral force with it.
harness.model.bearingLateralScalesWithRpm = true

-- THE COUPLING, per axis, as measured. The equilibrium hull angle per
-- commanded degree is (coefficient / restoring), so these reproduce -0.8205
-- and +0.5588.
harness.model.bearingTiltRollPerDegree = 0.8205 * 0.0223
harness.model.bearingTiltPitchPerDegree = 0.5588 * 0.0223
harness.model.bearingCouplingSign = -1        -- roll: NEGATIVE, measured
harness.model.bearingCouplingSignPitch = 1    -- pitch: POSITIVE, measured

-- A craft that sits off level, so there is something to hold against.
harness.model.rollEquilibrium = 0.30
harness.model.pitchEquilibrium = -0.55
harness.craft.roll = 0.30
harness.craft.pitch = -0.55

if mode == "direct" then
    harness.model.bearingCouplingSign = 1
    harness.model.bearingCouplingSignPitch = -1
elseif mode == "cancelling" then
    -- Hull term = coupling x 2.1334, and the direct force at 64 rpm is 0.8227.
    -- A coupling of -0.3857 makes the two cancel to within a few hundredths.
    harness.model.bearingTiltRollPerDegree = 0.3857 * 0.0223
    harness.model.bearingTiltPitchPerDegree = 0.3857 * 0.0223
    harness.model.bearingCouplingSign = -1
    harness.model.bearingCouplingSignPitch = 1
elseif mode ~= "inverted" and mode ~= "ground" then
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

print(("harness: mode=%s  rollCoupling=%s%s  lateralScales=%s")
    :format(mode, tostring(harness.model.bearingCouplingSign),
        harness.model.bearingTiltRollPerDegree > 0 and " (active)" or " (none)",
        tostring(harness.model.bearingLateralScalesWithRpm)))
print(("-"):rep(72))

local ok, err = pcall(function()
    harness.run({ function()
        local chunk = assert(loadfile("fcs/velocityholdflight.lua"))
        if mode == "ground" then chunk("--ground-only") else chunk() end
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
print(("harness: roll=%.2f pitch=%.2f speed=%.3f"):format(
    harness.craft.roll, harness.craft.pitch, harness.groundSpeed()))
