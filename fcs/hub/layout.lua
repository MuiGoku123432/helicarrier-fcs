-- Screen size in, zone rectangles out. No drawing, no state, no CC globals.
--
-- The reflow rule that matters: rather than shrinking every zone until they
-- are all illegible, drop whole zones in reverse priority order until the
-- survivors fit at their minimum size. A missing zone is honest; four
-- unreadable ones are not.

local layout = {}

-- Minimum size at which a zone can render truthfully. A zone that cannot get
-- this is dropped from plan.zones and listed in plan.hidden rather than shrunk.
layout.MINIMUMS = {
    ENGINES = { w = 48, h = 10 },
    PODS = { w = 38, h = 7 },
    ATTITUDE = { w = 28, h = 8 },
    POWER = { w = 22, h = 6 },
}

-- Most important first. ENGINES leads because the per-bearing thrust delta is
-- the reason the wall exists: corner aggregates sum magnitudes and cannot show
-- one bearing of a counter-rotating pair underperforming its twin.
layout.PRIORITY = { "ENGINES", "PODS", "ATTITUDE", "POWER" }

-- Below this width, attitude and power stack instead of pairing.
layout.SIDE_BY_SIDE_WIDTH = 70

-- Extra rows beyond the minimum, handed out in this order while surplus lasts.
--
-- Kept deliberately small. ENGINES and the top band both draw a FIXED list of
-- rows -- surplus handed to them is blank space they cannot grow into -- while
-- PODS, which takes whatever is left, is the one zone whose content genuinely
-- grows without bound (see the surplus comment in layout.compute). At { 3, 6 }
-- the 79x38 wall left blank rows in the ENGINES and ATTITUDE bands while PODS
-- reported "1 hidden", dropped its cmd s/a/r row, and gave the fault list a
-- single line. TOP keeps one row so a shared top band is not pinned exactly at
-- both minimums.
local EXTRA_BUDGET = { ENGINES = 0, TOP = 1 }

-- Attitude takes the larger share of a shared top band: it carries a ladder
-- and six numeric rows, where power carries a bar and three.
local ATTITUDE_SHARE = 0.58

local function contains(list, value)
    for _, item in ipairs(list) do
        if item == value then return true end
    end
    return false
end

local function topBandMinimum(present, sideBySide)
    local attitude = contains(present, "ATTITUDE")
    local power = contains(present, "POWER")
    if not attitude and not power then
        return 0
    end
    if attitude and power then
        if sideBySide then
            return math.max(layout.MINIMUMS.ATTITUDE.h, layout.MINIMUMS.POWER.h)
        end
        return layout.MINIMUMS.ATTITUDE.h + layout.MINIMUMS.POWER.h
    end
    return attitude and layout.MINIMUMS.ATTITUDE.h or layout.MINIMUMS.POWER.h
end

-- Height the present set needs at minimum size, given how the top band packs.
local function requiredHeight(present, sideBySide)
    local total = 0
    if contains(present, "ENGINES") then
        total = total + layout.MINIMUMS.ENGINES.h
    end
    if contains(present, "PODS") then
        total = total + layout.MINIMUMS.PODS.h
    end

    total = total + topBandMinimum(present, sideBySide)

    return total
end

