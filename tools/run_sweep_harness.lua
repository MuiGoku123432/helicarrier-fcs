-- Run /fcs/sweep.lua against the CC harness.
--
--   luajit tools/run_sweep_harness.lua [exponent] [maxAchievableRpm]
--
-- Verifies the sweep end to end: that it hears the pods at all, that it fits
-- the curve, that it brackets liftoff at the RPM the true model implies, and
-- that it leaves the craft in a defined state.

package.path = "./?.lua;./?/init.lua;" .. package.path

local harness = require("tools.cc_harness")

local exponent = tonumber(arg and arg[1]) or 2.0
local maxRpm = tonumber(arg and arg[2]) or math.huge

harness.model.exponent = exponent
harness.model.maxAchievableRpm = maxRpm
-- Third arg "silent" models genuinely dead pods, to prove the preflight tells
-- a real outage apart from the receive race that used to fake one.
harness.model.podsSilent = (arg and arg[3] == "silent") or false
-- Fourth arg: pod telemetry period in ms. Cranking this down models the status
-- traffic that competes with an ack for the single shared pod.type field.
if arg and arg[4] then harness.model.telemetryPeriodMs = tonumber(arg[4]) end
-- Fifth arg: silently drop every Nth set_rpm, reproducing the live failure.
harness.model.dropEveryNthCommand = tonumber(arg and arg[5]) or 0
-- Sixth arg "nodensity" makes thrust independent of air pressure, to check the
-- sweep picks the RIGHT model rather than always announcing the density one.
if arg and arg[6] == "nodensity" then harness.model.densityScalesThrust = false end
harness.readAnswer = "SWEEP"
harness.root = "/tmp/cc_harness_fs"
os.execute("rm -rf /tmp/cc_harness_fs")

harness.install(_G)

-- CC resolves "fcs.x" to /fcs/x.lua; locally that is fcs/x.lua.
_G.package = package
package.path = "./?.lua;./?/init.lua;" .. package.path

local weight = harness.craft.mass * math.abs(harness.craft.gravity)
-- Eight bearings: six nominal, plus RR's deficient pair.
local base16 = 13960.983782400237 * 6 + 13804.412918506092 + 13960.983782400237
local a = base16 / 16 ^ exponent
local P = harness.craft.groundPressure
local trueHover = harness.model.densityScalesThrust
    and (weight / (a * P)) ^ (1 / exponent)
    or (weight / a) ^ (1 / exponent)

print(("harness: true exponent k=%.2f, true hover=%.2f rpm, drivetrain ceiling=%s")
    :format(exponent, trueHover, maxRpm == math.huge and "none" or tostring(maxRpm)))
print(("harness: weight=%.1f  thrust@16=%.1f  T/W@16=%.4f")
    :format(weight, base16, base16 / weight))
print(("-"):rep(72))

local ok, err = pcall(function()
    harness.run({ function() dofile("fcs/sweep.lua") end }, true)
end)

print(("-"):rep(72))
if ok then
    print("sweep returned normally")
else
    print("sweep raised: " .. tostring(err))
end

local GROUND = -26.573583602905273
print(("harness: final craft y=%.4f (start %.4f), grounded=%s")
    :format(harness.craft.y, GROUND, tostring(harness.craft.grounded)))
print(("harness: PEAK altitude gain = %.2f blocks")
    :format((harness.craft.peakY or GROUND) - GROUND))
local rpms = {}
for corner, pod in pairs(harness.pods()) do
    rpms[#rpms + 1] = corner .. "=" .. tostring(pod.targetRpm)
end
table.sort(rpms)
print("harness: props left at " .. table.concat(rpms, " "))
print("harness: true hover was " .. string.format("%.2f", trueHover) .. " rpm")
