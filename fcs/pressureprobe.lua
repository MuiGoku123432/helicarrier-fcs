-- THROWAWAY PROBE -- handoff step 4, aero.getRaw().pressureFunction.
--
-- Read-only. Calls no setter, commands nothing, safe in any craft state.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS IS ACTUALLY FOR
--
-- HANDOFF.md says to use pressureFunction "instead of the sampled pressure
-- profile, since the atmosphere is not a clean exponential". Worth being
-- precise about what that does and does not buy, because the obvious reading
-- is wrong:
--
--   * The bad fit is the EXPONENTIAL fit (H = 263.9 blocks, r2 = 0.976).
--     airprofile.lua already warns about it and already interpolates between
--     real samples instead.
--   * aero.getAirPressure(position) is not an approximation -- it is the real
--     value at that position. Sampling it is already exact.
--
-- So the win is not accuracy. It is COST and COVERAGE:
--
--   1. getPoints() should hand back the curve's own control points in ONE
--      call, so a controller can build a local table at startup and never pay
--      a Sable call for pressure again. The loop already runs ~950 ms against
--      a 250 ms target, dominated by Sable calls -- this is one it can drop.
--   2. evaluateFunction(y) may be far cheaper than getAirPressure(vector),
--      which has to build a position first.
--
-- This probe answers: what shape do they return, what do they mean against
-- getAirPressure, and are they actually cheaper.
-- ---------------------------------------------------------------------------

package.path = "/?.lua;/?/init.lua;" .. package.path

local REPORT_PATH = "/fcs/pressureprobe.txt"

