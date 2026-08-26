-- Offline tests for fcs/hub/layout.lua.
--
-- Layout is pure arithmetic on a screen size, so this is plain Lua rather than
-- tools/cc_harness.lua -- there is no event scheduling to reproduce.
--
--     luajit tools/test_hub_layout.lua      (from the repo root)

package.path = "./?.lua;" .. package.path

local layout = require("fcs.hub.layout")

local passed, failed = 0, 0
local currentTest = "<none>"

local function fail(message)
    failed = failed + 1
    print(string.format("  FAIL  %s: %s", currentTest, message))
end

local function ok() passed = passed + 1 end

local function check(condition, message)
    if condition then ok() else fail(message) end
end

local function equal(actual, expected, message)
    if actual ~= expected then
        fail(string.format("%s: expected %s, got %s",
            message, tostring(expected), tostring(actual)))
        return
    end
    ok()
end

local function test(name, body)
    currentTest = name
    local succeeded, err = pcall(body)
    if not succeeded then fail("threw: " .. tostring(err)) end
end

-- The sizes that matter: the 4x3 wall at scale 0.5, an Advanced Computer
-- terminal, a wall one block bigger, and something far too small.
local SIZES = {
    { name = "wall 79x38", w = 79, h = 38 },
    { name = "terminal 51x19", w = 51, h = 19 },
    { name = "large 120x50", w = 120, h = 50 },
    { name = "tiny 29x12", w = 29, h = 12 },
    { name = "degenerate 5x3", w = 5, h = 3 },
}

local function byName(plan, name)
    for _, zone in ipairs(plan.zones) do
        if zone.name == name then return zone end
    end
    return nil
end

local function overlaps(a, b)
    return a.x < b.x + b.w and b.x < a.x + a.w
        and a.y < b.y + b.h and b.y < a.y + a.h
end

-- ---------------------------------------------------------------------------
-- Invariants that must hold at EVERY size
-- ---------------------------------------------------------------------------

for _, size in ipairs(SIZES) do
    test(size.name .. ": every zone rect is inside the body region", function()
        local plan = layout.compute(size.w, size.h)
        for _, zone in ipairs(plan.zones) do
            local r = zone.rect
            check(r.x >= 1, zone.name .. " x >= 1")
            check(r.y >= 2, zone.name .. " y >= 2 (below the header)")
            check(r.w >= 1, zone.name .. " w >= 1")
            check(r.h >= 1, zone.name .. " h >= 1")
            check(r.x + r.w - 1 <= size.w, zone.name .. " fits horizontally")
            check(r.y + r.h - 1 <= size.h - 1, zone.name .. " stays above the footer")
        end
    end)

    test(size.name .. ": no two zones overlap", function()
        local plan = layout.compute(size.w, size.h)
        for i = 1, #plan.zones do
            for j = i + 1, #plan.zones do
                check(not overlaps(plan.zones[i].rect, plan.zones[j].rect),
                    plan.zones[i].name .. " overlaps " .. plan.zones[j].name)
            end
        end
    end)

    test(size.name .. ": no zone is listed both visible and hidden", function()
        local plan = layout.compute(size.w, size.h)
        for _, name in ipairs(plan.hidden) do
            check(byName(plan, name) == nil, name .. " is both visible and hidden")
        end
    end)

    test(size.name .. ": every known zone is either placed or hidden", function()
        local plan = layout.compute(size.w, size.h)
        for _, name in ipairs(layout.PRIORITY) do
            local placed = byName(plan, name) ~= nil
            local hidden = false
            for _, hiddenName in ipairs(plan.hidden) do
                if hiddenName == name then hidden = true end
            end
            check(placed or hidden, name .. " is unaccounted for")
        end
    end)
end

-- ---------------------------------------------------------------------------
-- The design target
-- ---------------------------------------------------------------------------

