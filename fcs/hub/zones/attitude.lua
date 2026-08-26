-- Attitude and motion: is the craft level, and is it going anywhere.
--
-- The ladders exist because a number alone does not read at a glance from
-- across a room, and roll in particular is the number this craft has a history
-- of quietly sitting off-centre on.

local theme = require("fcs.hub.theme")
local widgets = require("fcs.hub.widgets")

local attitude = {}

attitude.name = "ATTITUDE"

local LABEL_WIDTH = 7
local LADDER_RANGE = 10

-- Roll and pitch are in degrees and should sit near zero. These thresholds are
-- deliberately tight: the standing offset this craft has carried was 1.23 deg,
-- and a scale that called that "fine" would have hidden it.
local function attitudeLevel(value)
    if not widgets.isFinite(value) then
        return "idle"
    end
    local magnitude = math.abs(value)
    if magnitude < 0.5 then
        return "ok"
    elseif magnitude < 2.0 then
        return "warn"
    end
    return "bad"
end

-- A horizontal scale with a marker. Clamped hard: a roll of 720 must pin the
-- marker to the edge, not write past the rect.
local function ladder(canvas, x, y, width, value, colour)
    if width < 5 then
        return
    end
    local track = string.rep("-", width)
    canvas:text(x, y, track, theme.rule, theme.background)
    canvas:text(x + math.floor((width - 1) / 2), y, "+", theme.label, theme.background)

    if not widgets.isFinite(value) then
        return
    end
    local fraction = (value + LADDER_RANGE) / (2 * LADDER_RANGE)
    if fraction < 0 then fraction = 0 end
    if fraction > 1 then fraction = 1 end
    local offset = math.floor(fraction * (width - 1) + 0.5)
    canvas:text(x + offset, y, "^", colour, theme.background)
end

-- The blank line between the ladder rows and the vector rows sits after this
-- many content rows. It is spacing, not data, so it collapses before any real
-- row is dropped.
local SPACER_AFTER = 3

-- widgets.title clips the right-hand text to rect.w - #title - 4, so a narrow
-- rect cannot carry both the altitude and the hidden-row note. The note wins,
-- and the zone name shortens before the note is given up: a row dropped
-- without saying so is exactly the defect this budget exists to fix.
local function titleTexts(rect, altText, hiddenRows)
    local long, short = "ATTITUDE / MOTION", "ATTITUDE"
    if hiddenRows <= 0 then
        return long, altText
    end

    local note = string.format("%d hidden", hiddenRows)
    local both = altText .. "  " .. note
    local candidates = { long, short }
    for _, title in ipairs(candidates) do
        if #both <= math.max(0, rect.w - #title - 4) then
            return title, both
        end
    end
    for _, title in ipairs(candidates) do
        if #note <= math.max(0, rect.w - #title - 4) then
            return title, note
        end
    end
    return short, note
end

function attitude.draw(canvas, rect, frame)
    frame = frame or {}
    local craft = frame.craft or {}
    local position = craft.position or {}
    local altitude = position.y

    -- Room for the label, the numeric value, and a ladder between them.
    local valueWidth = 9
    local ladderX = rect.x + LABEL_WIDTH
    local ladderWidth = rect.w - LABEL_WIDTH - valueWidth - 1

    local function drawAxis(y, label, value, useLadder, format)
        local level = useLadder and attitudeLevel(value) or "idle"
        local colour = useLadder and theme.status(level) or theme.foreground
        canvas:text(rect.x, y, label, theme.label, theme.background)
        if useLadder and ladderWidth >= 5 then
            ladder(canvas, ladderX, y, ladderWidth, value, colour)
        end
        -- One column short of the right edge: on the wall this zone sits
        -- directly against POWER, and a value flush to the edge reads as
        -- part of the neighbour.
        local text = widgets.number(value, format or "%+.2f")
        canvas:text(rect.x + rect.w - #text - 1, y, text, colour, theme.background)
    end

    local function drawVector(y, label, value)
        canvas:text(rect.x, y, label, theme.label, theme.background)
        value = value or {}
        local text = string.format("x %s  y %s  z %s",
            widgets.number(value.x, "%+.3f"),
            widgets.number(value.y, "%+.3f"),
            widgets.number(value.z, "%+.3f"))
        canvas:text(rect.x + LABEL_WIDTH + 1, y,
            widgets.clip(text, rect.w - LABEL_WIDTH - 1),
            theme.foreground, theme.background)
    end

    local function drawMass(y)
        canvas:text(rect.x, y, "MASS", theme.label, theme.background)
        canvas:text(rect.x + LABEL_WIDTH + 1, y,
            widgets.compact(craft.mass), theme.foreground, theme.background)
        local air = "AIR " .. widgets.number(craft.airPressure, "%.2f")
        canvas:text(rect.x + rect.w - #air - 1, y, air, theme.foreground, theme.background)
    end

    local function drawPosition(y)
        canvas:text(rect.x, y, "XYZ", theme.label, theme.background)
        local text = string.format("%s  %s  %s",
            widgets.number(position.x, "%.1f"),
            widgets.number(position.y, "%.1f"),
            widgets.number(position.z, "%.1f"))
        canvas:text(rect.x + LABEL_WIDTH + 1, y,
            widgets.clip(text, rect.w - LABEL_WIDTH - 1),
            theme.foreground, theme.background)
    end

    -- Content rows, most important first: this is also the order they are
    -- dropped in from the end when the rect cannot hold them all. The three
    -- ladder rows are the reason the zone exists, so they go last.
    local rows = {
        function(y) drawAxis(y, "ROLL", craft.roll, true) end,
        function(y) drawAxis(y, "PITCH", craft.pitch, true) end,
        function(y) drawAxis(y, "YAW", craft.yaw, false, "%.1f") end,
        function(y) drawVector(y, "BODY V", craft.bodyVel) end,
        function(y) drawVector(y, "WORLD V", craft.worldVel) end,
        function(y) drawVector(y, "ANG V", craft.angVel) end,
        drawMass,
        drawPosition,
    }

    -- Budget computed from rect.h, never from a hardcoded height: reserve one
    -- row for the title, the rest is content.
    local maxContentRows = math.max(1, rect.h - 1)
    local shownRows = math.min(#rows, maxContentRows)
    local hiddenRows = #rows - shownRows
    -- The spacer is affordable only once every real row already has a line.
    local spacer = (maxContentRows > #rows) and 1 or 0

    local titleText, rightText = titleTexts(rect,
        "ALT " .. widgets.number(altitude, "%.1f"), hiddenRows)
    widgets.title(canvas, rect, titleText, rightText)

    local y = rect.y
    for index = 1, shownRows do
        if index == SPACER_AFTER + 1 then
            y = y + spacer
        end
        y = y + 1
        if y > rect.y + rect.h - 1 then
            break
        end
        rows[index](y)
    end
end

return attitude
