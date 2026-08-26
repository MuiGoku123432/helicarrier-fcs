-- The hub's event loop.
--
-- It listens and it draws. It does not require fcs.banks, fcs.sensors or
-- fcs.network, and it must never start to: fcs/main.lua is the only program on
-- this computer that talks to CC:Sable or to the pods. A second reader would
-- duplicate ~50 ms of Sable calls per sample on a loop that already cannot
-- hold its period, and a second sender would put another session on the wire
-- for banks.lua's sender guards to trip over.

local canvas = require("fcs.hub.canvas")
local layout = require("fcs.hub.layout")
local theme = require("fcs.hub.theme")
local widgets = require("fcs.hub.widgets")
local zones = require("fcs.hub.zones")
local snapshot = require("fcs.snapshot")

local run = {}

-- Overridable so tools/test_hub_run.lua can resolve monitors without CC.
run._peripheral = nil

local function peripherals()
    return run._peripheral or _G.peripheral
end

function run.findMonitor(name)
    local api = peripherals()
    if type(api) ~= "table" then
        return nil, nil, "no peripheral API"
    end

    if type(name) == "string" and name ~= "" then
        if not api.isPresent(name) then
            return nil, nil, "configured monitor is missing: " .. name
        end
        if not api.hasType(name, "monitor") then
            return nil, nil, "configured peripheral is not a monitor: " .. name
        end
        return api.wrap(name), name
    end

    for _, candidate in ipairs(api.getNames()) do
        if api.hasType(candidate, "monitor") then
            return api.wrap(candidate), candidate
        end
    end

    return nil, nil, "no monitor is attached"
end

local FRESHNESS_LABEL = {
    live = "LIVE",
    stale = "STALE",
    dead = "NO TELEMETRY",
}

