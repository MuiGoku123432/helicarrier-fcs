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

    -- A THIRD TAB, dedicated to flight tools, and focused on boot.
    --
    -- The logger already had its own tab, yet it still ended up stopped for
    -- runs 9-13 -- every one of them flew with no flight CSV at all, which is
    -- exactly the data needed to explain the 2x scatter in measured authority.
    -- The failure mode is quiet: a tool started in the telemetry tab replaces
    -- main.lua, and nothing says so. last_error.txt stays EMPTY, because the
    -- loop never reached its own exit handler.
    --
    -- So make the safe tab the obvious one: label it, and land the operator in
    -- it. Nothing here prevents running a tool in the telemetry tab; it just
    -- stops being the path of least resistance.
    --
    -- pcall'd: the telemetry tab is already up by this point, and a failure to
    -- open a convenience tab must never be what stops the logger booting.
    local opened, toolTab = pcall(shell.openTab, "shell")
    if opened and toolTab then
        pcall(multishell.setTitle, toolTab, "Flight Tools")
        print("Flight tools tab: " .. tostring(toolTab))
        print("")
        print("Run flight tools in the 'Flight Tools' tab.")
        print("Running one in 'FCS Telemetry' kills the logger.")
        if multishell.setFocus then
            pcall(multishell.setFocus, toolTab)
        end
    else
        print("Could not open a flight-tools tab: " .. tostring(toolTab))
        print("Use THIS tab for tools -- not the telemetry tab.")
    end
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
