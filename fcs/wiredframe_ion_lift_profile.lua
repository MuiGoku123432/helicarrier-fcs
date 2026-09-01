-- Ion lift profile: step the ion banks through their hardware levels and
-- measure what each one is worth.
--
--     /fcs/wiredframe_ion_lift_profile.lua --ion-lift-profile
--     /fcs/wiredframe_ion_lift_profile.lua --self-test
--
-- WHY THIS EXISTS
--
-- Everything known about ion thrust so far is inferred from three points: the
-- reported quanta in fcs/ionsweep.lua, one neutral-hover run at level 2/15, and
-- the drift-test climb at 3/15. The intended architecture is ions carrying lift
-- while the props are left free for stabilisation and movement, and that needs
-- the whole curve, not three points.
--
-- WHAT IT DOES
--
-- Steps the ion command up one hardware level at a time, holding each for a
-- configurable dwell, then steps back down the same way. Tilt and azimuth are
-- exactly zero throughout and the props sit at a fixed RPM. There is no drift
-- logic, no position loop, and no vertical feedback: the point is to measure
-- the plant, so nothing may quietly correct it.
--
-- HOW THRUST-TO-WEIGHT IS OBTAINED
--
-- The pods report applied commands and transport counters, not thrust, so T/W
-- has to come from motion. Immediately after a step, before speed builds and
-- drag matters, vertical acceleration is very nearly (T - W)/m, so
--
--     T/W = 1 + a / g
--
-- The harness samples acceleration in a short window right after each step for
-- exactly that reason, and separately records the terminal climb rate at the
-- end of the dwell, where drag has balanced the excess thrust.
--
-- IMPORTANT: absolute T/W depends on the configured gravity below, which is an
-- estimate. The level at which acceleration crosses ZERO does not depend on it
-- at all -- that crossing is the hover level, it falls straight out of the
-- measured accelerations, and it is the number this test exists to find. Treat
-- `hover_level` as the result and the T/W column as indicative.

local source = debug.getinfo(1, "S").source
local scriptDirectory = source:match("^@(.+)/[^/]+$")
if scriptDirectory and package and type(package.path) == "string" then
    local moduleRoot = scriptDirectory:match("^(.*)/[^/]+$")
    if moduleRoot == nil then moduleRoot = "." end
    if moduleRoot == "" then moduleRoot = "/" end
    package.path = moduleRoot .. "/?.lua;" .. moduleRoot .. "/?/init.lua;"
        .. package.path
end

local args = { ... }

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

local DWELL_SECONDS = 30          -- hold at each level
local STEP_SETTLE_SECONDS = 1.0   -- ignored after a step before measuring accel
local STEP_MEASURE_SECONDS = 3.0  -- acceleration window used for the T/W estimate
local START_LEVEL = 1
local MAX_LEVEL = 15
-- Props are what made run 2 unreadable. They carry 52.1% of weight at 64 RPM
-- and their thrust falls with air pressure while ion thrust does not, so with
-- props flying the measurement is a function of altitude as well as ion level
-- and no clean ion curve exists.
--
-- Prop thrust is close to linear in RPM: 122 RPM is about hover and 64 RPM
-- measures 52.1% of weight, which the linear fit puts at 52.5%. At 8 RPM props
-- are therefore about 6.6% of weight, and across a 100-block sweep their
-- variation is 2.2% of weight -- a tenth of one ion level. Negligible.
--
-- 8 RPM also keeps the gyroscopic bearings turning, which is what stabilises
-- the craft. wiredframe_bearing_rpm8_run1 and wiredframe_corner_map_run1 both
-- exercised the bearings at this RPM successfully.
--
-- 0 is permitted by the pod for a genuinely ion-only reading, but NOTHING is
-- known about whether the bearings stabilise at zero, and an unstabilised craft
-- under four corner thrusters can tumble. Do not use 0 without deciding that
-- risk deliberately.
local PROP_RPM = 8
local FALLBACK_ION_POWER = 0.07
local FALLBACK_STOP_AFTER_MS = 5000

-- Ends the ascent early and begins the descent. At the upper levels the craft
-- accelerates hard: a full dwell at 15/15 would leave the world long before 30
-- seconds elapsed, so the sweep is altitude-bounded, not level-bounded.
local CEILING_BLOCKS = 1000
-- Stops the descent stepping any lower. Below this the harness holds its
-- current level and waits for the operator rather than walking the craft into
-- the ground.
-- Descent guards. Removing the props' 52.1% of weight makes every sub-hover
-- level a much harder fall than it was in runs 1 and 2: at 8 RPM level 0 is a
-- 0.93g drop where at 64 RPM it was 0.48g. The old ladder walked all the way to
-- level 0 and let the props soften the landing, which is no longer available.
local FLOOR_BLOCKS = 30
-- Ends the descent ladder if the craft is dropping this fast, whatever level it
-- is on. Two levels below hover is all the measurement needs; the rest of the
-- ladder is only risk.
local MAX_DESCENT_SPEED = 8
-- Levels below the lowest one that flew are never commanded on the way down.
local DESCENT_LEVELS_BELOW_HOVER = 2
-- Before shutting down, climb until the fall is arrested. shutdownBurst commands
-- ion 0 and RPM 0, which from altitude is an unpowered drop; runs 1 and 2 only
-- survived it because they had already landed.
local ARREST_SPEED = 0.5
local ARREST_TIMEOUT_SECONDS = 25

-- Rise above which the craft is genuinely flying rather than unloading its
-- contact with the ground. ionsweep.lua records a 0.077 block rise at 96.7% of
-- weight WITHOUT flying, so this sits well clear of that.
--
-- This distinction is the whole reason run 1 produced no usable curve. On the
-- ground the floor supports the craft, so acceleration reads ~0 whatever the
-- ion level: run 1's levels 1 and 2 moved 0.0017 and 0.0155 blocks in 30
-- seconds and reported accelerations of +0.020 and +0.006, which measure the
-- ground, not thrust. Sub-hover levels can therefore only be measured while
-- ALREADY AIRBORNE, which is what the descent leg is for.
local AIRBORNE_BLOCKS = 0.5

