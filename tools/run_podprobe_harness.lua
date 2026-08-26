-- Run /fcs/podprobe.lua against the CC harness, in each of the failure modes
-- it exists to tell apart.
--
--   luajit tools/run_podprobe_harness.lua healthy
--   luajit tools/run_podprobe_harness.lua ghost      FR hostname held by a dead
--                                                    computer; lookup gets it
--   luajit tools/run_podprobe_harness.lua twins      the ghost transmits too
--   luajit tools/run_podprobe_harness.lua slow       FR acks at 1400 ms
--   luajit tools/run_podprobe_harness.lua cmdloss    commands never land
--   luajit tools/run_podprobe_harness.lua ackloss    commands land, acks do not
--   luajit tools/run_podprobe_harness.lua all
--
-- The point is not that the probe runs. It is that each mode produces a
-- DIFFERENT verdict line, because the three causes need opposite fixes: a
-- ghost needs the duplicate stopped, a slow pod needs the timeout raised, and
-- loss needs a retry. A probe that cannot separate them is worth nothing.
package.path = "./?.lua;./?/init.lua;" .. package.path
local harness = require("tools.cc_harness")

local MODES = { "healthy", "ghost", "twins", "slow", "cmdloss", "ackloss" }

local requested = {}
for i = 1, #arg do
    if arg[i] == "all" then
        for _, mode in ipairs(MODES) do requested[#requested + 1] = mode end
    else
        requested[#requested + 1] = arg[i]
    end
end
if #requested == 0 then requested = { "all" } end
if requested[1] == "all" then requested = MODES end

-- The probe is a script, not a module: it runs on load and cannot be re-run in
-- one process (the harness clock and the installed globals are per-process
-- state). So each mode is a fresh child process.
if os.getenv("PODPROBE_MODE") == nil then
    local failures = 0
    for _, mode in ipairs(requested) do
        io.write(("="):rep(72), "\nMODE: ", mode, "\n", ("="):rep(72), "\n")
        io.flush()   -- the child writes to the same fd; unflushed headers land after it
        local command = ("PODPROBE_MODE=%s luajit %s"):format(mode, arg[0])
        local ok = os.execute(command)
        if ok ~= true and ok ~= 0 then
            failures = failures + 1
        end
    end
    os.exit(failures == 0 and 0 or 1)
end

local mode = os.getenv("PODPROBE_MODE")

harness.root = "/tmp/cc_harness_podprobe"
os.execute("rm -rf /tmp/cc_harness_podprobe")
harness.model.exponent = 1.0
-- Grounded: every corner reporting 0 RPM is what lets the ack test run without
-- --force, and it is the state the probe is meant to be used in.
for _, pod in pairs(harness.pods()) do
    pod.targetRpm = 0
    pod.armed = false
    pod.currentPower = 0
end

if mode == "ghost" then
    harness.model.ghostHost = { corner = "FR", id = 13, transmits = false }
elseif mode == "twins" then
    harness.model.ghostHost = { corner = "FR", id = 13, transmits = true }
elseif mode == "slow" then
    -- Just past actuators.REPLY_TIMEOUT_MS. The pod applies every command; the
    -- sender gives up before hearing so.
    harness.model.podReplyLatencyMs = { FR = 1400 }
elseif mode == "cmdloss" then
    -- Every third set_rpm never reaches the pod: the counter does not move and
    -- the propeller does not either.
    harness.model.dropEveryNthCommand = 3
elseif mode == "ackloss" then
    -- Every third set_rpm IS applied and its ack is lost. Identical from the
    -- sender's side, opposite in consequence -- the whole reason the probe
    -- reads the pod's counter as well as its replies.
    harness.model.dropEveryNthReply = 3
elseif mode ~= "healthy" then
    error("unknown mode " .. tostring(mode) .. "; use " .. table.concat(MODES, " "))
end

harness.install(_G)
_G.package = package
package.path = "./?.lua;./?/init.lua;" .. package.path

local ok, err = pcall(function()
    harness.run({ function()
        local chunk = assert(loadfile("fcs/podprobe.lua"))
        chunk("4")   -- four round trips per corner is enough to separate them
    end }, true)
end)

if not ok then
    print("raised: " .. tostring(err))
    os.exit(1)
end
