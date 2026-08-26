-- The atmosphere, evaluated locally for free.
--
-- Pure Lua. Requires nothing, and once built it makes NO CC:Sable calls -- so a
-- control loop can ask for pressure as often as it likes.
--
-- ---------------------------------------------------------------------------
-- WHY THIS EXISTS (and why the obvious version of step 4 is pointless)
--
-- HANDOFF.md said to use aero.getRaw().pressureFunction instead of the sampled
-- profile. Measured, that swap on its own buys nothing:
--
--     evaluateFunction   49.020 ms/call
--     getAirPressure     49.980 ms/call        -> 1.02x
--
-- Both are main-thread Sable calls costing a server tick. The sample loop
-- already runs ~950 ms against a 250 ms target because it is full of calls like
-- these; trading one for the other changes nothing.
--
-- The actual win is getPoints(). It returns the WHOLE CURVE in one call -- five
-- control points -- so the curve can be read once at startup and evaluated
-- locally forever after, at zero Sable cost. That is what this module is.
--
-- ---------------------------------------------------------------------------
-- THE CURVE
--
-- getPoints() on the creative superflat test server, 2026-08-25:
--
--     altitude   -38.366   63.000   263.000   280.000   320.000
--     value        1.500    1.000     0.449     0.420     0.000
--     slope       -0.0060  -0.0040  -0.001797 -0.001679 -0.020990
--
-- Interpolation is CUBIC HERMITE on (altitude, value, slope). That was derived
-- from the data, not assumed: against the measured pressures Hermite lands
-- within 3e-6 to 8e-6, while the exponential the scale height suggests is off
-- by 6e-5 -- an order of magnitude worse. tools/test_atmosphere.lua asserts
-- both facts, so a future "simplification" to an exponential fails loudly.
--
-- Two corrections to HANDOFF.md fall out of those points:
--
--   * "The atmosphere is not a clean exponential" is misleading. BELOW 280 it
--     very nearly is: every segment has slope/value = -0.004 to five digits,
--     i.e. H = 250 blocks. The old r2 = 0.976 fit failed because it was fitted
--     ACROSS the collapse above 280, not because the atmosphere is messy.
--   * There is a HARD CEILING at y = 320 where pressure is exactly 0. Props
--     make no thrust there. That is a flight envelope limit and it had not been
--     recorded anywhere.
-- ---------------------------------------------------------------------------

local atmosphere = {}