-- On the way up, a level that cannot lift the craft has nothing to say. Probe
-- briefly and move on instead of burning a full dwell sitting on the floor.
local GROUND_PROBE_SECONDS = 8

-- Prop thrust falls with air pressure on a 250-block scale height while ion
-- thrust does not, so T/W is a function of BOTH level and altitude and there is
-- no single hover level. Run 2 interpolated 3/15 measured at 220 blocks against
-- 4/15 measured at 122 blocks, where props differ by 32%, and reported a
-- meaningless 3.552. Two levels may only be compared if they were measured at
-- nearly the same altitude.
-- At 64 RPM props were 52.1% of weight and a 100-block gap moved T/W by 0.77
-- of an ion level, so comparisons had to be tight. At 8 RPM props are ~6.6% and
-- the same gap moves it by 0.10 of a level, so this can be far wider. Above
-- y=320 the atmosphere is gone entirely and props contribute nothing at all.
local HOVER_COMPARE_MAX_ALTITUDE_GAP = 300


-- Only for the indicative T/W column. Estimated from drift-test run 6, where
-- level 3/15 (about 1.19 of weight) produced roughly 0.83 blocks/s^2 early in
-- the climb. The hover-level result does not depend on this value.
local GRAVITY_BLOCKS_PER_SECOND2 = 4.4

local RESULT_PATH = "/fcs/wiredframe_ion_lift_profile_result.txt"
local CONFIRMATION = "ION-LIFT"

-- Transport
local CONTROL_CHANNEL, STATUS_CHANNEL = 42042, 42043
local PROTOCOL = "helicarrier.control-frame.v1"
local MODE = "ion_profile"
local CORNERS = { "FL", "FR", "RL", "RR" }
local CORNER_SET = { FL = true, FR = true, RL = true, RR = true }
local SEND_INTERVAL_SECONDS = 0.25
-- Run 3 aborted because a single frame aged out on all four pods at once
-- during a level transition, where three terminal prints land between two
-- transmits. 750 ms is a tight budget for that; CC terminal writes are slow.
-- The pod still falls back on its own if the FCS genuinely stops talking.
local VALID_FOR_MS, SHUTDOWN_VALID_FOR_MS = 1500, 5000

-- Pod counters are cumulative and never reset, so aborting on any non-zero
-- value means one transient ends the run and, worse, makes the shutdown
-- confirmation unsatisfiable forever after. A few expired frames are a
-- transport hiccup. fallbackStops is the serious event: it means a pod
-- actually cut its thrust, and that aborts immediately at any count.
local TOLERATED_EXPIRED = 3
local TOLERATED_FALLBACKS = 3
local PRECHECK_SECONDS, SHUTDOWN_SECONDS = 5, 3
local TELEMETRY_MAX_AGE_MS = 1250
local POD_MAX_AGE_MS = 1750

-- Loss-of-control stops. Vertical speed is deliberately NOT bounded: large
-- vertical speed is the measurement. Attitude and lateral motion are bounded,
-- because at zero commanded tilt any of either means something is wrong.
local MAX_HULL_TILT = 12
local MAX_ANGULAR_SPEED = 1.5
-- Run 1 aborted here at 8 blocks/s. That was the harness being wrong, not the
-- craft: this test commands ZERO tilt, so there is no lateral control at all and
-- any inherited drift or off-centre load accelerates the craft sideways
-- unopposed for the whole run. Even the full stationkeeping loop saw 7.4
-- blocks/s fighting an off-centre load (run 8). Lateral drift is an expected
-- condition of an open-loop lift test, not a fault, so this is now a runaway
-- stop rather than a drift stop. Hull tilt and angular speed remain the real
-- loss-of-control guards.
local MAX_HORIZONTAL_SPEED = 25
local MAX_FALL_BELOW_START = 5

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function finite(value)
    return type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
end

local function vector3(value)
    if type(value) ~= "table" then return nil end
    local x = tonumber(value.x or value[1])
    local y = tonumber(value.y or value[2])
    local z = tonumber(value.z or value[3])
    if not finite(x) or not finite(y) or not finite(z) then return nil end
    return { x = x, y = y, z = z }
end

local function quaternion(pose)
    if type(pose) ~= "table" then return nil end
    local candidate = pose.orientation or pose.rotation or pose.quaternion or pose
    if type(candidate) ~= "table" then return nil end
    local vector = candidate.v or candidate.vector or candidate
    local x = tonumber(vector.x or vector[1])
    local y = tonumber(vector.y or vector[2])
    local z = tonumber(vector.z or vector[3])
    local w = tonumber(candidate.a or candidate.w or candidate[4])
    if not finite(w) or not finite(x) or not finite(y) or not finite(z) then
        return nil
    end
    local length = math.sqrt(w * w + x * x + y * y + z * z)
    if length <= 1e-12 then return nil end
    return { w = w / length, x = x / length, y = y / length, z = z / length }
end

local function positionFromPose(pose)
    if type(pose) ~= "table" then return nil end
    for _, field in ipairs({ "position", "pos", "translation", "location" }) do
        local position = vector3(pose[field])
        if position then return position end
    end
    return nil
end

local function hullTiltDegrees(q)
    local upY = 1 - 2 * (q.x * q.x + q.z * q.z)
    upY = math.max(-1, math.min(1, upY))
    return math.deg(math.acos(upY))
end

-- The driver quantises to fifteenths as applied = floor(commanded * 15) / 15.
-- Commanding the bare fraction sits exactly on a boundary where float error can
-- fall to the level below, so aim a little inside each band. Level 15 is the
-- top of the range and 1.0 is already exact there.
local function powerForLevel(level)
    if level >= 15 then return 1.0 end
    return level / 15 + 0.005
end

local function quantisedLevel(power)
    return math.floor(power * 15)
end

