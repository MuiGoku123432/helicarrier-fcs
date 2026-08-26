-- Energy reserve, grid readings, and per-pod ion draw.
--
-- Every reading here is optional: energyStorage, powerMeter, voltmeter and
-- ammeter are all nil-by-default in fcs/config.lua. A carrier without meters
-- must render a clean zone full of dashes, not a broken one.

local theme = require("fcs.hub.theme")
local widgets = require("fcs.hub.widgets")

local power = {}

power.name = "POWER"

power.LOW_FRACTION = 0.20
power.WARN_FRACTION = 0.50

function power.fraction(stored, capacity)
    if not widgets.isFinite(stored) or not widgets.isFinite(capacity) then
        return nil
    end
    if capacity <= 0 then
        return nil
    end
    local fraction = stored / capacity
    if fraction < 0 then fraction = 0 end
    if fraction > 1 then fraction = 1 end
    return fraction
end

local function chargeLevel(fraction)
    if not widgets.isFinite(fraction) then
        return "idle"
    end
    if fraction < power.LOW_FRACTION then
        return "bad"
    elseif fraction < power.WARN_FRACTION then
        return "warn"
    end
    return "ok"
end

function power.draw(canvas, rect, frame)
    frame = frame or {}
    local readings = frame.power or {}

    local fraction = power.fraction(readings.storedFE, readings.capacityFE)
    local level = chargeLevel(fraction)
    local percent = fraction and string.format("%d%%", math.floor(fraction * 100 + 0.5))
        or widgets.MISSING

    -- Define content rows in priority order
    local rows = {
        { type = "bar", fraction = fraction, level = level },
        { type = "fe", stored = readings.storedFE, capacity = readings.capacityFE },
        { type = "grid_w", value = readings.gridPower },
        { type = "grid_v", value = readings.gridVoltage },
        { type = "grid_a", value = readings.gridAmperage },
        { type = "ion_label" },
        { type = "ion_pods_1", frame = frame },  -- FL, FR
        { type = "ion_pods_2", frame = frame },  -- RL, RR
    }

    -- Compute row budget: reserve title (1 row)
    local maxContentRows = math.max(1, rect.h - 1)
    local hiddenRows = math.max(0, #rows - maxContentRows)

    -- Update title with hidden row count if needed
    local rightText = percent
    if hiddenRows > 0 then
        rightText = rightText .. string.format("  %d hidden", hiddenRows)
    end
    widgets.title(canvas, rect, "POWER", rightText)

    -- Render only as many rows as budgeted, in priority order
    for index = 1, math.min(#rows, maxContentRows) do
        local row = rows[index]
        local y = rect.y + index
        if y <= rect.y + rect.h - 1 then
            if row.type == "bar" then
                canvas:bar(rect.x, y, rect.w, row.fraction or 0,
                    theme.status(row.level), theme.colours.gray)
            elseif row.type == "fe" then
                canvas:text(rect.x, y,
                    widgets.clip(string.format("%s / %s FE",
                        widgets.compact(row.stored),
                        widgets.compact(row.capacity)), rect.w),
                    theme.foreground, theme.background)
            elseif row.type == "grid_w" then
                canvas:text(rect.x, y,
                    widgets.clip("grid W", 8), theme.label, theme.background)
                canvas:text(rect.x + 9, y,
                    widgets.clip(widgets.compact(row.value), rect.w - 9),
                    theme.foreground, theme.background)
            elseif row.type == "grid_v" then
                canvas:text(rect.x, y,
                    widgets.clip("volts", 8), theme.label, theme.background)
                canvas:text(rect.x + 9, y,
                    widgets.clip(widgets.number(row.value, "%.0f"), rect.w - 9),
                    theme.foreground, theme.background)
            elseif row.type == "grid_a" then
                canvas:text(rect.x, y,
                    widgets.clip("amps", 8), theme.label, theme.background)
                canvas:text(rect.x + 9, y,
                    widgets.clip(widgets.number(row.value, "%.0f"), rect.w - 9),
                    theme.foreground, theme.background)
            elseif row.type == "ion_label" then
                canvas:text(rect.x, y, widgets.clip("ION AVG POWER", rect.w),
                    theme.label, theme.background)
            elseif row.type == "ion_pods_1" then
                -- FL, FR
                local parts = {}
                for offset = 1, 2 do
                    local corner = widgets.CORNERS[offset]
                    local pod = (row.frame.pods or {})[corner] or {}
                    parts[#parts + 1] = string.format("%s %s",
                        corner, widgets.number(pod.averagePower, "%.3f"))
                end
                canvas:text(rect.x + 1, y,
                    widgets.clip(table.concat(parts, "  "), rect.w - 1),
                    theme.foreground, theme.background)
            elseif row.type == "ion_pods_2" then
                -- RL, RR
                local parts = {}
                for offset = 3, 4 do
                    local corner = widgets.CORNERS[offset]
                    local pod = (row.frame.pods or {})[corner] or {}
                    parts[#parts + 1] = string.format("%s %s",
                        corner, widgets.number(pod.averagePower, "%.3f"))
                end
                canvas:text(rect.x + 1, y,
                    widgets.clip(table.concat(parts, "  "), rect.w - 1),
                    theme.foreground, theme.background)
            end
        end
    end
end

return power
