-- CC resolves relative require() patterns against the directory of the running
-- program, so from /fcs/ the module "fcs.config" is searched for at
-- /fcs/fcs/config.lua and never found. Patterns beginning with "/" are exempt
-- from that combine, so rooting the search path at / makes "fcs.x" resolve to
-- /fcs/x.lua no matter where the program was launched from.
package.path = "/?.lua;/?/init.lua;" .. package.path

local actuators = require("fcs.actuators")

local args = { ... }

local function usage()
    print("Manual propeller test tool")
    print("This program changes RPM; startup.lua does not.")
    print("")
    print("Usage:")
    print("  /fcs/propctl.lua status <FL|FR|RL|RR>")
    print("  /fcs/propctl.lua set <FL|FR|RL|RR> <rpm>")
end

if #args < 2 then
    usage()
    return
end

local command = string.lower(args[1])
local corner = string.upper(args[2])

if command == "status" then
    local status = actuators.getPropellerStatus(corner)
    print(textutils.serialize(status))
    return
end

if command == "set" then
    if not args[3] then
        usage()
        return
    end

    print("WARNING: This will command the " .. corner .. " propeller.")
    write("Type YES to continue: ")
    if read() ~= "YES" then
        print("Cancelled.")
        return
    end

    local status = actuators.setPropellerRpm(corner, args[3])
    print(textutils.serialize(status))
    return
end

usage()
