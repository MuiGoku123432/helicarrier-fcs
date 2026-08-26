-- CC resolves relative require() patterns against the directory of the running
-- program, so from /fcs/ the module "fcs.config" is searched for at
-- /fcs/fcs/config.lua and never found. Patterns beginning with "/" are exempt
-- from that combine, so rooting the search path at / makes "fcs.x" resolve to
-- /fcs/x.lua no matter where the program was launched from.
package.path = "/?.lua;/?/init.lua;" .. package.path

local config = require("fcs.config")
local banks = require("fcs.banks")

local args = { ... }

local function usage()
    print("Wireless ion-bank test tool")
    print("")
    print("Usage:")
    print("  /fcs/bankctl.lua status")
    print("  /fcs/bankctl.lua ping <FL|FR|RL|RR>")
    print("  /fcs/bankctl.lua pulse <corner> <power 0..1> <seconds>")
end

local function sendOrError(corner, messageType, fields)
    local ok, result = banks.send(corner, messageType, fields)
    if not ok then
        error(result, 0)
    end
    return result
end

local command = string.lower(args[1] or "")

if command == "status" then
    for _, corner in ipairs(banks.corners()) do
        banks.send(corner, "ping")
    end
    banks.poll()
    sleep(0.15)
    banks.poll()
    for _, corner in ipairs(banks.corners()) do
        local pod = banks.getState()[corner]
        print(corner .. ": " .. textutils.serialize(pod))
    end
    return
end

if command == "ping" and args[2] then
    local corner = string.upper(args[2])
    sendOrError(corner, "ping")
    print("Ping sent to " .. corner)
    return
end

if command == "pulse" and args[2] and args[3] and args[4] then
    local corner = string.upper(args[2])
    local power = tonumber(args[3])
    local duration = tonumber(args[4])

    if not power or power < 0 or power > 1 then
        error("power must be between 0 and 1", 0)
    end
    if not duration or duration <= 0 or duration > 5 then
        error("pulse duration must be greater than 0 and no more than 5 seconds", 0)
    end

    print("WARNING: This will command the " .. corner .. " ion bank.")
    print(string.format("Power %.3f for %.2f seconds", power, duration))
    write("Type YES to continue: ")
    if read() ~= "YES" then
        print("Cancelled.")
        return
    end

    sendOrError(corner, "arm")
    local finishAt = os.epoch("utc") + math.floor(duration * 1000)

    while os.epoch("utc") < finishAt do
        sendOrError(corner, "set_power", { power = power })
        sleep(0.10)
    end

    sendOrError(corner, "disarm")
    print("Pulse complete; pod returned to its configured fallback power.")
    return
end

usage()
