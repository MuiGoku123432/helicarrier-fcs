-- Reboot the engine pods from FCS-DEV.
--
--   /fcs/reboot.lua all
--   /fcs/reboot.lua FL FR
--   /fcs/reboot.lua all --force
--
-- Every code change to /pod/ needs the pods restarted, and doing that by hand
-- means four trips around the carrier. Each pod runs /pod/reboot_listener.lua in
-- its own tab, so this works even when the pod controller has crashed -- which
-- is exactly when a reboot is wanted and exactly when the controller cannot
-- answer.
--
-- THE GUARD THAT MATTERS: a rebooting pod runs thrusters.applyExact(
-- fallbackPower) on startup, which is 0.0. If the ion banks are carrying lift and
-- carrying lift, rebooting drops that lift. Measured: props at 64 RPM carry only
-- 52% of weight, so rebooting mid-flight on ions is a fall. This refuses while
-- any bank is armed unless --force.
--
-- Propellers are different: the Rotation Speed Controller is a Create block and
-- holds its target speed across a pod reboot, so prop lift is NOT lost. That is
-- expected rather than verified, so the safe habit is still to reboot grounded.

if package then
    package.path = "/?.lua;/?/init.lua;" .. package.path
else
    require, package = dofile("/rom/modules/main/cc/require.lua").make(_ENV, "/")
end

local config = require("fcs.config")
local banks = require("fcs.banks")

local CORNERS = { "FL", "FR", "RL", "RR" }

