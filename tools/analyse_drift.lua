-- What actually rotates the tilt vector? Read it off the flight CSVs.
--
--     luajit tools/analyse_drift.lua flight-logs/rolldrift_run2/*.csv
--     luajit tools/analyse_drift.lua --dense flight-logs/axisresponse_run4/*.csv
--
-- WHY THIS EXISTS. The craft drifts, and the drift CURVES -- the velocity
-- heading swept -225 degrees in 47 s. The recorded explanation was "roll and
-- pitch oscillate OUT OF PHASE, so the tilt vector rotates", and half of it
-- died on 2026-08-27: the pitch flight measured pitch as OVERDAMPED. It does
-- not ring, so it cannot be the second oscillator.
--
-- Something still rotates the tilt vector. This asks the CSVs, which have
-- carried roll, pitch, yaw and world velocity all along.
--
-- THE FOUR CANDIDATES, and what each one looks like in the numbers:
--
--   YAW ARTIFACT      the craft turns while drifting straight. Then the
--                     BODY-frame velocity heading sweeps and the WORLD-frame
--                     one does not, and yaw sweeps as far as the heading does.
--
--   ZERO CROSSING     the tilt magnitude decays through zero, and atan2 of a
--                     vector passing near the origin swings wildly for free.
--                     Then minimum tilt magnitude is small next to the mean.
--
--   QUADRATURE        both axes oscillate at ONE frequency, a quarter cycle
--                     apart. The recorded story. Then the two periods match
--                     and the tilt direction advances at that frequency.
--
--   TWO FREQUENCIES   the axes oscillate at DIFFERENT rates, and the tilt
--                     vector traces a Lissajous figure whose direction can
--                     still sweep monotonically. Then the periods differ.
--
-- Every one of them is a number below. Nothing here is fitted to a model:
-- periods come from zero crossings of each axis about its own mean, and the
-- sweeps come from unwrapping.

package.path = "./?.lua;./?/init.lua;" .. package.path

-- ---------------------------------------------------------------------------
-- THE ANGLE COLUMNS IN AN OLD CSV CANNOT BE TRUSTED, AND THIS IS NOT A
-- HYPOTHETICAL. attitude.lua once assumed +X forward and reported roll and
-- pitch TRANSPOSED. Flights either side of that fix are both in flight-logs/,
-- and nothing in the file says which is which.
--
-- So every angle here is RECOMPUTED from `quaternion_*`, which is raw sensor
-- output and cannot be wrong, using the current fcs/attitude.lua. The logged
-- columns are then compared against it and any disagreement is reported. On
-- flight-logs/rolldrift_run2 -- the passive drift flight this whole document's
-- drift analysis rests on -- the recomputed ROLL equals the logged PITCH to
-- 0.0000 degrees. Those columns are transposed, and every conclusion drawn
-- from them has the two axes swapped.
-- ---------------------------------------------------------------------------

local attitude = require("fcs.attitude")
local config = require("fcs.config")

local GROUND_Y = -26.58
local AIRBORNE_GAIN = 0.6
local MOVING = 0.20          -- blocks/s below which a heading is noise
local TILT_FLOOR = 0.30      -- degrees below which a tilt direction is noise

local dense = false
local paths = {}
for _, argument in ipairs({ ... }) do
    if argument == "--dense" then dense = true else paths[#paths + 1] = argument end
end

-- ---------------------------------------------------------------------------
-- Reading
-- ---------------------------------------------------------------------------

local function split(line)
    local fields, position = {}, 1
    while true do
        local comma = line:find(",", position, true)
        if not comma then fields[#fields + 1] = line:sub(position) break end
        fields[#fields + 1] = line:sub(position, comma - 1)
        position = comma + 1
    end
    return fields
end

local function readCsv(path, rows)
    local file = io.open(path, "r")
    if not file then return end
    local header = file:read("*l")
    if not header then file:close() return end
    local index = {}
    for position, name in ipairs(split(header)) do index[name] = position end
    -- A CSV whose columns moved is not a CSV to guess at.
    if not (index.utc_ms and index.roll_deg and index.pitch_deg) then
        file:close()
        return
    end
    local transposed, agreeing, total = 0, 0, 0
    for line in file:lines() do
        local fields = split(line)
        local function number(name)
            return tonumber(fields[index[name] or -1])
        end
        if fields[index.valid or -1] == "true" then
            local t = number("utc_ms")
            local roll, pitch = number("roll_deg"), number("pitch_deg")
            local y = number("position_y")

            -- RECOMPUTED FROM THE QUATERNION, always. The logged columns are
            -- only ever used to decide whether this file was written by code
            -- that had the axes right.
            local quaternion = {
                x = number("quaternion_x"), y = number("quaternion_y"),
                z = number("quaternion_z"), w = number("quaternion_w"),
            }
            if quaternion.x and quaternion.w then
                local ok, derived =
                    pcall(attitude.fromQuaternion, quaternion, config.axes)
                if ok and derived and derived.roll then
                    if roll and pitch then
                        total = total + 1
                        if math.abs(derived.roll - roll) < 0.01 then
                            agreeing = agreeing + 1
                        elseif math.abs(derived.roll - pitch) < 0.01 then
                            transposed = transposed + 1
                        end
                    end
                    roll, pitch = derived.roll, derived.pitch
                    number = function(name)
                        if name == "yaw_deg" then return derived.yaw end
                        return tonumber(fields[index[name] or -1])
                    end
                end
            end

            if t and roll and pitch and y then
                rows[#rows + 1] = {
                    t = t / 1000,
                    roll = roll, pitch = pitch, yaw = number("yaw_deg") or 0,
                    y = y,
                    vx = number("linear_world_x") or 0,
                    vz = number("linear_world_z") or 0,
                    px = number("position_x") or 0,
                    pz = number("position_z") or 0,
                }
            end
        end
    end
    file:close()

    if total > 0 then
        local label = path:gsub(".*/", "")
        if transposed > total * 0.5 then
            print(string.format("  ** %s: the logged angle columns are TRANSPOSED"
                .. " (%d/%d samples).", label, transposed, total))
            print("  ** Recomputed roll equals logged PITCH. Written before the axis")
            print("  ** fix; the numbers below use the quaternion, not those columns.")
        elseif agreeing < total * 0.5 then
            print(string.format("  ** %s: the logged angles match NEITHER the current"
                .. " code nor a", label))
            print("  ** transposition. Using the quaternion; treat with suspicion.")
        end
    end
