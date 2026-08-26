-- Pod link health and the fault list.
--
-- Pod freshness is tracked separately from frame freshness on purpose: a live
-- logger with a dead FL pod and a dead logger are different emergencies, and a
-- wall that renders them the same way is worse than no wall.

local theme = require("fcs.hub.theme")
local widgets = require("fcs.hub.widgets")

local pods = {}

pods.name = "PODS"

local LABEL_WIDTH = 12

-- Everything wrong right now, in one list: per-pod faults first, then the
-- frame-level errors from sensors and peripherals.
function pods.faultLines(frame)
    frame = frame or {}
    local lines = {}

    for _, corner in ipairs(widgets.CORNERS) do
        local pod = (frame.pods or {})[corner]
        if pod then
            for _, fault in ipairs(pod.faults or {}) do
                lines[#lines + 1] = corner .. ": " .. tostring(fault)
            end
            if pod.lastReject then
                lines[#lines + 1] = corner .. ": rejected " .. tostring(pod.lastReject)
            end
        end
    end

    for _, message in ipairs(frame.errors or {}) do
        lines[#lines + 1] = tostring(message)
    end

    return lines
end

local function cellsFor(frame, build)
    local cells = {}
    for index, corner in ipairs(widgets.CORNERS) do
        cells[index] = build((frame.pods or {})[corner] or {}, corner)
    end
    return cells
end

function pods.draw(canvas, rect, frame)
    frame = frame or {}

    local up = 0
    for _, corner in ipairs(widgets.CORNERS) do
        if ((frame.pods or {})[corner] or {}).online then
            up = up + 1
        end
    end

    -- Compute column width to choose appropriate link-cell format
    local xs, columnWidth = widgets.columns(rect, LABEL_WIDTH, #widgets.CORNERS)
    local usableWidth = columnWidth - 1

    local rows = {
        {
            label = "",
            build = function(_, corner)
                return { text = corner, colour = theme.foreground }
            end,
        },
        {
            label = "link",
            build = function(pod)
                if pod.online then
                    local text
                    if usableWidth >= 9 then
                        text = "UP " .. widgets.duration(pod.ageMs)
                    else
                        text = widgets.duration(pod.ageMs)
                    end
                    return {
                        text = text,
                        colour = theme.status("ok"),
                    }
                end
                -- Offline: if we have an age, show it; if not, show missing indicator
                local age = widgets.isFinite(pod.ageMs)
                    and widgets.duration(pod.ageMs) or widgets.MISSING
                local text
                if usableWidth >= 9 then
                    text = "DOWN " .. age
                else
                    text = age
                end
                -- Use different colour for "never reported" vs "offline with age"
                local colour = widgets.isFinite(pod.ageMs)
                    and theme.status("bad") or theme.status("idle")
                return { text = text, colour = colour }
            end,
        },
        {
            label = "armed",
            build = function(pod)
                if pod.armed == true then
                    return { text = "ARM", colour = theme.status("warn") }
                elseif pod.armed == false then
                    return { text = "safe", colour = theme.status("idle") }
                end
                return { text = widgets.MISSING, colour = theme.status("idle") }
            end,
        },
        {
            label = "power",
            build = function(pod)
                return { text = widgets.number(pod.currentPower, "%.3f") }
            end,
        },
        {
            label = "thrusters",
            build = function(pod)
                local healthy = pod.healthyThrusters
                local expected = pod.expectedThrusters
                if not widgets.isFinite(healthy) or not widgets.isFinite(expected) then
                    return { text = widgets.MISSING, colour = theme.status("idle") }
                end
                local level = "ok"
                if healthy < expected then
                    level = healthy == 0 and "bad" or "warn"
                end
                return {
                    text = string.format("%d/%d", healthy, expected),
                    colour = theme.status(level),
                }
            end,
        },
        {
            label = "obstructed",
            build = function(pod)
                local count = pod.obstructedThrusters
                if not widgets.isFinite(count) then
                    return { text = widgets.MISSING, colour = theme.status("idle") }
                end
                return {
                    text = string.format("%d", count),
                    colour = theme.status(count > 0 and "warn" or "ok"),
                }
            end,
        },
        {
            label = "cmd s/a/r",
            build = function(pod)
                return {
                    text = string.format("%s/%s/%s",
                        widgets.number(pod.commandsSeen, "%d"),
                        widgets.number(pod.commandsApplied, "%d"),
                        widgets.number(pod.commandsRejected, "%d")),
                    colour = widgets.isFinite(pod.commandsRejected)
                        and pod.commandsRejected > 0
                        and theme.status("warn") or theme.foreground,
                }
            end,
        },
    }

    -- Budget: reserve title + minimum 2 rows for faults section.
    -- This ensures the faults section always has a header and at least one line.
    local maxContentRows = math.max(1, rect.h - 3)
    local hiddenRows = math.max(0, #rows - maxContentRows)

    -- Update title with hidden row count if needed
    local rightText = string.format("%d/%d up", up, #widgets.CORNERS)
    if hiddenRows > 0 then
        rightText = rightText .. string.format("  %d hidden", hiddenRows)
    end
    widgets.title(canvas, rect, "PODS", rightText)

    -- Draw only as many content rows as budgeted
    local lastRow = 0
    for index = 1, math.min(#rows, maxContentRows) do
        local row = rows[index]
        local y = rect.y + index
        if y <= rect.y + rect.h - 1 then
            widgets.row(canvas, rect, y, row.label,
                cellsFor(frame, row.build), LABEL_WIDTH)
            lastRow = index
        end
    end

    -- Faults take whatever rows are left. A truncated list always says so:
    -- silently dropping the fault that mattered is the failure mode here.
    local faultTop = rect.y + lastRow + 1
    local available = rect.y + rect.h - faultTop
    if available < 2 then
        return
    end

    local lines = pods.faultLines(frame)
    canvas:text(rect.x, faultTop,
        widgets.clip(#lines > 0 and "FAULTS" or "FAULTS  none", rect.w),
        #lines > 0 and theme.status("bad") or theme.status("ok"),
        theme.background)

    local room = available - 1
    local shown = math.min(#lines, room)
    if #lines > room then
        shown = math.max(0, room - 1)
    end

    for index = 1, shown do
        canvas:text(rect.x + 1, faultTop + index,
            widgets.clip(lines[index], rect.w - 1),
            theme.status("bad"), theme.background)
    end

    if #lines > shown then
        canvas:text(rect.x + 1, faultTop + shown + 1,
            widgets.clip(string.format("... %d more", #lines - shown), rect.w - 1),
            theme.status("warn"), theme.background)
    end
end

return pods
