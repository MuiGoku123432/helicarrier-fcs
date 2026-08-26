-- Shared scaffolding for the hub test files: a fake canvas target that
-- records every blit, and fabricated telemetry frames.
--
-- Exists so test_hub_canvas, test_hub_zones and test_snapshot agree on what a
-- frame looks like. A zone test that invents its own frame shape tests the
-- test, not the zone.

local snapshot = require("fcs.snapshot")

local fixtures = {}

-- --- fake render target ----------------------------------------------------
-- Implements the subset of the CC term API that canvas uses, and records what
-- was written so a test can assert on the pixels rather than on the calls.

function fixtures.target(width, height, isColour)
    local self = {
        width = width,
        height = height,
        cursorX = 1,
        cursorY = 1,
        calls = {},           -- every blit, in order
        cells = {},           -- [y][x] = {char=, fg=, bg=}
    }

    for y = 1, height do
        self.cells[y] = {}
        for x = 1, width do
            self.cells[y][x] = { char = " ", fg = "0", bg = "f" }
        end
    end

    function self.getSize()
        return self.width, self.height
    end

    function self.setCursorPos(x, y)
        self.cursorX, self.cursorY = x, y
    end

    function self.isColour()
        return isColour ~= false
    end
    self.isColor = self.isColour

    function self.blit(text, fg, bg)
        self.calls[#self.calls + 1] = {
            x = self.cursorX, y = self.cursorY, text = text, fg = fg, bg = bg,
        }
        local row = self.cells[self.cursorY]
        if row then
            for i = 1, #text do
                local x = self.cursorX + i - 1
                if row[x] then
                    row[x] = {
                        char = text:sub(i, i),
                        fg = fg:sub(i, i),
                        bg = bg:sub(i, i),
                    }
                end
            end
        end
        self.cursorX = self.cursorX + #text
    end

    -- Total characters written across every blit since the last reset.
    function self.written()
        local total = 0
        for _, call in ipairs(self.calls) do
            total = total + #call.text
        end
        return total
    end

    function self.reset()
        self.calls = {}
    end

    -- Monitors change size when blocks are added; the canvas must cope.
    function self.resizeTo(newWidth, newHeight)
        self.width, self.height = newWidth, newHeight
        self.cells = {}
        for y = 1, newHeight do
            self.cells[y] = {}
            for x = 1, newWidth do
                self.cells[y][x] = { char = " ", fg = "0", bg = "f" }
            end
        end
        self.calls = {}
    end

    -- The visible screen as an array of strings, for readable assertions.
    function self.rows()
        local out = {}
        for y = 1, self.height do
            local chars = {}
            for x = 1, self.width do
                chars[x] = self.cells[y][x].char
            end
            out[y] = table.concat(chars)
        end
        return out
    end

    function self.rowText(y)
        return self.rows()[y]
    end

    return self
end

-- --- telemetry frames ------------------------------------------------------
-- Shaped exactly like snapshot.build's output. Zones are tested against these
-- rather than against invented tables, so a change to the snapshot contract
-- breaks the zone tests instead of silently diverging from them.

local CORNERS = { "FL", "FR", "RL", "RR" }

