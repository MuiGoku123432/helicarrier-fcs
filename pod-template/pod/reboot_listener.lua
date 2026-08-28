-- Remote reboot listener.
--
-- Runs in its OWN TAB, deliberately separate from /pod/main.lua.
--
-- pod/startup.lua runs main.lua in the foreground, so when main.lua dies -- and
-- it has: /pod/last_error.txt has read `outcome=error reason=Terminated` -- the
-- pod stops listening entirely and only a walk out to the carrier will bring it
-- back. A reboot command is least likely to be heard exactly when it is most
-- needed. This listener does nothing but wait for that one message, so there is
-- very little in it that can fail, and it survives main.lua crashing.
--
-- It is NOT a watchdog: it cannot notice that main.lua stopped, only act when
-- told. Detecting a dead pod and recovering it automatically is a separate job
-- for the FCS, which already receives the heartbeats that would reveal it.

if package then
    package.path = "/?.lua;/?/init.lua;" .. package.path
else
    require, package = dofile("/rom/modules/main/cc/require.lua").make(_ENV, "/")
end

local config = require("pod.config")
local protocol = require("pod.protocol")

-- SAME MODEM main.lua CHOSE. Not "any wireless one".
--
-- rednet's set of open modems is PER COMPUTER, not per tab. This listener runs
-- in its own tab, so opening a modem here opens it for main.lua's networkLoop
-- too -- and rednet.receive takes messages from ANY open modem.
--
-- MEASURED 2026-08-28. FR and RR were moved to the wired bus and opened only
-- their wired modem in main.lua, and netdiag still found them reachable on the
-- RADIO: they counted 10 probes across the two transports where FL and RL
-- counted 5. This tab was holding the wireless modem open behind main.lua's
-- back. That silently destroys the transport A/B -- a pod surviving an outage
-- proves nothing if it was listening on both paths.
--
-- Honouring modemName also keeps remote reboot working on a wired corner: the
-- FCS opens every modem it has, so it reaches this listener over the cable.
local function findModem()
    local configured = config.modemName or config.wirelessModemName

    if configured == "wired" or configured == "wireless" then
        local want = (configured == "wireless")
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.hasType(name, "modem") then
                local modem = peripheral.wrap(name)
                if type(modem.isWireless) == "function" then
                    local ok, wireless = pcall(modem.isWireless)
                    if ok and (wireless and true or false) == want then
                        return name
                    end
                end
            end
        end
        return nil
    end

    if configured then return configured end

    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "modem") then
            local modem = peripheral.wrap(name)
            if type(modem.isWireless) == "function" and modem.isWireless() then
                return name
            end
        end
    end
    return nil
end

local modem = findModem()
if not modem then
    print("reboot listener: no modem matching config.modemName")
    return
end

-- Harmless if main.lua already opened it.
rednet.open(modem)

term.clear()
term.setCursorPos(1, 1)
print("Reboot listener active on " .. modem)
print("Corner: " .. tostring(config.corner))
print("Accepting reboot only from computer "
    .. tostring(config.mainComputerId or "<any, unconfigured>"))
print("")
print("This tab is separate from the pod controller so that a")
print("crashed controller can still be rebooted remotely.")

while true do
    local senderId, message = rednet.receive(config.protocol)

    if senderId and type(message) == "table" and protocol.validate(message)
        and message.type == "reboot" then
        -- Same trust rule the controller uses: only the configured main
        -- computer. An unauthenticated reboot is a way to drop the carrier.
        local trusted = config.mainComputerId
        if trusted and senderId ~= trusted then
            print("ignored reboot from untrusted computer " .. tostring(senderId))
        elseif message.corner and message.corner ~= config.corner then
            print("ignored reboot addressed to " .. tostring(message.corner))
        else
            -- Acknowledge BEFORE rebooting; after os.reboot() nothing else runs.
            pcall(rednet.send, senderId, protocol.message("ack", {
                corner = config.corner,
                hostname = config.hostname,
                rebooting = true,
            }), config.protocol)
            print("reboot commanded by " .. tostring(senderId))
            sleep(0.2)
            os.reboot()
        end
    end
end
