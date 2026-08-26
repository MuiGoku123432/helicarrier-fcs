-- Run /fcs/reboot.lua against the CC harness.
--   luajit tools/run_reboot_harness.lua all
--   luajit tools/run_reboot_harness.lua armed all        (banks armed -> refuse)
--   luajit tools/run_reboot_harness.lua armed all --force
--   luajit tools/run_reboot_harness.lua holding all      (DISARMED but holding
--                                                         commsLossPower -> refuse)
--
-- `holding` is the state a comms-loss watchdog fire leaves a pod in: armed is
-- false, but the bank is still carrying commsLossPower. An armed-only guard
-- reboots that pod and drops the lift, so this mode exists to prove the guard
-- keys on thrust rather than on the armed flag.
package.path = "./?.lua;./?/init.lua;" .. package.path
local harness = require("tools.cc_harness")

local passed = {}
local armed, holding = false, false
for i = 1, #arg do
    if arg[i] == "armed" then
        armed = true
    elseif arg[i] == "holding" then
        holding = true
    else
        passed[#passed + 1] = arg[i]
    end
end

harness.readAnswer = "REBOOT"
harness.root = "/tmp/cc_harness_reboot"
os.execute("rm -rf /tmp/cc_harness_reboot")
harness.model.exponent = 1.0
-- Give the pods a command history so a reboot shows up as a counter reset.
for _, pod in pairs(harness.pods()) do
    pod.commandsSeen = 500
    pod.armed = armed
    if holding then
        -- Exactly what watchdogLoop leaves behind: disarmed, still lifting.
        pod.armed = false
        pod.currentPower = harness.model.ionCommsLossPower
    else
        pod.currentPower = armed and 0.15 or 0
    end
end

harness.install(_G)
_G.package = package
package.path = "./?.lua;./?/init.lua;" .. package.path

print(("harness: banks armed = %s; holding = %s; args = %s"):format(
    tostring(armed), tostring(holding), table.concat(passed, " ")))
print(("-"):rep(64))

local ok, err = pcall(function()
    harness.run({ function()
        local chunk = assert(loadfile("fcs/reboot.lua"))
        -- NOT `table.unpack and table.unpack(p) or unpack(p)`: an and/or
        -- expression keeps only the FIRST return value, so that silently
        -- passed just the first argument and --force never arrived.
        local unpackFn = table.unpack or unpack
        chunk(unpackFn(passed))
    end }, true)
end)

print(("-"):rep(64))
if not ok then print("raised: " .. tostring(err)) end
local st = {}
for c, pod in pairs(harness.pods()) do
    st[#st + 1] = c .. ":reboots=" .. tostring(pod.rebooted or 0)
end
table.sort(st)
print("harness: " .. table.concat(st, "  "))
