-- string.format specifiers that LuaJIT accepts and the CRAFT REJECTS.
--
-- This test exists because a `%+5s` shipped to the carrier and killed a ground
-- run on its second line: "invalid conversion specification". The harness
-- had run the same line minutes earlier without complaint.
--
-- LuaJIT is permissive about flags it cannot use; CC:Tweaked's Lua is strict.
-- So the whole offline rig -- every harness, every runner -- can be green on a
-- format string that aborts the moment it reaches the craft, and the failure
-- lands in flight rather than in a test. That is the same shape as this
-- project's signature bug: the rig agreeing with the code instead of with the
-- craft.
--
-- The flags +, space and # are only meaningful for NUMERIC conversions. Used
-- with %s they are an error on the target.
--
--     luajit tools/test_formats.lua
package.path = "./?.lua;./?/init.lua;" .. package.path

local FILES = {}
for _, directory in ipairs({ "fcs", "pod-template/pod", "tools" }) do
    local pipe = io.popen("ls " .. directory .. "/*.lua 2>/dev/null")
    if pipe then
        for line in pipe:lines() do FILES[#FILES + 1] = line end
        pipe:close()
    end
end

local failures, checked = 0, 0

for _, path in ipairs(FILES) do
    local file = io.open(path, "r")
    if file then
        local lineNumber = 0
        for line in file:lines() do
            lineNumber = lineNumber + 1
            -- Only lines that actually format something. Prose in a comment
            -- routinely contains things like "100% sure" and "%+5s" -- the
            -- first version of this file flagged its own header -- and a
            -- checker that cries wolf gets switched off.
            local formats = line:find("format%s*%(") ~= nil
            if not formats then line = "" end
            -- Every conversion specification in the line: % then flags, then
            -- width/precision, then the conversion character.
            for flags, conversion in line:gmatch("%%([-+ #0]*)[%d%.]*([a-zA-Z])") do
                checked = checked + 1
                if conversion == "s" or conversion == "q" then
                    local bad = flags:match("[+ #]")
                    if bad then
                        failures = failures + 1
                        print(string.format(
                            "FAIL %s:%d  '%%%s%s' -- the '%s' flag is numeric-only and",
                            path, lineNumber, flags, conversion, bad))
                        print("     is an error on the craft, though LuaJIT accepts it.")
                    end
                end
            end
        end
        file:close()
    end
end

print(string.format("%d conversion specifications checked across %d files, %d bad",
    checked, #FILES, failures))
os.exit(failures == 0 and 0 or 1)
