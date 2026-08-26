-- Zone registry.
--
-- Lookup is lazy and tolerant: a name whose module does not exist yet returns
-- nil rather than throwing, so the zones can land one task at a time and the
-- shared test battery picks each one up as it arrives.

local zones = {}

zones.NAMES = { "ATTITUDE", "ENGINES", "PODS", "POWER" }

local MODULE = {
    ATTITUDE = "fcs.hub.zones.attitude",
    ENGINES = "fcs.hub.zones.engines",
    PODS = "fcs.hub.zones.pods",
    POWER = "fcs.hub.zones.power",
}

local cache = {}

function zones.get(name)
    if cache[name] ~= nil then
        return cache[name] or nil
    end
    local path = MODULE[name]
    if not path then
        return nil
    end
    -- pcall here is deliberate tolerance for a module that does not exist yet
    -- (see the file header). The cost is that it is equally tolerant of a
    -- module that DOES exist but fails at load time -- that failure is
    -- swallowed the same way, and zones.available() just quietly returns one
    -- fewer name with nothing failing loudly. The shared battery below only
    -- iterates zones.available(), so it cannot catch this either. Each zone
    -- task therefore also adds a zone-specific test section (see "Attitude
    -- specifics" / "Engines specifics" below) that dereferences
    -- zones.get("<NAME>") directly, so a module that fails to load fails that
    -- section loudly instead of shrinking the battery's iteration count.
    local ok, module = pcall(require, path)
    if not ok or type(module) ~= "table" or type(module.draw) ~= "function" then
        cache[name] = false
        return nil
    end
    cache[name] = module
    return module
end

function zones.available()
    local found = {}
    for _, name in ipairs(zones.NAMES) do
        if zones.get(name) then
            found[#found + 1] = name
        end
    end
    return found
end

return zones
