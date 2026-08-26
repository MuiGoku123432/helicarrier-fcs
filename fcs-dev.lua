-- fcs-dev: the monitor hub for the main FCS computer.
--
-- Reads telemetry frames published by /fcs/main.lua and draws them. It sends
-- nothing, commands nothing, and opens no modem.
--
-- How this program is started decides whether it has require() at all.
-- shell.run and shell.openTab wrap a program in a shell env, which injects
-- require/package. multishell.launch goes straight to os.run() and injects
-- neither, so touching package.path there throws on a nil global. Build them
-- when missing, rooted at "/" so "fcs.x" resolves to /fcs/x.lua.
if package then
    package.path = "/?.lua;/?/init.lua;" .. package.path
else
    require, package = dofile("/rom/modules/main/cc/require.lua").make(_ENV, "/")
end

local config = require("fcs.config")
local run = require("fcs.hub.run")

local USAGE = [[
fcs-dev -- helicarrier monitor hub

  fcs-dev                    render to the configured or first monitor
  fcs-dev --term             render to this terminal instead
  fcs-dev --monitor <name>   render to a named monitor peripheral
  fcs-dev --scale <n>        override the monitor text scale

Reads frames published by /fcs/main.lua. Commands nothing.
]]

local hub = config.hub or {}

local options = {
    monitorName = hub.monitorName,
    textScale = hub.textScale or 0.5,
    maxRedrawHz = hub.maxRedrawHz or 5,
    staleAfterMs = hub.staleAfterMs or 1000,
    deadAfterMs = hub.deadAfterMs or 5000,
    term = false,
}

local arguments = { ... }
local index = 1
while index <= #arguments do
    local argument = arguments[index]
    if argument == "--term" then
        options.term = true
    elseif argument == "--monitor" then
        index = index + 1
        options.monitorName = arguments[index]
        if not options.monitorName then
            printError("--monitor needs a peripheral name")
            print(USAGE)
            return
        end
    elseif argument == "--scale" then
        index = index + 1
        local scale = tonumber(arguments[index])
        if not scale then
            printError("--scale needs a number")
            print(USAGE)
            return
        end
        options.textScale = scale
    elseif argument == "--help" or argument == "-h" then
        print(USAGE)
        return
    else
        printError("unknown option: " .. tostring(argument))
        print(USAGE)
        return
    end
    index = index + 1
end

run.start(options)
