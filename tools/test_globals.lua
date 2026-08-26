-- Does any file read a global that will not exist at run time?
--
-- WHY THIS EXISTS. Twice in one session a deployed flight tool died on a name
-- that was nil:
--
--   commandAllTilts   a `local function` referenced fifty lines above its own
--                     definition -- caught, afterwards, by test_forwardrefs
--   thrusts           a `local` declaration deleted during an edit, leaving
--                     three later uses reading a global that was never set
--
-- Both loaded cleanly. Both passed every unit test, because the code that
-- touched them only runs in flight. The first one died at +11 blocks with the
-- craft accelerating away and cost a forced pod reboot; the second aborted
-- preflight, which was luck rather than design.
--
-- luajit compiles a read of an undeclared name into a GGET instruction, so the
-- bytecode says exactly which names a file expects to find in _G. Anything
-- there that is not a real global is the bug above, before it flies.
--
--     luajit tools/test_globals.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local FILES = {
    "fcs/vectorprobe.lua", "fcs/vectoring.lua", "fcs/lateralhold.lua",
    "fcs/rolldamp.lua", "fcs/craftgeom.lua", "fcs/axisresponse.lua",
    "fcs/flight.lua", "fcs/mixer.lua", "fcs/attitude.lua", "fcs/actuators.lua",
    "fcs/banks.lua", "fcs/sensors.lua", "fcs/tiltctl.lua",
    "fcs/podprobe.lua",
    "fcs/rolldampflight.lua",
    -- Pod code is deployed flight code too, and it is the half that runs
    -- with nobody watching the screen.
    "pod-template/pod/main.lua", "pod-template/pod/payload.lua",
    "pod-template/pod/props.lua", "pod-template/pod/thrusters.lua",
}

-- Lua 5.1 / LuaJIT base library.
local ALLOWED = {
    _G = true, _VERSION = true, assert = true, collectgarbage = true,
    dofile = true, error = true, getfenv = true, getmetatable = true,
    ipairs = true, load = true, loadfile = true, loadstring = true,
    module = true, next = true, pairs = true, pcall = true, print = true,
    rawequal = true, rawget = true, rawlen = true, rawset = true,
    require = true, select = true, setfenv = true, setmetatable = true,
    tonumber = true, tostring = true, type = true, unpack = true,
    xpcall = true, coroutine = true, debug = true, io = true, math = true,
    os = true, package = true, string = true, table = true, bit = true,
    jit = true, arg = true,
    -- ComputerCraft. These exist on the computer but not under luajit, which
    -- is exactly why this has to read bytecode rather than run the file.
    colors = true, colours = true, commands = true, disk = true, fs = true,
    gps = true, help = true, http = true, keys = true, multishell = true,
    paintutils = true, parallel = true, peripheral = true, rednet = true,
    redstone = true, rs = true, settings = true, shell = true, term = true,
    textutils = true, vector = true, window = true, sleep = true,
    write = true, read = true, printError = true, turtle = true,
    -- CC:Sable injects these two into the environment the same way CC injects
    -- fs and peripheral. Every use in this repo guards with `if not sublevel`
    -- first, because a computer not mounted on a Sable craft has neither.
    sublevel = true, aero = true,
    -- _ENV is a Lua 5.2 upvalue and always exists on the computer (CC runs
    -- Cobalt, 5.2 semantics). LuaJIT is 5.1 and has no such name, so its
    -- bytecode records the read as a plain global and this lint would call a
    -- correct file broken. It appears exactly once, in the pod bootstrap that
    -- rebuilds require() when multishell.launch provides none -- which is how
    -- pod/main.lua is actually started.
    _ENV = true,
}

local failures, checked = 0, 0

for _, path in ipairs(FILES) do
    local handle = io.popen(string.format("luajit -bl %q 2>&1", path))
    if handle then
        local output = handle:read("*a")
        handle:close()

        -- Bytecode lines look like:
        --     0001    GGET     3   0      ; "type"
        -- The name is QUOTED, which the first version of this pattern missed
        -- -- it matched nothing and reported a clean sweep across every file.
        -- A lint that silently checks zero things is worse than no lint.
        local seen = {}
        for name in output:gmatch('GGET%s+%d+%s+%d+%s*;%s*"([%w_]+)"') do
            seen[name] = true
        end
        for name in output:gmatch('GSET%s+%d+%s+%d+%s*;%s*"([%w_]+)"') do
            seen[name] = true
        end

        for name in pairs(seen) do
            checked = checked + 1
            if not ALLOWED[name] then
                failures = failures + 1
                print(string.format("FAIL %s reads global '%s' -- nothing ever sets it",
                    path, name))
            end
        end
    end
end

print("")
print(string.format("%d global reads checked across %d files, %d undefined",
    checked, #FILES, failures))
if failures > 0 then
    print("")
    print("A name that is not a local and not a real global is nil at run time.")
    print("Usually a deleted `local` declaration, or a `local function` used")
    print("above where it is defined. Both load cleanly and both die in flight.")
end
os.exit(failures == 0 and 0 or 1)