local lines = {}
local function note(text)
    lines[#lines + 1] = text
    print(text)
end

local function render(value, depth)
    depth = depth or 0
    local kind = type(value)
    if kind == "nil" then return "nil" end
    if kind == "number" then return string.format("%.8f", value) end
    if kind == "string" then return string.format("%q", value) end
    if kind == "boolean" then return tostring(value) end
    if kind == "function" then return "<function>" end
    if kind ~= "table" then return "<" .. kind .. ">" end
    if depth > 3 then return "<table, deeper>" end

    local entries = {}
    for key, entry in pairs(value) do
        entries[#entries + 1] = { label = tostring(key), value = entry }
    end
    table.sort(entries, function(a, b) return a.label < b.label end)

    local parts = {}
    for _, entry in ipairs(entries) do
        parts[#parts + 1] = entry.label .. "=" .. render(entry.value, depth + 1)
    end
    if #parts == 0 then return "{}" end
    return "{" .. table.concat(parts, ", ") .. "}"
end

if not aero then
    error("CC:Sable aero API is unavailable", 0)
end

note("=== pressureFunction probe ===")
note("time " .. tostring(os.epoch("utc")))

local raw = aero.getRaw()
note("")
note("aero.getRaw() = " .. render(raw))

local pf = raw and raw.pressureFunction
if type(pf) ~= "table" then
    error("getRaw().pressureFunction is not a table", 0)
end

-- ---------------------------------------------------------------------------
-- getPoints: the whole curve in one call, if it is what it sounds like
-- ---------------------------------------------------------------------------

note("")
note("-- getPoints() --")
local okPoints, points = pcall(pf.getPoints)
if not okPoints then
    note("  rejected: " .. tostring(points))
else
    note("  type: " .. type(points))
    note("  rendered: " .. render(points))
    if type(points) == "table" then
        local count = 0
        for _ in pairs(points) do count = count + 1 end
        note("  entry count: " .. count)
    end
end

-- ---------------------------------------------------------------------------
-- evaluateFunction: signature unknown, so try the plausible shapes
-- ---------------------------------------------------------------------------

note("")
note("-- evaluateFunction() signature discovery --")

local candidates = {
    { label = "(0)", args = { 0 } },
    { label = "(64)", args = { 64 } },
    { label = "({0, 64, 0})", args = { { 0, 64, 0 } } },
    { label = "({x=0,y=64,z=0})", args = { { x = 0, y = 64, z = 0 } } },
    { label = "(vector.new(0,64,0))", args = { vector and vector.new and vector.new(0, 64, 0) or nil } },
    { label = "(0, 64, 0)", args = { 0, 64, 0 } },
}

local accepted
for _, candidate in ipairs(candidates) do
    if candidate.args[1] ~= nil then
        local results = { pcall(pf.evaluateFunction, table.unpack(candidate.args)) }
        if results[1] then
            note(string.format("  %-24s OK -> %s", candidate.label, render(results[2])))
            if not accepted then accepted = candidate end
        else
            note(string.format("  %-24s rejected: %s", candidate.label, tostring(results[2])))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Semantics: does it agree with getAirPressure, and in what units?
--
-- getRaw().pressure reads 1 while the craft origin measures 1.4309, so the
-- function is probably a multiplier on a base rather than an absolute
-- pressure. Comparing the two at the same altitudes settles it -- and the
-- ratio column is the conversion factor if they differ.
-- ---------------------------------------------------------------------------

if accepted then
    note("")
    note("Accepted signature: " .. accepted.label)
    note("")
    note("-- evaluateFunction vs aero.getAirPressure --")
    note(string.format("  %10s %16s %16s %12s", "y", "evaluate", "getAirPressure", "ratio"))

    local pose = sublevel and sublevel.isInPlotGrid and sublevel.isInPlotGrid()
        and sublevel.getLogicalPose() or nil
    local baseX = pose and pose.position and pose.position.x or 0
    local baseZ = pose and pose.position and pose.position.z or 0

    for _, y in ipairs({ -64, 0, 32, 64, 96, 128, 192, 256, 320 }) do
        local evaluated
        if type(accepted.args[1]) == "number" and #accepted.args == 1 then
            local ok, value = pcall(pf.evaluateFunction, y)
            evaluated = ok and value or nil
        elseif type(accepted.args[1]) == "table" then
            local argument = accepted.args[1][1] ~= nil and { 0, y, 0 } or { x = 0, y = y, z = 0 }
            local ok, value = pcall(pf.evaluateFunction, argument)
            evaluated = ok and value or nil
        else
            local ok, value = pcall(pf.evaluateFunction, 0, y, 0)
            evaluated = ok and value or nil
        end

        local ok, measured = pcall(aero.getAirPressure, vector.new(baseX, y, baseZ))
        measured = ok and measured or nil

        local ratio = (evaluated and measured and measured ~= 0)
            and string.format("%.6f", evaluated / measured) or "-"
        note(string.format("  %10d %16s %16s %12s", y,
            evaluated and string.format("%.8f", evaluated) or "nil",
            measured and string.format("%.8f", measured) or "nil",
            ratio))
    end

    -- -----------------------------------------------------------------------
    -- Cost. This is the whole point: the sample loop runs ~950 ms against a
    -- 250 ms target and Sable calls dominate it.
    -- -----------------------------------------------------------------------

    note("")
    note("-- cost per call (50 calls each) --")

    local ITERATIONS = 50

    local startEvaluate = os.epoch("utc")
    for index = 1, ITERATIONS do
        pcall(pf.evaluateFunction, (index % 200) + 1)
    end
    local evaluateMs = (os.epoch("utc") - startEvaluate) / ITERATIONS

    local startMeasure = os.epoch("utc")
    for index = 1, ITERATIONS do
        pcall(aero.getAirPressure, vector.new(baseX, (index % 200) + 1, baseZ))
    end
    local measureMs = (os.epoch("utc") - startMeasure) / ITERATIONS

    note(string.format("  evaluateFunction   %8.3f ms/call", evaluateMs))
    note(string.format("  getAirPressure     %8.3f ms/call", measureMs))
    if evaluateMs > 0 then
        note(string.format("  speedup            %8.2fx", measureMs / evaluateMs))
    end
    note("")
    note("  If getPoints returns the whole curve, the honest answer is neither:")
    note("  read it once at startup and interpolate locally for 0 ms/call.")
else
    note("")
    note("evaluateFunction rejected every candidate signature -- the error")
    note("text above names what it wanted.")
end

local file = fs.open(REPORT_PATH, "w")
file.write(table.concat(lines, "\n"))
file.close()
print("")
print("Report written to " .. REPORT_PATH)
