-- The four-corner engine strip.
--
-- Why per-bearing rows rather than a corner total: getThrust is signed by
-- HANDEDNESS, not by world direction, so a counter-rotating pair reports +x
-- and -x while pushing the same way. The corner aggregate therefore sums
-- MAGNITUDES -- which means it cannot show one bearing of a pair
-- underperforming its twin. That asymmetry is exactly what this craft has a
-- history of hiding, so b1, b2 and their delta get their own rows.

local theme = require("fcs.hub.theme")
local widgets = require("fcs.hub.widgets")

local engines = {}

engines.name = "ENGINES"

local LABEL_WIDTH = 14

-- Thresholds in percent. 1.12% was the real deficit on this craft; a scale
-- that graded that as "warn" would have let it keep hiding.
engines.DELTA_WARN = 0.25
engines.DELTA_BAD = 1.0

-- Magnitudes, deliberately. See the header comment.
function engines.deltaPercent(bearings)
    if type(bearings) ~= "table" then
        return nil
    end
    local first = (bearings[1] or {}).thrust
    local second = (bearings[2] or {}).thrust
    if not widgets.isFinite(first) or not widgets.isFinite(second) then
        return nil
    end
    local a, b = math.abs(first), math.abs(second)
    local largest = math.max(a, b)
    if largest == 0 then
        -- A stopped pair has no meaningful ratio; 0/0 is not "balanced".
        return nil
    end
    return (a - b) / largest * 100
end

function engines.deltaLevel(delta)
    if not widgets.isFinite(delta) then
        return "idle"
    end
    local magnitude = math.abs(delta)
    if magnitude < engines.DELTA_WARN then
        return "ok"
    elseif magnitude < engines.DELTA_BAD then
        return "warn"
    end
    return "bad"
end

local function flagsFor(corner)
    local flags = {}
    local level = "ok"
    if corner.controllerPresent == false then
        flags[#flags + 1] = "!C"
        level = "bad"
    end
    if corner.bearingPresent == false then
        flags[#flags + 1] = "!B"
        level = "bad"
    end
    if corner.overstressed then
        flags[#flags + 1] = "OS"
        level = "bad"
    end
    if corner.hasSource == false then
        flags[#flags + 1] = "!S"
        if level ~= "bad" then level = "warn" end
    end
    if corner.active then
        flags[#flags + 1] = "A"
    elseif corner.active == false then
        flags[#flags + 1] = "--"
        if level == "ok" then level = "idle" end
    end
    return table.concat(flags, " "), level
end

local function cellsFor(frame, build)
    local cells = {}
    for index, corner in ipairs(widgets.CORNERS) do
        cells[index] = build((frame.corners or {})[corner] or {}, corner)
    end
    return cells
end

function engines.draw(canvas, rect, frame)
    frame = frame or {}

    -- Worst delta across the corners, so the title carries the headline even
    -- when someone only glances at the zone header.
    local worst, worstCorner = nil, nil
    for _, corner in ipairs(widgets.CORNERS) do
        local delta = engines.deltaPercent(((frame.corners or {})[corner] or {}).bearings)
        if delta and (not worst or math.abs(delta) > math.abs(worst)) then
            worst, worstCorner = delta, corner
        end
    end
    local headline = worst
        and string.format("max d %s %+.2f%%", worstCorner, worst)
        or "max d --"
    widgets.title(canvas, rect, "ENGINES", headline)

    local rows = {
        {
            label = "",
            build = function(_, corner)
                return { text = corner, colour = theme.foreground }
            end,
        },
        {
            label = "target rpm",
            build = function(corner)
                return { text = widgets.number(corner.targetRpm, "%.0f") }
            end,
        },
        {
            label = "actual rpm",
            build = function(corner)
                return { text = widgets.number(corner.controllerRpm, "%.1f") }
            end,
        },
        {
            label = "thrust",
            build = function(corner)
                return { text = widgets.compact(corner.thrust) }
            end,
        },
        -- Full resolution, NOT widgets.compact: the deficit under
        -- investigation is ~1%, and 13960.98 vs 13804.41 both compact to
        -- "14.0k". Rounding here would erase the one number this zone exists
        -- to show.
        {
            label = "b1 thrust",
            build = function(corner)
                return { text = widgets.number(
                    ((corner.bearings or {})[1] or {}).thrust, "%.0f") }
            end,
        },
        {
            label = "b2 thrust",
            build = function(corner)
                return { text = widgets.number(
                    ((corner.bearings or {})[2] or {}).thrust, "%.0f") }
            end,
        },
        {
            label = "b1-b2 delta",
            build = function(corner)
                local delta = engines.deltaPercent(corner.bearings)
                return {
                    text = delta and string.format("%+.2f%%", delta) or widgets.MISSING,
                    colour = theme.status(engines.deltaLevel(delta)),
                }
            end,
        },
        {
            label = "tilt deg",
            build = function(corner)
                return { text = widgets.number(corner.tilt, "%+.1f") }
            end,
        },
        {
            label = "flags",
            build = function(corner)
                local flags, level = flagsFor(corner)
                return { text = flags, colour = theme.status(level) }
            end,
        },
    }

    for index, row in ipairs(rows) do
        widgets.row(canvas, rect, rect.y + index, row.label,
            cellsFor(frame, row.build), LABEL_WIDTH)
    end
end

return engines