end

local rows = {}
for _, path in ipairs(paths) do readCsv(path, rows) end
table.sort(rows, function(a, b) return a.t < b.t end)
if #rows == 0 then
    print("no usable rows -- check the paths and that the CSVs carry roll_deg")
    return
end
local t0 = rows[1].t
for _, row in ipairs(rows) do row.t = row.t - t0 end

-- ---------------------------------------------------------------------------
-- The window: airborne and actually moving. Everything else is a grounded
-- craft reporting 0.001 degrees, and averaging that in flatters every number.
-- ---------------------------------------------------------------------------

local window = {}
for _, row in ipairs(rows) do
    row.speed = math.sqrt(row.vx * row.vx + row.vz * row.vz)
    row.tilt = math.sqrt(row.roll * row.roll + row.pitch * row.pitch)
    if (row.y - GROUND_Y) > AIRBORNE_GAIN and row.speed > MOVING then
        window[#window + 1] = row
    end
end

print(string.format("%d samples, %d airborne and moving, over %.0f s",
    #rows, #window, rows[#rows].t))
if #window < 8 then
    print("too little airborne data to say anything")
    return
end
print(string.format("window %.1f -> %.1f s, mean dt %.2f s",
    window[1].t, window[#window].t,
    (window[#window].t - window[1].t) / (#window - 1)))
print("")

-- ---------------------------------------------------------------------------
-- Unwrapping
-- ---------------------------------------------------------------------------

local function unwrap(values)
    local out, previous, accumulated = {}, nil, 0
    for _, value in ipairs(values) do
        if previous then
            local delta = value - previous
            while delta > 180 do delta = delta - 360 end
            while delta < -180 do delta = delta + 360 end
            accumulated = accumulated + delta
        else
            accumulated = value
        end
        out[#out + 1] = accumulated
        previous = value
    end
    return out
end

local function sweepOf(values)
    if #values < 2 then return nil end
    local unwrapped = unwrap(values)
    return unwrapped[#unwrapped] - unwrapped[1], unwrapped
end

-- Velocity heading in WORLD axes, and the tilt direction in HULL axes.
local worldHeading, tiltDirection, bodyHeading = {}, {}, {}
for _, row in ipairs(window) do
    worldHeading[#worldHeading + 1] = math.deg(math.atan2(row.vx, row.vz))
    if row.tilt > TILT_FLOOR then
        tiltDirection[#tiltDirection + 1] = math.deg(math.atan2(row.roll, row.pitch))
    end
    -- The same velocity seen from the hull: world heading minus yaw. This is
    -- what separates a craft that turns from a craft whose drift turns.
    bodyHeading[#bodyHeading + 1] =
        math.deg(math.atan2(row.vx, row.vz)) - row.yaw
end

-- THE SAME TRAP THE TILT VECTOR HAS, ON THE VELOCITY VECTOR. A heading is the
-- atan2 of a vector, and a vector whose magnitude collapses swings its heading
-- for free. The passive drift window decays from 7.4 blocks/s to 0.2, so the
-- last samples are a near-zero vector being asked which way it points.
--
-- So the sweep is reported twice: over everything, and over only the samples
-- moving faster than a quarter of the window's mean. If the two disagree, the
-- headline number was measuring the decay.
local fastHeading, fastSeconds = {}, 0
do
    local total = 0
    for _, row in ipairs(window) do total = total + row.speed end
    local floor = (total / #window) * 0.25
    local firstFast, lastFast
    for _, row in ipairs(window) do
        if row.speed >= floor then
            fastHeading[#fastHeading + 1] = math.deg(math.atan2(row.vx, row.vz))
            firstFast = firstFast or row.t
            lastFast = row.t
        end
    end
    fastSeconds = (lastFast and firstFast) and (lastFast - firstFast) or 0
end

local headingSweep = sweepOf(worldHeading)
local tiltSweep = sweepOf(tiltDirection)
local bodySweep = sweepOf(bodyHeading)
local yawValues = {}
for _, row in ipairs(window) do yawValues[#yawValues + 1] = row.yaw end
local yawSweep = sweepOf(yawValues)

local seconds = window[#window].t - window[1].t

print("== THE SWEEPS ==")
print(string.format("  velocity heading, WORLD   %+8.1f deg   (%+.2f deg/s)",
    headingSweep or 0, (headingSweep or 0) / seconds))
print(string.format("  velocity heading, HULL    %+8.1f deg", bodySweep or 0))
print(string.format("  tilt direction,   HULL    %+8.1f deg   (%+.2f deg/s)",
    tiltSweep or 0, (tiltSweep or 0) / seconds))
print(string.format("  yaw                       %+8.1f deg", yawSweep or 0))

local fastSweep = sweepOf(fastHeading)
if fastSweep and #fastHeading >= 4 then
    print(string.format("  velocity heading, WORLD   %+8.1f deg over the %d samples"
        .. " above a quarter", fastSweep, #fastHeading))
    print(string.format("                                       of mean speed (%.0f s)"
        .. "  (%+.2f deg/s)", fastSeconds,
        fastSeconds > 0 and (fastSweep / fastSeconds) or 0))
    if headingSweep and math.abs(headingSweep) > 30 then
        local share = fastSweep / headingSweep
        if share < 0.7 then
            print(string.format("  ** %.0f%% OF THE SWEEP IS IN THE SLOW TAIL. The velocity"
                .. " vector decays", (1 - share) * 100))
            print("  ** toward zero and its heading swings for free -- the headline")
            print("  ** number is partly the decay, not a curve.")
        end
    end
end
print("")

-- CANDIDATE 1: is it just yaw?
if math.abs(headingSweep or 0) > 30 then
    local share = math.abs((yawSweep or 0) / headingSweep)
    if share > 0.5 then
        print(string.format("  YAW ARTIFACT: yaw accounts for %.0f%% of the heading sweep.",
            share * 100))
        print("  The craft is TURNING, not curving. A world-frame drift that is")
        print("  straight looks curved from the hull.")
    else
        print(string.format("  NOT A YAW ARTIFACT: yaw moved %.1f deg against %.1f of heading"
            .. " (%.0f%%).", yawSweep or 0, headingSweep, share * 100))
        print("  The velocity really does rotate in the WORLD frame.")
    end
end
print("")

-- CANDIDATE 2: is the tilt vector passing through zero?
local minTilt, maxTilt, meanTilt = math.huge, 0, 0
for _, row in ipairs(window) do
    if row.tilt < minTilt then minTilt = row.tilt end
    if row.tilt > maxTilt then maxTilt = row.tilt end
    meanTilt = meanTilt + row.tilt
end
meanTilt = meanTilt / #window

local minSpeed, maxSpeed, meanSpeed = math.huge, 0, 0
for _, row in ipairs(window) do
    if row.speed < minSpeed then minSpeed = row.speed end
    if row.speed > maxSpeed then maxSpeed = row.speed end
    meanSpeed = meanSpeed + row.speed
end
meanSpeed = meanSpeed / #window
print(string.format("== THE VELOCITY ==   min %.2f  mean %.2f  max %.2f blocks/s",
    minSpeed, meanSpeed, maxSpeed))
print("")

print("== THE TILT VECTOR ==")
print(string.format("  magnitude  min %.2f  mean %.2f  max %.2f deg",
    minTilt, meanTilt, maxTilt))
if minTilt < meanTilt * 0.15 then
    print("  ** THE VECTOR PASSES NEAR THE ORIGIN. atan2 of a vector through zero")
    print("  ** sweeps for free -- the direction sweep above may be an artifact of")
    print("  ** the magnitude decaying, not a precession.")
else
    print(string.format("  it never comes near zero (min is %.0f%% of the mean), so the",
        minTilt / meanTilt * 100))
    print("  direction sweep is a real rotation and not an atan2 artifact.")
end
print("")

-- ---------------------------------------------------------------------------
-- CANDIDATES 3 and 4: one frequency or two?
--
-- Period from zero crossings ABOUT EACH AXIS'S OWN MEAN. The standing offset
-- is a few tenths and it is not the oscillation; measuring crossings of zero
-- rather than of the mean counts the offset as signal.
-- ---------------------------------------------------------------------------

local function oscillation(field)
    local values, total = {}, 0
    for _, row in ipairs(window) do
        values[#values + 1] = row[field]
        total = total + row[field]
    end
    local mean = total / #values

    local low, high = math.huge, -math.huge
    for _, value in ipairs(values) do
        if value < low then low = value end
        if value > high then high = value end
    end
    local amplitude = (high - low) / 2
    -- Hysteresis at a tenth of the amplitude: a trace that has decayed jitters
    -- across its mean and every one of those is a crossing to a naive counter.
    local floor = math.max(0.15, amplitude * 0.10)

    local times, armed, previous = {}, nil, nil
    for index, row in ipairs(window) do
        local deviation = values[index] - mean
        if math.abs(deviation) >= floor then
            local sign = deviation > 0 and 1 or -1
            if armed and sign ~= armed and previous then
                -- interpolate the crossing
                local span = deviation - previous.deviation
                local fraction = math.abs(span) > 1e-9
                    and (-previous.deviation / span) or 0
                times[#times + 1] = previous.t + fraction * (row.t - previous.t)
            end
            armed = sign
            previous = { t = row.t, deviation = deviation }
        end
    end

    local period, spread
    if #times >= 2 then
        local gaps, sum = {}, 0
        for index = 2, #times do
            gaps[#gaps + 1] = times[index] - times[index - 1]
            sum = sum + gaps[#gaps]
        end
        local meanGap = sum / #gaps
        period = meanGap * 2
        local lo, hi = math.huge, -math.huge
        for _, gap in ipairs(gaps) do
            if gap < lo then lo = gap end
            if gap > hi then hi = gap end
        end
        spread = meanGap > 0 and ((hi - lo) / meanGap) or nil
    end
    return {
        mean = mean, low = low, high = high, amplitude = amplitude,
        crossings = #times, period = period, spread = spread,
    }
end

local roll, pitch = oscillation("roll"), oscillation("pitch")

print("== THE TWO AXES ==")
print("           mean      range            amplitude  crossings  period")
for _, entry in ipairs({ { "roll", roll }, { "pitch", pitch } }) do
    local name, axis = entry[1], entry[2]
    print(string.format("  %-6s %+7.3f   %+6.2f .. %+6.2f   %7.3f   %6d    %s%s",
        name, axis.mean, axis.low, axis.high, axis.amplitude, axis.crossings,
        axis.period and string.format("%.1f s", axis.period) or "-",
        axis.spread and string.format("  (spread %.0f%%)", axis.spread * 100) or ""))
end
print("")

if roll.period and pitch.period then
    local ratio = roll.period / pitch.period
    print(string.format("  PERIOD RATIO roll/pitch = %.2f", ratio))
    if math.abs(ratio - 1) < 0.25 then
        print("  ONE FREQUENCY. The two axes ring together, so a phase offset")
        print("  between them rotates the tilt vector -- the recorded explanation.")
    else
        print("  TWO DIFFERENT FREQUENCIES. The axes do NOT ring together, so the")
        print("  tilt vector traces a Lissajous figure rather than a circle. Its")
        print("  direction can still sweep monotonically, which is what the")
        print("  heading sees -- but 'out of phase' is the wrong description and")
        print("  a damper tuned to one period is wrong for the other.")
        local expected = math.sqrt(389383646.66 / 86772714.93)
        print(string.format("  For reference: equal restoring TORQUE would make pitch %.2fx",
            expected))
        print("  SLOWER than roll, from the inertia ratio alone.")
    end
    print("")
end

-- ---------------------------------------------------------------------------
-- DOES THE VELOCITY FOLLOW THE TILT, AND HOW FAR BEHIND?
--
-- It must, if lift is what pushes the craft: lift points along the hull's up
-- axis, so where the hull leans is where the craft accelerates. But it cannot
-- follow instantly -- drag sets the time constant, and 1/0.09 is about 11 s.
--
-- Comparing NET SWEEPS is the wrong test and gave the wrong answer first time:
-- over the passive window the tilt winds forward and then unwinds while the
-- velocity, still catching up, does not -- which read as the velocity rotating
-- 1.6x faster than the thing driving it. Correlating the two RATES at a range
-- of lags asks the real question.
-- ---------------------------------------------------------------------------

local function rates(unwrapped, times)
    local out = {}
    for index = 2, #unwrapped do
        local dt = times[index] - times[index - 1]
        out[#out + 1] = dt > 0 and ((unwrapped[index] - unwrapped[index - 1]) / dt) or 0
    end
    return out
end

if headingSweep and tiltSweep and math.abs(tiltSweep) > 30 then
    local _, headingUnwrapped = sweepOf(worldHeading)
    local _, tiltUnwrapped = sweepOf(tiltDirection)
    -- The tilt series drops samples below the tilt floor, so only compare when
    -- the two are the same length -- anything else is aligning two different
    -- clocks and calling the result physics.
    if headingUnwrapped and tiltUnwrapped
        and #headingUnwrapped == #tiltUnwrapped then
        local times = {}
        for _, row in ipairs(window) do times[#times + 1] = row.t end
        local headingRate = rates(headingUnwrapped, times)
        local tiltRate = rates(tiltUnwrapped, times)

        local function correlate(shift)
            local n, sx, sy, sxx, syy, sxy = 0, 0, 0, 0, 0, 0
            for index = 1, #tiltRate - shift do
                local x, y = tiltRate[index], headingRate[index + shift]
                n = n + 1
                sx, sy = sx + x, sy + y
                sxx, syy, sxy = sxx + x * x, syy + y * y, sxy + x * y
            end
            if n < 6 then return nil end
            local numerator = n * sxy - sx * sy
            local denominator = math.sqrt((n * sxx - sx * sx) * (n * syy - sy * sy))
            if denominator < 1e-9 then return nil end
            return numerator / denominator
        end

        local dt = (window[#window].t - window[1].t) / (#window - 1)
        local best, bestShift = nil, 0
        for shift = 0, math.min(20, math.floor(#tiltRate / 2)) do
            local r = correlate(shift)
            if r and (not best or r > best) then best, bestShift = r, shift end
        end
        if best then
            print(string.format("  the velocity follows the tilt best at a lag of"
                .. " %.1f s (r = %.2f)", bestShift * dt, best))
            print(string.format("  drag alone implies about %.0f s (1 / universalDrag)",
                1 / 0.09))
            if best > 0.5 then
                print("  THE TILT IS STEERING THE CRAFT. Nothing else needs to be")
                print("  invoked to explain the curve.")
            else
                print("  ** THE TWO ARE NOT WELL CORRELATED AT ANY LAG. Something other")
                print("  ** than hull tilt is steering, and it is worth finding.")
            end
        end
    end
    print("")
    print(string.format("  (net sweeps: heading %+.1f, tilt direction %+.1f -- these are"
        .. " NOT", headingSweep, tiltSweep))
    print("  expected to match when the tilt reverses inside the window and the")
    print("  velocity is still catching up.)")
    print("")
end

if dense then
    print("== THE WINDOW ==")
    print(string.format("%8s %8s %8s %8s %7s %8s %8s %8s",
        "t", "roll", "pitch", "yaw", "|v|", "vHead", "tiltDir", "tiltMag"))
    for _, row in ipairs(window) do
        local heading = math.deg(math.atan2(row.vx, row.vz))
        local direction = row.tilt > TILT_FLOOR
            and math.deg(math.atan2(row.roll, row.pitch)) or nil
        print(string.format("%8.1f %8.3f %8.3f %8.2f %7.3f %8.1f %8s %8.3f",
            row.t, row.roll, row.pitch, row.yaw, row.speed, heading,
            direction and string.format("%.1f", direction) or "-", row.tilt))
    end
end
