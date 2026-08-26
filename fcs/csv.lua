local csv = {}

local function encode(value)
    if value == nil then
        return ""
    end

    if type(value) == "boolean" then
        return value and "true" or "false"
    end

    local text = tostring(value)
    if text:find('[,\"\n\r]') then
        text = '"' .. text:gsub('"', '""') .. '"'
    end
    return text
end

function csv.open(path, columns, flushEveryRows)
    local file, reason = fs.open(path, "w")
    if not file then
        error("Cannot open log file " .. path .. ": " .. tostring(reason), 0)
    end

    local header = table.concat(columns, ",")
    file.writeLine(header)
    file.flush()

    local rowCount = 0
    -- Tracked rather than stat'd: fs.getSize on an open handle lags the buffer,
    -- and the caller needs to know when to roll BEFORE the quota bites.
    local bytesWritten = #header + 1
    local writer = {}

    function writer.write(row)
        local values = {}
        for index, column in ipairs(columns) do
            values[index] = encode(row[column])
        end

        local line = table.concat(values, ",")
        file.writeLine(line)
        rowCount = rowCount + 1
        bytesWritten = bytesWritten + #line + 1

        if rowCount % flushEveryRows == 0 then
            file.flush()
        end
    end

    function writer.bytes()
        return bytesWritten
    end

    function writer.rows()
        return rowCount
    end

    function writer.flush()
        file.flush()
    end

    function writer.close()
        file.flush()
        file.close()
    end

    return writer
end

return csv
