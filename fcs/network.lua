local config = require("fcs.config")

local network = {
    openedModem = nil,
    openedModems = {},
    errors = {},
    podIds = {},
}

-- ---------------------------------------------------------------------------
-- OPEN EVERY MODEM, WIRED OR WIRELESS.
--
-- This used to find ONE modem and REJECT anything that was not wireless. That
-- made a wired bus impossible to try, and a wired bus is the one architecture
-- that bypasses the layer under suspicion.
--
-- WHY IT MATTERS, measured 2026-08-28: in flight, commands FCS->pod stopped
-- arriving for about six seconds on ALL FOUR pods at once, while pod->FCS
-- telemetry kept flowing and the FCS loop stayed healthy at 201 ms. The pods
-- logged COMMAND_TIMEOUT, so they agree they heard nothing. The craft has
-- Ender modems, which are interdimensional and therefore skip CC:Tweaked's
-- distance check entirely -- so no distance, however wrong, can explain it.
-- What is left is the receiver not being in the set the transmit iterated at
-- all, which is Sable sublevel/registration state rather than geometry.
--
-- A wired network is a connected graph rather than a spatial query, so it does
-- not go through that code at all. Hence the A/B: some pods wired, some not.
--
-- rednet.send transmits on EVERY open modem, so opening both here means the
-- FCS reaches wired and wireless pods with no per-corner routing. Each POD
-- opens exactly one, which is what keeps the two transports from delivering
-- the same command twice and tripping the sequence gate as a replay.
-- ---------------------------------------------------------------------------

local function modemType(name)
    local modem = peripheral.wrap(name)
    if not modem then return nil end
    if type(modem.isWireless) ~= "function" then return "modem" end
    local ok, wireless = pcall(modem.isWireless)
    if not ok then return "modem" end
    return wireless and "wireless" or "wired"
end

local function findModems()
    if config.wireless.modemName then
        local name = config.wireless.modemName
        if not peripheral.isPresent(name) then
            return nil, "configured modem is missing: " .. name
        end
        if not peripheral.hasType(name, "modem") then
            return nil, "configured peripheral is not a modem: " .. name
        end
        return { name }
    end

    local found = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "modem") then
            found[#found + 1] = name
        end
    end
    if #found == 0 then
        return nil, "no modem is attached"
    end
    return found
end

function network.open()
    if not config.wireless.enabled then
        return false, "pod networking is disabled"
    end

    if network.openedModem and rednet.isOpen(network.openedModem) then
        return true
    end

    local names, reason = findModems()
    if not names then
        network.errors[#network.errors + 1] = reason
        return false, reason
    end

    network.openedModems = {}
    for _, name in ipairs(names) do
        -- One modem refusing to open must not cost the others. A wired modem
        -- with no cable attached is a normal state, not a failure.
        local ok, err = pcall(rednet.open, name)
        if ok then
            network.openedModems[#network.openedModems + 1] =
                { name = name, kind = modemType(name) }
        else
            network.errors[#network.errors + 1] =
                "rednet.open " .. name .. ": " .. tostring(err)
        end
    end

    if #network.openedModems == 0 then
        return false, "no modem could be opened"
    end
    -- The first one stays as `openedModem` so the reports and probes that name
    -- a single modem keep working.
    network.openedModem = network.openedModems[1].name

    local hosted, hostError = pcall(
        rednet.host,
        config.wireless.protocol,
        config.wireless.mainHostname
    )
    if not hosted and not tostring(hostError):find("already") then
        network.errors[#network.errors + 1] = "rednet host: " .. tostring(hostError)
    end

    return true
end

-- "back(wireless) top(wired)", for any report that wants to say what the
-- transport actually is rather than assuming.
function network.describeModems()
    local parts = {}
    for _, entry in ipairs(network.openedModems or {}) do
        parts[#parts + 1] = string.format("%s(%s)", entry.name, entry.kind)
    end
    if #parts == 0 then return "none" end
    return table.concat(parts, " ")
end

function network.lookupPod(corner)
    if config.wireless.podIds[corner] then
        return config.wireless.podIds[corner]
    end
    return network.podIds[corner]
end

function network.discoverPod(corner)
    local known = network.lookupPod(corner)
    if known then
        return known
    end

    local hostname = config.wireless.podHostnames[corner]
    if not hostname then
        return nil
    end
    local id = rednet.lookup(config.wireless.protocol, hostname)
    network.podIds[corner] = id
    return id
end

function network.rememberPod(corner, id)
    if not config.wireless.podIds[corner] then
        network.podIds[corner] = id
    end
end

return network