-- Acceleration during a dwell is (T - W)/m MINUS drag, and drag grows with
-- speed. Runs 1-3 tried to dodge that by sampling just after a step, but with
-- no vertical feedback the craft is never at rest and every reading came back
-- drag-contaminated.
--
-- Instead of waiting for a stillness that never comes, sample the whole dwell
-- and extrapolate. Fitting a = A + B*v + C*v^2 over the dwell and taking A --
-- the value at v = 0 -- gives the drag-free acceleration directly, because the
-- drag terms carry all the velocity dependence. A dwell that spans 0 to 12
-- blocks/s constrains that fit well.
local function fitAccelerationAtRest(series)
    if #series < 8 then return nil, "fewer than 8 samples" end

    local points = {}
    local minV, maxV = math.huge, -math.huge
    for index = 2, #series do
        local a, b = series[index - 1], series[index]
        local dt = (b.t - a.t) / 1000
        if dt > 0 then
            local v = (a.v + b.v) / 2
            points[#points + 1] = { v = v, a = (b.v - a.v) / dt }
            if v < minV then minV = v end
            if v > maxV then maxV = v end
        end
    end
    if #points < 6 then return nil, "fewer than 6 usable intervals" end
    local span = maxV - minV
    if span < 1.0 then
        return nil, string.format("velocity span %.2f too narrow to separate drag", span)
    end

    -- Normal equations for a quadratic least-squares fit.
    local n = #points
    local s0, s1, s2, s3, s4 = n, 0, 0, 0, 0
    local t0, t1, t2 = 0, 0, 0
    for _, point in ipairs(points) do
        local v = point.v
        local v2 = v * v
        s1 = s1 + v; s2 = s2 + v2; s3 = s3 + v2 * v; s4 = s4 + v2 * v2
        t0 = t0 + point.a; t1 = t1 + point.a * v; t2 = t2 + point.a * v2
    end
    local m = {
        { s0, s1, s2, t0 },
        { s1, s2, s3, t1 },
        { s2, s3, s4, t2 },
    }
    for column = 1, 3 do
        local pivot = column
        for row = column + 1, 3 do
            if math.abs(m[row][column]) > math.abs(m[pivot][column]) then pivot = row end
        end
        m[column], m[pivot] = m[pivot], m[column]
        if math.abs(m[column][column]) < 1e-12 then
            return nil, "fit is singular"
        end
        for row = 1, 3 do
            if row ~= column then
                local factor = m[row][column] / m[column][column]
                for col = column, 4 do
                    m[row][col] = m[row][col] - factor * m[column][col]
                end
            end
        end
    end
    local intercept = m[1][4] / m[1][1]
    if not finite(intercept) then return nil, "fit did not converge" end
    return intercept, nil, #points, span
end

local function thrustToWeight(acceleration)
    if not finite(acceleration) then return nil end
    return 1 + acceleration / GRAVITY_BLOCKS_PER_SECOND2
end

local function command(level)
    if level == nil then
        return {
            ionPower = 0, fallbackIonPower = 0, propRpm = 0,
            tiltDegrees = 0, azimuthDegrees = 0, shutdown = true,
        }
    end
    return {
        ionPower = level == 0 and 0 or powerForLevel(level),
        fallbackIonPower = level == 0 and 0 or FALLBACK_ION_POWER,
        fallbackStopAfterMs = FALLBACK_STOP_AFTER_MS,
        propRpm = PROP_RPM,
        tiltDegrees = 0, azimuthDegrees = 0, shutdown = false,
    }
end

local function frame(session, sequence, sentAt, level)
    local commands = {}
    for _, corner in ipairs(CORNERS) do commands[corner] = command(level) end
    return {
        protocol = PROTOCOL, kind = "control_frame", mode = MODE, armed = true,
        session = session, sequence = sequence, sentAt = sentAt,
        validForMs = level == nil and SHUTDOWN_VALID_FOR_MS or VALID_FOR_MS,
        corners = commands,
    }
end

-- Faults that must never happen at all: a malformed or misrouted frame, or an
-- actuator write that failed.
local function countersClean(status)
    if type(status) ~= "table" then return false end
    for _, field in ipairs({
        "missing", "duplicates", "outOfOrder", "invalid", "applyErrors",
    }) do
        if (tonumber(status[field]) or 0) ~= 0 then return false end
    end
    return true
end

-- Returns a fault string, or nil. Separated from countersClean because pod
-- counters are cumulative: treating a single stale frame as fatal both ends the
-- run on a transient and leaves the shutdown confirmation permanently
-- unsatisfiable, which is exactly what happened on run 3.
local function statusFault(status)
    if type(status) ~= "table" then return "no status" end
    if not countersClean(status) then return "transport or apply fault" end
    if (tonumber(status.fallbackStops) or 0) > 0 then
        return "pod stopped thrust in fallback"
    end
    if (tonumber(status.expiredBeforeApply) or 0) > TOLERATED_EXPIRED then
        return "repeated expired frames"
    end
    if (tonumber(status.fallbackCount) or 0) > TOLERATED_FALLBACKS then
        return "repeated stale fallback"
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Self-test: no CC APIs, no modem, no actuation
-- ---------------------------------------------------------------------------

-- Interpolates the level at which vertical acceleration crosses zero, i.e.
-- where thrust equals weight AT THE ALTITUDE THE READINGS WERE TAKEN.
--
-- There is no single hover level for this craft. Prop thrust falls with air
-- pressure while ion thrust does not, so hover level rises with altitude. Two
-- levels may therefore only be compared if they were measured at nearly the
-- same height, and the answer must be reported with that height attached.
--
-- Rows are excluded unless they are "airborne": a grounded craft reads ~0
-- acceleration at every level because the floor carries it, and a reading taken
-- at speed is mostly drag. Run 1 failed to bracket because the ground never let
-- anything read negative; run 2 bracketed across a 98-block altitude gap and
-- produced a meaningless answer. Both are guarded here, and the function
-- returns WHY it refused rather than a number nobody can trust.
local function hoverLevelFrom(records)
    local usable = {}
    for _, record in ipairs(records) do
        if record.state == "airborne" and record.acceleration
            and record.measureRise then
            local existing = usable[record.level]
            if not existing or record.direction == "down" then
                usable[record.level] = record
            end
        end
    end

    local levels = {}
    for level in pairs(usable) do levels[#levels + 1] = level end
    table.sort(levels)
    if #levels < 2 then
        return nil, "fewer than two drag-free airborne levels"
    end

    local rejectedForAltitude = false
    for index = 2, #levels do
        local below, above = usable[levels[index - 1]], usable[levels[index]]
        if below.acceleration < 0 and above.acceleration >= 0 then
            local gap = math.abs(above.measureRise - below.measureRise)
            if gap > HOVER_COMPARE_MAX_ALTITUDE_GAP then
                rejectedForAltitude = true
            else
                local span = above.acceleration - below.acceleration
                if span > 0 then
                    local level = below.level
                        + (0 - below.acceleration) / span
                            * (above.level - below.level)
                    return level, string.format(
                        "%d/15(a=%.3f,y=%.1f)..%d/15(a=%.3f,y=%.1f) gap %.1f blocks",
                        below.level, below.acceleration, below.measureRise,
                        above.level, above.acceleration, above.measureRise, gap)
                end
            end
        end
    end

    if rejectedForAltitude then
        return nil, string.format(
            "bracket found but the two levels were measured more than %d blocks "
                .. "apart; prop thrust differs too much to compare them",
            HOVER_COMPARE_MAX_ALTITUDE_GAP)
    end
    return nil, "no sign change across drag-free airborne levels"
end

if args[1] == "--self-test" then
    for level = 1, 15 do
        assert(quantisedLevel(powerForLevel(level)) == level,
            "level " .. level .. " must quantise to itself")
        assert(powerForLevel(level) <= 1, "command must stay inside 0..1")
    end
    assert(command(0).ionPower == 0)
    assert(command(0).propRpm == PROP_RPM, "props run even at ion level 0")
    assert(quantisedLevel(command(3).ionPower) == 3)

    local stop = frame("self", 1, 1000, nil)
    assert(stop.corners.FL.shutdown == true)
    assert(stop.corners.FL.ionPower == 0 and stop.corners.FL.propRpm == 0)
    assert(stop.validForMs == SHUTDOWN_VALID_FOR_MS)

    local live = frame("self", 2, 1001, 7)
    assert(live.protocol == PROTOCOL and live.mode == MODE and live.armed == true)
    for _, corner in ipairs(CORNERS) do
        assert(quantisedLevel(live.corners[corner].ionPower) == 7)
        assert(live.corners[corner].tiltDegrees == 0)
        assert(live.corners[corner].azimuthDegrees == 0)
        assert(live.corners[corner].propRpm == PROP_RPM)
    end

    -- T/W is anchored so that zero acceleration is hover, whatever gravity is.
    assert(math.abs(thrustToWeight(0) - 1) < 1e-12,
        "zero acceleration must read as exactly hover")
    assert(thrustToWeight(1) > 1 and thrustToWeight(-1) < 1)

    assert(countersClean({ missing = 0, duplicates = 0, outOfOrder = 0,
        invalid = 0, expiredBeforeApply = 0, applyErrors = 0 }))
    assert(not countersClean({ missing = 1 }))

    -- The ground-contact trap that cost run 1: a grounded craft reads ~0
    -- acceleration at every level, so grounded rows must never reach the fit.
    local grounded = {
        { level = 1, direction = "up", state = "grounded", acceleration = 0.020 },
        { level = 2, direction = "up", state = "grounded", acceleration = 0.006 },
        { level = 3, direction = "up", state = "transition", acceleration = 1.240 },
    }
    assert(hoverLevelFrom(grounded) == nil,
        "grounded and transition rows must not produce a hover level")

    local flying = {
        { level = 1, direction = "down", state = "airborne",
          acceleration = -2.0, measureRise = 100 },
        { level = 2, direction = "down", state = "airborne",
          acceleration = -0.5, measureRise = 102 },
        { level = 3, direction = "down", state = "airborne",
          acceleration = 1.5, measureRise = 104 },
    }
    local level, note = hoverLevelFrom(flying)
    assert(level and math.abs(level - 2.25) < 1e-9,
        "airborne rows at matched altitude must bracket hover")
    assert(note and note:find("2/15") and note:find("3/15"))

    -- Mixed: the grounded ascent rows must not shift the answer.
    local mixed = {}
    for _, r in ipairs(grounded) do mixed[#mixed + 1] = r end
    for _, r in ipairs(flying) do mixed[#mixed + 1] = r end
    local mixedLevel = hoverLevelFrom(mixed)
    assert(mixedLevel and math.abs(mixedLevel - 2.25) < 1e-9,
        "grounded rows must not perturb the airborne fit")

    -- Run 2's 98-block spread was fatal at 64 RPM, where props were 52.1% of
    -- weight. At 8 RPM props are ~6.6% and that same gap shifts T/W by about a
    -- tenth of a level, so it is now acceptable and must produce an answer.
    local spread = {
        { level = 3, direction = "down", state = "airborne",
          acceleration = -1.922, measureRise = 220.5 },
        { level = 4, direction = "up", state = "airborne",
          acceleration = 1.557, measureRise = 122.6 },
    }
    assert(hoverLevelFrom(spread),
        "a 98-block gap is tolerable once props are at the near-zero-lift RPM")

    -- Beyond the configured gap it must still refuse and say why.
    local farApart = {
        { level = 3, direction = "down", state = "airborne",
          acceleration = -1.0, measureRise = 20 },
        { level = 4, direction = "up", state = "airborne",
          acceleration = 1.0,
          measureRise = 20 + HOVER_COMPARE_MAX_ALTITUDE_GAP + 1 },
    }
    local farLevel, farNote = hoverLevelFrom(farApart)
    assert(farLevel == nil,
        "levels beyond the altitude gap must not be interpolated")
    assert(farNote and farNote:find("apart"), "the refusal must say why")

    -- A level whose fit could not be made must not be fitted.
    local unfitted = {
        { level = 2, direction = "down", state = "airborne_unfitted",
          acceleration = -1.29, measureRise = 90 },
        { level = 4, direction = "up", state = "airborne",
          acceleration = 1.56, measureRise = 92 },
    }
    assert(hoverLevelFrom(unfitted) == nil,
        "levels without a usable fit must not be fitted")

    -- The drag extrapolation must recover a known answer. Simulate a dwell with
    -- a true rest acceleration of 2.0 and quadratic drag: a(v) = 2.0 - 0.02*v^2.
    -- Every sample is drag-contaminated -- the craft is never at rest -- yet the
    -- extrapolation to v = 0 must still return 2.0.
    local simulated, v, t = {}, 0, 0
    for _ = 1, 120 do
        simulated[#simulated + 1] = { t = t, v = v }
        v = v + (2.0 - 0.02 * v * v) * 0.25
        t = t + 250
    end
    local fitted, reason, count, span = fitAccelerationAtRest(simulated)
    assert(fitted, "the extrapolation must produce a value: " .. tostring(reason))
    assert(math.abs(fitted - 2.0) < 0.05,
        string.format("extrapolation returned %.4f, expected 2.0", fitted))
    assert(count and count > 100 and span and span > 5)
    assert(simulated[#simulated].v > 8,
        "the simulated dwell must actually reach a drag-dominated speed")

    -- Too few samples, or too narrow a velocity span, must refuse.
    assert(fitAccelerationAtRest({ { t = 0, v = 0 }, { t = 250, v = 1 } }) == nil,
        "a short series must not be fitted")
    local flat = {}
    for index = 1, 40 do flat[index] = { t = index * 250, v = 3.0 } end
    local flatFit, flatReason = fitAccelerationAtRest(flat)
    assert(flatFit == nil and flatReason and flatReason:find("span"),
        "a constant-velocity dwell cannot separate drag and must refuse")

    assert(HOVER_COMPARE_MAX_ALTITUDE_GAP > 0)
    assert(AIRBORNE_BLOCKS > 0.077,
        "airborne threshold must clear the measured contact-unloading rise")
    assert(GROUND_PROBE_SECONDS < DWELL_SECONDS)

    -- The pod's ion_profile validator accepts only these two prop RPMs.
    assert(PROP_RPM == 8 or PROP_RPM == 0,
        "ion_profile accepts prop RPM 8 or 0 only; see the note above PROP_RPM")
    assert(MODE == "ion_profile",
        "this harness must not run under a mode that permits lateral authority")
    for _, level in ipairs({ 0, 1, 7, 15 }) do
        local c = command(level)
        assert(c.tiltDegrees == 0 and c.azimuthDegrees == 0,
            "ion profile commands must carry no lateral authority")
        assert(c.propRpm == PROP_RPM)
        assert(c.fallbackIonPower <= c.ionPower,
            "fallback must never exceed the commanded ion power")
    end
    assert(START_LEVEL >= 1 and MAX_LEVEL <= 15 and START_LEVEL <= MAX_LEVEL)
    assert(FLOOR_BLOCKS < CEILING_BLOCKS)
    assert(STEP_SETTLE_SECONDS + STEP_MEASURE_SECONDS < DWELL_SECONDS,
        "the acceleration window must fit inside a dwell")

    print("ion lift profile self-test: PASS")
    return
end

if args[1] ~= "--ion-lift-profile" then
    error("use --ion-lift-profile; this steps the ion banks and measures lift", 0)
end

-- ---------------------------------------------------------------------------
-- Live run
-- ---------------------------------------------------------------------------

local function safeCall(api, method)
    local fn = api and api[method]
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn)
    if not ok then return nil end
    return value
end

local POSITION_METHODS = {
    "getPosition", "getLogicalPosition", "getContraptionPosition", "getWorldPosition",
}

local function readSample(api)
    local startedAt = os.epoch("utc")
    local pose = safeCall(api, "getLogicalPose")
    local linear = vector3(safeCall(api, "getLinearVelocity"))
    local angular = vector3(safeCall(api, "getAngularVelocity"))
    local position = positionFromPose(pose)
    if not position then
        for _, method in ipairs(POSITION_METHODS) do
            position = vector3(safeCall(api, method))
            if position then break end
        end
    end
    local finishedAt = os.epoch("utc")
    return {
        finishedAt = finishedAt,
        elapsedMs = finishedAt - startedAt,
        quaternion = quaternion(pose),
        position = position,
        linearVelocity = linear,
        angularVelocity = angular,
    }
end

local function sampleValid(sample)
    return type(sample) == "table"
        and finite(sample.finishedAt)
        and finite(sample.elapsedMs) and sample.elapsedMs <= TELEMETRY_MAX_AGE_MS
        and sample.quaternion and sample.position
        and sample.linearVelocity and sample.angularVelocity
end

local function allModems()
    local result = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            result[#result + 1] = { name = name, modem = peripheral.wrap(name) }
        end
    end
    return result
end

local function findWiredModem()
    for _, entry in ipairs(allModems()) do
        local ok, wireless = pcall(entry.modem.isWireless)
        if ok and wireless == false then return entry.modem, entry.name end
    end
    return nil, nil
end

local function closeChannels()
    for _, entry in ipairs(allModems()) do
        pcall(entry.modem.close, CONTROL_CHANNEL)
        pcall(entry.modem.close, STATUS_CHANNEL)
    end
end

local function loadSublevel()
    if type(_G.sublevel) == "table" then return _G.sublevel, "global" end
    if type(require) == "function" then
        local ok, api = pcall(require, "sublevel")
        if ok and type(api) == "table" then return api, "require" end
    end
    return nil, "unavailable"
end

print("ION LIFT PROFILE")
print(string.format("Steps ion levels %d..%d, %ds each, then back down.",
    START_LEVEL, MAX_LEVEL, DWELL_SECONDS))
print(string.format("Props fixed at %d RPM. Tilt and azimuth are exactly zero.", PROP_RPM))
print("No drift logic and no vertical feedback: the craft is NOT held.")
print(string.format("Ascent stops at +%d blocks; descent stops stepping at +%d.",
    CEILING_BLOCKS, FLOOR_BLOCKS))
print("Ctrl+T stops and commands exact-zero shutdown. Clear the area first.")
print("Type " .. CONFIRMATION .. " to arm.")
write("> ")
if read() ~= CONFIRMATION then
    print("Not armed.")
    return
end

local modem, modemName = findWiredModem()
if not modem then error("wired modem unavailable", 0) end
local sublevel, sublevelSource = loadSublevel()
if not sublevel then error("CC:Sable sublevel API unavailable", 0) end
closeChannels()
modem.open(STATUS_CHANNEL)

local session = tostring(os.getComputerID()) .. "-ionlift-" .. tostring(os.epoch("utc"))
local active = true
local stopRequested, abortReason, runError, shutdownError
local phase = "idle"
local sequence, framesSent, samples = 0, 0, 0
local finalSequence
local latestSample, latestTelemetryAt, origin
local statuses, statusAt = {}, {}
local startedAt = os.epoch("utc")
local records = {}
local currentLevel
local ceilingReached = false
local descentSpeedReached = false
local arrested = nil
local liftLevel
local DONE_EVENT = "ion_lift_done"

local function abort(reason)
    if not abortReason then
        abortReason = tostring(reason)
        print("ABORT: " .. abortReason)
    end
end

local function requestStop()
    if not stopRequested then print("Operator stop requested; shutting down.") end
    stopRequested = true
end

local function rise()
    if not latestSample or not origin then return 0 end
    return latestSample.position.y - origin.position.y
end

local function verticalVelocity()
    if not latestSample then return 0 end
    return latestSample.linearVelocity.y
end

local function transmit(level)
    sequence = sequence + 1
    modem.transmit(CONTROL_CHANNEL, STATUS_CHANNEL,
        frame(session, sequence, os.epoch("utc"), level))
    framesSent = framesSent + 1
    return sequence
end

local function recordStatus(status)
    statuses[status.corner] = status
    statusAt[status.corner] = os.epoch("utc")
    if phase ~= "shutdown" then
        local fault = statusFault(status)
        if fault then abort("pod " .. status.corner .. ": " .. fault) end
    end
end

local function podsFresh(expectedLevel)
    local now = os.epoch("utc")
    for _, corner in ipairs(CORNERS) do
        local status = statuses[corner]
        if not status or not statusAt[corner]
            or now - statusAt[corner] > POD_MAX_AGE_MS then
            return false, corner
        end
        if statusFault(status) then return false, corner end
        if expectedLevel and status.appliedIonPower
            and quantisedLevel(status.appliedIonPower) ~= expectedLevel then
            return false, corner
        end
    end
    return true
end

local function rawSleep(seconds, doneEvent, onTerminate)
    local timer = os.startTimer(math.max(0, seconds or 0))
    while true do
        local event, value = os.pullEventRaw()
        if event == "terminate" then
            if onTerminate then onTerminate() end
            return false
        end
        if event == doneEvent then return false end
        if event == "timer" and value == timer then return true end
    end
end

local function receiveLoop()
    while active do
        local event, _, channel, _, message = os.pullEventRaw()
        if event == "terminate" then requestStop() end
        if event == DONE_EVENT then return end
        if event == "modem_message" and channel == STATUS_CHANNEL
            and type(message) == "table" and message.protocol == PROTOCOL
            and message.session == session and CORNER_SET[message.corner] then
            recordStatus(message)
        end
    end
end

local function telemetryLoop()
    while active do
        if phase ~= "shutdown" then
            local sample = readSample(sublevel)
            if sampleValid(sample) then
                latestSample = sample
                latestTelemetryAt = sample.finishedAt
                origin = origin or sample
                samples = samples + 1
                local q = sample.quaternion
                local v = sample.linearVelocity
                local a = sample.angularVelocity
                local horizontal = math.sqrt(v.x * v.x + v.z * v.z)
                local angular = math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
                if phase ~= "idle" then
                    if hullTiltDegrees(q) > MAX_HULL_TILT then
                        abort("hull tilt limit exceeded")
                    elseif angular > MAX_ANGULAR_SPEED then
                        abort("angular speed limit exceeded")
                    elseif horizontal > MAX_HORIZONTAL_SPEED then
                        abort("horizontal speed limit exceeded")
                    elseif rise() < -MAX_FALL_BELOW_START then
                        abort("fell below the start altitude")
                    end
                end
            end
        end
        rawSleep(0.05, DONE_EVENT, requestStop)
    end
end

-- Holds one level for `seconds`, sending continuously. Returns a record of what
-- the craft did. Acceleration is sampled in a window just after the step, where
-- it is closest to (T - W)/m; the terminal climb rate is taken at the end of the
-- dwell, where drag has caught up.
local function holdLevel(level, seconds, direction)
    phase = "level"
    currentLevel = level
    local beganAt = os.epoch("utc")
    local stopAt = beganAt + math.floor(seconds * 1000)
    local measureFrom = beganAt + math.floor(STEP_SETTLE_SECONDS * 1000)
    local measureTo = measureFrom + math.floor(STEP_MEASURE_SECONDS * 1000)

    local riseAtStart, velocityAtStart = rise(), verticalVelocity()
    local series = {}
    local velocityAtMeasureStart, velocityAtMeasureEnd
    local measuredFrom, measuredTo
    local riseAtMeasureStart, riseAtMeasureEnd
    local peakVelocity, minVelocity = velocityAtStart, velocityAtStart

    while os.epoch("utc") < stopAt do
        if stopRequested or abortReason then break end
        transmit(level)

        local now = os.epoch("utc")
        local vy = verticalVelocity()
        -- Every sample feeds the drag extrapolation, not just a short window.
        series[#series + 1] = { t = now, v = vy }
        if vy > peakVelocity then peakVelocity = vy end
        if vy < minVelocity then minVelocity = vy end
        if velocityAtMeasureStart == nil and now >= measureFrom then
            velocityAtMeasureStart, measuredFrom = vy, now
            riseAtMeasureStart = rise()
        end
        if velocityAtMeasureStart ~= nil and now <= measureTo then
            velocityAtMeasureEnd, measuredTo = vy, now
            riseAtMeasureEnd = rise()
        end

        if not latestTelemetryAt
            or now - latestTelemetryAt > TELEMETRY_MAX_AGE_MS then
            abort("telemetry stale")
            break
        end
        if now - beganAt > POD_MAX_AGE_MS then
            local fresh, corner = podsFresh(level)
            if not fresh then
                abort("pod " .. tostring(corner) .. " status stale or off-level")
                break
            end
        end
        if direction == "up" and rise() >= CEILING_BLOCKS then
            ceilingReached = true
            break
        end
        if direction == "up" and rise() < AIRBORNE_BLOCKS
            and now - beganAt >= GROUND_PROBE_SECONDS * 1000 then
            break
        end
        if direction == "down" and verticalVelocity() <= -MAX_DESCENT_SPEED then
            descentSpeedReached = true
            break
        end
        if not rawSleep(SEND_INTERVAL_SECONDS, DONE_EVENT, requestStop) then break end
    end

    -- Raw window acceleration, kept for comparison. It includes drag.
    local windowAcceleration
    if velocityAtMeasureStart and velocityAtMeasureEnd and measuredTo
        and measuredFrom and measuredTo > measuredFrom then
        windowAcceleration = (velocityAtMeasureEnd - velocityAtMeasureStart)
            / ((measuredTo - measuredFrom) / 1000)
    end

    -- The drag-free value, and the one everything downstream uses.
    local acceleration, fitReason, fitPoints, fitSpan = fitAccelerationAtRest(series)

    -- Classify on the MEASUREMENT WINDOW, not the end of the dwell. Run 2's
    -- descent from 90 blocks to the ground was marked "grounded" because it
    -- finished on the floor, discarding a reading that was taken at 90 blocks
    -- in free flight. What matters is where the craft was while the
    -- acceleration was being sampled.
    local riseEnd = rise()
    local measureLow = math.min(riseAtMeasureStart or riseAtStart,
        riseAtMeasureEnd or riseAtStart)
    local state
    if measureLow <= AIRBORNE_BLOCKS then
        state = riseEnd > AIRBORNE_BLOCKS and "transition" or "grounded"
    else
        state = "airborne"
    end

    -- Speed no longer disqualifies a reading: the extrapolation removes drag.
    -- What disqualifies it is a fit that could not be made.
    local measureSpeed = math.max(math.abs(velocityAtMeasureStart or 0),
        math.abs(velocityAtMeasureEnd or 0))
    if state == "airborne" and not acceleration then
        state = "airborne_unfitted"
    end

    local record = {
        level = level,
        direction = direction,
        state = state,
        commandedPower = level == 0 and 0 or powerForLevel(level),
        heldSeconds = (os.epoch("utc") - beganAt) / 1000,
        riseStart = riseAtStart,
        riseEnd = riseEnd,
        measureRise = riseAtMeasureStart,
        measureSpeed = measureSpeed,
        windowAcceleration = windowAcceleration,
        fitReason = fitReason,
        fitPoints = fitPoints,
        fitSpan = fitSpan,
        velocityStart = velocityAtStart,
        velocityEnd = verticalVelocity(),
        peakVelocity = peakVelocity,
        minVelocity = minVelocity,
        acceleration = acceleration,
        thrustToWeight = thrustToWeight(acceleration),
    }
    records[#records + 1] = record

    print(string.format(
        "%s level %2d/15 (ion %.3f) %-17s rise %+8.2f -> %+8.2f  peak vy %+6.2f  a0=%s (%d pts)  T/W=%s",
        direction == "up" and "UP  " or "DOWN", level, record.commandedPower,
        state, record.riseStart, record.riseEnd, record.peakVelocity,
        acceleration and string.format("%+.3f", acceleration)
            or ("n/a:" .. tostring(fitReason)),
        fitPoints or 0,
        record.thrustToWeight and string.format("%.3f", record.thrustToWeight) or "n/a"))
    return record
end

local function shutdownBurst()
    phase = "shutdown"
    local stopAt = os.epoch("utc") + SHUTDOWN_SECONDS * 1000
    while os.epoch("utc") < stopAt do
        finalSequence = transmit(nil)
        rawSleep(0.1, DONE_EVENT, requestStop)
    end
    rawSleep(1, DONE_EVENT, requestStop)
    -- Confirm what the pods ACTUALLY APPLIED, not their cumulative fault
    -- history. Run 3 reported an unconfirmed shutdown purely because an earlier
    -- transient had set a counter that can never go back to zero.
    local now = os.epoch("utc")
    for _, corner in ipairs(CORNERS) do
        local status = statuses[corner]
        local fresh = status and statusAt[corner]
            and now - statusAt[corner] <= POD_MAX_AGE_MS
        local zeroed = status
            and (tonumber(status.appliedIonPower) or -1) == 0
            and (tonumber(status.appliedPropRpm) or -1) == 0
        if not fresh or not zeroed then
            shutdownError = "exact-zero shutdown not confirmed for " .. corner
            break
        end
    end
end

local function waitForTelemetry()
    local stopAt = os.epoch("utc") + 4000
    while not latestSample and os.epoch("utc") < stopAt do
        if stopRequested or abortReason then return false end
        rawSleep(0.05, DONE_EVENT, requestStop)
    end
    return latestSample ~= nil
end

local function senderLoop()
    if not waitForTelemetry() then
        runError = abortReason or "initial telemetry unavailable"
    end

    if not runError then
        print("Precheck: zero ion, props only.")
        phase = "precheck"
        local until_ = os.epoch("utc") + PRECHECK_SECONDS * 1000
        while os.epoch("utc") < until_ and not stopRequested and not abortReason do
            transmit(0)
            rawSleep(SEND_INTERVAL_SECONDS, DONE_EVENT, requestStop)
        end
        local ready, corner = podsFresh(0)
        if not ready then
            runError = "precheck not acknowledged by " .. tostring(corner)
        end
    end

    -- Ascend.
    local topLevel = START_LEVEL
    if not runError then
        for level = START_LEVEL, MAX_LEVEL do
            if stopRequested or abortReason then break end
            topLevel = level
            local record = holdLevel(level, DWELL_SECONDS, "up")
            if not liftLevel and record.riseEnd > AIRBORNE_BLOCKS then
                liftLevel = level
            end
            if ceilingReached then
                print(string.format(
                    "Ceiling +%d blocks reached at level %d/15; descending.",
                    CEILING_BLOCKS, level))
                break
            end
        end
    end

    -- Descend back down the same ladder.
    if not runError then
        -- Only descend a couple of levels below the one that first flew. Lower
        -- levels add nothing the measurement needs and a great deal of fall.
        local lowest = math.max(0,
            (liftLevel or 1) - DESCENT_LEVELS_BELOW_HOVER)
        for level = topLevel - 1, lowest, -1 do
            if stopRequested or abortReason then break end
            if rise() <= FLOOR_BLOCKS then
                print(string.format("Floor +%d blocks reached; ending descent.",
                    FLOOR_BLOCKS))
                break
            end
            holdLevel(level, DWELL_SECONDS, "down")
            if descentSpeedReached then
                print(string.format(
                    "Descending faster than %d blocks/s; ending descent.",
                    MAX_DESCENT_SPEED))
                break
            end
        end
    end

    -- Never hand an unpowered craft back to gravity. Climb until the fall is
    -- arrested before the exact-zero shutdown burst.
    if not stopRequested and latestSample and verticalVelocity() < -ARREST_SPEED then
        phase = "arrest"
        local arrestLevel = math.max(topLevel, (liftLevel or 1) + 1)
        print(string.format("Arresting descent at level %d/15 before shutdown.",
            arrestLevel))
        local stopAt = os.epoch("utc") + ARREST_TIMEOUT_SECONDS * 1000
        while os.epoch("utc") < stopAt do
            transmit(arrestLevel)
            if verticalVelocity() >= -ARREST_SPEED then
                arrested = true
                break
            end
            if not rawSleep(SEND_INTERVAL_SECONDS, DONE_EVENT, requestStop) then break end
        end
        if arrested == nil then arrested = false end
        print(arrested and "Descent arrested."
            or "WARNING: descent NOT arrested before shutdown.")
    end

    if runError then print("RUN ERROR: " .. tostring(runError)) end
    shutdownBurst()
    active = false
    os.queueEvent(DONE_EVENT)
end

local ok, err = pcall(parallel.waitForAll, senderLoop, receiveLoop, telemetryLoop)
if not ok then
    runError = runError or tostring(err)
    pcall(function()
        local stopAt = os.epoch("utc") + 2000
        while os.epoch("utc") < stopAt do
            transmit(nil)
            sleep(0.1)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Result
-- ---------------------------------------------------------------------------

local endedAt = os.epoch("utc")

local hoverLevel, hoverNote = hoverLevelFrom(records)

local overall = not runError and not abortReason and not shutdownError
local lines = {
    "WIRED ION LIFT PROFILE RESULT",
    "session=" .. session,
    "overall=" .. (overall and "PASS" or "FAIL"),
    "termination=" .. (stopRequested and "operator"
        or (abortReason and "abort" or "complete")),
    "run_error=" .. tostring(runError),
    "abort_reason=" .. tostring(abortReason),
    "shutdown_error=" .. tostring(shutdownError),
    "duration_seconds=" .. string.format("%.3f", (endedAt - startedAt) / 1000),
    "dwell_seconds=" .. tostring(DWELL_SECONDS),
    "step_measure_seconds=" .. tostring(STEP_MEASURE_SECONDS),
    "prop_rpm=" .. tostring(PROP_RPM),
    "start_level=" .. tostring(START_LEVEL),
    "max_level=" .. tostring(MAX_LEVEL),
    "ceiling_blocks=" .. tostring(CEILING_BLOCKS),
    "ceiling_reached=" .. tostring(ceilingReached),
    "descent_speed_reached=" .. tostring(descentSpeedReached),
    "lift_level=" .. tostring(liftLevel),
    "descent_arrested=" .. tostring(arrested),
    "prop_rpm_note=props_at_" .. tostring(PROP_RPM) .. "rpm_near_zero_lift",
    "gravity_blocks_per_second2=" .. string.format("%.3f", GRAVITY_BLOCKS_PER_SECOND2),
    "hover_level=" .. (hoverLevel and string.format("%.3f", hoverLevel) or "not_bracketed"),
    "hover_note=" .. tostring(hoverNote),
    "hover_compare_max_altitude_gap=" .. tostring(HOVER_COMPARE_MAX_ALTITUDE_GAP),
    "tolerated_expired=" .. tostring(TOLERATED_EXPIRED),
    "tolerated_fallbacks=" .. tostring(TOLERATED_FALLBACKS),
    "valid_for_ms=" .. tostring(VALID_FOR_MS),
    "airborne_blocks=" .. tostring(AIRBORNE_BLOCKS),
    "levels_recorded=" .. tostring(#records),
    "frames_sent=" .. tostring(framesSent),
    "samples=" .. tostring(samples),
    "final_sequence=" .. tostring(finalSequence),
    "modem=" .. tostring(modemName),
    "sublevel=" .. tostring(sublevelSource),
    "",
    "# direction level state ion_command held_s measure_rise rise_start rise_end peak_vy fit_points fit_span accel_at_rest window_accel thrust_to_weight",
    "# accel_at_rest is the drag-free value (fit extrapolated to v=0); the hover level uses it",
    "# only rows marked airborne are thrust measurements; grounded rows measure the floor",
}

for _, record in ipairs(records) do
    lines[#lines + 1] = string.format(
        "level %s %d %s %.4f %.2f %.4f %.4f %.4f %.4f %d %.3f %s %s %s",
        record.direction, record.level, record.state,
        record.commandedPower, record.heldSeconds,
        record.measureRise or -1,
        record.riseStart, record.riseEnd, record.peakVelocity,
        record.fitPoints or 0, record.fitSpan or 0,
        record.acceleration and string.format("%.6f", record.acceleration)
            or ("nil(" .. tostring(record.fitReason) .. ")"),
        record.windowAcceleration
            and string.format("%.6f", record.windowAcceleration) or "nil",
        record.thrustToWeight and string.format("%.6f", record.thrustToWeight) or "nil")
end

lines[#lines + 1] = ""
for _, corner in ipairs(CORNERS) do
    local status = statuses[corner]
    lines[#lines + 1] = string.format(
        "%s applied=%s ion=%s rpm=%s missing=%s duplicate=%s order=%s invalid=%s expired=%s errors=%s fallback=%s stops=%s",
        corner, tostring(status and status.appliedSequence),
        tostring(status and status.appliedIonPower),
        tostring(status and status.appliedPropRpm),
        tostring(status and status.missing), tostring(status and status.duplicates),
        tostring(status and status.outOfOrder), tostring(status and status.invalid),
        tostring(status and status.expiredBeforeApply),
        tostring(status and status.applyErrors),
        tostring(status and status.fallbackCount),
        tostring(status and status.fallbackStops))
end

local file = fs.open(RESULT_PATH, "w")
if file then
    for _, line in ipairs(lines) do file.writeLine(line) end
    file.close()
end
for _, line in ipairs(lines) do print(line) end
print("Saved to " .. RESULT_PATH)
closeChannels()