test("the 4x3 wall shows all four zones", function()
    local plan = layout.compute(79, 38)
    equal(#plan.zones, 4, "zone count")
    equal(#plan.hidden, 0, "hidden count")
    equal(plan.message, nil, "no too-small message")
    for _, zone in ipairs(plan.zones) do
        equal(zone.degraded, false, zone.name .. " degraded")
    end
end)

test("the wall places attitude and power side by side", function()
    local plan = layout.compute(79, 38)
    local attitude = byName(plan, "ATTITUDE")
    local power = byName(plan, "POWER")
    equal(attitude.rect.y, power.rect.y, "same top edge")
    check(attitude.rect.x < power.rect.x, "attitude sits left of power")
    equal(attitude.rect.w + power.rect.w, 79, "the pair spans the full width")
end)

test("engines and pods span the full width and sit below the top band", function()
    local plan = layout.compute(79, 38)
    local engines = byName(plan, "ENGINES")
    local pods = byName(plan, "PODS")
    local attitude = byName(plan, "ATTITUDE")
    equal(engines.rect.x, 1, "engines x")
    equal(engines.rect.w, 79, "engines width")
    equal(pods.rect.w, 79, "pods width")
    check(engines.rect.y > attitude.rect.y, "engines below the top band")
    check(pods.rect.y > engines.rect.y, "pods below engines")
end)

test("the body exactly fills the space between header and footer", function()
    local plan = layout.compute(79, 38)
    local lowest = 0
    for _, zone in ipairs(plan.zones) do
        lowest = math.max(lowest, zone.rect.y + zone.rect.h - 1)
    end
    equal(plan.header.y, 1, "header row")
    equal(plan.footer.y, 38, "footer row")
    equal(lowest, 37, "body reaches the row above the footer")
end)

-- ---------------------------------------------------------------------------
-- Degradation
-- ---------------------------------------------------------------------------

test("a narrow screen stacks attitude and power instead of pairing them", function()
    -- 60 is below SIDE_BY_SIDE_WIDTH but tall enough to keep both.
    local plan = layout.compute(60, 44)
    local attitude = byName(plan, "ATTITUDE")
    local power = byName(plan, "POWER")
    check(attitude and power, "both zones present at 60x44")
    if attitude and power then
        check(attitude.rect.y ~= power.rect.y, "stacked, not side by side")
        equal(attitude.rect.w, 60, "attitude spans full width when stacked")
        equal(power.rect.w, 60, "power spans full width when stacked")
    end
end)

test("the terminal keeps the highest-priority zones and hides the rest", function()
    local plan = layout.compute(51, 19)
    check(byName(plan, "ENGINES") ~= nil, "engines survives")
    check(byName(plan, "PODS") ~= nil, "pods survives")
    check(#plan.hidden > 0, "something was hidden")
    equal(plan.message, nil, "not a too-small screen")
end)

test("zones are dropped in reverse priority order", function()
    -- Tall enough for engines + pods only.
    local plan = layout.compute(79, 20)
    for _, name in ipairs(plan.hidden) do
        check(name == "POWER" or name == "ATTITUDE",
            "engines and pods must never be the first dropped, got " .. name)
    end
end)

test("a tiny screen keeps only what fits and hides the rest", function()
    -- 29 columns cannot hold engines (48) or pods (38), but attitude (28) fits.
    -- Dropping whole zones is the point: one readable zone beats four garbled.
    local plan = layout.compute(29, 12)
    check(byName(plan, "ENGINES") == nil, "engines cannot fit 29 columns")
    check(byName(plan, "PODS") == nil, "pods cannot fit 29 columns")
    check(#plan.zones >= 1, "something still renders")
    check(#plan.hidden >= 2, "the zones that cannot fit are listed as hidden")
    equal(plan.message, nil, "not a too-small screen -- something rendered")
end)

test("a screen too small for anything reports a message and places nothing", function()
    local plan = layout.compute(20, 6)
    equal(#plan.zones, 0, "zone count")
    check(type(plan.message) == "string", "message is a string")
    check(plan.message:find("20") ~= nil, "message names the actual width")
end)

test("a degenerate screen does not throw", function()
    local plan = layout.compute(5, 3)
    equal(#plan.zones, 0, "zone count")
    check(type(plan.message) == "string", "message present")
end)

test("a placed zone is never below its minimum -- layout drops, it never shrinks", function()
    -- The packing rule is drop-whole, never shrink: a zone that cannot fit at
    -- its minimum is hidden instead of squeezed. Sweeping the size space is the
    -- only way to assert that, and it is what catches a future tuning of
    -- SIDE_BY_SIDE_WIDTH or the attitude share silently breaking it.
    local placed, offenders = 0, 0
    for width = 10, 140, 3 do
        for height = 4, 60, 3 do
            local plan = layout.compute(width, height)
            for _, zone in ipairs(plan.zones) do
                placed = placed + 1
                local minimum = layout.MINIMUMS[zone.name]
                if zone.rect.w < minimum.w or zone.rect.h < minimum.h
                    or zone.degraded then
                    offenders = offenders + 1
                end
            end
        end
    end
    check(placed > 1000, "the sweep actually placed zones (got " .. placed .. ")")
    equal(offenders, 0, "placed zones below minimum, or flagged degraded")
end)

test("compute is deterministic", function()
    local first = layout.compute(79, 38)
    local second = layout.compute(79, 38)
    equal(#first.zones, #second.zones, "zone count")
    for i = 1, #first.zones do
        equal(first.zones[i].name, second.zones[i].name, "zone " .. i .. " name")
        equal(first.zones[i].rect.x, second.zones[i].rect.x, "zone " .. i .. " x")
        equal(first.zones[i].rect.y, second.zones[i].rect.y, "zone " .. i .. " y")
        equal(first.zones[i].rect.w, second.zones[i].rect.w, "zone " .. i .. " w")
        equal(first.zones[i].rect.h, second.zones[i].rect.h, "zone " .. i .. " h")
    end
end)

-- ---------------------------------------------------------------------------

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
