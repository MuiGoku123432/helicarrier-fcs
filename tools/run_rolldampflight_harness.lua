-- Fly /fcs/rolldampflight.lua against the CC harness.
--
--   luajit tools/run_rolldampflight_harness.lua ground
--   luajit tools/run_rolldampflight_harness.lua damped     spring + real damping
--   luajit tools/run_rolldampflight_harness.lua undamped   spring, NO damping
--   luajit tools/run_rolldampflight_harness.lua wrongsign  the damper inverted
--
-- WHAT THIS CAN AND CANNOT PROVE. The harness's roll physics are a spring and a
-- damping coefficient chosen here, not the craft's -- so it cannot validate the
-- 0.0941 authority, and a "DAMPED" verdict here is not evidence about the
-- carrier. What it DOES prove is everything that has actually gone wrong on
-- this project: that the loop sequences correctly, that the pulse is applied
-- and released, that both halves record comparable windows, that the verdict
-- distinguishes a working damper from an absent one, that the abort paths fire,
-- and that the craft is never left asymmetric or with its props cut in the air.
--
-- `wrongsign` is the important one. A sign error is the failure mode that looks
-- most like success -- it commands confidently and the craft gets worse -- so
-- the verdict has to catch it rather than print a decay number.
package.path = "./?.lua;./?/init.lua;" .. package.path
local harness = require("tools.cc_harness")

local mode = arg[1] or "damped"

harness.root = "/tmp/cc_harness_rolldampflight"
os.execute("rm -rf /tmp/cc_harness_rolldampflight")

-- A craft that oscillates: restoring spring, and the damping we are testing for
-- has to come from the CONTROL, not from the model. rollDamping stays 0 so an
-- undamped run really does ring forever.
-- MEASURED: propeller thrust is LINEAR in rpm (r^2 = 1.000000 from 8 to 96),
-- not quadratic. The harness default of 2.0 predates that measurement, and
-- leaving it makes 64 rpm carry far more than the 52% of weight it really does
-- -- which showed up here as a climb to +8 overshooting to +63.
harness.model.exponent = 1.0

harness.model.rollRestoring = 0.0223     -- the measured self-levelling spring
harness.model.rollDamping = 0            -- so an undamped run really does ring

-- 0.347 makes the harness reproduce the MEASURED authority (0.0941 deg/s^2 per
-- rpm) instead of the 0.2712 its own thrust model implies. Same 2.9x nobody
-- has explained; here it is at least explicit.
harness.model.propRollScale = 0.347

if mode == "undamped" then
    -- The control commands and the craft ignores it. A negative control:
    -- proves the verdict does not report DAMPED when nothing happened.
    harness.model.propRollScale = 0
elseif mode == "wrongsign" then
    harness.model.propRollScale = -0.347
elseif mode ~= "damped" and mode ~= "ground" then
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

print(("harness: mode=%s  propRollScale=%s  spring=%s"):format(
    mode, tostring(harness.model.propRollScale),
    tostring(harness.model.rollRestoring)))
print(("-"):rep(72))

local ok, err = pcall(function()
    harness.run({ function()
        local chunk = assert(loadfile("fcs/rolldampflight.lua"))
        if mode == "ground" then
            chunk("--ground-only")
        else
            -- Short windows: the harness clock is virtual, but the sample
            -- count still has to be large enough for the verdict to mean
            -- something.
            chunk("--window", "25", "--hold", "8")
        end
    end }, true)
end)

print(("-"):rep(72))
if not ok then print("raised: " .. tostring(err)) end

local rpms = {}
for corner, pod in pairs(harness.pods()) do
    rpms[#rpms + 1] = corner .. "=" .. tostring(pod.targetRpm)
end
table.sort(rpms)
print("harness: props left at " .. table.concat(rpms, " "))
print(("harness: roll=%.2f deg  y-gain=%.2f"):format(
    harness.orientation().roll or 0,
    harness.craft.y - (harness.craft.groundY or harness.craft.y)))
