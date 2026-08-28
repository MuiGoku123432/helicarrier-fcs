-- Run /fcs/netdiag.lua against the CC harness.
--
--   luajit tools/run_netdiag_harness.lua wireless   one wireless modem
--   luajit tools/run_netdiag_harness.lua mixed      wireless + a wired bus
--   luajit tools/run_netdiag_harness.lua unplugged  a wired modem on no cable
--   luajit tools/run_netdiag_harness.lua quick      --quick, no matrix
--   luajit tools/run_netdiag_harness.lua all
--
-- WHAT THIS CAN AND CANNOT PROVE. The harness does NOT route messages by
-- transport -- every pod hears every send whatever is open -- so this cannot
-- show a wired corner surviving while a wireless one does not. That is what
-- the craft is for.
--
-- What it proves is that the tool RUNS: that it enumerates modems, opens them
-- one at a time and puts them all back, survives rednet.close() with no
-- argument, formats every line without hitting a specifier the craft rejects,
-- and does not index a nil when a pod reports no modem. A 300-line diagnostic
-- that has never executed is exactly how a %+5s reached the carrier and killed
-- a run.
package.path = "./?.lua;./?/init.lua;" .. package.path
local harness = require("tools.cc_harness")

local MODES = { "wireless", "mixed", "unplugged", "quick" }
local mode = arg[1] or "mixed"

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

harness.root = "/tmp/cc_harness_netdiag"
os.execute("rm -rf /tmp/cc_harness_netdiag")

if mode == "mixed" or mode == "quick" then
    harness.model.modems = {
        { name = "back", wireless = true },
        { name = "top", wireless = false, networkName = "computer_1",
          remote = { "modem_3", "modem_5" } },
    }
    harness.model.wiredCorners = { FR = true, RR = true }
elseif mode == "unplugged" then
    -- A wired modem attached to nothing. getNameLocal is nil, and the tool has
    -- to say so rather than reporting a bus that does not exist -- this is the
    -- single most common way a wired bus silently is not one.
    harness.model.modems = {
        { name = "back", wireless = true },
        { name = "top", wireless = false, networkName = nil, remote = {} },
    }
elseif mode == "wireless" then
    harness.model.modems = { { name = "top", wireless = true } }
else
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

print(("harness: mode=%s"):format(mode))
print(("-"):rep(72))

-- CAPTURE THE OUTPUT. netdiag wraps its own main loop in a pcall and prints
-- "RUN ERROR" rather than propagating -- which is right on the craft, where an
-- abort must still save its log and reopen the modems, and WRONG here: the
-- runner saw a clean exit code on a tool that had died at its first line.
local captured = {}
local realPrint = print
_G.print = function(...)
    local parts = {}
    for index = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(index, ...)))
    end
    captured[#captured + 1] = table.concat(parts, "\t")
    realPrint(...)
end

local ok, err = pcall(function()
    harness.run({ function()
        local chunk = assert(loadfile("fcs/netdiag.lua"))
        if mode == "quick" then chunk("--quick") else chunk() end
    end }, true)
end)

_G.print = realPrint

print(("-"):rep(72))
if not ok then
    print("raised: " .. tostring(err))
    os.exit(1)
end

for _, line in ipairs(captured) do
    if line:find("RUN ERROR", 1, true) then
        print("FAIL: netdiag reported a run error:")
        print("  " .. line)
        os.exit(1)
    end
end

-- EVERY MODEM MUST BE BACK OPEN. The tool closes them one at a time to isolate
-- a transport, and leaving the FCS on a single modem after a diagnostic would
-- be a worse fault than the one it went looking for.
local shut = {}
for _, entry in ipairs(harness.model.modems) do
    if not rednet.isOpen(entry.name) then shut[#shut + 1] = entry.name end
end
if #shut > 0 then
    print("FAIL: left closed after the run: " .. table.concat(shut, " "))
    os.exit(1)
end
print("harness: all modems reopened (" .. #harness.model.modems .. ")")
