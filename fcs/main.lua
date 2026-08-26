-- How this program is started decides whether it has require() at all.
-- shell.run and shell.openTab wrap a program in a shell env, which injects
-- require/package. multishell.launch goes straight to os.run() and injects
-- neither, so touching package.path there throws on a nil global. Build them
-- when missing, rooted at "/" so "fcs.x" resolves to /fcs/x.lua.
if package then
    package.path = "/?.lua;/?/init.lua;" .. package.path
else
    require, package = dofile("/rom/modules/main/cc/require.lua").make(_ENV, "/")
end

local config = require("fcs.config")
local sensors = require("fcs.sensors")
local devices = require("fcs.peripherals")
local csv = require("fcs.csv")
local banks = require("fcs.banks")
local network = require("fcs.network")
local atmosphere = require("fcs.atmosphere")
local snapshot = require("fcs.snapshot")

local CORNERS = { "FL", "FR", "RL", "RR" }

-- Each corner carries a counter-rotating pair. Fixed at 2 so the column
-- set is stable across runs: a corner that loses a bearing must leave an
-- empty cell, not silently shorten the row and shift every later column.
local BEARINGS_PER_CORNER = 2

local columns = {
    "schema_version", "sequence", "utc_ms", "dt_s", "valid", "errors",
    "craft_uuid", "craft_name",
    "position_x", "position_y", "position_z",
    "linear_world_x", "linear_world_y", "linear_world_z",
    "linear_body_x", "linear_body_y", "linear_body_z",
    "global_velocity_x", "global_velocity_y", "global_velocity_z",
    "quaternion_x", "quaternion_y", "quaternion_z", "quaternion_w",
    "roll_deg", "pitch_deg", "yaw_deg",
    "angular_world_x", "angular_world_y", "angular_world_z",
    "angular_body_x", "angular_body_y", "angular_body_z",
    "mass", "inverse_mass", "com_x", "com_y", "com_z",
    -- Sampled every Nth row (sensors.tensorEveryNth), so these columns are
    -- SPARSE by design -- blank means "not read this tick", not "zero".
    -- Present to settle whether the tensor is body- or world-frame: compare
    -- rows taken at different roll/pitch.
    "inertia_xx", "inertia_yy", "inertia_zz",
    "inertia_xy", "inertia_xz", "inertia_yz",
    "magnetic_north_x", "magnetic_north_y", "magnetic_north_z",
    "gravity_x", "gravity_y", "gravity_z", "air_pressure", "universal_drag",
}

