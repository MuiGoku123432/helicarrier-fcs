-- Drawing primitives shared by the zone modules, one layer above canvas.
--
-- The formatting helpers matter more than the drawing ones. Telemetry fields
-- are nil constantly -- an offline pod reports nothing, a corner with no
-- bearing reports no thrust -- and string.format("%.1f", nil) throws. Every
-- number reaching the screen goes through widgets.number so that a missing
-- value renders as "--" in one place instead of four.

local theme = require("fcs.hub.theme")

local widgets = {}

widgets.CORNERS = { "FL", "FR", "RL", "RR" }

widgets.MISSING = "--"

local function isFinite(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

widgets.isFinite = isFinite

function widgets.number(value, format, fallback)
    if not isFinite(value) then
        return fallback or widgets.MISSING
    end
    return string.format(format or "%.2f", value)
end

function widgets.compact(value)
    if not isFinite(value) then
        return widgets.MISSING
    end
    local sign = value < 0 and "-" or ""
    local magnitude = math.abs(value)
    if magnitude >= 1000000 then
        return string.format("%s%.2fM", sign, magnitude / 1000000)
    elseif magnitude >= 1000 then
        return string.format("%s%.1fk", sign, magnitude / 1000)
    end
    return string.format("%s%d", sign, math.floor(magnitude + 0.5))
end

function widgets.duration(ms)
    if not isFinite(ms) then
        return widgets.MISSING
    end
    if ms < 1000 then
        return string.format("%dms", math.floor(ms + 0.5))
    end
    return string.format("%.1fs", ms / 1000)
end

function widgets.clip(text, width)
    if type(text) ~= "string" then
        return ""
    end
    if width == nil or #text <= width then
        return text
    end
    if width <= 0 then
        return ""
    end
    return text:sub(1, width)
end

-- A zone header: name on the left, an optional summary on the right, drawn as
-- an inverted bar so the eye can find zone boundaries on a wall without box
-- glyphs (CC's font has no reliable line-drawing characters).
-- background overrides the default bar colour. run.lua uses it to paint the
-- header by freshness, so a dead feed is a red band across the top of the wall
-- rather than a word someone has to be close enough to read.
function widgets.title(canvas, rect, text, rightText, background)
    local bar = background or theme.titleBackground
    canvas:fill(rect.x, rect.y, rect.w, 1, bar)
    canvas:text(rect.x + 1, rect.y,
        widgets.clip(text, rect.w - 2), theme.titleForeground, bar)

    if type(rightText) == "string" and rightText ~= "" then
        local clipped = widgets.clip(rightText, math.max(0, rect.w - #text - 4))
        if #clipped > 0 then
            canvas:text(rect.x + rect.w - #clipped - 1, rect.y,
                clipped, theme.titleForeground, bar)
        end
    end
end

-- What a zone draws when its rect is below its minimum: the name and the size
-- it wants. Never a partial render -- a half-drawn engine strip is worse than
-- an absent one, because it looks like data.
function widgets.degraded(canvas, rect, name, minimum)
    canvas:fill(rect.x, rect.y, rect.w, rect.h, theme.background)
    canvas:text(rect.x, rect.y,
        widgets.clip(name, rect.w), theme.status("warn"), theme.background)
    if rect.h >= 2 then
        canvas:text(rect.x, rect.y + 1,
            widgets.clip(string.format("needs %dx%d", minimum.w, minimum.h), rect.w),
            theme.label, theme.background)
    end
end

-- Column geometry for the four-corner zones. Returns the x of each column and
-- the width each one may use.
function widgets.columns(rect, labelWidth, count)
    -- Ensure there's room for at least columnWidth=1 for each column.
    -- The constraint is: labelWidth + count * columnWidth <= rect.w
    -- With columnWidth >= 1, this means labelWidth <= rect.w - count
    if labelWidth > rect.w - count then
        labelWidth = math.max(1, rect.w - count)
    end

    local available = rect.w - labelWidth
    local columnWidth = math.floor(available / count)
    if columnWidth < 1 then
        columnWidth = 1
    end

    local xs = {}
    for i = 1, count do
        xs[i] = rect.x + labelWidth + (i - 1) * columnWidth
    end
    return xs, columnWidth
end

-- One labelled row of per-column values. cells is an array of {text=, colour=};
-- a nil entry leaves its column blank rather than shifting the others.
function widgets.row(canvas, rect, y, label, cells, labelWidth)
    if y < rect.y or y > rect.y + rect.h - 1 then
        return
    end

    canvas:text(rect.x, y,
        widgets.clip(label, math.min(labelWidth - 1, rect.w)), theme.label, theme.background)

    local count = #widgets.CORNERS
    local xs, columnWidth = widgets.columns(rect, labelWidth, count)
    for i = 1, count do
        local cell = cells[i]
        if cell and type(cell.text) == "string" then
            canvas:text(xs[i], y,
                widgets.clip(cell.text, columnWidth - 1),
                cell.colour or theme.foreground, theme.background)
        end
    end
end

return widgets
