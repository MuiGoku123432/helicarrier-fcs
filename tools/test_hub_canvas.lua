-- Offline tests for fcs/hub/canvas.lua.
--
--     luajit tools/test_hub_canvas.lua      (from the repo root)

package.path = "./?.lua;" .. package.path

local canvas = require("fcs.hub.canvas")
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

local WHITE, BLACK = theme.colours.white, theme.colours.black
local RED, GREEN = theme.colours.red, theme.colours.green

-- ---------------------------------------------------------------------------

test("reports the target size", function()
    local surface = canvas.new(fixtures.target(20, 5))
    equal(surface.width, 20, "width")
    equal(surface.height, 5, "height")
end)

test("writes text into the buffer and flushes it to the target", function()
    local target = fixtures.target(20, 3)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:text(3, 2, "HELLO", WHITE, BLACK)
    surface:flush()
    equal(target.rowText(2):sub(3, 7), "HELLO", "row 2")
end)

test("clips writes that run past the right edge", function()
    local target = fixtures.target(10, 2)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:text(8, 1, "ABCDEFG", WHITE, BLACK)
    surface:flush()
    equal(target.rowText(1), "       ABC", "clipped row")
end)

test("clips writes that start off-screen to the left", function()
    local target = fixtures.target(10, 2)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:text(-2, 1, "ABCDEFG", WHITE, BLACK)
    surface:flush()
    equal(target.rowText(1), "DEFG      ", "left-clipped row")
end)

test("drops writes entirely outside the surface", function()
    local target = fixtures.target(10, 2)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:text(1, 9, "NOPE", WHITE, BLACK)
    surface:text(1, -1, "NOPE", WHITE, BLACK)
    surface:flush()
    equal(target.rowText(1), "          ", "row 1 untouched")
end)

test("a second identical frame writes nothing", function()
    local target = fixtures.target(30, 4)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:text(1, 1, "STATIC", WHITE, BLACK)
    surface:flush()
    target.reset()

    surface:clear(BLACK)
    surface:text(1, 1, "STATIC", WHITE, BLACK)
    local cells = surface:flush()
    equal(cells, 0, "cells written on unchanged frame")
    equal(#target.calls, 0, "blit calls on unchanged frame")
end)

test("only the changed cells are written", function()
    local target = fixtures.target(40, 3)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:text(1, 1, "value: 100", WHITE, BLACK)
    surface:flush()
    target.reset()

    surface:clear(BLACK)
    surface:text(1, 1, "value: 200", WHITE, BLACK)
    local cells = surface:flush()
    equal(cells, 1, "only the changed digit is written")
    equal(target.calls[1].text, "2", "written character")
    equal(target.calls[1].x, 8, "written column")
end)

test("adjacent changed cells coalesce into one blit", function()
    local target = fixtures.target(40, 3)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:text(1, 1, "AAAA", WHITE, BLACK)
    surface:flush()
    target.reset()

    surface:clear(BLACK)
    surface:text(1, 1, "BBBB", WHITE, BLACK)
    local cells, runs = surface:flush()
    equal(cells, 4, "cells written")
    equal(runs, 1, "runs written")
end)

test("a colour-only change is still a change", function()
    local target = fixtures.target(20, 2)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:text(1, 1, "OK", GREEN, BLACK)
    surface:flush()
    target.reset()

    surface:clear(BLACK)
    surface:text(1, 1, "OK", RED, BLACK)
    local cells = surface:flush()
    equal(cells, 2, "cells written on colour change")
end)

test("invalidate forces a full repaint", function()
    local target = fixtures.target(20, 2)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:text(1, 1, "HI", WHITE, BLACK)
    surface:flush()
    target.reset()

    surface:invalidate()
    surface:clear(BLACK)
    surface:text(1, 1, "HI", WHITE, BLACK)
    local cells = surface:flush()
    equal(cells, 40, "every cell repainted")
end)

test("resize rebuilds the buffers and forces a full repaint", function()
    local target = fixtures.target(20, 2)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:flush()

    target.resizeTo(30, 4)

    local w, h = surface:resize()
    equal(w, 30, "new width")
    equal(h, 4, "new height")
    surface:clear(BLACK)
    local cells = surface:flush()
    equal(cells, 120, "every cell of the new size repainted")
end)

test("dim mode rewrites foreground colours through the theme", function()
    local target = fixtures.target(10, 2)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:setDim(true)
    -- lime, not green: theme.dim maps lime -> green, whereas green is already
    -- its own dim form, so asserting on green would prove nothing.
    surface:text(1, 1, "X", theme.colours.lime, BLACK)
    surface:flush()
    equal(target.cells[1][1].fg, "d", "lime must dim to green")
    equal(surface:isDim(), true, "dim flag")
end)

test("dim mode is off by default", function()
    local target = fixtures.target(10, 2)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:text(1, 1, "X", theme.colours.lime, BLACK)
    surface:flush()
    equal(target.cells[1][1].fg, "5", "lime renders as lime when not dimmed")
    equal(surface:isDim(), false, "dim flag defaults to false")
end)

test("a monochrome target receives only white on black", function()
    local target = fixtures.target(12, 2, false)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:text(1, 1, "RED", RED, GREEN)
    surface:flush()
    equal(target.cells[1][1].fg, "0", "foreground forced to white")
    equal(target.cells[1][1].bg, "f", "background forced to black")
end)

test("bar fills the correct number of cells", function()
    local target = fixtures.target(20, 2)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:bar(1, 1, 10, 0.5, GREEN, theme.colours.gray)
    surface:flush()
    local filled = 0
    for x = 1, 10 do
        if target.cells[1][x].bg ~= "7" then filled = filled + 1 end
    end
    equal(filled, 5, "filled cells at 50%")
end)

test("bar clamps fractions outside 0..1 instead of overflowing", function()
    local target = fixtures.target(20, 2)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:bar(1, 1, 8, 5.0, GREEN, theme.colours.gray)
    surface:bar(1, 2, 8, -3.0, GREEN, theme.colours.gray)
    surface:flush()
    equal(#target.rowText(1), 20, "row 1 length unchanged")
    equal(#target.rowText(2), 20, "row 2 length unchanged")
end)

test("a nil or non-string text write is ignored rather than thrown", function()
    local target = fixtures.target(10, 2)
    local surface = canvas.new(target)
    surface:clear(BLACK)
    surface:text(1, 1, nil, WHITE, BLACK)
    surface:text(1, 1, 42, WHITE, BLACK)
    surface:flush()
    ok()
end)

-- ---------------------------------------------------------------------------

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
