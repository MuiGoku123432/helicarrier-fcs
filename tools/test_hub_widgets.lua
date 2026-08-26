-- Offline tests for fcs/hub/widgets.lua.
--
--     luajit tools/test_hub_widgets.lua      (from the repo root)

package.path = "./?.lua;" .. package.path

local canvas = require("fcs.hub.canvas")
local widgets = require("fcs.hub.widgets")
local theme = require("fcs.hub.theme")
local fixtures = require("tools.hub_fixtures")

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

local function surfaceOf(w, h)
    local target = fixtures.target(w, h)
    local surface = canvas.new(target)
    surface:clear(theme.background)
    return surface, target
end

-- ---------------------------------------------------------------------------
-- Nil-safe formatting. Telemetry fields are nil constantly: a pod that is
-- offline reports nothing, and a corner with no bearing reports no thrust.
-- ---------------------------------------------------------------------------

test("number formats a value", function()
    equal(widgets.number(12.345, "%.2f"), "12.35", "formatted")
end)

test("number falls back for nil", function()
    equal(widgets.number(nil, "%.2f"), "--", "nil")
    equal(widgets.number(nil, "%.2f", "n/a"), "n/a", "custom fallback")
end)

test("number falls back for NaN and infinity", function()
    equal(widgets.number(0 / 0, "%.2f"), "--", "NaN")
    equal(widgets.number(1 / 0, "%.2f"), "--", "infinity")
    equal(widgets.number(-1 / 0, "%.2f"), "--", "negative infinity")
end)

test("number falls back for a non-number", function()
    equal(widgets.number("64", "%.1f"), "--", "string")
    equal(widgets.number(true, "%.1f"), "--", "boolean")
    equal(widgets.number({}, "%.1f"), "--", "table")
end)

test("compact scales large values", function()
    equal(widgets.compact(412), "412", "hundreds")
    equal(widgets.compact(18400), "18.4k", "thousands")
    equal(widgets.compact(1240000), "1.24M", "millions")
    equal(widgets.compact(nil), "--", "nil")
end)

test("compact handles negatives and zero", function()
    equal(widgets.compact(0), "0", "zero")
    equal(widgets.compact(-18400), "-18.4k", "negative thousands")
end)

test("duration reads in the unit that fits", function()
    equal(widgets.duration(120), "120ms", "milliseconds")
    equal(widgets.duration(6200), "6.2s", "seconds")
    equal(widgets.duration(nil), "--", "nil")
end)

test("clip truncates rather than overflowing", function()
    equal(widgets.clip("ABCDEFGH", 4), "ABCD", "truncated")
    equal(widgets.clip("AB", 4), "AB", "short text untouched")
    equal(widgets.clip(nil, 4), "", "nil")
end)

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------

test("title draws on the first row of the rect", function()
    local surface, target = surfaceOf(40, 6)
    widgets.title(surface, { x = 1, y = 2, w = 40, h = 5 }, "ENGINES")
    surface:flush()
    check(target.rowText(2):find("ENGINES") ~= nil, "title text present")
    equal(target.rowText(1):find("ENGINES"), nil, "nothing drawn above the rect")
end)

test("title right-aligns its second string", function()
    local surface, target = surfaceOf(40, 6)
    widgets.title(surface, { x = 1, y = 1, w = 40, h = 5 }, "PODS", "4 UP")
    surface:flush()
    local row = target.rowText(1)
    check(row:find("PODS") ~= nil, "left text")
    check(row:find("4 UP") ~= nil, "right text")
    check(row:find("4 UP") > row:find("PODS"), "right text is to the right")
end)

test("title honours a background override", function()
    local surface, target = surfaceOf(40, 4)
    widgets.title(surface, { x = 1, y = 1, w = 40, h = 3 }, "FCS-DEV", "LIVE",
        theme.colours.red)
    surface:flush()
    equal(target.cells[1][1].bg, "e", "header bar painted red")
end)

test("title never writes outside the rect", function()
    local surface, target = surfaceOf(20, 4)
    widgets.title(surface, { x = 5, y = 2, w = 10, h = 2 },
        "AVERYLONGTITLETHATOVERFLOWS", "ALSOLONG")
    surface:flush()
    equal(target.rowText(2):sub(1, 4), "    ", "left of the rect untouched")
    equal(target.rowText(2):sub(15, 20), "      ", "right of the rect untouched")
end)

test("degraded states the zone and the size it needs", function()
    local surface, target = surfaceOf(30, 6)
    widgets.degraded(surface, { x = 1, y = 1, w = 30, h = 4 },
        "ENGINES", { w = 48, h = 9 })
    surface:flush()
    local joined = table.concat(target.rows(), "\n")
    check(joined:find("ENGINES") ~= nil, "zone name")
    check(joined:find("48") ~= nil, "needed width")
    check(joined:find("9") ~= nil, "needed height")
end)