-- The RAW producer-shaped input fcs/main.lua holds at the moment it calls
-- snapshot.publish: sensors.read()'s state, peripherals.read()'s state, and
-- banks.getState()'s pod table. Every field name here is the PRODUCER'S name
-- -- linearVelocityBody, perBearing, tiltAngle, receivedAt, energy -- not the
-- frame's.
--
-- This is the half of the contract nothing used to pin down. fixtures.frame()
-- was a hand-written literal that only claimed to be built from the snapshot
-- contract, and tools/test_snapshot.lua exercised snapshot.build against a
-- separately-invented input, so no assertion tied build's output to what the
-- zones read, or build's input to what the producers emit. That gap is how
-- prop.tilt -- a field with no producer anywhere on the craft -- survived
-- thirteen reviews while the ENGINES tilt row rendered "--" forever.
function fixtures.context()
    local timestamp = 1787670000000

    local context = {
        timestamp = timestamp,
        sequence = 12481,
        dt = 0.26,
        state = {
            valid = true,
            errors = {},
            uuid = "abc-123",
            name = "Helicarrier",
            position = { x = 10.5, y = 82.0, z = -3.25 },
            roll = 1.23, pitch = -0.4, yaw = 271.5,
            linearVelocityBody = { x = 0.1, y = -0.02, z = 0.0 },
            linearVelocityWorld = { x = 0.1, y = -0.02, z = 0.0 },
            angularVelocityBody = { x = 0.0, y = 0.01, z = 0.0 },
            mass = 41250.0,
            airPressure = 0.86,
        },
        peripheralState = {
            valid = true,
            errors = {},
            energy = 1240000, energyCapacity = 2000000,
            gridPower = 18400, gridVoltage = 240, gridAmperage = 76,
            props = {},
        },
        podStates = {},
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

    for _, corner in ipairs(CORNERS) do
        context.peripheralState.props[corner] = {
            controllerPresent = true, bearingPresent = true,
            targetRpm = 64, controllerRpm = 63.9, bearingRpm = 4.8,
            thrust = 27921.9, thrustImbalance = 0.4, airflow = 12.0,
            sailPower = 267, hasSource = true, overstressed = false,
            active = true,
            -- perBearing, not bearings: the frame-side name is bearings.
            perBearing = {
                { thrust = 13960.98, assembled = true },
                { thrust = 13960.92, assembled = true },
            },
            -- tiltAngle, not tilt: pod-template/pod/props.lua publishes
            -- result.tiltAngle and nothing anywhere publishes prop.tilt.
            tiltAngle = 0.0,
        }
        context.podStates[corner] = {
            corner = corner, hostname = "ENG-" .. corner,
            online = true, podId = 20, armed = true,
            currentPower = 0.45, fallbackPower = 0.0,
            healthyThrusters = 20, expectedThrusters = 20,
            obstructedThrusters = 0, totalThrustKN = 900.0,
            averagePower = 0.45, energyFE = 400000, energyCapacityFE = 500000,
            -- receivedAt, not ageMs: snapshot.build subtracts it from the
            -- frame timestamp. 120 ms old, as the old literal asserted.
            receivedAt = timestamp - 120,
            faults = {},
            commandsSeen = 412, commandsApplied = 412, commandsRejected = 0,
            bootedAt = 1787660000000,
        }
    end

    -- The interesting corner: RR's second bearing reading under its twin is
    -- the asymmetry this whole wall exists to make visible.
    context.peripheralState.props.RR.perBearing[2].thrust = 13804.41
    context.peripheralState.props.RR.thrust = 27765.4

    return context
end

-- Built by the real producer, never by hand: what the zones are tested against
-- is exactly what snapshot.build emits from a producer-shaped input.
function fixtures.frame()
    return snapshot.build(fixtures.context())
end

-- Every way a frame can be wrong that the hub must survive. A bad tick is
-- exactly when someone is staring at the wall.
function fixtures.hostileFrames()
    local cases = {}

    cases[#cases + 1] = { label = "empty table", frame = {} }

    local noCraft = fixtures.frame()
    noCraft.craft = {}
    cases[#cases + 1] = { label = "no craft state", frame = noCraft }

    local noCorners = fixtures.frame()
    noCorners.corners = {}
    noCorners.pods = {}
    cases[#cases + 1] = { label = "no corners or pods", frame = noCorners }

    local offline = fixtures.frame()
    for _, corner in ipairs(CORNERS) do
        offline.pods[corner].online = false
        offline.pods[corner].ageMs = 9000
        offline.pods[corner].armed = nil
        offline.pods[corner].currentPower = nil
        offline.pods[corner].healthyThrusters = nil
        offline.corners[corner] = {
            bearings = { {}, {} },
        }
    end
    cases[#cases + 1] = { label = "all pods offline", frame = offline }

    local missingBearings = fixtures.frame()
    for _, corner in ipairs(CORNERS) do
        missingBearings.corners[corner].bearings = { {}, {} }
    end
    cases[#cases + 1] = { label = "no bearing readings", frame = missingBearings }

    local nan = fixtures.frame()
    nan.craft.roll = 0 / 0
    nan.craft.pitch = 1 / 0
    nan.craft.position.y = -1 / 0
    nan.power.storedFE = 0 / 0
    nan.power.capacityFE = 0
    for _, corner in ipairs(CORNERS) do
        nan.corners[corner].thrust = 0 / 0
        nan.corners[corner].controllerRpm = 1 / 0
        nan.corners[corner].bearings[1].thrust = 0 / 0
        nan.pods[corner].currentPower = 0 / 0
    end
    cases[#cases + 1] = { label = "NaN and infinity", frame = nan }

    local faults = fixtures.frame()
    faults.pods.RR.faults = {
        "thruster_7 unresponsive",
        "thruster_11 obstructed by a block that has a very long name indeed",
        "bearing not assembled",
        "rsc lost source",
        "a fifth fault to overflow any fixed list",
    }
    faults.errors = { "RR pod offline: no propeller telemetry" }
    cases[#cases + 1] = { label = "many long faults", frame = faults }

    local negative = fixtures.frame()
    for _, corner in ipairs(CORNERS) do
        negative.corners[corner].thrust = -27921.9
        negative.corners[corner].targetRpm = -256
        negative.corners[corner].bearings[1].thrust = -13960.98
    end
    cases[#cases + 1] = { label = "negative values", frame = negative }

    local huge = fixtures.frame()
    huge.power.storedFE = 2000000
    huge.power.capacityFE = 1
    cases[#cases + 1] = { label = "fraction above one", frame = huge }

    return cases
end

return fixtures
