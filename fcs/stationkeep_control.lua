local lateralhold = require("fcs.lateralhold")
local config = require("fcs.config")

local stationkeep = {}

stationkeep.DEFAULTS = {
    velocityGain = 0.80,
    positionGain = 0.015,
    integralGain = 0.010,
    deadbandSpeed = 0.08,
    positionDeadband = 0.50,
    maxTiltDegrees = 6.0,
    slewDegreesPerSecond = 0.15,
    maxDtSeconds = 1.0,
    highCooldownSlots = 3,
    feedbackVerticalSpeed = 0.20,
    feedbackAltitude = 0.20,
    highInhibitRise = 8.0,
}

local function finite(value)
    return type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
end

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function magnitude(x, z)
    return math.sqrt(x * x + z * z)
end

local function copyOptions(options)
    local result = {}
    for key, value in pairs(stationkeep.DEFAULTS) do result[key] = value end
    for key, value in pairs(options or {}) do result[key] = value end
    return result
end

function stationkeep.new(options)
    local settings = copyOptions(options)
    local state = {
        integralX = 0,
        integralZ = 0,
        commandX = 0,
        commandZ = 0,
        highCooldown = 0,
    }

    local instance = {}

    function instance.reset()
        state.integralX, state.integralZ = 0, 0
        state.commandX, state.commandZ = 0, 0
        state.highCooldown = 0
    end

    function instance.state()
        return {
            integralX = state.integralX,
            integralZ = state.integralZ,
            commandX = state.commandX,
            commandZ = state.commandZ,
            highCooldown = state.highCooldown,
        }
    end

    function instance.update(sample, dt)
        if type(sample) ~= "table"
            or not finite(sample.velocityX) or not finite(sample.velocityZ)
            or type(sample.quaternion) ~= "table" then
            instance.reset()
            return { tiltDegrees = 0, azimuthDegrees = 0, valid = false }
        end

        dt = clamp(finite(dt) and dt or 0, 0, settings.maxDtSeconds)
        local positionX = finite(sample.positionErrorX) and sample.positionErrorX or 0
        local positionZ = finite(sample.positionErrorZ) and sample.positionErrorZ or 0
        local velocityX, velocityZ = sample.velocityX, sample.velocityZ
        if magnitude(velocityX, velocityZ) < settings.deadbandSpeed
            and magnitude(positionX, positionZ) < settings.positionDeadband then
            velocityX, velocityZ = 0, 0
            positionX, positionZ = 0, 0
        end

        -- Integrate the outer position-loop error, not velocity alone. At
        -- steady state this lets the integral hold a constant external bias
        -- while both position error and velocity converge to zero.
        local positionLoopGain = settings.positionGain / settings.velocityGain
        local candidateIntegralX = state.integralX
            + (velocityX + positionLoopGain * positionX) * dt
        local candidateIntegralZ = state.integralZ
            + (velocityZ + positionLoopGain * positionZ) * dt
        local function target(ix, iz)
            return settings.velocityGain * velocityX
                    + settings.positionGain * positionX
                    + settings.integralGain * ix,
                settings.velocityGain * velocityZ
                    + settings.positionGain * positionZ
                    + settings.integralGain * iz
        end

        local oldTargetX, oldTargetZ = target(state.integralX, state.integralZ)
        local candidateX, candidateZ = target(candidateIntegralX, candidateIntegralZ)
        local candidateMagnitude = magnitude(candidateX, candidateZ)
        local oldMagnitude = magnitude(oldTargetX, oldTargetZ)

        -- Conditional integration: at the tilt limit retain only integration
        -- that reduces the requested magnitude. This prevents hidden windup
        -- during a long external push while still letting the bias unwind.
        if candidateMagnitude <= settings.maxTiltDegrees
            or candidateMagnitude < oldMagnitude then
            state.integralX, state.integralZ = candidateIntegralX, candidateIntegralZ
        end

        local targetX, targetZ = target(state.integralX, state.integralZ)
        local targetMagnitude = magnitude(targetX, targetZ)
        local saturated = targetMagnitude > settings.maxTiltDegrees
        if saturated then
            local scale = settings.maxTiltDegrees / targetMagnitude
            targetX, targetZ = targetX * scale, targetZ * scale
        end

        local deltaX = targetX - state.commandX
        local deltaZ = targetZ - state.commandZ
        local deltaMagnitude = magnitude(deltaX, deltaZ)
        local maximumStep = settings.slewDegreesPerSecond * dt
        if deltaMagnitude > maximumStep and deltaMagnitude > 0 then
            local scale = maximumStep / deltaMagnitude
            deltaX, deltaZ = deltaX * scale, deltaZ * scale
        end
        state.commandX = state.commandX + deltaX
        state.commandZ = state.commandZ + deltaZ

        local command = lateralhold.command({
            quaternion = sample.quaternion,
            -- The wired pod plant responds opposite the legacy velocity-hold
            -- convention. Reverse the synthetic world vector here, at the
            -- controller/actuator boundary, without changing wire semantics.
            linearVelocityWorld = {
                x = -state.commandX,
                y = 0,
                z = -state.commandZ,
            },
        }, config.axes, {
            gainDegreesPerSpeed = 1,
            deadbandSpeed = 0,
            maxTiltDegrees = settings.maxTiltDegrees,
        })
        if not command then
            instance.reset()
            return { tiltDegrees = 0, azimuthDegrees = 0, valid = false }
        end

        return {
            tiltDegrees = command.tilt,
            azimuthDegrees = command.azimuth,
            headingDegrees = command.heading,
            targetMagnitude = targetMagnitude,
            commandX = state.commandX,
            commandZ = state.commandZ,
            saturated = saturated,
            valid = true,
        }
    end

    function instance.vertical(metrics, slot)
        metrics = metrics or {}
        local rise = finite(metrics.rise) and metrics.rise or 0
        local verticalVelocity = finite(metrics.verticalVelocity)
            and metrics.verticalVelocity or 0
        local altitudeError = finite(metrics.altitudeError)
            and metrics.altitudeError or 0
        local kind, reason

        if rise >= settings.highInhibitRise then
            kind, reason = "low", "absolute_high_inhibit"
        elseif state.highCooldown > 0 then
            kind, reason = "low", "high_cooldown"
        elseif verticalVelocity >= settings.feedbackVerticalSpeed then
            kind, reason = "low", "upward_speed"
        elseif altitudeError >= settings.feedbackAltitude then
            kind, reason = "low", "above_target"
        elseif verticalVelocity <= -settings.feedbackVerticalSpeed then
            kind, reason = "high", "downward_speed"
        elseif altitudeError <= -settings.feedbackAltitude then
            kind, reason = "high", "below_target"
        elseif ((slot or 1) - 1) % 4 == 0 then
            kind, reason = "high", "nominal_duty"
        else
            kind, reason = "low", "nominal_duty"
        end

        if kind == "high" then
            state.highCooldown = settings.highCooldownSlots
        elseif state.highCooldown > 0 then
            state.highCooldown = state.highCooldown - 1
        end
        return kind, reason
    end

    return instance
end

return stationkeep