for _, corner in ipairs(CORNERS) do
    local prefix = string.lower(corner)
    columns[#columns + 1] = prefix .. "_controller_present"
    columns[#columns + 1] = prefix .. "_bearing_present"
    columns[#columns + 1] = prefix .. "_target_rpm"
    columns[#columns + 1] = prefix .. "_controller_rpm"
    columns[#columns + 1] = prefix .. "_bearing_rpm"
    columns[#columns + 1] = prefix .. "_thrust"
    columns[#columns + 1] = prefix .. "_thrust_imbalance"
    columns[#columns + 1] = prefix .. "_airflow"
    columns[#columns + 1] = prefix .. "_sail_power"
    columns[#columns + 1] = prefix .. "_has_source"
    columns[#columns + 1] = prefix .. "_overstressed"
    columns[#columns + 1] = prefix .. "_active"

    -- Per-bearing thrust, because the corner aggregate sums MAGNITUDES and so
    -- cannot show one bearing of a pair underperforming its twin -- which is
    -- precisely the open RR question (bearing_5 reads ~1.1% under the other
    -- seven). Aggregates hid this once already; do not go back to them.
    for index = 1, BEARINGS_PER_CORNER do
        columns[#columns + 1] = prefix .. "_b" .. index .. "_thrust"
        columns[#columns + 1] = prefix .. "_b" .. index .. "_assembled"
    end
end

columns[#columns + 1] = "stored_fe"
columns[#columns + 1] = "capacity_fe"
columns[#columns + 1] = "grid_power"
columns[#columns + 1] = "grid_voltage"
columns[#columns + 1] = "grid_amperage"

for _, corner in ipairs(CORNERS) do
    local prefix = string.lower(corner) .. "_pod_"
    columns[#columns + 1] = prefix .. "online"
    columns[#columns + 1] = prefix .. "id"
    columns[#columns + 1] = prefix .. "armed"
    columns[#columns + 1] = prefix .. "current_power"
    columns[#columns + 1] = prefix .. "fallback_power"
    columns[#columns + 1] = prefix .. "healthy_thrusters"
    columns[#columns + 1] = prefix .. "expected_thrusters"
    columns[#columns + 1] = prefix .. "total_thrust_kn"
    columns[#columns + 1] = prefix .. "average_power"
    columns[#columns + 1] = prefix .. "energy_fe"
    columns[#columns + 1] = prefix .. "energy_capacity_fe"
    columns[#columns + 1] = prefix .. "obstructed_thrusters"
    columns[#columns + 1] = prefix .. "telemetry_age_ms"
    columns[#columns + 1] = prefix .. "faults"
end

local function putVector(row, prefix, value)
    if value then
        row[prefix .. "_x"] = value.x
        row[prefix .. "_y"] = value.y
        row[prefix .. "_z"] = value.z
    end
end

local function buildRow(sequence, timestamp, dt, state, peripheralState, podStates)
    local allErrors = {}
    for _, message in ipairs(state.errors or {}) do
        allErrors[#allErrors + 1] = message
    end
    for _, message in ipairs(peripheralState.errors or {}) do
        allErrors[#allErrors + 1] = message
    end

    local row = {
        schema_version = config.schemaVersion,
        sequence = sequence,
        utc_ms = timestamp,
        dt_s = dt,
        valid = state.valid and peripheralState.valid,
        errors = table.concat(allErrors, " | "),
        craft_uuid = state.uuid,
        craft_name = state.name,
        roll_deg = state.roll,
        pitch_deg = state.pitch,
        yaw_deg = state.yaw,
        mass = state.mass,
        inverse_mass = state.inverseMass,
        inertia_xx = state.inertia and state.inertia.xx,
        inertia_yy = state.inertia and state.inertia.yy,
        inertia_zz = state.inertia and state.inertia.zz,
        inertia_xy = state.inertia and state.inertia.xy,
        inertia_xz = state.inertia and state.inertia.xz,
        inertia_yz = state.inertia and state.inertia.yz,
        air_pressure = state.airPressure,
        universal_drag = state.universalDrag,
        stored_fe = peripheralState.energy,
        capacity_fe = peripheralState.energyCapacity,
        grid_power = peripheralState.gridPower,
        grid_voltage = peripheralState.gridVoltage,
        grid_amperage = peripheralState.gridAmperage,
    }

    putVector(row, "position", state.position)
    putVector(row, "linear_world", state.linearVelocityWorld)
    putVector(row, "linear_body", state.linearVelocityBody)
    putVector(row, "global_velocity", state.globalVelocityWorld)
    putVector(row, "angular_world", state.angularVelocityWorld)
    putVector(row, "angular_body", state.angularVelocityBody)
    putVector(row, "com", state.centerOfMass)
    putVector(row, "magnetic_north", state.magneticNorth)
    putVector(row, "gravity", state.gravityWorld)

    if state.quaternion then
        row.quaternion_x = state.quaternion.x
        row.quaternion_y = state.quaternion.y
        row.quaternion_z = state.quaternion.z
        row.quaternion_w = state.quaternion.w
    end

    for _, corner in ipairs(CORNERS) do
        local prop = peripheralState.props[corner] or {}
        local prefix = string.lower(corner) .. "_"
        row[prefix .. "controller_present"] = prop.controllerPresent
        row[prefix .. "bearing_present"] = prop.bearingPresent
        row[prefix .. "target_rpm"] = prop.targetRpm
        row[prefix .. "controller_rpm"] = prop.controllerRpm
        row[prefix .. "bearing_rpm"] = prop.bearingRpm
        row[prefix .. "thrust"] = prop.thrust
        row[prefix .. "thrust_imbalance"] = prop.thrustImbalance
        row[prefix .. "airflow"] = prop.airflow
        row[prefix .. "sail_power"] = prop.sailPower
        row[prefix .. "has_source"] = prop.hasSource
        row[prefix .. "overstressed"] = prop.overstressed
        row[prefix .. "active"] = prop.active

        local perBearing = prop.perBearing or {}
        for index = 1, BEARINGS_PER_CORNER do
            local bearing = perBearing[index] or {}
            row[prefix .. "b" .. index .. "_thrust"] = bearing.thrust
            row[prefix .. "b" .. index .. "_assembled"] = bearing.assembled
        end

        local pod = podStates[corner] or {}
        local podPrefix = string.lower(corner) .. "_pod_"
        row[podPrefix .. "online"] = pod.online
        row[podPrefix .. "id"] = pod.podId
        row[podPrefix .. "armed"] = pod.armed
        row[podPrefix .. "current_power"] = pod.currentPower
        row[podPrefix .. "fallback_power"] = pod.fallbackPower
        row[podPrefix .. "healthy_thrusters"] = pod.healthyThrusters
        row[podPrefix .. "expected_thrusters"] = pod.expectedThrusters
        row[podPrefix .. "total_thrust_kn"] = pod.totalThrustKN
        row[podPrefix .. "average_power"] = pod.averagePower
        row[podPrefix .. "energy_fe"] = pod.energyFE
        row[podPrefix .. "energy_capacity_fe"] = pod.energyCapacityFE
        row[podPrefix .. "obstructed_thrusters"] = pod.obstructedThrusters
        row[podPrefix .. "telemetry_age_ms"] = pod.receivedAt and timestamp - pod.receivedAt or nil
        row[podPrefix .. "faults"] = type(pod.faults) == "table" and table.concat(pod.faults, " | ") or pod.faults
    end

    return row
end

local function draw(state, peripheralState, podStates, path, sequence)
    term.clear()
    term.setCursorPos(1, 1)
    print("HELICARRIER DATA FOUNDATION")
    print("Logging: " .. path)
    print("Samples: " .. sequence)
    local valid = state.valid and peripheralState.valid
    print("State: " .. (valid and "VALID" or "INVALID"))

    if state.position then
        print(string.format("XYZ: %.2f  %.2f  %.2f", state.position.x, state.position.y, state.position.z))
    end
    if state.roll then
        print(string.format("R/P/Y: %+.3f  %+.3f  %6.2f", state.roll, state.pitch, state.yaw))
    end
    if state.linearVelocityBody then
        print(string.format("BODY V: %+.3f  %+.3f  %+.3f", state.linearVelocityBody.x, state.linearVelocityBody.y, state.linearVelocityBody.z))
    end

    local errorCount = #(state.errors or {}) + #(peripheralState.errors or {})
    print("Errors: " .. errorCount)
    local podSummary = {}
    for _, corner in ipairs(CORNERS) do
        podSummary[#podSummary + 1] = corner .. ":" .. (podStates[corner].online and "UP" or "--")
    end
    print("Pods: " .. table.concat(podSummary, " "))
    print("")
    print("Ctrl+T stops logging. No outputs are commanded.")
end

fs.makeDir(config.logDirectory)

-- Logs are named flight_<utc ms>.csv, so lexicographic order is chronological
-- for as long as the timestamp keeps its digit count -- which it does for the
-- next several centuries.
local function existingLogs()
    local names = {}
    for _, name in ipairs(fs.list(config.logDirectory)) do
        if name:match("^flight_%d+%.csv$") then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

local function pruneLogs(keep)
    local names = existingLogs()
    for index = 1, #names - keep do
        pcall(fs.delete, fs.combine(config.logDirectory, names[index]))
    end
end

local function openLog()
    -- Make room for the file about to be written, not merely for the ones
    -- already there: keep one fewer than the budget.
    pruneLogs(math.max(0, (config.maxLogFiles or 3) - 1))
    local startedAt = os.epoch("utc")
    local logPath = fs.combine(config.logDirectory,
        "flight_" .. tostring(startedAt) .. ".csv")
    return csv.open(logPath, columns, config.flushEveryRows), logPath, startedAt
end

local writer, path, startedAt = openLog()

local sequence = 0
local previousTimestamp = startedAt

-- Read the atmosphere ONCE. getPoints() hands back the whole pressure curve --
-- five control points -- so every later pressure lookup is local arithmetic
-- instead of a ~50 ms Sable call inside the sample loop.
--
-- Degrades rather than failing: nil here just means sensors.read falls back to
-- aero.getAirPressure, which is what it did before. A missing atmosphere must
-- not stop the logger.
local atmosphereModel, atmosphereReason = atmosphere.load()
if atmosphereModel then
    print(string.format("atmosphere: %d control points, ceiling y=%.0f%s",
        #atmosphereModel.points, atmosphereModel.ceiling,
        atmosphereModel.scaleHeight
            and string.format(", H=%.0f below y=%.0f",
                atmosphereModel.scaleHeight, atmosphereModel.exponentialTo)
            or ""))
else
    print("atmosphere: unavailable (" .. tostring(atmosphereReason)
        .. "); falling back to aero.getAirPressure per sample")
end

-- The telemetry program runs in a background tab, where a crash is invisible
-- unless someone happens to switch to it. Record it instead.
local function writeReport(path, lines)
    local ok, file = pcall(fs.open, path, "w")
    if ok and file then
        file.write(table.concat(lines, "\n"))
        file.close()
    end
end

local function sample()
    local timestamp = os.epoch("utc")
    local dt = (timestamp - previousTimestamp) / 1000
    previousTimestamp = timestamp
    sequence = sequence + 1

    local state = sensors.read(config, atmosphereModel)
    -- Receiving happens in the listener coroutine; this only does the periodic
    -- status requests and offline marking.
    banks.tick()
    local podStates = banks.getState()
    local peripheralState = devices.read(config, podStates)
    writer.write(buildRow(sequence, timestamp, dt, state, peripheralState, podStates))
    draw(state, peripheralState, podStates, path, sequence)

    -- Hand the monitor hub a frame. Wrapped, because a rendering-side bug must
    -- never be able to stop logging: this loop is the only thing on the
    -- computer that talks to Sable and to the pods, and it keeps running even
    -- if nothing is watching.
    local published = pcall(function()
        snapshot.publish(snapshot.build({
            sequence = sequence,
            timestamp = timestamp,
            dt = dt,
            state = state,
            peripheralState = peripheralState,
            podStates = podStates,
            netStats = banks.stats,
            log = {
                path = path,
                bytes = writer.bytes(),
                samples = sequence,
                targetHz = config.samplePeriodSeconds > 0
                    and 1 / config.samplePeriodSeconds or nil,
                actualHz = dt > 0 and 1 / dt or nil,
                freeSpace = fs.getFreeSpace("/"),
            },
        }))
    end)
    if not published then
        snapshot.failures = snapshot.failures + 1
    end

    if sequence % 8 == 1 then
        local st = banks.stats
        local ages = {}
        for _, corner in ipairs(CORNERS) do
            local pod = podStates[corner]
            ages[#ages + 1] = corner .. "=" ..
                tostring(pod.receivedAt and (timestamp - pod.receivedAt) or "never")
        end
        writeReport("/fcs/heartbeat.txt", {
            "utc_ms=" .. tostring(timestamp),
            "sequence=" .. tostring(sequence),
            "snapshot_publishes=" .. tostring(snapshot.publishes),
            "snapshot_failures=" .. tostring(snapshot.failures),
            "snapshot_last_error=" .. tostring(snapshot.lastError),
            "modem=" .. tostring(network.openedModem),
            "rednet_open=" .. tostring(network.openedModem and rednet.isOpen(network.openedModem)),
            "msgs_seen=" .. tostring(st.seen),
            "accepted=" .. tostring(st.accepted),
            "bad_protocol=" .. tostring(st.badProtocol),
            "wrong_type=" .. tostring(st.wrongType),
            "unknown_corner=" .. tostring(st.unknownCorner),
            "hostname_mismatch=" .. tostring(st.hostnameMismatch),
            "sender_mismatch=" .. tostring(st.senderMismatch),
            "per_corner=" .. string.format("FL=%d FR=%d RL=%d RR=%d",
                st.perCorner.FL, st.perCorner.FR, st.perCorner.RL, st.perCorner.RR),
            "ages_ms=" .. table.concat(ages, " "),
            "net_errors=" .. table.concat(network.errors, " | "),
        })
    end

    if config.maxLogBytes and writer.bytes() >= config.maxLogBytes then
        writer.close()
        writer, path = openLog()
    end

    sleep(config.samplePeriodSeconds)
end

-- The sample loop spends most of its time blocked inside sublevel API calls,
-- and CC drops events that do not match a filtered wait -- so anything received
-- on that coroutine is lost. The listener gets its own coroutine and its own
-- filter, which is exactly how the pods manage to hear us reliably.
local function listenLoop()
    while true do
        if not banks.listen(1) then
            -- listen() returns false on timeout or when the modem is missing;
            -- yield briefly so a closed modem cannot spin this loop.
            sleep(0.05)
        end
    end
end

local function sampleLoop()
    while true do
        sample()
    end
end

local ok, reason = pcall(function()
    parallel.waitForAny(sampleLoop, listenLoop)
end)

writeReport("/fcs/last_error.txt", {
    "utc_ms=" .. tostring(os.epoch("utc")),
    "outcome=" .. (ok and "loop returned without error" or "error"),
    "reason=" .. tostring(reason),
    "sequence=" .. tostring(sequence),
    "log=" .. tostring(path),
})

writer.close()
if not ok then
    error(reason, 0)
end
