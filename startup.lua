-- Main FCS computer startup.
-- Safe by design: the background service gathers telemetry only.
-- Manual pod tests use /fcs/bankctl.lua from the shell.

-- Root the module search at "/" so "fcs.config" resolves to /fcs/config.lua
-- regardless of the shell's working directory.
if package then
    package.path = "/?.lua;/?/init.lua;" .. package.path
end

term.clear()
term.setCursorPos(1, 1)
print("FCS data foundation starting in background...")

-- shell.openTab, NOT multishell.launch: openTab runs the program inside
-- rom/programs/shell.lua, which is what injects require/package into its
-- environment. multishell.launch calls os.run directly and the program starts
-- with no require at all.
if multishell and shell and shell.openTab then
    local tab = shell.openTab("/fcs/main.lua")
    multishell.setTitle(tab, "FCS Telemetry")
    print("Telemetry tab: " .. tostring(tab))
    print("Use the shell for /fcs/discover.lua and /fcs/bankctl.lua")
else
    local ok = shell.run("/fcs/main.lua")
    if not ok then
        printError("FCS logger stopped.")
        printError("Run /fcs/main.lua to see the error again.")
    end
end

-- Monitor hub, in its own tab. Guarded on a monitor actually being present, so
-- a computer with no wall boots exactly as it did before this existed.
local configLoaded, config = pcall(require, "fcs.config")
local hub = (configLoaded and type(config) == "table" and config.hub) or {}

if hub.autoStart ~= false and multishell and shell and shell.openTab then
    local hasMonitor = false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "monitor") then
            hasMonitor = true
            break
        end
    end

    if hasMonitor then
        local hubTab = shell.openTab("/fcs-dev.lua")
        multishell.setTitle(hubTab, "Monitor Hub")
        print("Monitor hub tab: " .. tostring(hubTab))
    else
        print("No monitor attached; run fcs-dev when one is placed.")
    end
end
