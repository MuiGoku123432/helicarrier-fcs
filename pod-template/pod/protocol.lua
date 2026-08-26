local protocol = {}

protocol.MAGIC = "HELICARRIER_FCS"
protocol.VERSION = 2

local allowedTypes = {
    ping = true,
    status_request = true,
    status = true,
    arm = true,
    disarm = true,
    set_power = true,
    set_rpm = true,
    -- Thrust vectoring. NOTE THE BOOTSTRAP GOTCHA: a running pod holds its old
    -- protocol.lua in memory, so until it is restarted protocol.validate()
    -- rejects set_tilt before dispatch ever sees it. The first restart after
    -- deploying this MUST be done by hand at each pod terminal (Ctrl+R) --
    -- /fcs/reboot.lua cannot install itself either, for exactly this reason.
    set_tilt = true,
    clear_tilt = true,
    reboot = true,
    ack = true,
    fault = true,
}

function protocol.message(messageType, fields)
    local message = fields or {}
    message.magic = protocol.MAGIC
    message.version = protocol.VERSION
    message.type = messageType
    message.sentAt = os.epoch("utc")
    return message
end

function protocol.validate(message)
    if type(message) ~= "table" then
        return false, "message is not a table"
    end
    if message.magic ~= protocol.MAGIC then
        return false, "wrong protocol magic"
    end
    if message.version ~= protocol.VERSION then
        return false, "unsupported protocol version"
    end
    if not allowedTypes[message.type] then
        return false, "unknown message type"
    end
    return true
end

function protocol.validPower(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

return protocol