local function isFiniteNumber(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

-- Cubic Hermite across one segment. `span` scales the tangents because the
-- slopes are dPressure/dAltitude in world units, not per-unit-t.
local function hermite(t, span, p0, m0, p1, m1)
    local t2 = t * t
    local t3 = t2 * t

    local h00 =  2 * t3 - 3 * t2 + 1
    local h10 =      t3 - 2 * t2 + t
    local h01 = -2 * t3 + 3 * t2
    local h11 =      t3 -     t2

    return h00 * p0 + h10 * span * m0 + h01 * p1 + h11 * span * m1
end

-- Build a model from control points. Copies them, so a later mutation of the
-- caller's table cannot silently change the atmosphere underneath a running
-- controller.
function atmosphere.fromPoints(points)
    if type(points) ~= "table" or #points == 0 then
        error("atmosphere.fromPoints needs a non-empty list of control points", 2)
    end

    local knots = {}
    for index, point in ipairs(points) do
        if type(point) ~= "table"
            or not isFiniteNumber(point.altitude)
            or not isFiniteNumber(point.value)
            or not isFiniteNumber(point.slope) then
            error("control point " .. index
                .. " needs finite altitude, value and slope", 2)
        end
        knots[index] = {
            altitude = point.altitude,
            value = point.value,
            slope = point.slope,
        }
    end

    -- getPoints() came back sorted, but nothing promises it always will, and a
    -- mis-ordered curve would be quietly wrong everywhere rather than visibly
    -- broken.
    table.sort(knots, function(a, b) return a.altitude < b.altitude end)

    local lowest, highest = knots[1], knots[#knots]

    local model = {
        points = knots,
        floor = lowest.altitude,
        ceiling = highest.altitude,
    }

    -- Where the curve stops being exponential. Every segment below this shares
    -- slope/value = -0.004; the last one does not, because it dives to zero.
    -- Reported rather than used: it is what makes the scale height meaningful
    -- and it marks the edge of the well-behaved region.
    local exponentialTo, rateSum, rateCount = nil, 0, 0
    for index = 1, #knots - 1 do
        local knot = knots[index]
        if knot.value ~= 0 then
            local rate = knot.slope / knot.value
            local nextKnot = knots[index + 1]
            local nextRate = nextKnot.value ~= 0 and (nextKnot.slope / nextKnot.value) or nil
            if nextRate and math.abs(rate - nextRate) < 1e-6 then
                rateSum = rateSum + rate
                rateCount = rateCount + 1
                exponentialTo = nextKnot.altitude
            end
        end
    end

    model.exponentialTo = exponentialTo
    model.scaleHeight = rateCount > 0 and math.abs(rateCount / rateSum) or nil

    -- Evaluate. Zero Sable calls, by construction: everything it needs is in
    -- `knots`, captured above.
    function model.pressureAt(altitude)
        if not isFiniteNumber(altitude) then
            error("pressureAt needs a finite altitude", 2)
        end

        -- Below the curve the pressure is flat, not extrapolated: measured,
        -- y=-64 reads exactly 1.5, the same as the lowest knot.
        if altitude <= lowest.altitude then
            return lowest.value
        end
        -- At and above the ceiling there is no atmosphere at all. Extrapolating
        -- the last segment would hand back a negative pressure, which would
        -- read as thrust in the wrong direction.
        if altitude >= highest.altitude then
            return highest.value
        end

        for index = 1, #knots - 1 do
            local low, high = knots[index], knots[index + 1]
            if altitude <= high.altitude then
                local span = high.altitude - low.altitude
                if span <= 0 then
                    return low.value
                end
                return hermite((altitude - low.altitude) / span, span,
                    low.value, low.slope, high.value, high.slope)
            end
        end

        return highest.value
    end

    return model
end

-- Read the curve out of CC:Sable once. Call this at startup, keep the model.
--
-- Returns nil plus a reason instead of erroring, so a pod running an older
-- CC:Sable degrades to sampling rather than refusing to boot.
function atmosphere.load(aeroApi)
    aeroApi = aeroApi or aero
    if type(aeroApi) ~= "table" or type(aeroApi.getRaw) ~= "function" then
        return nil, "aero API unavailable"
    end

    local ok, raw = pcall(aeroApi.getRaw)
    if not ok or type(raw) ~= "table" then
        return nil, "aero.getRaw() failed: " .. tostring(raw)
    end

    local pressureFunction = raw.pressureFunction
    if type(pressureFunction) ~= "table"
        or type(pressureFunction.getPoints) ~= "function" then
        return nil, "pressureFunction.getPoints is unavailable"
    end

    local gotPoints, points = pcall(pressureFunction.getPoints)
    if not gotPoints or type(points) ~= "table" then
        return nil, "getPoints() failed: " .. tostring(points)
    end

    local built, model = pcall(atmosphere.fromPoints, points)
    if not built then
        return nil, "control points were unusable: " .. tostring(model)
    end
    return model
end

-- Cross-check the local model against the mod itself. Costs one Sable call per
-- altitude, so it is a startup or diagnostic step, never an inner-loop one.
--
-- This exists because the top segment (280 -> 320) has never been measured:
-- the probe read pressures below 280 and at 320, nothing between. The Hermite
-- evaluation there is inference. Run this in game to confirm or refute it.
function atmosphere.verify(model, altitudes, aeroApi)
    aeroApi = aeroApi or aero
    if type(aeroApi) ~= "table" or type(aeroApi.getAirPressure) ~= "function" then
        return nil, "aero.getAirPressure unavailable"
    end

    local worst, worstAt, rows = 0, nil, {}
    for _, altitude in ipairs(altitudes) do
        local ok, measured = pcall(aeroApi.getAirPressure, vector.new(0, altitude, 0))
        if ok and type(measured) == "number" then
            local predicted = model.pressureAt(altitude)
            local error = math.abs(predicted - measured)
            if error > worst then
                worst, worstAt = error, altitude
            end
            rows[#rows + 1] = {
                altitude = altitude,
                predicted = predicted,
                measured = measured,
                error = error,
            }
        end
    end

    return { worst = worst, worstAt = worstAt, rows = rows }
end

return atmosphere