function layout.compute(width, height)
    local plan = {
        width = width,
        height = height,
        zones = {},
        hidden = {},
        message = nil,
    }

    -- One header row, one footer row, and at least the smallest zone between.
    local minimumHeight = 2 + layout.MINIMUMS.POWER.h
    local minimumWidth = layout.MINIMUMS.POWER.w
    if type(width) ~= "number" or type(height) ~= "number"
        or width < minimumWidth or height < minimumHeight then
        plan.message = string.format("screen too small: need %dx%d, have %sx%s",
            minimumWidth, minimumHeight, tostring(width), tostring(height))
        for _, name in ipairs(layout.PRIORITY) do
            plan.hidden[#plan.hidden + 1] = name
        end
        return plan
    end

    plan.header = { x = 1, y = 1, w = width, h = 1 }
    plan.footer = { x = 1, y = height, w = width, h = 1 }

    local bodyTop = 2
    local bodyHeight = height - 2
    local sideBySide = width >= layout.SIDE_BY_SIDE_WIDTH

    -- Start with everything, then drop the least important until it fits both
    -- ways: horizontally at minimum width, and vertically as a set.
    local present = {}
    for _, name in ipairs(layout.PRIORITY) do
        present[#present + 1] = name
    end

    local function drop(name)
        for index, item in ipairs(present) do
            if item == name then
                table.remove(present, index)
                break
            end
        end
        if not contains(plan.hidden, name) then
            plan.hidden[#plan.hidden + 1] = name
        end
    end

    -- Horizontal fit. In a side-by-side band each of the pair gets a share of
    -- the width, so check that share rather than the whole screen.
    for index = #layout.PRIORITY, 1, -1 do
        local name = layout.PRIORITY[index]
        local available = width
        if sideBySide and (name == "ATTITUDE" or name == "POWER") then
            available = name == "ATTITUDE"
                and math.floor(width * ATTITUDE_SHARE)
                or width - math.floor(width * ATTITUDE_SHARE)
        end
        if available < layout.MINIMUMS[name].w then
            drop(name)
        end
    end

    -- Vertical fit, dropping from the end of the priority list.
    for index = #layout.PRIORITY, 1, -1 do
        if requiredHeight(present, sideBySide) <= bodyHeight then
            break
        end
        drop(layout.PRIORITY[index])
    end

    if #present == 0 then
        plan.message = string.format("screen too small: need %dx%d, have %dx%d",
            minimumWidth, minimumHeight, width, height)
        return plan
    end

    -- Hand out the surplus: engines first (more corners' worth of rows), then
    -- the top band, and whatever is left to pods, whose fault list is the one
    -- thing that genuinely grows without bound.
    local surplus = bodyHeight - requiredHeight(present, sideBySide)
    local enginesExtra = 0
    if contains(present, "ENGINES") then
        enginesExtra = math.min(surplus, EXTRA_BUDGET.ENGINES)
        surplus = surplus - enginesExtra
    end
    local topExtra = 0
    if topBandMinimum(present, sideBySide) > 0 then
        topExtra = math.min(surplus, EXTRA_BUDGET.TOP)
        surplus = surplus - topExtra
    end
    local podsExtra = contains(present, "PODS") and surplus or 0

    local topHeight = topBandMinimum(present, sideBySide) + topExtra
    local enginesHeight = contains(present, "ENGINES")
        and layout.MINIMUMS.ENGINES.h + enginesExtra or 0
    local podsHeight = contains(present, "PODS")
        and layout.MINIMUMS.PODS.h + podsExtra or 0

    -- Anything unclaimed (no pods present) goes to whatever is left, so the
    -- body always reaches the row above the footer.
    local claimed = topHeight + enginesHeight + podsHeight
    local leftover = bodyHeight - claimed
    if leftover > 0 then
        if podsHeight > 0 then
            podsHeight = podsHeight + leftover
        elseif enginesHeight > 0 then
            enginesHeight = enginesHeight + leftover
        else
            topHeight = topHeight + leftover
        end
    end

    local function add(name, rect)
        local minimum = layout.MINIMUMS[name]
        plan.zones[#plan.zones + 1] = {
            name = name,
            rect = rect,
            -- Defensive guard: the packing rule above means degraded should always
            -- be false (zones below minimum are dropped, never shrunk). Retained so
            -- a future change to SIDE_BY_SIDE_WIDTH, ATTITUDE_SHARE, or MINIMUMS
            -- that broke the invariant would be caught by the consumer.
            degraded = rect.w < minimum.w or rect.h < minimum.h,
        }
    end

    local y = bodyTop

    if topHeight > 0 then
        local attitude = contains(present, "ATTITUDE")
        local power = contains(present, "POWER")
        if attitude and power and sideBySide then
            local attitudeWidth = math.floor(width * ATTITUDE_SHARE)
            add("ATTITUDE", { x = 1, y = y, w = attitudeWidth, h = topHeight })
            add("POWER", {
                x = attitudeWidth + 1, y = y,
                w = width - attitudeWidth, h = topHeight,
            })
        elseif attitude and power then
            -- Stacked: attitude keeps its share of the band's height.
            local attitudeHeight = math.max(
                layout.MINIMUMS.ATTITUDE.h,
                math.floor(topHeight * ATTITUDE_SHARE))
            attitudeHeight = math.min(attitudeHeight, topHeight - layout.MINIMUMS.POWER.h)
            add("ATTITUDE", { x = 1, y = y, w = width, h = attitudeHeight })
            add("POWER", {
                x = 1, y = y + attitudeHeight,
                w = width, h = topHeight - attitudeHeight,
            })
        elseif attitude then
            add("ATTITUDE", { x = 1, y = y, w = width, h = topHeight })
        elseif power then
            add("POWER", { x = 1, y = y, w = width, h = topHeight })
        end
        y = y + topHeight
    end

    if enginesHeight > 0 then
        add("ENGINES", { x = 1, y = y, w = width, h = enginesHeight })
        y = y + enginesHeight
    end

    if podsHeight > 0 then
        add("PODS", { x = 1, y = y, w = width, h = podsHeight })
        y = y + podsHeight
    end

    return plan
end

return layout
