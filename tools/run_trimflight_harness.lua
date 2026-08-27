-- Fly /fcs/trimflight.lua against the CC harness.
--
--   luajit tools/run_trimflight_harness.lua ground
--   luajit tools/run_trimflight_harness.lua positive   coupling sign +1
--   luajit tools/run_trimflight_harness.lua negative   coupling sign -1
--   luajit tools/run_trimflight_harness.lua nocoupling bearings do not roll it
--   luajit tools/run_trimflight_harness.lua all
--
-- THE POINT IS THE SIGN. The bearing roll coupling's sign has never been
-- measured on the craft, and a saturated command with it wrong once ran the
-- craft from 1.76 to 11.5 blocks/s. So the tool must MEASURE it and then trim
-- correctly EITHER WAY -- not merely work for the sign the author guessed.
--
-- positive and negative must both end with the standing tilt reduced. If only
-- one does, the tool is assuming a sign somewhere.
--
-- nocoupling is the refusal case: bearings that cannot roll the hull give a
-- gain of zero, and dividing an offset by that is a large command derived from
-- noise -- exactly the shape of the runaway. It must REFUSE, not command.
package.path = "./?.lua;./?/init.lua;" .. package.path
local harness = require("tools.cc_harness")

local MODES = { "positive", "negative", "nocoupling" }
local mode = arg[1] or "positive"

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

harness.root = "/tmp/cc_harness_trimflight"
os.execute("rm -rf /tmp/cc_harness_trimflight")

-- MEASURED: propeller thrust is linear in rpm, not quadratic.
harness.model.exponent = 1.0
harness.model.rollRestoring = 0.0223
harness.model.rollDamping = 0
harness.model.propRollScale = 0.347       -- the measured 0.0941 per rpm

-- A craft that SITS off level, like the real one: +0.368 roll, -0.638 pitch.
--
-- The spring's equilibrium, not a starting angle. A starting angle just
-- oscillates about level and averages to zero, so there would be no standing
-- offset to cancel -- which is how the first version of this runner produced a
-- tool that measured a baseline of -0.037 and had nothing to trim.
harness.model.rollEquilibrium = 0.368
harness.model.pitchEquilibrium = -0.638
harness.craft.roll = 0.368
harness.craft.pitch = -0.638

if mode == "negative" then
    harness.model.bearingCouplingSign = -1
elseif mode == "nocoupling" then
    harness.model.bearingTiltRollPerDegree = 0
    harness.model.bearingTiltPitchPerDegree = 0
elseif mode ~= "positive" and mode ~= "ground" then
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

print(("harness: mode=%s  couplingSign=%s  rollPerDeg=%s  start roll=%.3f pitch=%.3f")
    :format(mode, tostring(harness.model.bearingCouplingSign),
        tostring(harness.model.bearingTiltRollPerDegree),
        harness.craft.roll, harness.craft.pitch))
print(("-"):rep(72))

local ok, err = pcall(function()
    harness.run({ function()
        local chunk = assert(loadfile("fcs/trimflight.lua"))
        if mode == "ground" then
            chunk("--ground-only")
        else
            chunk()
        end
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
print(("harness: final roll=%.3f pitch=%.3f speed=%.3f"):format(
    harness.craft.roll, harness.craft.pitch, harness.groundSpeed()))
