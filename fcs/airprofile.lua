-- Map air pressure against altitude, and dump what CC:Sable actually exposes.
--
-- Read-only. It commands nothing, so it is safe to run at any time.
--
-- Why this exists. The RPM sweep bracketed hover at 122 < rpm <= 124, implying
-- real force = getThrust x 1.353. Air pressure at the logged craft origin reads
-- 1.4309 -- close, but 5.8% high. The suspicion is that Create Aeronautics
-- scales propeller thrust by air density at the PROPELLER's altitude, and the
-- props sit above the hull reference point getLogicalPose returns.
-- aero.getAirPressure takes an arbitrary position, so the profile can be
-- measured outright instead of inferred from the fraction of a block the
-- carrier moved during a sweep.
--
-- It also lists every method on the aero and sublevel APIs. The twelve calls
-- this project uses were all found ad hoc; if CC:Sable exposes air density (or
-- temperature) directly, reconstructing it from pressure is wasted effort and
-- probably wrong.
--
--   /fcs/airprofile.lua [targetPressure]

if package then
    package.path = "/?.lua;/?/init.lua;" .. package.path
else
    require, package = dofile("/rom/modules/main/cc/require.lua").make(_ENV, "/")
end

local config = require("fcs.config")
local csv = require("fcs.csv")

local args = { ... }
local targetPressure = tonumber(args[1]) or 1.3529

if not sublevel then
    error("CC:Sable sublevel API unavailable; run this on the carrier", 0)
end
if not aero then
    error("aero API unavailable; nothing to profile", 0)
end

local function writeReport(path, lines)
    local ok, file = pcall(fs.open, path, "w")
    if ok and file then
        file.write(table.concat(lines, "\n"))
        file.close()
    end
end

