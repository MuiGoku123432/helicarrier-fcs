local lines = {}

local function add(text)
    lines[#lines + 1] = text
    print(text)
end

local function packedResults(callback)
    local values = table.pack(callback())
    values.n = nil
    return values
end

term.clear()
term.setCursorPos(1, 1)
add("FCS PERIPHERAL DISCOVERY")
add("Computer ID: " .. tostring(os.getComputerID()))
add("Generated UTC ms: " .. tostring(os.epoch("utc")))
add("")

add("CC:Sable sublevel API: " .. tostring(sublevel ~= nil))
if sublevel then
    local ok, value = pcall(sublevel.isInPlotGrid)
    add("On Sable sublevel: " .. tostring(ok and value))
    if ok and value then
        local idOk, id = pcall(sublevel.getUniqueId)
        local nameOk, name = pcall(sublevel.getName)
        add("Sublevel UUID: " .. tostring(idOk and id or "ERROR"))
        add("Sublevel name: " .. tostring(nameOk and name or "ERROR"))
    end
end
add("CC:Sable aero API: " .. tostring(aero ~= nil))
add("")

local names = peripheral.getNames()
table.sort(names)
add("Peripheral count: " .. tostring(#names))

for _, name in ipairs(names) do
    add("")
    add("NAME: " .. name)

    local typeOk, types = pcall(function()
        return packedResults(function()
            return peripheral.getType(name)
        end)
    end)
    add("TYPES: " .. (typeOk and textutils.serialize(types) or "ERROR: " .. tostring(types)))

    local methodsOk, methods = pcall(peripheral.getMethods, name)
    if methodsOk and methods then
        table.sort(methods)
        add("METHODS: " .. table.concat(methods, ", "))
    else
        add("METHODS ERROR: " .. tostring(methods))
    end

    local wrapped = peripheral.wrap(name)
    if wrapped and type(wrapped.isWireless) == "function" then
        local wirelessOk, isWireless = pcall(wrapped.isWireless)
        if wirelessOk and not isWireless and type(wrapped.getNamesRemote) == "function" then
            local remoteOk, remotes = pcall(wrapped.getNamesRemote)
            if remoteOk then
                table.sort(remotes)
                add("WIRED REMOTES: " .. table.concat(remotes, ", "))
            end
        end
    end
end

local path = "/fcs/peripheral_manifest.txt"
local file = assert(fs.open(path, "w"))
file.write(table.concat(lines, "\n"))
file.close()

add("")
add("Saved to " .. path)