local args = { ... }
local force, requested = false, {}
for _, arg in ipairs(args) do
    local upper = string.upper(arg)
    if arg == "--force" then
        force = true
    elseif upper == "ALL" then
        for _, corner in ipairs(CORNERS) do requested[#requested + 1] = corner end
    else
        requested[#requested + 1] = upper
    end
end

if #requested == 0 then
    print("Reboot engine pods from FCS-DEV.")
    print("")
    print("  /fcs/reboot.lua all")
    print("  /fcs/reboot.lua FL RR")
    print("  /fcs/reboot.lua all --force   (reboot even while armed)")
    return
end

local valid = {}
for _, corner in ipairs(CORNERS) do valid[corner] = true end
for _, corner in ipairs(requested) do
    if not valid[corner] then
        error("unknown corner " .. corner .. "; use FL, FR, RL, RR or all", 0)
    end
end

-- ---------------------------------------------------------------------------
-- Listen in its own coroutine. CC delivers an event to a coroutine only when it
-- matches that coroutine's filter and drops it otherwise, and every wait below
-- is filtered -- the same trap that cost this project a session twice.
-- ---------------------------------------------------------------------------

local function listenLoop()
    while true do
        if not banks.listen(1) then
            sleep(0.05)
        end
    end
end

local function rebootLoop()
    -- A fresh program starts with every corner marked offline and nothing
    -- received, so wait for telemetry before judging anything armed.
    write("reading pod state")
    local deadline = os.epoch("utc") + config.wireless.offlineAfterMs + 3000
    local seen = {}
    while os.epoch("utc") < deadline do
        banks.poll()
        local missing = false
        for _, corner in ipairs(requested) do
            local pod = banks.getState()[corner] or {}
            if pod.online then seen[corner] = true else missing = true end
        end
        if not missing then break end
        sleep(0.25)
    end
    print("")

    -- Guard on LIVE THRUST, not on `armed`.
    --
    -- Since commsLossPower was split out of fallbackPower, a watchdog timeout
    -- disarms the bank but leaves it HOLDING lift. A pod in that state reports
    -- armed=false while carrying half the craft's weight, so an armed-only
    -- guard would cheerfully reboot it -- and a reboot returns thrusters to
    -- fallbackPower, which is 0.0. That is the exact fall this command exists
    -- to prevent, and it is most likely precisely when comms have been flaky.
    local live, liveLabels, offline = {}, {}, {}
    for _, corner in ipairs(requested) do
        local pod = banks.getState()[corner] or {}
        local power = tonumber(pod.currentPower) or 0
        if pod.armed or power > 0 then
            live[#live + 1] = corner
            liveLabels[#liveLabels + 1] = pod.armed and corner
                or string.format("%s (disarmed, still holding %.3f)", corner, power)
        end
        if not pod.online then offline[#offline + 1] = corner end
    end

    for _, corner in ipairs(requested) do
        local pod = banks.getState()[corner] or {}
        print(string.format("  %s  %s  armed=%s  power=%s  rpm=%s",
            corner,
            pod.online and "online " or "OFFLINE",
            tostring(pod.armed),
            tostring(pod.currentPower),
            tostring((pod.prop or {}).targetRpm)))
    end
    print("")

    if #offline > 0 then
        -- Not fatal. A pod whose controller has crashed reports offline yet its
        -- listener tab is still running, which is the main reason this exists.
        print("offline: " .. table.concat(offline, ", "))
        print("(the listener tab may still answer -- that is the point)")
        print("")
    end

    if #live > 0 and not force then
        print("REFUSING: banks carrying thrust on " .. table.concat(liveLabels, ", "))
        print("")
        print("A rebooting pod returns its thrusters to fallbackPower (0.0),")
        print("so rebooting one drops whatever lift it is carrying.")
        print("A bank can be DISARMED and still holding: a comms-loss watchdog")
        print("fire disarms it but leaves it at commsLossPower.")
        print("Disarm first, or pass --force if you know it is grounded.")
        error("banks carrying thrust; refusing to reboot", 0)
    end

    if #live > 0 then
        print("WARNING: --force with banks carrying thrust on "
            .. table.concat(liveLabels, ", "))
    end

    write("Type REBOOT to confirm " .. table.concat(requested, " ") .. ": ")
    if read() ~= "REBOOT" then
        print("Cancelled. Nothing was sent.")
        return
    end

    -- Sample the boot stamps BEFORE sending anything. Read afterwards they are
    -- already the post-reboot values, and nothing ever looks restarted.
    local before = {}
    for _, corner in ipairs(requested) do
        local pod = banks.getState()[corner] or {}
        before[corner] = pod.bootedAt
    end

    -- Send several times rather than once. A pod that ignores the first message
    -- gives no second chance -- it is about to stop listening either way, so
    -- there is nothing to be gained by being frugal here.
    for attempt = 1, 3 do
        for _, corner in ipairs(requested) do
            banks.send(corner, "reboot")
        end
        banks.poll()
        sleep(0.4)
        print("  sent (attempt " .. attempt .. ")")
    end

    print("")
    print("Waiting for pods to come back...")

    -- Coming back is the only real confirmation, and the boot stamp is the only
    -- unambiguous sign of it: a pod that ignored the command is online too.
    local waitUntil = os.epoch("utc") + 30000
    local back = {}
    while os.epoch("utc") < waitUntil do
        banks.poll()
        for _, corner in ipairs(requested) do
            if not back[corner] then
                local pod = banks.getState()[corner] or {}
                if pod.online and pod.bootedAt and pod.bootedAt ~= before[corner] then
                    back[corner] = true
                    print("  " .. corner .. " is back (new boot stamp)")
                end
            end
        end
        local pending = false
        for _, corner in ipairs(requested) do
            if not back[corner] then pending = true end
        end
        if not pending then break end
        sleep(0.5)
    end

    local late = {}
    for _, corner in ipairs(requested) do
        if not back[corner] then late[#late + 1] = corner end
    end

    print("")
    if #late == 0 then
        print("All requested pods rebooted and reporting.")
    else
        print("No confirmed restart from: " .. table.concat(late, ", "))
        print("They may still be booting, or may not have heard it.")
        print("Check /pod/heartbeat.txt, or reboot those by hand.")
    end
end

parallel.waitForAny(rebootLoop, listenLoop)
