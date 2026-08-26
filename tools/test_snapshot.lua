-- Offline tests for fcs/snapshot.lua (the build half).
--
--     luajit tools/test_snapshot.lua      (from the repo root)

package.path = "./?.lua;" .. package.path

local snapshot = require("fcs.snapshot")

local passed, failed = 0, 0
local currentTest = "<none>"

local function fail(message)
    failed = failed + 1
    print(string.format("  FAIL  %s: %s", currentTest, message))
end

local function ok() passed = passed + 1 end

local function check(condition, message)
    if condition then ok() else fail(message) end
end

local function equal(actual, expected, message)
    if actual ~= expected then
        fail(string.format("%s: expected %s, got %s",
            message, tostring(expected), tostring(actual)))
        return
    end
    ok()
end

local function test(name, body)
    currentTest = name
    local succeeded, err = pcall(body)
    if not succeeded then fail("threw: " .. tostring(err)) end
end

-- ---------------------------------------------------------------------------
-- Fabricated inputs, shaped exactly like what fcs/main.lua holds at the point
-- it will call publish: sensors.read, devices.read, banks.getState.
-- ---------------------------------------------------------------------------

local function sampleState()
    return {
        valid = true,
        errors = {},
        uuid = "abc-123",
        name = "Helicarrier",
        position = { x = 10.5, y = 82.0, z = -3.25 },
        linearVelocityBody = { x = 0.1, y = -0.02, z = 0.0 },
        linearVelocityWorld = { x = 0.1, y = -0.02, z = 0.0 },
        angularVelocityBody = { x = 0.0, y = 0.01, z = 0.0 },
        roll = 1.23, pitch = -0.4, yaw = 271.5,
        mass = 41250.0,
        airPressure = 0.86,
    }
end

local function samplePeripheralState()
    return {
        valid = true,
        errors = { "RR pod: thruster_7 unresponsive" },
        energy = 1240000, energyCapacity = 2000000,
        gridPower = 18400, gridVoltage = 240, gridAmperage = 76,
        props = {
            FL = { controllerPresent = true, bearingPresent = true,
                targetRpm = 64, controllerRpm = 63.8, bearingRpm = 4.8,
                thrust = 27921.9, thrustImbalance = 0.4, airflow = 12.0,
                sailPower = 267, hasSource = true, overstressed = false,
                active = true,
                perBearing = {
                    { thrust = 13960.98, assembled = true },
                    { thrust = 13960.92, assembled = true },
                },
                -- tiltAngle, not tilt: this is the name
                -- pod-template/pod/props.lua actually publishes.
                tiltAngle = 4.29 },
            FR = { controllerPresent = true, bearingPresent = true,
                targetRpm = 64, controllerRpm = 64.0, thrust = 27921.9,
                perBearing = { { thrust = 13960.98 }, { thrust = 13960.92 } } },
            RL = { controllerPresent = true, bearingPresent = true,
                targetRpm = 64, controllerRpm = 63.9, thrust = 27921.9,
                perBearing = { { thrust = 13960.98 }, { thrust = 13960.92 } } },
            RR = { controllerPresent = true, bearingPresent = true,
                targetRpm = 64, controllerRpm = 64.0, thrust = 27765.4,
                perBearing = { { thrust = 13960.98 }, { thrust = 13804.41 } } },
        },
    }
end

local function samplePodStates()
    local pods = {}
    for _, corner in ipairs({ "FL", "FR", "RL", "RR" }) do
        pods[corner] = {
            corner = corner,
            hostname = "ENG-" .. corner,
            online = true,
            podId = 20,
            armed = true,
            currentPower = 0.45,
            fallbackPower = 0.0,
            healthyThrusters = 20,
            expectedThrusters = 20,
            obstructedThrusters = 0,
            totalThrustKN = 900.0,
            averagePower = 0.45,
            energyFE = 400000,
            energyCapacityFE = 500000,
            receivedAt = 1787670000000 - 120,
            faults = {},
            commandsSeen = 412, commandsApplied = 412, commandsRejected = 0,
            bootedAt = 1787660000000,
        }
    end
    pods.RR.faults = { "thruster_7 unresponsive" }
    pods.RL.online = false
    pods.RL.receivedAt = 1787670000000 - 6200
    return pods
