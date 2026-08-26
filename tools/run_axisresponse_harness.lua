-- Run /fcs/axisresponse.lua against the CC harness.
--
--     luajit tools/run_axisresponse_harness.lua                 full run
--     luajit tools/run_axisresponse_harness.lua --ground-only   phase A only
--     luajit tools/run_axisresponse_harness.lua dropNth=3       lose every 3rd command
--     luajit tools/run_axisresponse_harness.lua arm=0           banks refuse to arm
--
-- WHAT THIS CAN AND CANNOT PROVE
--
-- Can: phase sequencing, that pulses are cancelled rather than merely stopped,
-- that aborts restore symmetric hover instead of disarming airborne, that the
-- slope fit degrades honestly when the loop is too slow to give it samples,
-- and that the run survives command loss.
--
-- Cannot: the actual value of Aroll/Apitch. The harness's cornerArmBlocks is a
-- guess -- it is the very quantity nobody has measured -- so the coefficient it
-- produces is a property of the harness, not of the carrier. Only the live run
-- gives a real number. Do not copy a coefficient out of this into
-- mixer_profile.lua.
package.path = "./?.lua;./?/init.lua;" .. package.path
local harness = require("tools.cc_harness")

local passed, dropNth, allowArm, stable, rrDeficit = {}, 0, true, false, false
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
    elseif a:match("^arm=") then
        allowArm = a:match("=(%d)") ~= "0"
    else
        passed[#passed + 1] = a
    end
end

harness.root = "/tmp/cc_harness_axis"
os.execute("rm -rf /tmp/cc_harness_axis")
harness.model.dropEveryNthCommand = dropNth
harness.model.exponent = 1.0
harness.model.rrDeficit = rrDeficit

if not allowArm then
    harness.model.refuseArm = true
end

if stable then
    -- The MEASURED world. /fcs/rolldrift.lua found the hull self-levels:
    -- roll bounded within -2.75..+0.82 deg over 78.7 s against a free-drift
    -- prediction of -34.7, crossing zero twice. Stiffness ~0.0091 deg/s^2 per
    -- degree, period ~66 s.
    --
    -- The harness default remains NO restoring moment, because a harness that
    -- assumes stabilization is forgiving in exactly the way that wrecks a
    -- carrier. `stable` reproduces what was actually measured.
    harness.model.rollRestoring = 0.0091
    harness.model.rollDamping = 0.05
end

harness.install(_G)
_G.package = package
package.path = "./?.lua;./?/init.lua;" .. package.path

print(("harness: dropNth=%d arm=%s stable=%s args=%s"):format(
    dropNth, tostring(allowArm), tostring(stable), table.concat(passed, " ")))
print(("-"):rep(72))

local ok, err = pcall(function()
    harness.run({ function()
        local chunk = assert(loadfile("fcs/axisresponse.lua"))
        local unpackFn = table.unpack or unpack
        chunk(unpackFn(passed))
    end }, true)
end)

print(("-"):rep(72))
if not ok then print("raised: " .. tostring(err)) end

local craft = harness.craft
print(string.format("harness: final y=%.3f (ground %.3f, gain %+.2f) grounded=%s",
    craft.y, -26.5736, craft.y - (-26.5736), tostring(craft.grounded)))
print(string.format("harness: roll=%.3f deg  pitch=%.3f deg  rollRate=%.4f  pitchRate=%.4f",
    craft.roll, craft.pitch, craft.rollRate, craft.pitchRate))
print(string.format("harness: TOUCHDOWN vy = %.3f blocks/s  (peak descent %.3f)", craft.vy, craft.peakDescent or 0))

local parts = {}
for corner, pod in pairs(harness.pods()) do
    parts[#parts + 1] = string.format("%s:armed=%s pwr=%.3f", corner, tostring(pod.armed), pod.currentPower or 0)
end
table.sort(parts)
print("harness: " .. table.concat(parts, "  "))

-- The safety property that matters most: never left airborne AND disarmed.
local airborne = (craft.y - (-26.5736)) > 1.0
local anyArmed = false
for _, pod in pairs(harness.pods()) do
    if pod.armed or (pod.currentPower or 0) > 0 then anyArmed = true end
end
if airborne and not anyArmed then
    print("SAFETY VIOLATION: airborne with every bank at zero -- this is a fall")
    os.exit(1)
end
print("safety: " .. (airborne and "airborne, banks still carrying" or "grounded"))
