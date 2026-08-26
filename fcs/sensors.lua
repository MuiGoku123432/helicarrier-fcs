local attitude = require("fcs.attitude")

local sensors = {}

-- Read the inertia tensor on every Nth sample. 0 disables it entirely.
-- Deliberately not 1: see the note in sensors.read.
sensors.tensorEveryNth = 10
sensors.tensorCounter = 0

local function plainVector(value)
    if not value then
        return nil
    end
    return { x = value.x, y = value.y, z = value.z }
end

-- CC:Sable orientations are quaternion objects from the `quaternion` API, which
-- stores them as { v = <vector>, a = <real part> } -- NOT as x/y/z/w. Reading
-- .x/.y/.z/.w off one yields four nils, and a table of four nils is still
-- non-nil, so it slips past every "if quaternion then" guard and dies doing
-- arithmetic further down. Normalise both shapes here, and return nil for
-- anything unrecognised so the guards actually fire.
local function plainQuaternion(value)
    if type(value) ~= "table" then
        return nil
    end

    -- CC:Sable / quaternion API shape.
    if type(value.v) == "table" and type(value.a) == "number"
        and type(value.v.x) == "number" then
        return { x = value.v.x, y = value.v.y, z = value.v.z, w = value.a }
    end

    -- Plain component table.
    if type(value.x) == "number" and type(value.y) == "number"
        and type(value.z) == "number" and type(value.w) == "number" then
        return { x = value.x, y = value.y, z = value.z, w = value.w }
    end

    return nil
end

-- CC:Sable exposes more than this project historically used -- the twelve
-- methods here were found ad hoc, and /fcs/airprofile.lua later enumerated
-- twenty. Guard each newer call so a pod running an older CC:Sable degrades
-- instead of erroring, rather than assuming the method exists.
local function optional(api, name)
    return type(api) == "table" and type(api[name]) == "function" and api[name] or nil
end

