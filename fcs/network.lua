local config = require("fcs.config")

local network = {
    openedModem = nil,
    errors = {},
    podIds = {},
}

local function findWirelessModem()
    if config.wireless.modemName then
        local name = config.wireless.modemName
        if not peripheral.isPresent(name) then
            return nil, "configured wireless modem is missing: " .. name
        end
        local modem = peripheral.wrap(name)
        if type(modem.isWireless) ~= "function" or not modem.isWireless() then
            return nil, "configured modem is not wireless: " .. name
        end
        return name
    end

    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "modem") then
            local modem = peripheral.wrap(name)
            if type(modem.isWireless) == "function" and modem.isWireless() then
                return name
            end
        end
    end

    return nil, "no wireless modem is attached"
end

function network.open()
    if not config.wireless.enabled then
        return false, "wireless pod networking is disabled"
    end

    if network.openedModem and rednet.isOpen(network.openedModem) then
        return true
    end

    local name, reason = findWirelessModem()
    if not name then
        network.errors[#network.errors + 1] = reason
        return false, reason
    end

    rednet.open(name)
    network.openedModem = name

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