end

local function sampleContext()
    return {
        sequence = 12481,
        timestamp = 1787670000000,
        dt = 0.26,
        state = sampleState(),
        peripheralState = samplePeripheralState(),
        podStates = samplePodStates(),
        netStats = {
            seen = 5000, accepted = 4980, badProtocol = 2, wrongType = 0,
            unknownCorner = 0, hostnameMismatch = 0, senderMismatch = 18,
            perCorner = { FL = 1250, FR = 1250, RL = 1230, RR = 1250 },
        },
        log = {
            path = "/fcs/logs/flight_1787670000000.csv",
            bytes = 412000, samples = 12481,
            targetHz = 4.0, actualHz = 3.85, freeSpace = 9000000,
        },
    }
end

-- ---------------------------------------------------------------------------

test("stamps the schema version", function()
    equal(snapshot.build(sampleContext()).v, snapshot.VERSION, "v")
    equal(snapshot.VERSION, 1, "VERSION constant")
end)

test("carries the sample identity", function()
    local frame = snapshot.build(sampleContext())
    equal(frame.sequence, 12481, "sequence")
    equal(frame.utc_ms, 1787670000000, "utc_ms")
    equal(frame.dt_s, 0.26, "dt_s")
    equal(frame.valid, true, "valid")
end)

test("valid is false when either half is invalid", function()
    local context = sampleContext()
    context.state.valid = false
    equal(snapshot.build(context).valid, false, "state invalid")

    context = sampleContext()
    context.peripheralState.valid = false
    equal(snapshot.build(context).valid, false, "peripheral invalid")
end)