test("degraded fits inside a one-row rect without throwing", function()
    local surface = surfaceOf(30, 3)
    widgets.degraded(surface, { x = 1, y = 1, w = 30, h = 1 },
        "POWER", { w = 22, h = 6 })
    surface:flush()
    ok()
end)

test("columns divide the rect evenly after the label gutter", function()
    local xs, columnWidth = widgets.columns({ x = 1, y = 1, w = 79, h = 10 }, 15, 4)
    equal(#xs, 4, "column count")
    equal(xs[1], 16, "first column starts after the label gutter")
    check(columnWidth >= 15, "columns are wide enough to be useful")
    check(xs[4] + columnWidth - 1 <= 79, "last column stays inside the rect")
    for i = 2, 4 do
        equal(xs[i] - xs[i - 1], columnWidth, "even spacing at column " .. i)
    end
end)

test("columns degrade rather than going negative on a narrow rect", function()
    local xs, columnWidth = widgets.columns({ x = 1, y = 1, w = 20, h = 4 }, 15, 4)
    equal(#xs, 4, "column count")
    check(columnWidth >= 1, "column width stays positive")
end)

test("row draws a label and one cell per column", function()
    local surface, target = surfaceOf(60, 5)
    local rect = { x = 1, y = 1, w = 60, h = 5 }
    widgets.row(surface, rect, 2, "target rpm", {
        { text = "64" }, { text = "64" }, { text = "64" }, { text = "64" },
    }, 14)
    surface:flush()
    local row = target.rowText(2)
    check(row:find("target rpm") ~= nil, "label present")
    local count = 0
    for _ in row:gmatch("64") do count = count + 1 end
    equal(count, 4, "one value per corner")
end)

test("row clips cell text to the column width", function()
    local surface, target = surfaceOf(40, 4)
    local rect = { x = 1, y = 1, w = 40, h = 4 }
    widgets.row(surface, rect, 1, "label", {
        { text = "AAAAAAAAAAAAAAAAAAAA" }, { text = "B" },
        { text = "C" }, { text = "D" },
    }, 10)
    surface:flush()
    equal(#target.rowText(1), 40, "row length unchanged")
    check(target.rowText(1):find("B") ~= nil, "later columns are not overwritten")
end)

test("row tolerates missing cells", function()
    local surface = surfaceOf(60, 4)
    widgets.row(surface, { x = 1, y = 1, w = 60, h = 4 }, 1, "label",
        { { text = "1" }, nil, { text = "3" } }, 12)
    surface:flush()
    ok()
end)

test("row outside the rect is dropped", function()
    local surface, target = surfaceOf(40, 6)
    widgets.row(surface, { x = 1, y = 2, w = 40, h = 2 }, 9, "label",
        { { text = "X" } }, 10)
    surface:flush()
    for y = 1, 6 do
        equal(target.rowText(y):find("label"), nil, "nothing drawn at row " .. y)
    end
end)

-- Regression test: columns never place a cell outside the rect, even when clamped
test("columns never place a cell outside the rect, even when clamped", function()
    -- available = 2 for 4 columns: this is the input that trips the
    -- columnWidth < 1 clamp, which no existing test reaches.
    local rect = { x = 1, y = 1, w = 17, h = 1 }
    local xs, columnWidth = widgets.columns(rect, 15, 4)
    equal(#xs, 4, "column count")
    check(columnWidth >= 1, "column width stays positive")
    check(xs[4] + columnWidth - 1 <= rect.x + rect.w - 1,
        "last column ends inside the rect")
    for i = 1, 4 do
        check(xs[i] >= rect.x, "column " .. i .. " starts inside the rect")
    end
end)

-- Regression test: row at degenerate geometry with constrained label
test("row handles degenerate geometry with constrained label", function()
    local surface, target = surfaceOf(20, 3)
    local rect = { x = 2, y = 2, w = 17, h = 1 }
    widgets.row(surface, rect, 2, "RPM", {
        { text = "X" }, { text = "X" }, { text = "X" }, { text = "X" },
    }, 14)
    surface:flush()
    equal(#target.rowText(2), 20, "row length unchanged")
    -- Cells outside the rect (x=1 and x=20) should be untouched
    check(target.rowText(2):sub(1, 1) == " ", "cell left of rect is untouched")
    check(target.rowText(2):sub(20, 20) == " ", "cell right of rect is untouched")
    -- Cells inside the rect should have content
    local inside = target.rowText(2):sub(2, 18)
    check(inside:find("RPM") ~= nil or inside:find("X") ~= nil, "content drawn inside rect")
end)

-- ---------------------------------------------------------------------------

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
