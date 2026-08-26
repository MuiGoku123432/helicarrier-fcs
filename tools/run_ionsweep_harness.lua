-- Run /fcs/ionsweep.lua against the CC harness.
--   luajit tools/run_ionsweep_harness.lua [dropEveryNth] [ionForceFraction]
package.path = "./?.lua;./?/init.lua;" .. package.path
local harness = require("tools.cc_harness")

harness.readAnswer = "IONS"
harness.root = "/tmp/cc_harness_ion"
os.execute("rm -rf /tmp/cc_harness_ion")
harness.model.dropEveryNthCommand = tonumber(arg and arg[1]) or 0
-- The carrier's props are LINEAR in RPM (measured). Without this the harness
-- uses its square-law default and props at 122 rpm alone make 8x weight.
harness.model.exponent = 1.0
local weight = 105299.39999999988 * 11.0
local frac = tonumber(arg and arg[2]) or 1.0
harness.model.ionForceAtFullTotal = weight * frac
-- Props start where the prop sweep leaves them: just under hover.
for _, pod in pairs(harness.pods()) do pod.targetRpm = 122 end

harness.trace = true
harness.install(_G)
_G.package = package
package.path = "./?.lua;./?/init.lua;" .. package.path

print(("harness: ions at full power = %.2f x weight; props start at 122 rpm"):format(frac))
print(("-"):rep(70))
local ok, err = pcall(function()
    harness.run({ function() dofile("fcs/ionsweep.lua") end }, true)
end)
print(("-"):rep(70))
if not ok then print("raised: " .. tostring(err)) end
local GROUND = -26.573583602905273
print(("harness: peak altitude gain = %.2f blocks"):format((harness.craft.peakY or GROUND) - GROUND))
local t0 = harness.traceLog[1] and harness.traceLog[1].t or 0
print(("harness: peak reached at t+%.1fs; run ended t+%.1fs"):format(
    ((harness.craft.peakAt or t0) - t0)/1000,
    ((harness.traceLog[#harness.traceLog] and harness.traceLog[#harness.traceLog].t or t0) - t0)/1000))
print(("harness: %d trace entries; first 12 and the 12 around the peak"):format(#harness.traceLog))
local function show(i)
    local e = harness.traceLog[i]
    if e then print(("   [%5d] t+%7.2fs  y=%9.3f  vy=%+8.3f"):format(i,(e.t-t0)/1000, e.y, e.vy)) end
end
for i = 1, math.min(12, #harness.traceLog) do show(i) end
local pk = 1
for i, e in ipairs(harness.traceLog) do if e.y > harness.traceLog[pk].y then pk = i end end
print("   ... peak at index " .. pk)
for i = pk - 5, pk + 5 do show(i) end
local st = {}
for c, pod in pairs(harness.pods()) do
    st[#st+1] = c .. ":armed=" .. tostring(pod.armed) .. " pwr=" .. string.format("%.2f", pod.currentPower) .. " rpm=" .. tostring(pod.targetRpm)
end
table.sort(st)
print("harness: " .. table.concat(st, "  "))
