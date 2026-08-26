-- The interface between the telemetry loop and the monitor hub.
--
-- build() takes the three tables fcs/main.lua already holds each sample and
-- returns a fresh frame. It reads nothing itself: there is exactly one place
-- on this computer that talks to CC:Sable and to the pods, and it is the
-- sample loop. A second reader would duplicate ~50 ms of Sable calls on a loop
-- that already cannot hold its declared period.
--
-- Everything is COPIED. banks.acceptStatus writes into its pod tables in place
-- on every message that lands, so a frame that held references would tear
-- halfway through a render -- roll from one tick, thrust from the next.
--
-- build() above is pure and runs anywhere. Below it is the ComputerCraft-
-- facing half, publish()/read(): it guards every CC global it touches so
-- this module still loads under plain luajit and tools/test_snapshot.lua
-- can exercise both halves off-server.

local snapshot = {}

snapshot.VERSION = 1

snapshot.CORNERS = { "FL", "FR", "RL", "RR" }

-- Fixed at 2, matching BEARINGS_PER_CORNER in fcs/main.lua: a corner that
-- loses a bearing must leave an empty slot, not silently shorten the row.
snapshot.BEARINGS_PER_CORNER = 2

local function copyVector(vector)
    if type(vector) ~= "table" then
        return nil
    end
    return { x = vector.x, y = vector.y, z = vector.z }
end

local function copyList(list)
    local out = {}
    if type(list) == "table" then
        for index, value in ipairs(list) do
            out[index] = value
        end
    elseif type(list) == "string" and list ~= "" then
        -- A pod that reports a single fault as a bare string still belongs on
        -- the wall.
        out[1] = list
    end
    return out
end

local function buildCraft(state)
    state = state or {}
    return {
        uuid = state.uuid,
        name = state.name,
        position = copyVector(state.position),
        roll = state.roll,
        pitch = state.pitch,
        yaw = state.yaw,
        bodyVel = copyVector(state.linearVelocityBody),
        worldVel = copyVector(state.linearVelocityWorld),
        angVel = copyVector(state.angularVelocityBody),
        mass = state.mass,
        airPressure = state.airPressure,
    }
end

