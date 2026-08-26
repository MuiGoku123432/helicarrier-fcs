-- Colour constants and value-to-colour rules for the hub.
--
-- The numbers are ComputerCraft's colour palette, redeclared here rather than
-- read from the `colours` global: every module below run.lua must load under
-- plain luajit, where that global does not exist.

local theme = {}

theme.colours = {
    white = 1, orange = 2, magenta = 4, lightBlue = 8,
    yellow = 16, lime = 32, pink = 64, gray = 128,
    lightGray = 256, cyan = 512, purple = 1024, blue = 2048,
    brown = 4096, green = 8192, red = 16384, black = 32768,
}

local c = theme.colours

theme.background = c.black
theme.foreground = c.white
theme.titleForeground = c.black
theme.titleBackground = c.lightGray
theme.label = c.lightGray
theme.rule = c.gray

local LEVEL_COLOUR = {
    idle = c.gray,
    ok = c.lime,
    warn = c.yellow,
    bad = c.red,
}

function theme.status(level)
    return LEVEL_COLOUR[level] or c.white
end

-- Dim mode is how a stale frame stays readable while announcing that it is no
-- longer true. Everything collapses toward gray; nothing stays saturated,
-- because a saturated green on a frozen frame is exactly the lie to avoid.
local DIM = {
    [c.white] = c.lightGray,
    [c.lightGray] = c.gray,
    [c.gray] = c.gray,
    [c.lime] = c.green,
    [c.green] = c.green,
    [c.yellow] = c.brown,
    [c.orange] = c.brown,
    [c.red] = c.brown,
    [c.cyan] = c.blue,
    [c.lightBlue] = c.blue,
    [c.blue] = c.blue,
    [c.magenta] = c.purple,
    [c.pink] = c.purple,
    [c.purple] = c.purple,
    [c.brown] = c.brown,
    [c.black] = c.black,
}

function theme.dim(colour)
    return DIM[colour] or c.gray
end

-- Frame freshness. Thresholds come from config.hub; the defaults here are the
-- spec's and are used when a caller passes none.
theme.defaultStaleAfterMs = 1000
theme.defaultDeadAfterMs = 5000

function theme.freshness(ageMs, staleAfterMs, deadAfterMs)
    if type(ageMs) ~= "number" then
        return "dead"
    end
    staleAfterMs = staleAfterMs or theme.defaultStaleAfterMs
    deadAfterMs = deadAfterMs or theme.defaultDeadAfterMs
    if ageMs < staleAfterMs then
        return "live"
    elseif ageMs < deadAfterMs then
        return "stale"
    end
    return "dead"
end

local FRESHNESS_COLOUR = { live = c.lime, stale = c.yellow, dead = c.red }

function theme.freshnessColour(freshness)
    return FRESHNESS_COLOUR[freshness] or c.red
end

return theme
