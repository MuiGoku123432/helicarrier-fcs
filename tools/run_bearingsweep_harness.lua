-- Run /fcs/bearingsweep.lua against the CC harness.
--
--   luajit tools/run_bearingsweep_harness.lua linear     thrust linear in rpm
--   luajit tools/run_bearingsweep_harness.lua square     the classic square law
--   luajit tools/run_bearingsweep_harness.lua flat       thrust does not scale
--   luajit tools/run_bearingsweep_harness.lua dead       bearings never active
--   luajit tools/run_bearingsweep_harness.lua all
--
-- WHAT EACH MODE IS FOR. The sweep exists to replace a stored constant with a
-- reading, so the thing to prove is that it REPORTS WHAT THE CRAFT DOES rather
-- than what the code believes:
--
--   linear  proportional thrust. Must report LINEAR, ~872 per rpm, and a
--           64 rpm gain 4x the stored constant.
--   craft   what the carrier actually measured on 2026-08-27: the same slope
--           with a -442.6 offset. Must report LINEAR+OFFSET and still hand out
--           the gain -- a proportional fit BENDS to absorb that offset, and
--           the bend is what made the first real sweep cry NONLINEAR on data
--           whose residuals are all under 0.11%.
--   square  a craft whose thrust went as rpm^2. Must NOT report LINEAR --
--           this is the case where extrapolating from two points would have
--           produced a confident wrong answer.
--   flat    thrust independent of rpm: the sweep must report the 16 rpm
--           constant back and a ratio of 1.0, because that is the world in
--           which the stored number was right all along.
--   dead    bearings inactive. THE RULE: an inactive bearing reports a stored
--           target it is ignoring, so this must produce NO readings rather
--           than a clean-looking gain.
package.path = "./?.lua;./?/init.lua;" .. package.path
local harness = require("tools.cc_harness")

local MODES = { "linear", "craft", "square", "flat", "dead" }
local mode = arg[1] or "linear"

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

harness.root = "/tmp/cc_harness_bearingsweep"
os.execute("rm -rf /tmp/cc_harness_bearingsweep")

-- MEASURED: thrust is linear in rpm, not the classic square law.
harness.model.exponent = 1.0
harness.model.bearingLateralScalesWithRpm = true

if mode == "craft" then
    harness.model.bearingThrustOffset = -442.6
elseif mode == "square" then
    harness.model.exponent = 2.0
elseif mode == "flat" then
    harness.model.exponent = 0.0
elseif mode == "dead" then
    -- Not a real knob: the pods report active only above 0 rpm, so a craft
    -- that cannot turn its props is a craft whose bearings never activate.
    harness.model.maxAchievableRpm = 0
elseif mode ~= "linear" then
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

print(("harness: mode=%s  exponent=%s  lateral scales=%s")
    :format(mode, tostring(harness.model.exponent),
        tostring(harness.model.bearingLateralScalesWithRpm)))
print(("-"):rep(72))

local ok, err = pcall(function()
    harness.run({ function()
        assert(loadfile("fcs/bearingsweep.lua"))()
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
print(("harness: grounded=%s y=%.3f"):format(
    tostring(harness.craft.grounded), harness.craft.y))
