-- Fly /fcs/pitchdampflight.lua against the CC harness.
--
--   luajit tools/run_pitchdampflight_harness.lua ground      the maths, no flight
--   luajit tools/run_pitchdampflight_harness.lua slow        89 s pitch period
--   luajit tools/run_pitchdampflight_harness.lua stiff       42 s, like roll
--   luajit tools/run_pitchdampflight_harness.lua wrongsign   the craft responds
--                                                            opposite to the map
--   luajit tools/run_pitchdampflight_harness.lua noresponse  pitch does not move
--   luajit tools/run_pitchdampflight_harness.lua all
--
-- WHAT THIS CAN AND CANNOT PROVE, stated the same way the roll runner states
-- it. The harness's pitch physics are a spring and a scale chosen HERE, not the
-- craft's, so nothing below is evidence about the carrier's real pitch
-- authority or period. What it proves is everything that has actually gone
-- wrong on this project: that the phases sequence, that phase A produces an
-- authority and a period from its own pulse, that phase B refuses when phase A
-- did not, that the SIGN is measured rather than assumed, that the abort paths
-- fire, and that the craft is never left asymmetric or with its props cut in
-- the air.
--
-- THE TWO MODES THAT MATTER:
--
--   wrongsign   the craft's pitch responds OPPOSITE to pitchdamp.CORNER_SIGNS.
--               The tool must measure a negative authority, say so in words,
--               and still damp -- because the command divides by the signed
--               authority. A tool that only works on the sign its author
--               guessed is the failure this file is shaped to avoid, and this
--               craft has already produced one opposite sign per axis on the
--               bearings.
--
--   noresponse  the differential does nothing. Phase A must report NO
--               DISTURBANCE and phase B must not run at all: a damper built on
--               an authority of zero is a saturated command derived from noise.
--
-- slow vs stiff are the two hypotheses about the spring. If the restoring
-- TORQUE per degree matches roll's, pitch springs at 0.00497 (89 s) because it
-- carries 4.49x the inertia; if the hull levels both axes at the same RATE, it
-- springs at roll's own 0.0223 (42 s). The tool must read back whichever one it
-- is flown against and name it.
package.path = "./?.lua;./?/init.lua;" .. package.path
local harness = require("tools.cc_harness")

local MODES = { "slow", "stiff", "wrongsign", "noresponse" }
local mode = arg[1] or "slow"

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

harness.root = "/tmp/cc_harness_pitchdampflight"
os.execute("rm -rf /tmp/cc_harness_pitchdampflight")

-- MEASURED: propeller thrust is LINEAR in rpm, not quadratic.
harness.model.exponent = 1.0

-- Roll behaves as it does on the craft, because the roll damper runs
-- throughout this flight and must not be the thing that goes wrong.
harness.model.rollRestoring = 0.0223
harness.model.rollDamping = 0
harness.model.propRollScale = 0.347

-- THE LONGITUDINAL ARM. craftgeom's box is 87.1 beam x 205.1 length, so the
-- pitch lever is 2.35x the roll one. Scaling the harness's own 20-block lateral
-- arm by that ratio keeps the ARM RATIO honest, which is what sets the
-- roll/pitch authority ratio the tool predicts from.
harness.model.cornerArmLongitudinal = 20 * (102.55 / 43.57)
harness.model.propPitchScale = 0.347

-- The pitch spring: the equal-restoring-torque hypothesis. 4.49x the inertia
-- for the same torque per degree gives 0.0223 / 4.49.
harness.model.pitchRestoring = 0.00497
harness.model.pitchDamping = 0

if mode == "stiff" then
    harness.model.pitchRestoring = 0.0223
elseif mode == "wrongsign" then
    harness.model.propPitchScale = -0.347
elseif mode == "noresponse" then
    harness.model.propPitchScale = 0
elseif mode ~= "slow" and mode ~= "ground" then
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

print(("harness: mode=%s  pitchScale=%s  pitchSpring=%s  longArm=%.1f")
    :format(mode, tostring(harness.model.propPitchScale),
        tostring(harness.model.pitchRestoring),
        harness.model.cornerArmLongitudinal))
print(("-"):rep(72))

local ok, err = pcall(function()
    harness.run({ function()
        local chunk = assert(loadfile("fcs/pitchdampflight.lua"))
        if mode == "ground" then chunk("--ground-only") else chunk() end
    end }, true)
end)

print(("-"):rep(72))
if not ok then print("raised: " .. tostring(err)) end

local rpms = {}
for corner, pod in pairs(harness.pods()) do
    rpms[#rpms + 1] = corner .. "=" .. tostring(pod.targetRpm)
end
table.sort(rpms)
print("harness: props " .. table.concat(rpms, " "))
print(("harness: roll=%.2f pitch=%.2f  y-gain=%.2f"):format(
    harness.craft.roll, harness.craft.pitch,
    harness.craft.y - (-26.573583602905273)))
