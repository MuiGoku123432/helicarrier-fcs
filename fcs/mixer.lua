-- Control allocation: a demand vector in, per-corner ion power out.
--
-- This module is PURE. It requires nothing, touches no peripheral, opens no
-- modem, reads no clock, and keeps no state between calls. Same inputs, same
-- outputs, always. That is what lets tools/test_mixer.lua exercise every path
-- on a desktop in milliseconds instead of costing an in-game session.
--
-- It is NOT a controller. It does not fly the craft and it commands nothing --
-- it only says what the commands should be. The loop that reads sensors,
-- decides on a demand, and sends it is separate work.
--
--     local plan = mixer.allocate(profile, demand)
--
-- Units are ACTUATOR units, not physical ones:
--
--     demand.collective  ion power, 0..1
--     demand.roll        -1..1, normalized authority, positive = starboard-low
--     demand.pitch       -1..1, normalized authority, positive = bow-high
--     demand.yaw         -1..1, accepted, reported unmet, does nothing yet
--
-- Converting "I want 0.45 of craft weight from the ions" into a power number
-- belongs to the caller, as does the inertia-tensor weighting: the tensor maps
-- desired angular ACCELERATION to torque, which is a control question, not an
-- allocation one. Keeping this module in actuator units also keeps the
-- unresolved force-per-power coefficient (see mixer_profile.lua) out of the
-- command path entirely.
--
-- CALLERS MUST READ `saturated` AND `attitudeScale`. A demand whose attitude
-- component has been scaled all the way to zero returns a perfectly ordinary
-- looking plan. See "Saturation" below.

local mixer = {}

local CORNERS = { "FL", "FR", "RL", "RR" }

mixer.corners = CORNERS

local function clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function demandComponent(demand, key)
    local value = tonumber(demand[key]) or 0
    return clamp(value, -1, 1)
end

-- ---------------------------------------------------------------------------
-- Collective
--
-- Resolved first and independently of attitude, because the chosen saturation
-- policy protects lift: under the 64 RPM plan the ions are half the carrier's
-- lift, so a collective that quietly yields is a descent nobody asked for.
--
-- The clamp has to bind on the MOST BIASED corner, not on maximumPower. A
-- corner carrying a positive bias reaches the limit before the others, so a
-- collective of maximumPower would drive it past the limit before any attitude
-- is even considered.
-- ---------------------------------------------------------------------------

local function collectiveBounds(profile)
    local lower, upper
    for _, corner in ipairs(CORNERS) do
        local bias = profile.corners[corner].bias or 0
        local cornerLower = profile.ion.minimumPower - bias
        local cornerUpper = profile.ion.maximumPower - bias
        if not lower or cornerLower > lower then lower = cornerLower end
        if not upper or cornerUpper < upper then upper = cornerUpper end
    end
    return lower, upper
end

-- ---------------------------------------------------------------------------
-- Saturation
--
-- Each corner's command is (collective + A_c * s) / e_c, where A_c is that
-- corner's attitude contribution at full scale and s is the scale we solve
-- for. Requiring every corner to land inside [minimumPower, maximumPower]
-- bounds s directly:
--
--     A_c > 0:  s <= (maximumPower - collective - bias_c) / A_c
--     A_c < 0:  s <= (minimumPower - collective - bias_c) / A_c
--     A_c = 0:  unconstrained
--
-- Take the minimum, clamp to [0, 1]. This is exact -- at the returned scale at
-- least one corner sits precisely on a limit -- so there is no clipping pass
-- afterwards and no iteration.
--
-- Because collective is already inside the bounds above, every numerator has
-- the same sign as its denominator and the result cannot go negative on its
-- own. The clamp to 0 is belt and braces against a profile whose biases
-- contradict the bounds.
-- ---------------------------------------------------------------------------

local function attitudeScale(profile, collective, contributions)
    local scale = 1.0

    for _, corner in ipairs(CORNERS) do
        local contribution = contributions[corner]
        if contribution ~= 0 then
            local bias = profile.corners[corner].bias or 0
            local headroom
            if contribution > 0 then
                headroom = (profile.ion.maximumPower - collective - bias) / contribution
            else
                headroom = (profile.ion.minimumPower - collective - bias) / contribution
            end
            if headroom < scale then
                scale = headroom
            end
        end
    end

    return clamp(scale, 0, 1)
end

-- ---------------------------------------------------------------------------
-- Expected thrust: advisory, opt-in, and never fed back
--
-- Populated only when the profile supplies forcePerPower, which is currently
-- unset because the two available readings disagree by a factor of ~1.5. The
-- commands above are exact arithmetic and do not depend on it; this field
-- exists so a test or a log line can be compared against what the hardware
-- will actually settle on rather than against ideal arithmetic.
-- ---------------------------------------------------------------------------

local function expectedThrust(profile, ions)
    local forcePerPower = profile.ion.forcePerPower
    if not forcePerPower then
        return nil
    end

    local quantum = profile.ion.quantumKN
    local expected = {}
    for _, corner in ipairs(CORNERS) do
        local force = ions[corner] * forcePerPower
        if quantum and quantum > 0 then
            force = math.floor(force / quantum) * quantum
        end
        expected[corner] = force
    end
    return expected
end

-- ---------------------------------------------------------------------------

function mixer.allocate(profile, demand)
    if type(profile) ~= "table" then
        error("mixer.allocate needs a profile table", 2)
    end
    if type(demand) ~= "table" then
        error("mixer.allocate needs a demand table", 2)
    end

    local roll = demandComponent(demand, "roll")
    local pitch = demandComponent(demand, "pitch")
    local yaw = demandComponent(demand, "yaw")

    local requested = tonumber(demand.collective) or 0
    local lower, upper = collectiveBounds(profile)
    local collective = clamp(requested, lower, upper)
    local collectiveClamped = (collective ~= requested)

    -- Each corner's attitude contribution at full scale.
    local contributions = {}
    for _, corner in ipairs(CORNERS) do
        local coefficients = profile.corners[corner]
        contributions[corner] =
            roll * profile.authority.roll * coefficients.roll
            + pitch * profile.authority.pitch * coefficients.pitch
    end

    local scale = attitudeScale(profile, collective, contributions)

    local ions = {}
    for _, corner in ipairs(CORNERS) do
        local raw = collective + (profile.corners[corner].bias or 0)
            + contributions[corner] * scale
        -- The algebra already guarantees this range; the clamp only absorbs
        -- floating-point dust at the limits, where a command one ulp over
        -- would be rejected by the pod rather than saturating gracefully.
        ions[corner] = clamp(raw, profile.ion.minimumPower, profile.ion.maximumPower)
    end

    return {
        props = { rpm = profile.props.rpm },
        ions = ions,
        expected = expectedThrust(profile, ions),

        saturated = scale < 1.0,
        attitudeScale = scale,
        collectiveClamped = collectiveClamped,

        -- Yaw is unsolved on this craft: aero.getMagneticNorth() returns
        -- {0,0,0} here, so there is no heading datum, and no actuator is wired
        -- to the axis yet. The channel exists so that solving yaw via the
        -- gyroscopic propeller bearings plugs into an interface that already
        -- exists instead of rewriting every caller.
        yawAvailable = false,
        unmet = { yaw = yaw },
    }
end

return mixer
