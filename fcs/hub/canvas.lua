-- A double-buffered character grid over a term-like target.
--
-- Why buffer at all: the 4x3 wall is roughly 3000 cells, and repainting all of
-- it four times a second both flickers and burns server tick. Draw into a back
-- buffer, compare against what the screen already shows, and emit only the
-- runs that changed -- a typical frame changes a few hundred cells.
--
-- Deliberately knows nothing about telemetry, and touches no ComputerCraft
-- global, so it runs under plain luajit in tools/test_hub_canvas.lua.

local theme = require("fcs.hub.theme")

local canvas = {}

local Canvas = {}
Canvas.__index = Canvas

local HEX = "0123456789abcdef"

-- Colour numbers are powers of two; blit wants the exponent as a hex digit.
local HEX_OF = {}
do
    local value = 1
    for i = 0, 15 do
        HEX_OF[value] = HEX:sub(i + 1, i + 1)
        value = value * 2
    end
end

local WHITE_HEX = HEX_OF[theme.colours.white]
local BLACK_HEX = HEX_OF[theme.colours.black]

local function hexOf(colour, fallback)
    return HEX_OF[colour] or fallback
end

function canvas.new(target)
    local self = setmetatable({}, Canvas)
    self.target = target
    self.dim = false
    -- Monochrome monitors accept only white on black; asking for anything else
    -- is not an error, it just silently renders wrong.
    local isColour = target.isColour or target.isColor
    self.colour = isColour and isColour() or false
    self:resize()
    return self
end

local function blankRow(width)
    local row = { char = {}, fg = {}, bg = {} }
    for x = 1, width do
        row.char[x] = " "
        row.fg[x] = WHITE_HEX
        row.bg[x] = BLACK_HEX
    end
    return row
end

function Canvas:resize()
    local width, height = self.target.getSize()
    self.width, self.height = width, height
    self.back = {}
    self.front = {}
    for y = 1, height do
        self.back[y] = blankRow(width)
        self.front[y] = blankRow(width)
    end
    self:invalidate()
    return width, height
end

-- Poison the front buffer so every cell compares unequal on the next flush.
function Canvas:invalidate()
    for y = 1, self.height do
        local row = self.front[y]
        for x = 1, self.width do
            row.char[x] = "\0"
        end
    end
end

function Canvas:setDim(flag)
    self.dim = flag and true or false
end

function Canvas:isDim()
    return self.dim
end

function Canvas:resolveForeground(colour)
    if not self.colour then
        return WHITE_HEX
    end
    if self.dim then
        colour = theme.dim(colour)
    end
    return hexOf(colour, WHITE_HEX)
end

function Canvas:resolveBackground(colour)
    if not self.colour then
        return BLACK_HEX
    end
    return hexOf(colour, BLACK_HEX)
end

function Canvas:clear(bg)
    local fgHex = self:resolveForeground(theme.foreground)
    local bgHex = self:resolveBackground(bg or theme.background)
    for y = 1, self.height do
        local row = self.back[y]
        for x = 1, self.width do
            row.char[x] = " "
            row.fg[x] = fgHex
            row.bg[x] = bgHex
        end
    end
end

-- Clipped single-cell write. Every other drawing method funnels through here,
-- so bounds checking lives in exactly one place.
function Canvas:set(x, y, char, fgHex, bgHex)
    if y < 1 or y > self.height or x < 1 or x > self.width then
        return
    end
    local row = self.back[y]
    row.char[x] = char
    row.fg[x] = fgHex
    row.bg[x] = bgHex
end

function Canvas:text(x, y, str, fg, bg)
    if type(str) ~= "string" then
        return
    end
    local fgHex = self:resolveForeground(fg or theme.foreground)
    local bgHex = self:resolveBackground(bg or theme.background)
    for i = 1, #str do
        self:set(x + i - 1, y, str:sub(i, i), fgHex, bgHex)
    end
end

function Canvas:fill(x, y, w, h, bg, char)
    char = char or " "
    local fgHex = self:resolveForeground(theme.foreground)
    local bgHex = self:resolveBackground(bg or theme.background)
    for dy = 0, h - 1 do
        for dx = 0, w - 1 do
            self:set(x + dx, y + dy, char, fgHex, bgHex)
        end
    end
end

-- A gauge drawn as coloured background cells rather than glyphs: it reads at a
-- glance on a wall and costs nothing extra to flush.
function Canvas:bar(x, y, w, fraction, bgFilled, bgEmpty)
    if type(fraction) ~= "number" or fraction ~= fraction then
        fraction = 0
    end
    if fraction < 0 then fraction = 0 end
    if fraction > 1 then fraction = 1 end
    w = math.max(0, math.floor(w))
    local filled = math.floor(w * fraction + 0.5)
    for i = 1, w do
        self:fill(x + i - 1, y, 1, 1, i <= filled and bgFilled or bgEmpty)
    end
end

-- Emit only what changed, coalescing adjacent changed cells into one blit.
-- Returns cells written and runs written, which is what the tests assert on
-- and what run.lua can log when a frame is unexpectedly expensive.
function Canvas:flush()
    local cells, runs = 0, 0
    for y = 1, self.height do
        local back, front = self.back[y], self.front[y]
        local x = 1
        while x <= self.width do
            if back.char[x] ~= front.char[x]
                or back.fg[x] ~= front.fg[x]
                or back.bg[x] ~= front.bg[x] then
                local startX = x
                local chars, fgs, bgs = {}, {}, {}
                while x <= self.width
                    and (back.char[x] ~= front.char[x]
                        or back.fg[x] ~= front.fg[x]
                        or back.bg[x] ~= front.bg[x]) do
                    local i = x - startX + 1
                    chars[i], fgs[i], bgs[i] = back.char[x], back.fg[x], back.bg[x]
                    front.char[x], front.fg[x], front.bg[x] =
                        back.char[x], back.fg[x], back.bg[x]
                    x = x + 1
                end
                self.target.setCursorPos(startX, y)
                self.target.blit(
                    table.concat(chars), table.concat(fgs), table.concat(bgs))
                cells = cells + #chars
                runs = runs + 1
            else
                x = x + 1
            end
        end
    end
    return cells, runs
end

return canvas