test("merges errors from both halves", function()
    local context = sampleContext()
    context.state.errors = { "sable timeout" }
    local frame = snapshot.build(context)
    equal(#frame.errors, 2, "error count")
    check(frame.errors[1]:find("sable") or frame.errors[2]:find("sable"),
        "state error carried")
end)

test("copies craft state", function()
    local frame = snapshot.build(sampleContext())
    equal(frame.craft.roll, 1.23, "roll")
    equal(frame.craft.pitch, -0.4, "pitch")
    equal(frame.craft.yaw, 271.5, "yaw")
    equal(frame.craft.position.y, 82.0, "altitude")
    equal(frame.craft.bodyVel.x, 0.1, "body velocity x")
    equal(frame.craft.mass, 41250.0, "mass")
end)

test("copies every corner with both bearings", function()
    local frame = snapshot.build(sampleContext())
    for _, corner in ipairs(snapshot.CORNERS) do
        local entry = frame.corners[corner]
        check(entry ~= nil, corner .. " present")
        equal(#entry.bearings, snapshot.BEARINGS_PER_CORNER, corner .. " bearing count")
    end
    equal(frame.corners.RR.bearings[2].thrust, 13804.41, "RR bearing 2 thrust")
    equal(frame.corners.FL.targetRpm, 64, "FL target rpm")
end)

-- Regression: buildCorner used to read prop.tilt, a field no producer emits,
-- so frame.corners[c].tilt was always nil on a real craft and the ENGINES
-- "tilt deg" row rendered "--" forever. The producer field is tiltAngle.
test("corner tilt comes from the producer's tiltAngle, not a phantom tilt", function()
    local frame = snapshot.build(sampleContext())
    equal(frame.corners.FL.tilt, 4.29, "FL tilt from tiltAngle")
    equal(frame.corners.FL.tiltAzimuth, nil, "no phantom tiltAzimuth on the corner")

    -- A prop that only carries the old (never-produced) name must not resurrect it.
    local context = sampleContext()
    context.peripheralState.props.FR.tilt = 9.99
    local phantom = snapshot.build(context)
    equal(phantom.corners.FR.tilt, nil, "prop.tilt is not a source")
end)

test("a corner missing a bearing leaves an empty slot, not a short row", function()
    local context = sampleContext()
    context.peripheralState.props.FR.perBearing = { { thrust = 13960.98 } }
    local frame = snapshot.build(context)
    equal(#frame.corners.FR.bearings, snapshot.BEARINGS_PER_CORNER, "slot count")
    equal(frame.corners.FR.bearings[2].thrust, nil, "empty slot has no thrust")
end)

test("copies pod state including age", function()
    local frame = snapshot.build(sampleContext())
    equal(frame.pods.FL.online, true, "FL online")
    equal(frame.pods.FL.ageMs, 120, "FL age")
    equal(frame.pods.RL.online, false, "RL offline")
    equal(frame.pods.RL.ageMs, 6200, "RL age")
    equal(frame.pods.FL.healthyThrusters, 20, "healthy thrusters")
    equal(frame.pods.RR.faults[1], "thruster_7 unresponsive", "fault text")
end)

test("a pod that has never reported has a nil age rather than a wrong one", function()
    local context = sampleContext()
    context.podStates.FR.receivedAt = nil
    local frame = snapshot.build(context)
    equal(frame.pods.FR.ageMs, nil, "age")
end)

test("copies power and network and log blocks", function()
    local frame = snapshot.build(sampleContext())
    equal(frame.power.storedFE, 1240000, "stored FE")
    equal(frame.power.gridVoltage, 240, "voltage")
    equal(frame.net.accepted, 4980, "accepted")
    equal(frame.net.senderMismatch, 18, "sender mismatch")
    equal(frame.net.perCorner.RL, 1230, "per corner")
    equal(frame.log.samples, 12481, "log samples")
    equal(frame.log.actualHz, 3.85, "actual Hz")
end)

-- ---------------------------------------------------------------------------
-- Isolation. banks.acceptStatus writes into its pod tables in place on every
-- message, so a frame holding references would tear mid-render.
-- ---------------------------------------------------------------------------

test("the frame does not alias the pod state tables", function()
    local context = sampleContext()
    local frame = snapshot.build(context)
    check(frame.pods.FL ~= context.podStates.FL, "pod table is a copy")
    context.podStates.FL.currentPower = 0.99
    equal(frame.pods.FL.currentPower, 0.45, "frame value unchanged by later mutation")
end)

test("the frame does not alias the fault arrays", function()
    local context = sampleContext()
    local frame = snapshot.build(context)
    check(frame.pods.RR.faults ~= context.podStates.RR.faults, "faults is a copy")
    table.insert(context.podStates.RR.faults, "new fault")
    equal(#frame.pods.RR.faults, 1, "frame fault count unchanged")
end)

test("the frame does not alias corner or vector tables", function()
    local context = sampleContext()
    local frame = snapshot.build(context)
    check(frame.corners.FL ~= context.peripheralState.props.FL, "corner is a copy")
    context.state.position.y = 999
    equal(frame.craft.position.y, 82.0, "position is a copy")
end)

-- ---------------------------------------------------------------------------
-- Hostile inputs. A frame must be buildable from whatever the loop is holding
-- during a bad tick, because a bad tick is exactly when the wall is read.
-- ---------------------------------------------------------------------------

test("builds from an empty context without throwing", function()
    local frame = snapshot.build({})
    equal(frame.v, snapshot.VERSION, "version")
    for _, corner in ipairs(snapshot.CORNERS) do
        check(frame.corners[corner] ~= nil, corner .. " corner present")
        check(frame.pods[corner] ~= nil, corner .. " pod present")
    end
    equal(frame.pods.FL.online, false, "unknown pod defaults to offline")
end)

test("builds when sensors returned nothing", function()
    local context = sampleContext()
    context.state = { valid = false, errors = { "no craft" } }
    local frame = snapshot.build(context)
    equal(frame.craft.roll, nil, "roll")
    equal(frame.craft.position, nil, "position")
    equal(frame.valid, false, "valid")
end)

test("builds when a pod reports a fault string instead of an array", function()
    local context = sampleContext()
    context.podStates.FL.faults = "single fault"
    local frame = snapshot.build(context)
    equal(frame.pods.FL.faults[1], "single fault", "coerced to an array")
end)

test("builds when props are missing entirely", function()
    local context = sampleContext()
    context.peripheralState.props = nil
    local frame = snapshot.build(context)
    for _, corner in ipairs(snapshot.CORNERS) do
        check(frame.corners[corner] ~= nil, corner .. " present")
        equal(frame.corners[corner].targetRpm, nil, corner .. " target rpm")
    end
end)

test("builds when netStats and log are absent", function()
    local context = sampleContext()
    context.netStats = nil
    context.log = nil
    local frame = snapshot.build(context)
    check(type(frame.net) == "table", "net is a table")
    check(type(frame.log) == "table", "log is a table")
    equal(frame.net.accepted, nil, "absent counter is nil, not zero")
end)

-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- publish(). Exercised with fake fs/textutils globals, because the guarantee
-- under test is "a publish failure never reaches the caller" -- and the only
-- way to prove that is to make it fail.
-- ---------------------------------------------------------------------------

local function fakeFilesystem()
    local disk = { files = {}, opens = 0, failNextOpen = false, failNextMove = false }

    local fs = {}
    function fs.open(path, mode)
        disk.opens = disk.opens + 1
        if disk.failNextOpen then
            disk.failNextOpen = false
            return nil
        end
        if mode == "r" then
            local content = disk.files[path]
            if not content then return nil end
            return {
                readAll = function() return content end,
                close = function() end,
            }
        end
        local buffer = {}
        return {
            -- CC file handles are called with a dot, not a colon: the code
            -- under test does file.write(text), so text is the FIRST argument.
            -- Getting this wrong makes the handle silently write nothing and
            -- every "file written" assertion pass against an empty string.
            write = function(text)
                buffer[#buffer + 1] = tostring(text)
            end,
            close = function()
                disk.files[path] = table.concat(buffer)
            end,
        }
    end
    function fs.exists(path) return disk.files[path] ~= nil end
    function fs.delete(path) disk.files[path] = nil end
    function fs.move(from, to)
        if disk.failNextMove then
            disk.failNextMove = false
            error("simulated move failure", 0)
        end
        disk.files[to] = disk.files[from]
        disk.files[from] = nil
    end
    function fs.getFreeSpace() return 9000000 end

    return fs, disk
end

local function withFakeCC(body)
    local savedFs, savedTextutils, savedQueue = _G.fs, _G.textutils, os.queueEvent
    local fs, disk = fakeFilesystem()
    local queued = {}

    _G.fs = fs
    _G.textutils = {
        serialize = function(value) return "SERIALIZED:" .. tostring(value.sequence) end,
        unserialize = function(text) return { v = 1, marker = text } end,
    }
    os.queueEvent = function(name, payload)
        queued[#queued + 1] = { name = name, payload = payload }
    end

    local succeeded, err = pcall(body, disk, queued)

    _G.fs, _G.textutils, os.queueEvent = savedFs, savedTextutils, savedQueue
    if not succeeded then error(err, 0) end
end

local function resetPublishState()
    snapshot.failures = 0
    snapshot.publishes = 0
    snapshot.lastDiskWriteAt = nil
    snapshot.lastError = nil
end

test("publish queues an fcs_snapshot event carrying the frame", function()
    withFakeCC(function(disk, queued)
        resetPublishState()
        local frame = snapshot.build(sampleContext())
        snapshot.publish(frame)
        equal(#queued, 1, "events queued")
        equal(queued[1].name, "fcs_snapshot", "event name")
        equal(queued[1].payload.sequence, 12481, "payload carries the frame")
    end)
end)

test("publish writes the snapshot file on the first call", function()
    withFakeCC(function(disk)
        resetPublishState()
        snapshot.publish(snapshot.build(sampleContext()))
        check(disk.files[snapshot.PATH] ~= nil, "snapshot file written")
        equal(disk.files[snapshot.PATH], "SERIALIZED:12481",
            "the serialized frame actually reached the file")
    end)
end)

test("publish throttles the disk write but never the event", function()
    withFakeCC(function(disk, queued)
        resetPublishState()
        local context = sampleContext()
        snapshot.publish(snapshot.build(context))
        local opensAfterFirst = disk.opens

        -- 250 ms later: same second, well inside DISK_PERIOD_MS.
        context.timestamp = context.timestamp + 250
        context.sequence = context.sequence + 1
        snapshot.publish(snapshot.build(context))

        equal(disk.opens, opensAfterFirst, "no second disk write inside the window")
        equal(#queued, 2, "both events still queued")

        -- Past the window.
        context.timestamp = context.timestamp + snapshot.DISK_PERIOD_MS
        snapshot.publish(snapshot.build(context))
        check(disk.opens > opensAfterFirst, "disk write resumes after the window")
    end)
end)

test("publish writes via a temporary file so a reader never sees half a frame", function()
    withFakeCC(function(disk)
        resetPublishState()
        snapshot.publish(snapshot.build(sampleContext()))
        equal(disk.files[snapshot.PATH .. ".tmp"], nil, "temporary file was moved, not left")
        check(disk.files[snapshot.PATH] ~= nil, "final file present")
    end)
end)

test("a disk failure is counted and swallowed, never raised", function()
    withFakeCC(function(disk)
        resetPublishState()
        disk.failNextOpen = true
        local ok = snapshot.publish(snapshot.build(sampleContext()))
        equal(ok, false, "publish reports failure")
        equal(snapshot.failures, 1, "failure counted")
        check(type(snapshot.lastError) == "string", "error recorded")
    end)
end)

test("a move failure after the destination is deleted leaves the temporary frame intact", function()
    withFakeCC(function(disk)
        resetPublishState()
        disk.failNextMove = true
        local ok = snapshot.publish(snapshot.build(sampleContext()))
        equal(ok, false, "publish reports failure")
        equal(snapshot.failures, 1, "failure counted exactly once")
        equal(disk.files[snapshot.PATH .. ".tmp"], "SERIALIZED:12481",
            "the only complete frame on disk was not deleted")
    end)
end)

test("publish tolerates a frame with no timestamp", function()
    withFakeCC(function(_, queued)
        resetPublishState()
        snapshot.publish({ v = 1 })
        equal(#queued, 1, "event still queued")
        equal(snapshot.failures, 0, "no failure counted")
    end)
end)

test("publish does nothing harmful with no ComputerCraft globals at all", function()
    resetPublishState()
    local ok = snapshot.publish(snapshot.build(sampleContext()))
    equal(ok, true, "publish succeeds as a no-op off-server")
    equal(snapshot.failures, 0, "no failure counted")
end)

test("read returns nil when there is no snapshot file", function()
    withFakeCC(function()
        resetPublishState()
        local frame, reason = snapshot.read()
        equal(frame, nil, "frame")
        check(type(reason) == "string", "reason given")
    end)
end)

test("read returns the deserialized frame when the file exists", function()
    withFakeCC(function()
        resetPublishState()
        snapshot.publish(snapshot.build(sampleContext()))
        local frame = snapshot.read()
        check(type(frame) == "table", "frame is a table")
        equal(frame.v, 1, "version")
    end)
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