local report = {}
local function note(line)
    report[#report + 1] = line
    print(line)
end

term.clear()
term.setCursorPos(1, 1)

-- --- what does CC:Sable actually offer? ------------------------------------
local function describeApi(name, api)
    local names = {}
    for key, value in pairs(api) do
        names[#names + 1] = key .. (type(value) == "function" and "()" or
            (" = " .. tostring(value)))
    end
    table.sort(names)
    note(name .. " (" .. #names .. " entries):")
    for _, entry in ipairs(names) do
        note("  " .. entry)
    end
    note("")
end

note("CC:SABLE API SURFACE")
note("")
describeApi("aero", aero)
describeApi("sublevel", sublevel)

-- Names alone are not enough to consume a method: getInertiaTensor could be a
-- 3x3, a flat 9-array, or a table of named fields, and guessing wrong produces
-- confidently wrong control maths. Call every no-argument getter and print what
-- it actually returns, so these get wired from evidence.
local function shapeOf(value, depth)
    depth = depth or 0
    if type(value) ~= "table" then
        return tostring(value)
    end
    if depth > 2 then
        return "{...}"
    end

    local parts, count = {}, 0
    for key, inner in pairs(value) do
        count = count + 1
        if count > 12 then
            parts[#parts + 1] = "..."
            break
        end
        parts[#parts + 1] = tostring(key) .. "=" .. shapeOf(inner, depth + 1)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function dumpValues(name, api)
    note(name .. " return values (no-argument calls):")
    local names = {}
    for key, value in pairs(api) do
        if type(value) == "function" then names[#names + 1] = key end
    end
    table.sort(names)

    for _, key in ipairs(names) do
        local ok, value = pcall(api[key])
        if ok then
            note(string.format("  %-26s -> %s", key .. "()", shapeOf(value)))
        else
            -- Needs arguments, or is not valid here. Either is worth seeing.
            note(string.format("  %-26s !! %s", key .. "()", tostring(value)))
        end
    end
    note("")
end

dumpValues("aero", aero)
dumpValues("sublevel", sublevel)

-- --- profile ----------------------------------------------------------------
local ok, pose = pcall(sublevel.getLogicalPose)
if not ok or not pose or not pose.position then
    error("cannot read craft pose", 0)
end
local origin = pose.position

local function pressureAt(y)
    local got, value = pcall(aero.getAirPressure,
        vector.new(origin.x, y, origin.z))
    if not got then
        return nil, tostring(value)
    end
    return value
end

local originPressure = pressureAt(origin.y)
if not originPressure then
    error("aero.getAirPressure failed at the craft origin", 0)
end

note("AIR PRESSURE PROFILE")
note(string.format("  origin   : %.3f %.3f %.3f", origin.x, origin.y, origin.z))
note(string.format("  pressure : %.8f", originPressure))
note(string.format("  target   : %.6f", targetPressure))
note("")

-- Dense near the craft where the propellers plausibly sit, sparse far out to
-- pin the scale height. Negative offsets included so the shape is measured
-- both ways rather than assumed monotonic.
local offsets = {
    -64, -32, -16, -8, -4, -2, -1,
    0,
    1, 2, 3, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 28, 32,
    48, 64, 96, 128, 192, 256, 384, 512,
}

local columns = { "y_offset", "world_y", "pressure", "ratio_to_origin" }
fs.makeDir(config.logDirectory)
local path = fs.combine(config.logDirectory,
    "airprofile_" .. tostring(os.epoch("utc")) .. ".csv")
local writer = csv.open(path, columns, 1)

local samples = {}
for _, offset in ipairs(offsets) do
    local y = origin.y + offset
    local pressure, reason = pressureAt(y)
    if pressure then
        samples[#samples + 1] = { offset = offset, pressure = pressure }
        writer.write({
            y_offset = offset,
            world_y = y,
            pressure = pressure,
            ratio_to_origin = pressure / originPressure,
        })
    else
        note(string.format("  %+7.1f  FAILED: %s", offset, tostring(reason)))
    end
end
writer.close()

note(string.format("  sampled %d altitudes", #samples))
note("")

-- Is it even exponential? Fit ln(P) = ln(P0) - dy/H and report r2, so an
-- atmosphere that is linear or capped shows up as a bad fit rather than as a
-- confidently wrong scale height.
local n, sx, sy, sxx, sxy = 0, 0, 0, 0, 0
for _, sample in ipairs(samples) do
    if sample.pressure > 0 then
        local x, y = sample.offset, math.log(sample.pressure)
        n = n + 1
        sx, sy = sx + x, sy + y
        sxx, sxy = sxx + x * x, sxy + x * y
    end
end

local scaleHeight, r2
if n >= 2 then
    local denominator = n * sxx - sx * sx
    if math.abs(denominator) > 1e-12 then
        local slope = (n * sxy - sx * sy) / denominator
        local intercept = (sy - slope * sx) / n

        local meanY, ssTot, ssRes = sy / n, 0, 0
        for _, sample in ipairs(samples) do
            if sample.pressure > 0 then
                local y = math.log(sample.pressure)
                ssTot = ssTot + (y - meanY) ^ 2
                ssRes = ssRes + (y - (intercept + slope * sample.offset)) ^ 2
            end
        end
        r2 = ssTot > 0 and (1 - ssRes / ssTot) or 1
        if slope < 0 then
            scaleHeight = -1 / slope
        end
    end
end

if scaleHeight then
    note(string.format("  exponential fit: H = %.1f blocks, r2 = %.6f",
        scaleHeight, r2 or 0))
    if (r2 or 0) < 0.99 then
        note("  WARNING: poor fit -- not a simple exponential. Use the CSV,")
        note("  not the scale height, when correcting thrust.")
    end
else
    note("  could not fit an exponential profile")
end
note("")

-- Where does the target pressure actually occur? Interpolate between real
-- samples rather than trusting the fit.
local found
for index = 2, #samples do
    local low, high = samples[index - 1], samples[index]
    local span = high.pressure - low.pressure
    if span ~= 0
        and ((low.pressure >= targetPressure and high.pressure <= targetPressure)
          or (low.pressure <= targetPressure and high.pressure >= targetPressure)) then
        local fraction = (targetPressure - low.pressure) / span
        found = low.offset + fraction * (high.offset - low.offset)
        break
    end
end

note("WHERE THE SWEEP'S IMPLIED PRESSURE OCCURS")
if found then
    note(string.format("  %.6f is reached %+.2f blocks from the origin",
        targetPressure, found))
    note("  If the propellers sit about there, air density at the PROP")
    note("  explains the sweep and the thrust model is settled.")
else
    note(string.format("  %.6f is outside the sampled range", targetPressure))
end
if scaleHeight then
    note(string.format("  exponential fit says %+.2f blocks",
        -scaleHeight * math.log(targetPressure / originPressure)))
end

note("")
note("csv    : " .. path)
note("report : /fcs/airprofile.txt")
writeReport("/fcs/airprofile.txt", report)