local function buildCorner(prop)
    prop = prop or {}
    local bearings = {}
    local source = type(prop.perBearing) == "table" and prop.perBearing or {}
    for index = 1, snapshot.BEARINGS_PER_CORNER do
        local bearing = source[index] or {}
        bearings[index] = {
            thrust = bearing.thrust,
            assembled = bearing.assembled,
        }
    end

    return {
        controllerPresent = prop.controllerPresent,
        bearingPresent = prop.bearingPresent,
        controllerName = prop.controllerName,
        bearingName = prop.bearingName,
        targetRpm = prop.targetRpm,
        controllerRpm = prop.controllerRpm,
        bearingRpm = prop.bearingRpm,
        thrust = prop.thrust,
        thrustImbalance = prop.thrustImbalance,
        airflow = prop.airflow,
        sailPower = prop.sailPower,
        hasSource = prop.hasSource,
        overstressed = prop.overstressed,
        active = prop.active,
        bearings = bearings,
        -- PRODUCER-SIDE NAME IS tiltAngle. pod-template/pod/props.lua publishes
        -- result.tiltAngle (mean tilt across the corner's bearings, degrees);
        -- fcs/actuators.lua and fcs/tiltctl.lua read prop.tiltAngle too. There
        -- is no prop.tilt anywhere -- do not "tidy" this back. The FRAME-side
        -- name stays "tilt": fcs/hub/zones/engines.lua reads corner.tilt.
        tilt = prop.tiltAngle,
    }
end

local function buildPod(pod, timestamp)
    pod = pod or {}
    local ageMs = nil
    if type(pod.receivedAt) == "number" and type(timestamp) == "number" then
        ageMs = timestamp - pod.receivedAt
    end

    return {
        corner = pod.corner,
        hostname = pod.hostname,
        online = pod.online == true,
        podId = pod.podId,
        armed = pod.armed,
        currentPower = pod.currentPower,
        fallbackPower = pod.fallbackPower,
        commandedTilt = pod.commandedTilt,
        commandedTiltAzimuth = pod.commandedTiltAzimuth,
        healthyThrusters = pod.healthyThrusters,
        expectedThrusters = pod.expectedThrusters,
        obstructedThrusters = pod.obstructedThrusters,
        totalThrustKN = pod.totalThrustKN,
        averagePower = pod.averagePower,
        energyFE = pod.energyFE,
        energyCapacityFE = pod.energyCapacityFE,
        ageMs = ageMs,
        faults = copyList(pod.faults),
        commandsSeen = pod.commandsSeen,
        commandsApplied = pod.commandsApplied,
        commandsRejected = pod.commandsRejected,
        lastReject = pod.lastReject,
        bootedAt = pod.bootedAt,
    }
end

function snapshot.build(context)
    context = context or {}
    local state = context.state or {}
    local peripheralState = context.peripheralState or {}
    local podStates = context.podStates or {}
    local props = peripheralState.props or {}
    local netStats = context.netStats or {}
    local log = context.log or {}

    local errors = {}
    for _, message in ipairs(state.errors or {}) do
        errors[#errors + 1] = message
    end
    for _, message in ipairs(peripheralState.errors or {}) do
        errors[#errors + 1] = message
    end

    local frame = {
        v = snapshot.VERSION,
        utc_ms = context.timestamp,
        sequence = context.sequence,
        dt_s = context.dt,
        valid = (state.valid == true) and (peripheralState.valid == true),
        errors = errors,
        craft = buildCraft(state),
        corners = {},
        pods = {},
        power = {
            storedFE = peripheralState.energy,
            capacityFE = peripheralState.energyCapacity,
            gridPower = peripheralState.gridPower,
            gridVoltage = peripheralState.gridVoltage,
            gridAmperage = peripheralState.gridAmperage,
        },
        net = {
            seen = netStats.seen,
            accepted = netStats.accepted,
            badProtocol = netStats.badProtocol,
            wrongType = netStats.wrongType,
            unknownCorner = netStats.unknownCorner,
            hostnameMismatch = netStats.hostnameMismatch,
            senderMismatch = netStats.senderMismatch,
            perCorner = {
                FL = (netStats.perCorner or {}).FL,
                FR = (netStats.perCorner or {}).FR,
                RL = (netStats.perCorner or {}).RL,
                RR = (netStats.perCorner or {}).RR,
            },
        },
        log = {
            path = log.path,
            bytes = log.bytes,
            samples = log.samples,
            targetHz = log.targetHz,
            actualHz = log.actualHz,
            freeSpace = log.freeSpace,
        },
    }

    for _, corner in ipairs(snapshot.CORNERS) do
        frame.corners[corner] = buildCorner(props[corner])
        frame.pods[corner] = buildPod(podStates[corner], context.timestamp)
    end

    return frame
end

-- ---------------------------------------------------------------------------
-- ComputerCraft side. Everything below guards its globals so the module still
-- loads under plain luajit for the tests above.
-- ---------------------------------------------------------------------------

snapshot.PATH = "/fcs/snapshot.dat"

-- The event fires every sample; the file is a cold-start seed, not a channel.
-- Writing it at 4 Hz would put roughly 8 KB/s of churn against the same disk
-- quota the CSV budget (maxLogBytes x maxLogFiles) is already tuned against.
snapshot.DISK_PERIOD_MS = 2000

snapshot.publishes = 0
snapshot.failures = 0
snapshot.lastDiskWriteAt = nil
snapshot.lastError = nil

local function haveFilesystem()
    return type(_G.fs) == "table" and type(_G.textutils) == "table"
end

function snapshot.publish(frame)
    snapshot.publishes = snapshot.publishes + 1

    -- CC delivers non-input events to every multishell process, which is what
    -- lets the hub tab hear the logger tab without a second rednet listener.
    if type(os) == "table" and type(os.queueEvent) == "function" then
        os.queueEvent("fcs_snapshot", frame)
    end

    local timestamp = type(frame) == "table" and frame.utc_ms or nil
    if type(timestamp) ~= "number" then
        return true
    end
    -- If frame.utc_ms ever regresses (clock reset, corrected drift), this
    -- subtraction goes negative and reads as "inside the window", so disk
    -- writes stay suppressed until the clock passes
    -- lastDiskWriteAt + DISK_PERIOD_MS again. A bounded stall, not a wedge.
    if snapshot.lastDiskWriteAt
        and timestamp - snapshot.lastDiskWriteAt < snapshot.DISK_PERIOD_MS then
        return true
    end
    if not haveFilesystem() then
        return true
    end
    snapshot.lastDiskWriteAt = timestamp

    -- Write to a temporary path and move it into place, so a hub reading the
    -- file mid-write gets the previous whole frame rather than half of this one.
    local temporary = snapshot.PATH .. ".tmp"
    local ok, err = pcall(function()
        local file = fs.open(temporary, "w")
        if not file then
            error("cannot open " .. temporary, 0)
        end
        file.write(textutils.serialize(frame))
        file.close()
        if fs.exists(snapshot.PATH) then
            fs.delete(snapshot.PATH)
        end
        fs.move(temporary, snapshot.PATH)
    end)

    if not ok then
        snapshot.failures = snapshot.failures + 1
        snapshot.lastError = tostring(err)
        -- Deliberately NOT deleting the temporary file here. fs.move errors
        -- if the destination exists, so the destination was already deleted
        -- above; if the failure happened at or after that point, temporary
        -- holds the only complete frame left on disk. Deleting it would
        -- destroy both copies. It cannot accumulate: the next publish opens
        -- this same path with "w" and overwrites it in place.
        return false, err
    end

    return true
end

-- Hub-side cold start: something to draw before the first event arrives, and
-- the last known frame when the logger is not running at all.
function snapshot.read()
    if not haveFilesystem() then
        return nil, "no filesystem"
    end
    if not fs.exists(snapshot.PATH) then
        return nil, "no snapshot file"
    end

    local ok, result = pcall(function()
        local file = fs.open(snapshot.PATH, "r")
        if not file then
            error("cannot open " .. snapshot.PATH, 0)
        end
        local text = file.readAll()
        file.close()
        return textutils.unserialize(text)
    end)

    if not ok then
        return nil, tostring(result)
    end
    if type(result) ~= "table" then
        return nil, "snapshot file is not a table"
    end
    return result
end

return snapshot
