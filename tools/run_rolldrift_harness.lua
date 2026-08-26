-- Run /fcs/rolldrift.lua against the CC harness.
--
--     luajit tools/run_rolldrift_harness.lua                 60 s at +5
--     luajit tools/run_rolldrift_harness.lua 30 5            shorter window
--     luajit tools/run_rolldrift_harness.lua 60 5 stable     model a craft that self-levels
--     luajit tools/run_rolldrift_harness.lua 60 5 dropNth=3  with command loss
--
-- WHAT THIS PROVES
--
-- The harness models NO restoring moment, so a default run is the "nothing
-- resists" case and the tool must say so. `stable` adds a restoring moment to
-- the harness, so the tool must reach the opposite verdict on the same code.
-- A diagnostic that only ever prints one answer is not a diagnostic, and the
-- only way to know is to run it against both worlds.
package.path = "./?.lua;./?/init.lua;" .. package.path
local harness = require("tools.cc_harness")

local passed, dropNth, stable, rrDeficit = {}, 0, false, false
for i = 1, #arg do
    local a = arg[i]
    if a:match("^dropNth=") then
        dropNth = tonumber(a:match("=(%d+)")) or 0
    elseif a == "stable" then
        stable = true
    elseif a == "rrdeficit" then
        -- Re-enable the pre-repair RR bearing_5 asymmetry. Repaired and
        -- verified 2026-08-26, so this is a regression path, not the craft.
        rrDeficit = true
    else
        passed[#passed + 1] = a
    end
end

harness.root = "/tmp/cc_harness_rolldrift"
os.execute("rm -rf /tmp/cc_harness_rolldrift")
harness.model.dropEveryNthCommand = dropNth
harness.model.exponent = 1.0
harness.model.rrDeficit = rrDeficit

if stable then
    -- A restoring moment proportional to tilt, plus damping: the craft returns
    -- to level. Magnitude chosen so it comfortably beats the RR deficit.
    harness.model.rollRestoring = 0.02
    harness.model.rollDamping = 0.5
end

harness.install(_G)
_G.package = package
package.path = "./?.lua;./?/init.lua;" .. package.path

print(("harness: stable=%s dropNth=%d args=%s"):format(
    tostring(stable), dropNth, table.concat(passed, " ")))
print(("-"):rep(72))

local ok, err = pcall(function()
    harness.run({ function()
        local chunk = assert(loadfile("fcs/rolldrift.lua"))
        local unpackFn = table.unpack or unpack
        chunk(unpackFn(passed))
    end }, true)
end)

print(("-"):rep(72))
if not ok then print("raised: " .. tostring(err)) end

local craft = harness.craft
print(string.format("harness: final y=%.3f (gain %+.2f) grounded=%s",
    craft.y, craft.y - (-26.5736), tostring(craft.grounded)))
print(string.format("harness: roll=%.3f deg rollRate=%.4f  TOUCHDOWN vy=%.3f (peak %.3f)",
    craft.roll, craft.rollRate, craft.vy, craft.peakDescent or 0))

local airborne = (craft.y - (-26.5736)) > 1.0
local carrying = false
for _, pod in pairs(harness.pods()) do
    if pod.armed or (pod.currentPower or 0) > 0 then carrying = true end
end
if airborne and not carrying then
    print("SAFETY VIOLATION: airborne with every bank at zero -- this is a fall")
    os.exit(1)
end
print("safety: " .. (airborne and "airborne, banks still carrying" or "grounded"))
