-- Does any file call a `local function` before it is defined?
--
-- WHY THIS EXISTS. On 2026-08-26 the vectoring probe's drift abort called
-- commandAllTilts, which was declared `local function` FIFTY LINES BELOW it.
-- Lua resolves that to a global, the global is nil, and the call throws -- but
-- only when the abort actually fires. It loaded fine, it passed every offline
-- test, it flew the ground phase fine, and it died at +11 blocks with the craft
-- accelerating away:
--
--     PROBE ERROR: attempt to call global 'commandAllTilts' (a nil value)
--
-- The craft was left airborne with the engines running and needed a forced pod
-- reboot. A syntax check cannot see this and neither can a unit test, because
-- the broken path is the one that only runs in an emergency.
--
-- So it gets a lint. Crude on purpose: text, not a parser -- it only has to
-- catch a call textually above its own `local function` line.
--
--     luajit tools/test_forwardrefs.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local FILES = {
    "fcs/vectorprobe.lua", "fcs/vectoring.lua", "fcs/lateralhold.lua",
    "fcs/craftgeom.lua", "fcs/axisresponse.lua", "fcs/flight.lua",
    "fcs/mixer.lua", "fcs/attitude.lua", "fcs/actuators.lua",
    "fcs/tiltctl.lua", "fcs/banks.lua", "fcs/podprobe.lua",
    "fcs/rolldampflight.lua",
    "fcs/trim.lua", "fcs/trimflight.lua",
    -- The harness too. It is not flight code, but the rule is the same and it
    -- has now cost a run: commandedTilt() was called from stepRotation fifty
    -- lines above its own definition, and the flight died at "climb to +12".
    "tools/cc_harness.lua",
    -- Pod code is deployed flight code too, and it is the half that runs
    -- with nobody watching the screen.
    "pod-template/pod/main.lua", "pod-template/pod/payload.lua",
    "pod-template/pod/props.lua", "pod-template/pod/thrusters.lua",
}

local failures = 0
local checked = 0

for _, path in ipairs(FILES) do
    local handle = io.open(path, "r")
    if handle then
        local lines = {}
        for line in handle:lines() do lines[#lines + 1] = line end
        handle:close()

        -- Where each local function is defined.
        local definedAt = {}
        for number, line in ipairs(lines) do
            local name = line:match("^%s*local function ([%w_]+)%s*%(")
            -- First definition wins; a redefinition later is a different smell.
            if name and not definedAt[name] then definedAt[name] = number end
        end

        for name, definitionLine in pairs(definedAt) do
            checked = checked + 1
            for number = 1, definitionLine - 1 do
                local line = lines[number]
                -- Skip comments -- this file and the ones it lints talk about
                -- these function names in prose constantly.
                if not line:match("^%s*%-%-") then
                    -- A call, not a mention: the name followed by an open paren,
                    -- and not preceded by a word character, a dot or a colon
                    -- (so obj.name( and obj:name( do not count).
                    local before, after = line:match("()([%w_]+%s*%()")
                    local _ = before, after
                    for position, candidate in line:gmatch("()([%w_]+)%s*%(") do
                        if candidate == name then
                            local preceding = position > 1
                                and line:sub(position - 1, position - 1) or " "
                            if not preceding:match("[%w_.:]") then
                                failures = failures + 1
                                print(string.format(
                                    "FAIL %s:%d calls '%s' but it is defined at line %d",
                                    path, number, name, definitionLine))
                            end
                        end
                    end
                end
            end
        end
    end
end

print("")
print(string.format("%d local functions checked across %d files, %d forward calls",
    checked, #FILES, failures))
if failures > 0 then
    print("")
    print("A forward reference to a `local function` is nil at call time.")
    print("Move the definition above its first use, or pre-declare it with")
    print("`local name` and assign `function name(...)` later.")
end
os.exit(failures == 0 and 0 or 1)