function run.headerText(frame, freshness, ageMs)
    local left = "FCS-DEV"
    local parts = { FRESHNESS_LABEL[freshness] or "NO TELEMETRY" }

    if freshness ~= "live" then
        parts[#parts + 1] = widgets.isFinite(ageMs)
            and widgets.duration(ageMs) or "never"
    end

    if type(frame) == "table" then
        if widgets.isFinite(frame.sequence) then
            parts[#parts + 1] = "seq " .. widgets.number(frame.sequence, "%d")
        end
        local log = frame.log or {}
        if widgets.isFinite(log.actualHz) then
            parts[#parts + 1] = widgets.number(log.actualHz, "%.1f") .. " Hz"
        end
    end

    return left, table.concat(parts, "  ")
end

function run.footerText(frame)
    frame = type(frame) == "table" and frame or {}
    local net = frame.net or {}
    local log = frame.log or {}

    local dropped = nil
    if widgets.isFinite(net.seen) and widgets.isFinite(net.accepted) then
        dropped = net.seen - net.accepted
    end

    local left = string.format("rednet %s/%s/%s",
        widgets.number(net.seen, "%d"),
        widgets.number(net.accepted, "%d"),
        widgets.number(dropped, "%d"))

    local name = widgets.MISSING
    if type(log.path) == "string" then
        name = log.path:match("([^/]+)$") or log.path
    end
    local right = string.format("%s  %s", name, widgets.compact(log.bytes))

    -- fcs/snapshot.dat and the CSV flight log share one disk quota, so free
    -- space is the number that answers "will the log keep writing". Appended
    -- rather than inlined so a frame that never carried it (an old snapshot,
    -- a run with no filesystem) does not spend footer width on "free --".
    if widgets.isFinite(log.freeSpace) then
        right = right .. "  free " .. widgets.compact(log.freeSpace)
    end

    return left, right
end

-- What the wall shows for a zone whose module is not there.
--
-- Deliberately NOT widgets.degraded: that says "needs 22x6", which on a rect
-- far larger than that is a false explanation -- it sends the operator off to
-- rebuild the monitor wall when the real fault is a half-finished hand-copy of
-- /fcs/hub/zones/ or a syntax error in one file (fcs/hub/zones/init.lua
-- swallows a load failure into the same nil a missing file returns).
function run.missingZone(surface, rect, name)
    surface:fill(rect.x, rect.y, rect.w, rect.h, theme.background)
    surface:text(rect.x, rect.y,
        widgets.clip(name .. " not deployed", rect.w),
        theme.status("bad"), theme.background)
    if rect.h >= 2 then
        surface:text(rect.x, rect.y + 1,
            widgets.clip("module missing -- re-copy /fcs/hub/zones/", rect.w),
            theme.label, theme.background)
    end
end

function run.render(surface, frame, freshness, ageMs)
    -- A stale frame keeps its numbers but loses its saturation: a green
    -- reading on a frozen frame is precisely the lie to avoid.
    surface:setDim(freshness ~= "live")
    surface:clear(theme.background)

    local plan = layout.compute(surface.width, surface.height)

    local headerLeft, headerRight = run.headerText(frame, freshness, ageMs)
    if plan.header then
        widgets.title(surface, plan.header, headerLeft, headerRight,
            theme.freshnessColour(freshness))
    end

    if plan.message then
        surface:text(1, math.max(2, math.floor(surface.height / 2)),
            widgets.clip(plan.message, surface.width),
            theme.status("warn"), theme.background)
        surface:setDim(false)
        return plan
    end

    -- A frame from a schema this build does not know is refused rather than
    -- mis-rendered: field names would silently mean something else.
    if type(frame) == "table" and frame.v ~= nil and frame.v ~= snapshot.VERSION then
        surface:text(1, 3, widgets.clip(string.format(
            "snapshot version %s, this hub speaks %s -- redeploy /fcs-dev.lua and /fcs/",
            tostring(frame.v), tostring(snapshot.VERSION)), surface.width),
            theme.status("bad"), theme.background)
        surface:setDim(false)
        return plan
    end

    for _, entry in ipairs(plan.zones) do
        local zone = zones.get(entry.name)
        if not zone then
            run.missingZone(surface, entry.rect, entry.name)
        elseif entry.degraded then
            widgets.degraded(surface, entry.rect, entry.name,
                layout.MINIMUMS[entry.name])
        else
            -- One zone must not be able to blank the wall.
            local ok, err = pcall(zone.draw, surface, entry.rect, frame)
            if not ok then
                surface:fill(entry.rect.x, entry.rect.y,
                    entry.rect.w, entry.rect.h, theme.background)
                surface:text(entry.rect.x, entry.rect.y,
                    widgets.clip(entry.name .. " render failed", entry.rect.w),
                    theme.status("bad"), theme.background)
                surface:text(entry.rect.x, entry.rect.y + 1,
                    widgets.clip(tostring(err), entry.rect.w),
                    theme.status("warn"), theme.background)
            end
        end
    end

    if plan.footer then
        local footerLeft, footerRight = run.footerText(frame)
        if freshness == "dead" then
            footerLeft = "logger not running -- start /fcs/main.lua"
        elseif #plan.hidden > 0 then
            footerLeft = footerLeft .. "  hidden: " .. table.concat(plan.hidden, " ")
        end
        widgets.title(surface, plan.footer, footerLeft, footerRight)
    end

    surface:setDim(false)
    return plan
end

-- Slowest redraw the hub will accept. config.hub is hand-edited on the CC
-- computer with no version control, and 1/maxRedrawHz has no natural floor:
-- maxRedrawHz = 0 gives inf and os.startTimer throws at launch, killing the tab
-- before it draws once; a negative value gives a negative period, which spins
-- the loop at tick rate and steals the shared Lua thread from the sample loop
-- that is flying the craft. Both are worse than a slow wall.
run.MIN_REDRAW_HZ = 0.2

function run.redrawPeriod(maxRedrawHz)
    if not widgets.isFinite(maxRedrawHz) or maxRedrawHz < run.MIN_REDRAW_HZ then
        maxRedrawHz = run.MIN_REDRAW_HZ
    end
    return 1 / maxRedrawHz
end

function run.start(options)
    options = options or {}
    local maxRedrawHz = options.maxRedrawHz or 5
    local staleAfterMs = options.staleAfterMs or theme.defaultStaleAfterMs
    local deadAfterMs = options.deadAfterMs or theme.defaultDeadAfterMs
    local redrawPeriod = run.redrawPeriod(maxRedrawHz)

    local target, targetName
    local onMonitor = false
    if options.term then
        target = term.current()
        targetName = "terminal"
    else
        local monitor, name, reason = run.findMonitor(options.monitorName)
        if monitor then
            monitor.setTextScale(options.textScale or 0.5)
            target, targetName = monitor, name
            onMonitor = true
        else
            print("fcs-dev: " .. tostring(reason) .. "; using the terminal")
            target = term.current()
            targetName = "terminal"
        end
    end

    local surface = canvas.new(target)
    print("fcs-dev: rendering to " .. tostring(targetName)
        .. " (" .. surface.width .. "x" .. surface.height .. ")")

    -- Seed from disk so a hub started cold has something to draw immediately,
    -- and so a hub started with no logger running shows the last known frame
    -- with an honest age rather than an empty screen.
    local frame = snapshot.read()
    local dirty = true
    local lastFreshness = nil
    local lastDrawAt = 0
    -- Cleared when the monitor we hold leaves. The loop keeps running with no
    -- surface: the tab must outlive the wall, because startup.lua only opens
    -- it at boot and a dead tab means a dark wall until someone reboots.
    local attached = true

    local timer = os.startTimer(redrawPeriod)

    while true do
        local event, first = os.pullEvent()

        if event == "fcs_snapshot" then
            if type(first) == "table" then
                frame = first
                dirty = true
            end
        elseif event == "monitor_resize" or event == "term_resize" then
            if surface then
                -- resize() reads getSize() off a handle that may already be
                -- dead; a throw here would escape the loop just as blit would.
                if not pcall(surface.resize, surface) then
                    attached = false
                    surface = nil
                end
            end
            dirty = true
        elseif event == "peripheral_detach" then
            -- Chunk boundary, broken block, a wall being re-assembled: the
            -- monitor can leave at any time. Stop drawing to the dead handle
            -- rather than letting the next blit throw out of run.start.
            if onMonitor and attached and first == targetName then
                attached = false
                surface = nil
            end
        elseif event == "peripheral" then
            if onMonitor and not attached then
                local monitor, name = run.findMonitor(options.monitorName)
                if monitor then
                    pcall(monitor.setTextScale, options.textScale or 0.5)
                    local ok, rebuilt = pcall(canvas.new, monitor)
                    if ok and rebuilt then
                        target, targetName = monitor, name
                        surface = rebuilt
                        attached = true
                        -- A fresh canvas starts invalidated, so the next draw
                        -- is a full repaint onto a screen we know nothing about.
                        dirty = true
                    end
                end
            end
        elseif event == "timer" and first == timer then
            local now = os.epoch("utc")
            local ageMs = nil
            if type(frame) == "table" and widgets.isFinite(frame.utc_ms) then
                ageMs = now - frame.utc_ms
            end
            local freshness = theme.freshness(ageMs, staleAfterMs, deadAfterMs)

            -- Repaint on new data, on a change of freshness, and at least once
            -- a second so the age counter keeps moving while nothing arrives.
            if surface
                and (dirty or freshness ~= lastFreshness or now - lastDrawAt >= 1000) then
                run.render(surface, frame, freshness, ageMs)
                -- canvas:flush() blits straight at the target with no guard of
                -- its own, and that is where a detached monitor throws. The
                -- zone-level pcall in run.render protects against one zone
                -- blanking the wall; this is the same protection one layer up,
                -- for the whole tab. A failed flush leaves the front buffer
                -- half-synced with a screen we can no longer see, so the only
                -- safe next paint is a complete one.
                if pcall(surface.flush, surface) then
                    dirty = false
                else
                    surface:invalidate()
                    dirty = true
                end
                lastFreshness = freshness
                lastDrawAt = now
            end

            timer = os.startTimer(redrawPeriod)
        end
    end
end

return run