local function attempt(errors, label, callback)
    local ok, value = pcall(callback)
    if not ok then
        errors[#errors + 1] = label .. ": " .. tostring(value)
        return nil
    end
    return value
end

-- `atmosphereModel` is optional: a model from fcs/atmosphere.lua, built once at
-- startup from the mod's own pressure curve. When present, air pressure is
-- evaluated LOCALLY and costs nothing. When absent, this falls back to
-- aero.getAirPressure, which is one Sable call (~50 ms, a whole server tick) on
-- a loop that already runs ~950 ms against a 250 ms target.
--
-- Both paths return the same number: the probe measured evaluateFunction and
-- getAirPressure agreeing to eight decimals at nine altitudes, and
-- tools/test_atmosphere.lua pins the local model to those measurements.
-- Exposed so the cheap inner-loop read in fcs/flight.lua can reuse them.
-- Duplicating these would risk re-introducing bug 3: CC:Sable orientations are
-- {v = <vector>, a = <w>}, and reading .x off one yields nils that pass every
-- `if quaternion` guard.
sensors.plainQuaternion = plainQuaternion
sensors.plainVector = plainVector

function sensors.read(config, atmosphereModel)
    local result = {
        valid = true,
        errors = {},
    }

    if not sublevel then
        result.valid = false
        result.errors[1] = "CC:Sable sublevel API is unavailable"
        return result
    end

    local onCraft = attempt(result.errors, "isInPlotGrid", function()
        return sublevel.isInPlotGrid()
    end)

    if not onCraft then
        result.valid = false
        result.errors[#result.errors + 1] = "computer is not on a Sable sublevel"
        return result
    end

    result.uuid = attempt(result.errors, "getUniqueId", sublevel.getUniqueId)
    result.name = attempt(result.errors, "getName", sublevel.getName)

    local pose = attempt(result.errors, "getLogicalPose", sublevel.getLogicalPose)
    local linearVelocity = attempt(result.errors, "getLinearVelocity", sublevel.getLinearVelocity)
    local globalVelocity = attempt(result.errors, "getVelocity", sublevel.getVelocity)
    local angularVelocity = attempt(result.errors, "getAngularVelocity", sublevel.getAngularVelocity)

    result.mass = attempt(result.errors, "getMass", sublevel.getMass)
    result.centerOfMass = plainVector(attempt(result.errors, "getCenterOfMass", sublevel.getCenterOfMass))

    -- Read directly rather than derived as 1/mass. The whole thrust/weight
    -- investigation hung on getMass being right, and this is an independent
    -- statement of the same quantity: if 1/inverse_mass disagrees with mass,
    -- that is worth knowing before a controller is built on either.
    local getInverseMass = optional(sublevel, "getInverseMass")
    if getInverseMass then
        result.inverseMass = attempt(result.errors, "getInverseMass", getInverseMass)
    end

    -- Inertia tensor, sampled PERIODICALLY rather than every read.
    --
    -- The question it answers is whether getInertiaTensor is BODY-frame or
    -- WORLD-frame, which nobody has ever established -- both archived reads
    -- were taken grounded and level, where the two are indistinguishable. It
    -- matters: the "axes are coupled at 32%" claim is a body-frame statement,
    -- and any controller using the tensor needs to know which it is.
    --
    -- The test is to compare reads at DIFFERENT ATTITUDES. The craft routinely
    -- tilts 4-5 deg, which would mix t[1][1] and t[2][2] -- they differ by 46
    -- million -- by roughly sin^2(5 deg) = 0.8%, about 350,000 units. The two
    -- archived reads agree to 0.00015%, so that signal is far above the noise.
    -- Constant across attitudes means body-frame.
    --
    -- Every-sample would be wrong. These are sequential main-thread Sable
    -- calls at ~50 ms each, and the loop is already slow enough that the
    -- axis-response pulse gets only 2 samples in 3.25 s. A handful of reads at
    -- varied attitudes settles the question; 1 Hz of them buys nothing and
    -- costs the one thing the pulse measurement is short of.
    sensors.tensorCounter = (sensors.tensorCounter or 0) + 1
    if sensors.tensorEveryNth > 0
        and sensors.tensorCounter % sensors.tensorEveryNth == 0 then
        local getTensor = optional(sublevel, "getInertiaTensor")
        if getTensor then
            local tensor = attempt(result.errors, "getInertiaTensor", getTensor)
            -- rows/columns are DIMENSION COUNTS (3.0), not containers -- the
            -- matrix is tensor[i][j]. Indexing rows as a table is what crashed
            -- the first stabprobe run.
            if type(tensor) == "table" and type(tensor[1]) == "table" then
                result.inertia = {
                    xx = tensor[1][1], yy = tensor[2] and tensor[2][2],
                    zz = tensor[3] and tensor[3][3],
                    xy = tensor[1][2],
                    xz = tensor[1][3],
                    yz = tensor[2] and tensor[2][3],
                }
            end
        end
    end

    if pose then
        result.position = plainVector(pose.position)
        result.quaternion = plainQuaternion(pose.orientation)
    end

    result.linearVelocityWorld = plainVector(linearVelocity)
    result.globalVelocityWorld = plainVector(globalVelocity)
    result.angularVelocityWorld = plainVector(angularVelocity)

    if result.quaternion then
        local derived = attitude.fromQuaternion(result.quaternion, config.axes)
        result.roll = derived.roll
        result.pitch = derived.pitch
        result.yaw = derived.yaw

        if result.linearVelocityWorld then
            result.linearVelocityBody = attitude.worldToBody(derived.matrix, result.linearVelocityWorld)
        end

        if result.angularVelocityWorld then
            result.angularVelocityBody = attitude.worldToBody(derived.matrix, result.angularVelocityWorld)
        end
    end

    if aero and result.position then
        -- A heading reference from the mod instead of the hand-calibrated
        -- axes.yawOffsetDegrees. Yaw is the unsolved axis; this is the datum
        -- it was missing.
        local getMagneticNorth = optional(aero, "getMagneticNorth")
        if getMagneticNorth then
            result.magneticNorth = plainVector(
                attempt(result.errors, "aero.getMagneticNorth", getMagneticNorth))
        end

        result.gravityWorld = plainVector(attempt(result.errors, "aero.getGravity", aero.getGravity))
        if atmosphereModel then
            result.airPressure = attempt(result.errors, "atmosphere.pressureAt", function()
                return atmosphereModel.pressureAt(result.position.y)
            end)
            result.airPressureSource = "local"
        end
        if not result.airPressure then
            result.airPressure = attempt(result.errors, "aero.getAirPressure", function()
                return aero.getAirPressure(vector.new(result.position.x, result.position.y, result.position.z))
            end)
            result.airPressureSource = "sable"
        end
        result.universalDrag = attempt(result.errors, "aero.getUniversalDrag", aero.getUniversalDrag)
    end

    if not result.position or not result.quaternion or not result.linearVelocityWorld or not result.angularVelocityWorld then
        result.valid = false
    end

    return result
end

return sensors
