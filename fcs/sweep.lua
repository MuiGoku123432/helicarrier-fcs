-- Propeller RPM sweep and liftoff bracket.
--
-- Answers three open questions in one run:
--   1. thrust vs RPM  -- the exponent and coefficient of the prop curve
--   2. thrust units   -- does the craft leave the ground at the RPM the fitted
--                        curve and the logged mass/gravity jointly predict?
--   3. RR bearing     -- per-bearing thrust at every RPM point, not just at 16
--
-- Launch this in its own tab ALONGSIDE the logger; it commands RPM and writes
-- its own step summary, while /fcs/main.lua keeps writing the full-resolution
-- CSV. Both run on computer 1. CC queues events per coroutine, so the logger's
-- listener and this program's polling each get their own copy of every
-- rednet_message -- neither starves the other.
--
-- WHY THIS DOES NOT FLY THE CRAFT TO A TARGET RPM
--
-- There is no controller and no altitude hold. Above thrust-to-weight 1 the
-- carrier accelerates upward without limit, and any abort that cuts RPM from
-- altitude turns into a fall. So the lift phase creeps up in small steps and
-- watches for the FIRST sustained positive climb -- that instant IS T/W = 1,
-- which is the whole measurement. On detection it drops back one step and
-- holds. The abort target is therefore always a known barely-sub-hover RPM,
-- which settles the craft gently instead of dropping it.

if package then
    package.path = "/?.lua;/?/init.lua;" .. package.path
else
    require, package = dofile("/rom/modules/main/cc/require.lua").make(_ENV, "/")
end

local config = require("fcs.config")
local banks = require("fcs.banks")
local csv = require("fcs.csv")

local CORNERS = { "FL", "FR", "RL", "RR" }
local BEARINGS_PER_CORNER = 2

local plan = {
    -- Ground phase. getThrust is reported independently of craft motion (proven
    -- over 132 stationary samples where it was bit-identical), so the entire
    -- curve can be fitted with the carrier sitting on the ground. Keep the top
    -- of this list comfortably under the predicted liftoff RPM.
    -- Measured on the live carrier: one corner left at 8 RPM read 6980.4919
    -- per bearing against 13960.9838 at 16 RPM -- exactly 2.000x for exactly
    -- 2x the RPM. Thrust is LINEAR in RPM here, not the classic square law,
    -- which puts hover near 166 RPM rather than 52. A list stopping at 40 would
    -- extrapolate 4x beyond its own data; these points reach thrust/weight 0.77
    -- so the fit barely extrapolates at all. Safe because the running fit below
    -- exits early the moment the curve looks steeper than linear.
    -- Measured live: thrust is exactly LINEAR at 6968.34 per RPM (constant to
    -- 4 s.f. from 8 to 96 RPM), which predicts hover at 166.2. But the carrier
    -- LIFTED AND ACCELERATED at 128 RPM, where reported thrust/weight is only
    -- 0.7701 -- so the thrust readings overstate the RPM needed by ~30% and
    -- must not be trusted to keep the ground phase on the ground. Top out at 80
    -- (well under the ~128 where it actually flew) and let the measured unload
    -- detector below stop earlier if the craft starts coming off its contact.
    groundRpm = { 0, 8, 16, 24, 32, 48, 64, 80, 96 },

    -- Long enough for Create's kinetic network to reach the commanded speed and
    -- for the pods' 1 Hz telemetry to deliver several settled samples.
    dwellSeconds = 14,
    settleSeconds = 7,
    sampleSeconds = 0.5,

    -- Lift phase. Walked up from the highest RPM actually confirmed safe --
    -- NOT from a fraction of the thrust-predicted hover, which the live run
    -- proved is ~30% too high and would have started the search at 141 RPM,
    -- already past the ~128 where the craft flies. Coarse steps find the
    -- bracket quickly, then fine steps close it.
    searchStepRpm = 2,
    coarseStepRpm = 8,
    -- Hover is expected near 166; the pod clamps at +/-256, so leave headroom
    -- for a curve that flattens at high RPM rather than stopping just short.
    searchCeilingRpm = 250,
    searchDwellSeconds = 6,

    -- Liftoff detection and aborts.
    climbDetectBlocks = 0.15,
    -- A ground step that rises this far without tripping climbDetect is the
    -- craft unloading its ground contact as thrust approaches weight. Measured
    -- rather than predicted: at 96 RPM the live carrier already oscillated
    -- ~0.004 blocks with velocity spikes to 0.05, which is the real warning
    -- that the thrust-based prediction missed entirely.
    unloadBlocks = 0.02,
    climbConfirmSamples = 3,
    abortClimbBlocks = 5.0,
    baselineRpm = 16,
}

-- ---------------------------------------------------------------------------
-- Craft state. Deliberately NOT sensors.read(): that makes about a dozen
-- blocking Sable calls, each costing a server tick, and the logger is already
-- paying for those every sample. This needs two.
-- ---------------------------------------------------------------------------

local function craftY()
    if not sublevel then
        return nil
    end
    local ok, pose = pcall(sublevel.getLogicalPose)
    if not ok or not pose or not pose.position then
        return nil
    end
    return pose.position.y
end

local function craftMass()
    if not sublevel then
        return nil
    end
    local ok, mass = pcall(sublevel.getMass)
    return ok and mass or nil
end

-- Air pressure at the craft. Create Aeronautics propeller thrust scales with
-- air density, and getThrust appears to report the value BEFORE that factor is
-- applied: at y=-26.57 the pressure reads 1.4309, and the correction needed to
-- put hover at 116 RPM is 1.4329 -- a 0.14% match. Logged per step so the
-- relationship can be confirmed, and so a climb (which lowers pressure, and
-- therefore thrust) is visible in the data rather than inferred.
local function craftPressure()
    if not aero or not sublevel then
        return nil
    end
    local ok, pose = pcall(sublevel.getLogicalPose)
    if not ok or not pose or not pose.position then
        return nil
    end
    local got, pressure = pcall(aero.getAirPressure,
        vector.new(pose.position.x, pose.position.y, pose.position.z))
    return got and pressure or nil
end

local function craftGravityY()
    if not aero then
        return nil
    end
    local ok, gravity = pcall(aero.getGravity)
    if not ok or not gravity then
        return nil
    end
    return gravity.y
end

-- ---------------------------------------------------------------------------
-- Reporting (declared before the commanding section, which calls note())
-- ---------------------------------------------------------------------------

local summary = {}
local function note(line)
    summary[#summary + 1] = line
    print(line)
end

-- ---------------------------------------------------------------------------
-- Commanding
-- ---------------------------------------------------------------------------

local function roundedInteger(value)
    if value >= 0 then
        return math.floor(value + 0.5)
    end
    return math.ceil(value - 0.5)
end

-- Command every corner and CONFIRM FROM TELEMETRY, retrying until the pods
-- report the RPM they were asked for.
--
-- The first live run died here: the FR pod never applied an 8 rpm command and
-- never replied, and the RL pod later swallowed one too -- two of eight
-- commands lost. FR's own fault list was empty and its telemetry never
-- faltered, so props.setRpm was never reached. The pod's set_rpm branch has two
-- paths that skip silently, taking the reply with them:
--
--     elseif message.type == "set_rpm" and newCommand(message) then
--         if protocol.validPower(message.rpm) then ... reply(...) end
--
-- Neither newCommand() returning false (its session/sequence replay guard) nor
-- a rejected rpm value sends anything back, so "no reply within 1000 ms" is
-- what a silently dropped command looks like from this end.
--
-- Rather than guess which guard fired, confirm the thing that actually matters:
-- the pod's reported targetRpm. That is immune to a lost ack, a clobbered ack,
-- a dropped packet, and a rejected sequence alike -- and a retry carries a
-- fresh sequence, which clears the replay guard if that is what bit. Attempt
-- counts are returned so a run reports how often it had to retry, which is the
-- measurement that will finally pin the cause.
local function setAllCorners(requestedRpm, timeoutSeconds, resendMs, watch)
    local rpm = roundedInteger(math.max(config.propeller.minimumRpm,
        math.min(config.propeller.maximumRpm, tonumber(requestedRpm) or 0)))

    local deadline = os.epoch("utc") + ((timeoutSeconds or 12) * 1000)
    local pending, attempts = {}, {}
    for _, corner in ipairs(CORNERS) do
        pending[corner] = true
        attempts[corner] = 0
    end

    local nextSendAt = 0

    while true do
        if os.epoch("utc") >= nextSendAt then
            for _, corner in ipairs(CORNERS) do
                if pending[corner] then
                    attempts[corner] = attempts[corner] + 1
                    banks.send(corner, "set_rpm", { rpm = rpm })
                end
            end
            -- Default is long enough for the pod's 1 Hz telemetry to carry the
            -- new targetRpm back before deciding the command was lost. The
            -- settle and abort paths override it hard: above thrust/weight 1
            -- the carrier accelerates upward, so a dropped throttle-down costs
            -- altitude for the whole resend interval. A harness run at 25%
            -- command loss peaked 7.57 blocks -- past the 5 block ceiling --
            -- purely because the settle was resent on the slow cadence.
            nextSendAt = os.epoch("utc") + (resendMs or 1500)
        end

        banks.poll()

        -- Watch the craft WHILE commanding, not only during the dwell that
        -- follows. A retry leaves the other corners already at the new RPM, and
        -- three of four corners is enough to lift the carrier -- so it can be
        -- climbing for the whole retry window with nothing looking. That is how
        -- a 25% command-loss run reached 7.20 blocks and blew the ceiling at
        -- k=2.5 while every altitude check was still waiting for the dwell.
        if watch then
            local stopped = watch()
            if stopped then
                local left = {}
                for _, corner in ipairs(CORNERS) do
                    if pending[corner] then left[#left + 1] = corner end
                end
                return rpm, left, attempts, stopped
            end
        end

        for _, corner in ipairs(CORNERS) do
            if pending[corner] then
                local prop = (banks.getState()[corner] or {}).prop or {}
                if type(prop.targetRpm) == "number"
                    and math.abs(prop.targetRpm - rpm) < 0.5 then
                    pending[corner] = nil
                end
            end
        end

        local remaining = {}
        for _, corner in ipairs(CORNERS) do
            if pending[corner] then
                remaining[#remaining + 1] = corner
            end
        end

        if #remaining == 0 then
            return rpm, {}, attempts
        end
        if os.epoch("utc") > deadline then
            return rpm, remaining, attempts
        end

        sleep(0.1)
    end
end

-- Command, confirm, and report retries. Errors if a corner never converges:
-- a half-applied RPM is an asymmetric thrust state with nothing to trim it out.
local function commandAll(rpm, timeoutSeconds, resendMs, watch)
    local applied, failed, attempts, stopped =
        setAllCorners(rpm, timeoutSeconds, resendMs, watch)

    local retried = {}
    for _, corner in ipairs(CORNERS) do
        if (attempts[corner] or 0) > 1 then
            retried[#retried + 1] = corner .. "x" .. attempts[corner]
        end
    end
    if #retried > 0 then
        note("    retried: " .. table.concat(retried, " ")
            .. "  (pods silently dropped those commands)")
    end

    -- A watch verdict outranks an unconfirmed corner: the craft moving is the
    -- more urgent fact, and a partially applied RPM still brackets hover
    -- correctly (it sits between lastSafeRpm and this probe).
    if stopped then
        return applied, stopped
    end

    if #failed > 0 then
        error(string.format(
            "%s never confirmed %d rpm after %d s of retries -- commanded but "
            .. "never applied, and the pod reported no fault",
            table.concat(failed, ", "), applied, timeoutSeconds or 12), 0)
    end

    return applied, nil
end

-- ---------------------------------------------------------------------------
-- Sampling
-- ---------------------------------------------------------------------------

local function readCorners()
    local state = banks.getState()
    local sample = { corners = {}, total = 0, sawThrust = false, overstressed = false }
    local rpmSum, rpmCount = 0, 0

    for _, corner in ipairs(CORNERS) do
        local pod = state[corner] or {}
        local prop = pod.prop or {}
        local entry = {
            online = pod.online,
            targetRpm = prop.targetRpm,
            controllerRpm = prop.controllerRpm,
            thrust = prop.thrust,
            thrustImbalance = prop.thrustImbalance,
            sailPower = prop.sailPower,
            airflow = prop.airflow,
            bearings = {},
        }

        local perBearing = prop.perBearing or {}
        for index = 1, BEARINGS_PER_CORNER do
            local bearing = perBearing[index] or {}
            entry.bearings[index] = { thrust = bearing.thrust, assembled = bearing.assembled }
        end

        if prop.thrust then
            sample.sawThrust = true
            sample.total = sample.total + prop.thrust
        end
        if prop.overstressed or prop.bearingOverstressed then
            sample.overstressed = true
        end

        if type(prop.controllerRpm) == "number" then
            rpmSum = rpmSum + prop.controllerRpm
            rpmCount = rpmCount + 1
        end

        sample.corners[corner] = entry
    end

    -- Fit against the RPM the propellers ACTUALLY reached, not the one that was
    -- asked for. If the kinetic network cannot deliver the commanded speed the
    -- two diverge, and fitting on the command would attribute the shortfall to
    -- the thrust curve instead of to the drivetrain.
    sample.actualRpm = rpmCount > 0 and (rpmSum / rpmCount) or nil

    -- A real drivetrain stall is a corner whose controller cannot reach ITS OWN
    -- target -- not one whose telemetry has not caught up with the command yet.
    -- Comparing the fleet-mean against the commanded RPM instead produced a
    -- false "props stalled at 118 against 120" the moment a single corner's
    -- status message lagged one cycle behind.
    local worst, worstCorner = 0, nil
    for _, corner in ipairs(CORNERS) do
        local entry = sample.corners[corner]
        if entry and type(entry.controllerRpm) == "number"
            and type(entry.targetRpm) == "number" then
            local gap = math.abs(entry.controllerRpm - entry.targetRpm)
            if gap > worst then
                worst, worstCorner = gap, corner
            end
        end
    end
    sample.speedShortfall = worst
    sample.speedShortfallCorner = worstCorner

    return sample
end

-- Dwell at the current command, draining rednet throughout, and return the LAST
-- settled sample plus the altitude change across the settled window. The last
-- sample rather than a mean: thrust is a step function of commanded RPM here,
-- so once settled every sample is identical and a mean would only blur the
-- transient in if settling ran long.
local function dwell(seconds, settleSeconds, onSample)
    local startedAt = os.epoch("utc")
    local settledAt = startedAt + settleSeconds * 1000
    local endsAt = startedAt + seconds * 1000

    local settledY, latest = nil, nil
    local peakY = craftY()
    local baseY = peakY

    while os.epoch("utc") < endsAt do
        banks.poll()

        local now = os.epoch("utc")
        local y = craftY()
        if y then
            if peakY == nil or y > peakY then peakY = y end
            if now >= settledAt and settledY == nil then settledY = y end
        end

        if now >= settledAt then
            latest = readCorners()
            latest.y = y
        end

        if onSample then
            local stop, reason = onSample(y, baseY, peakY, now - startedAt)
            if stop then
                return latest, baseY, y, peakY, reason
            end
        end

        sleep(plan.sampleSeconds)
    end

    return latest, baseY, craftY(), peakY, nil
end

-- ---------------------------------------------------------------------------
-- Curve fit: least squares on log(thrust) vs log(rpm), i.e. thrust = a * rpm^k
-- ---------------------------------------------------------------------------

local function fitPowerLaw(points)
    local n, sx, sy, sxx, sxy = 0, 0, 0, 0, 0
    for _, point in ipairs(points) do
        if point.rpm > 0 and point.thrust and point.thrust > 0 then
            local x, y = math.log(point.rpm), math.log(point.thrust)
            n = n + 1
            sx, sy = sx + x, sy + y
            sxx, sxy = sxx + x * x, sxy + x * y
        end
    end

    if n < 2 then
        return nil, "need at least two non-zero RPM points with thrust"
    end

    local denominator = n * sxx - sx * sx
    if math.abs(denominator) < 1e-12 then
        return nil, "all RPM points identical; cannot fit"
    end

    local exponent = (n * sxy - sx * sy) / denominator
    local intercept = (sy - exponent * sx) / n
    local coefficient = math.exp(intercept)

    -- Coefficient of determination, so a bad fit is visible rather than
    -- silently producing a confident wrong hover prediction.
    local meanY, ssTot, ssRes = sy / n, 0, 0
    for _, point in ipairs(points) do
        if point.rpm > 0 and point.thrust and point.thrust > 0 then
            local y = math.log(point.thrust)
            local predicted = intercept + exponent * math.log(point.rpm)
            ssTot = ssTot + (y - meanY) ^ 2
            ssRes = ssRes + (y - predicted) ^ 2
        end
    end

    return {
        exponent = exponent,
        coefficient = coefficient,
        samples = n,
        r2 = ssTot > 0 and (1 - ssRes / ssTot) or 1,
    }
end

-- ---------------------------------------------------------------------------
-- Reporting
-- ---------------------------------------------------------------------------

local columns = { "phase", "step", "utc_ms", "commanded_rpm", "y_start", "y_end", "y_peak", "dy",
    "air_pressure", "total_thrust", "total_thrust_x_pressure" }
for _, corner in ipairs(CORNERS) do
    local prefix = string.lower(corner)
    columns[#columns + 1] = prefix .. "_online"
    columns[#columns + 1] = prefix .. "_target_rpm"
    columns[#columns + 1] = prefix .. "_controller_rpm"
    columns[#columns + 1] = prefix .. "_thrust"
    columns[#columns + 1] = prefix .. "_thrust_imbalance"
    columns[#columns + 1] = prefix .. "_sail_power"
    columns[#columns + 1] = prefix .. "_airflow"
    for index = 1, BEARINGS_PER_CORNER do
        columns[#columns + 1] = prefix .. "_b" .. index .. "_thrust"
        columns[#columns + 1] = prefix .. "_b" .. index .. "_assembled"
    end
end

local function stepRow(phase, step, commandedRpm, sample, yStart, yEnd, yPeak)
    local row = {
        phase = phase,
        step = step,
        utc_ms = os.epoch("utc"),
        commanded_rpm = commandedRpm,
        y_start = yStart,
        y_end = yEnd,
        y_peak = yPeak,
        dy = (yEnd and yStart) and (yEnd - yStart) or nil,
        total_thrust = sample and sample.sawThrust and sample.total or nil,
    }

    row.air_pressure = craftPressure()
    if row.total_thrust and row.air_pressure then
        row.total_thrust_x_pressure = row.total_thrust * row.air_pressure
    end

    for _, corner in ipairs(CORNERS) do
        local prefix = string.lower(corner) .. "_"
        local entry = (sample and sample.corners[corner]) or {}
        row[prefix .. "online"] = entry.online
        row[prefix .. "target_rpm"] = entry.targetRpm
        row[prefix .. "controller_rpm"] = entry.controllerRpm
        row[prefix .. "thrust"] = entry.thrust
        row[prefix .. "thrust_imbalance"] = entry.thrustImbalance
        row[prefix .. "sail_power"] = entry.sailPower
        row[prefix .. "airflow"] = entry.airflow
        for index = 1, BEARINGS_PER_CORNER do
            local bearing = (entry.bearings or {})[index] or {}
            row[prefix .. "b" .. index .. "_thrust"] = bearing.thrust
            row[prefix .. "b" .. index .. "_assembled"] = bearing.assembled
        end
    end

    return row
end


local function writeSummary(path)
    local ok, file = pcall(fs.open, path, "w")
    if ok and file then
        file.write(table.concat(summary, "\n"))
        file.close()
    end
end

-- ---------------------------------------------------------------------------
-- Preflight
-- ---------------------------------------------------------------------------

term.clear()
term.setCursorPos(1, 1)
print("PROPELLER RPM SWEEP + LIFTOFF BRACKET")
print("")
print("This COMMANDS the propellers and WILL lift the carrier off the")
print("ground at the end of the run. Ion banks are untouched.")
print("Ctrl+T aborts; on abort the props are left at the last RPM")
print("known NOT to lift, so the craft settles rather than drops.")
print("")

if not sublevel then
    error("CC:Sable sublevel API unavailable; run this on the carrier", 0)
end

local mass = craftMass()
local gravityY = craftGravityY()
if not mass or not gravityY then
    error("cannot read mass/gravity; refusing to sweep blind", 0)
end

local weight = mass * math.abs(gravityY)
print(string.format("mass    = %.1f", mass))
print(string.format("gravity = %.3f", gravityY))
print(string.format("weight  = %.1f", weight))
print("")
write("Type SWEEP to begin: ")
if read() ~= "SWEEP" then
    print("Cancelled. Nothing was commanded.")
    return
end

-- Wait for the pods rather than asking once and reading the answer a
-- millisecond later.
--
-- This program is a SEPARATE process from the logger, so it gets its own copy
-- of banks with every corner initialised offline and nothing received. On top
-- of that, the SWEEP prompt above is a filtered event wait, and CC discards
-- events that do not match a filter -- so every rednet_message that arrived
-- while the operator was typing was thrown away. The sweep tab therefore starts
-- genuinely deaf, and a single poll() reports four dead pods that are in fact
-- perfectly healthy. Pods broadcast unprompted every telemetryPeriodSeconds, so
-- polling for a couple of seconds is enough; the budget is offlineAfterMs plus
-- room for one status_request round trip.
local function waitForPods(timeoutSeconds)
    local deadline = os.epoch("utc") + timeoutSeconds * 1000

    while true do
        banks.poll()

        local missing = {}
        for _, corner in ipairs(CORNERS) do
            if not (banks.getState()[corner] or {}).online then
                missing[#missing + 1] = corner
            end
        end

        if #missing == 0 then
            return true, nil
        end
        if os.epoch("utc") >= deadline then
            return false, missing
        end

        sleep(0.25)
    end
end

local function assertPodsOnline()
    write("waiting for pods")
    local allOnline, missing = waitForPods((config.wireless.offlineAfterMs / 1000) + 3)
    print("")

    if allOnline then
        for _, corner in ipairs(CORNERS) do
            local pod = banks.getState()[corner] or {}
            print(string.format("  %s online (id=%s)", corner, tostring(pod.podId)))
        end
        return
    end

    local detail = {}
    for _, corner in ipairs(missing) do
        local pod = banks.getState()[corner] or {}
        detail[#detail + 1] = corner .. "(id=" .. tostring(pod.podId) .. ")"
    end
    print("messages seen=" .. tostring(banks.stats.seen)
        .. " accepted=" .. tostring(banks.stats.accepted))
    print("rejections: protocol=" .. tostring(banks.stats.badProtocol)
        .. " type=" .. tostring(banks.stats.wrongType)
        .. " corner=" .. tostring(banks.stats.unknownCorner)
        .. " hostname=" .. tostring(banks.stats.hostnameMismatch)
        .. " sender=" .. tostring(banks.stats.senderMismatch))
    print("Compare against /fcs/heartbeat.txt: if the logger is still")
    print("accepting messages, the pods are fine and this is a receive")
    print("problem in THIS tab, not a dead corner.")
    error("no telemetry from: " .. table.concat(detail, ", ")
        .. " -- a sweep with a dead corner is an asymmetric thrust test", 0)
end

local startedAt = os.epoch("utc")
local logPath = fs.combine(config.logDirectory, "sweep_" .. tostring(startedAt) .. ".csv")
fs.makeDir(config.logDirectory)
local writer = csv.open(logPath, columns, 1)

note("sweep started utc_ms=" .. tostring(startedAt))
note(string.format("mass=%.3f gravity_y=%.3f weight=%.3f", mass, gravityY, weight))
note("log=" .. logPath)

-- Highest RPM confirmed not to lift the craft. The abort target throughout.
local lastSafeRpm = plan.baselineRpm
local groundY = craftY()
local lifted = false

local function panic(reason)
    note("ABORT: " .. reason)
    note("returning props to last non-lifting RPM " .. tostring(lastSafeRpm))
    setAllCorners(lastSafeRpm, 6, 250)
end

-- ---------------------------------------------------------------------------
-- Run
-- ---------------------------------------------------------------------------

local points = {}

-- The listener exists for exactly the reason documented as bug 6 in HANDOFF.md,
-- and this program hit it a second time. CC delivers an event to a coroutine
-- only when it matches that coroutine's filter, and a non-matching event is
-- DROPPED, not queued. Every wait in the sweep loop is filtered: sleep() waits
-- on "timer", and each Sable call waits on "task_complete". So a sweep that
-- received inline would be deaf for almost its whole runtime -- telemetry would
-- read stale, and banks.tick() would start declaring healthy pods offline
-- mid-run after offlineAfterMs.
--
-- A dedicated listener has its own filter and keeps hearing while the sweep
-- loop blocks. Both coroutines mutate the same banks state table, so the
-- actuator's own poll-and-wait for an ack still sees replies the listener
-- accepted.
local function listenLoop()
    while true do
        if not banks.listen(1) then
            sleep(0.05)
        end
    end
end

local ok, failure

local function sweepLoop()
    ok, failure = pcall(function()
        assertPodsOnline()

        -- --- Phase A: grounded thrust curve -----------------------------------
        note("")
        note("PHASE A -- grounded thrust curve")

        for step, commanded in ipairs(plan.groundRpm) do
            note(string.format("  step %d/%d: %d rpm", step, #plan.groundRpm, commanded))

            commandAll(commanded)

            local sample, yStart, yEnd, yPeak, stopped = dwell(
                plan.dwellSeconds, plan.settleSeconds,
                function(y, baseY, peak)
                    if y and baseY and (y - baseY) > plan.climbDetectBlocks then
                        return true, "craft climbed during the GROUND phase at "
                            .. commanded .. " rpm"
                    end
                    return false
                end)

            -- Record BEFORE deciding to abort. The first live run aborted at
            -- 128 rpm and threw away that step's row -- the single most
            -- interesting data point of the whole session, because it was the
            -- one where the craft actually flew.
            writer.write(stepRow("ground", step, commanded, sample, yStart, yEnd, yPeak))

            if stopped then
                error(stopped .. " -- ground RPM points are set too high", 0)
            end

            if sample and sample.overstressed then
                error("kinetic network overstressed at " .. commanded .. " rpm", 0)
            end

            lastSafeRpm = commanded

            local total = sample and sample.sawThrust and sample.total or nil
            local actual = sample and sample.actualRpm or nil
            points[#points + 1] = { rpm = actual or commanded, thrust = total }
            note(string.format("    total thrust = %s  T/W = %s",
                total and string.format("%.1f", total) or "nil",
                total and string.format("%.4f", total / weight) or "nil"))

            if actual and commanded > 0 and math.abs(actual - commanded) > 0.5 then
                note(string.format(
                    "    WARNING: props reached %.2f rpm, not the commanded %d --",
                    actual, commanded))
                note("    the kinetic network is not delivering the commanded speed")
            end

            -- Measured stop rule, which outranks the predicted one below. A
            -- craft still firmly on the ground does not move at all: the live
            -- log sat at position_y -26.573582 to six decimals for minutes.
            -- Any real rise means the contact is unloading and hover is near,
            -- whatever the thrust numbers claim.
            if yStart and yPeak and (yPeak - yStart) > plan.unloadBlocks then
                note(string.format(
                    "    craft rose %.3f blocks at %d rpm -- unloading its ground",
                    yPeak - yStart, commanded))
                note("    contact, so hover is close. Stopping the ground phase.")
                break
            end

            -- Re-fit after every point and stop early if the NEXT planned RPM would
            -- reach liftoff. Kept as a backstop, but NOT trusted on its own: the
            -- live run showed this prediction sitting ~30% above the RPM where
            -- the craft actually flew, so it happily waved through a point that
            -- lifted the carrier.
            local nextRpm = plan.groundRpm[step + 1]
            if nextRpm then
                local running = fitPowerLaw(points)
                if running and running.exponent > 0 then
                    local projected = (weight / running.coefficient) ^ (1 / running.exponent)
                    if projected == projected and projected <= nextRpm * 1.15 then
                        note(string.format(
                            "    running fit puts liftoff at %.1f rpm; stopping the",
                            projected))
                        note(string.format(
                            "    ground phase before the planned %d rpm point", nextRpm))
                        break
                    end
                end
            end
        end

        -- --- Fit ---------------------------------------------------------------
        note("")
        note("FIT -- thrust = a * rpm^k")
        local fit, fitError = fitPowerLaw(points)
        if not fit then
            error("curve fit failed: " .. tostring(fitError), 0)
        end

        note(string.format("  k (exponent)  = %.4f", fit.exponent))
        note(string.format("  a (coeff)     = %.6g", fit.coefficient))
        note(string.format("  r2            = %.6f  over %d points", fit.r2, fit.samples))

        if fit.r2 < 0.99 then
            note("  WARNING: poor fit; hover prediction below is unreliable")
        end

        local predictedHover = (weight / fit.coefficient) ^ (1 / fit.exponent)
        note(string.format("  hover RPM, raw thrust      = %.2f", predictedHover))

        -- Competing hypothesis, and the one the evidence favours: Create
        -- Aeronautics scales propeller thrust by air density, and getThrust
        -- reports the value before that factor. Both predictions are recorded
        -- so the bracket below decides between them instead of assuming.
        local pressure = craftPressure()
        local predictedHoverPressure = nil
        if pressure and pressure > 0 then
            predictedHoverPressure =
                (weight / (fit.coefficient * pressure)) ^ (1 / fit.exponent)
            note(string.format("  air pressure               = %.6f", pressure))
            note(string.format("  hover RPM, thrust x press. = %.2f",
                predictedHoverPressure))
        end

        -- Guard against the LOWER of the two: whichever hypothesis holds, the
        -- craft leaves the ground at the smaller RPM, and that is the number
        -- safety decisions have to respect.
        local earliestHover = predictedHover
        if predictedHoverPressure and predictedHoverPressure < earliestHover then
            earliestHover = predictedHoverPressure
        end

        if earliestHover ~= earliestHover or earliestHover <= 0 then
            error("hover prediction is not a usable number", 0)
        end
        if earliestHover > plan.searchCeilingRpm then
            error(string.format("predicted hover %.1f rpm exceeds the %d rpm search ceiling",
                earliestHover, plan.searchCeilingRpm), 0)
        end

        -- --- Phase B: liftoff bracket ------------------------------------------
        note("")
        note("PHASE B -- liftoff bracket (the craft will leave the ground)")

        -- Walk up from the highest RPM the craft has actually been held at
        -- without leaving the ground. Two things are deliberately NOT used to
        -- pick the starting point:
        --
        --   * plan.groundRpm's last entry -- diverges from what was really
        --     flown whenever the ground phase exits early (harness k=3: it
        --     started at 40 against a true hover of 34.9 and climbed 21 blocks)
        --   * predictedHover -- the live run measured this ~30% high, so a
        --     0.85x start would have opened Phase B at 141 RPM when the carrier
        --     already flies at 128
        --
        -- Only lastSafeRpm is evidence. Coarse steps close the gap quickly,
        -- then the search backs off and repeats at fine resolution.
        local stride = plan.coarseStepRpm
        local rpm = lastSafeRpm + stride
        local step = 0
        groundY = craftY()
        -- Never reassigned. groundY moves when the search re-datums after a
        -- coarse liftoff; this stays the real ground, so "altitude gained"
        -- means what it says.
        local groundDatumY = groundY

        while rpm <= plan.searchCeilingRpm do
            step = step + 1
            -- Set when the coarse->fine transition has already chosen the next
            -- rpm, so the loop tail must not advance past it a second time.
            local reseeded = false
            note(string.format("  probe %d: %d rpm", step, rpm))

            -- Same predicate as the dwell below, so a craft that lifts while
            -- the command is still being retried is caught immediately.
            local commandWatch = function()
                local y = craftY()
                if not y then return nil end
                if (y - groundY) > plan.abortClimbBlocks then return "abort_ceiling" end
                if (y - groundY) > plan.climbDetectBlocks then return "liftoff" end
                return nil
            end

            local _, commandStopped = commandAll(rpm, nil, nil, commandWatch)

            local confirmations = 0
            local sample, yStart, yEnd, yPeak, stopped = nil, nil, nil, nil, nil
            if commandStopped then
                stopped = commandStopped
                yStart, yEnd, yPeak = groundY, craftY(), craftY()
                sample = readCorners()
            else
            sample, yStart, yEnd, yPeak, stopped = dwell(
                plan.searchDwellSeconds, math.min(2, plan.searchDwellSeconds / 2),
                function(y, baseY)
                    if not y or not baseY then
                        return false
                    end
                    if (y - groundY) > plan.abortClimbBlocks then
                        return true, "abort_ceiling"
                    end
                    if (y - baseY) > plan.climbDetectBlocks then
                        confirmations = confirmations + 1
                        if confirmations >= plan.climbConfirmSamples then
                            return true, "liftoff"
                        end
                    else
                        confirmations = 0
                    end
                    return false
                end)
            end

            writer.write(stepRow("lift", step, rpm, sample, yStart, yEnd, yPeak))

            if sample and sample.overstressed then
                panic("kinetic network overstressed at " .. rpm .. " rpm")
                error("overstressed before liftoff -- the drivetrain, not the units, "
                    .. "is the limit; a 'no liftoff' verdict here would be false", 0)
            end

            if sample and (sample.speedShortfall or 0) > 1.0 then
                panic(string.format(
                    "%s cannot reach its own target: %.2f rpm short at a %d rpm command",
                    tostring(sample.speedShortfallCorner), sample.speedShortfall, rpm))
                error("the drivetrain cannot reach the commanded RPM; liftoff cannot "
                    .. "be bracketed and the units question stays open", 0)
            end

            if stopped == "abort_ceiling" then
                lifted = true
                panic(string.format("climbed %.2f blocks above the start altitude",
                    plan.abortClimbBlocks))
                error("liftoff exceeded the altitude ceiling before it could be bracketed", 0)
            end

            if stopped == "liftoff" then
                lifted = true

                -- Coarse pass only brackets to coarseStepRpm. Back off to the
                -- last RPM that held the craft down and repeat at fine
                -- resolution, rather than reporting a bracket eight RPM wide.
                if stride > plan.searchStepRpm then
                    note(string.format(
                        "  lifted at %d rpm; coarse bracket %d < hover <= %d",
                        rpm, lastSafeRpm, rpm))
                    note(string.format("  backing off to %d rpm and refining in %d rpm steps",
                        lastSafeRpm, plan.searchStepRpm))
                    -- Put it back on the ground before refining. Holding
                    -- lastSafeRpm only descends slowly (it is barely below
                    -- hover), so the fine probes would start airborne and every
                    -- altitude comparison after that would be against a datum
                    -- taken in mid-air.
                    note("  descending to the ground before refining")
                    setAllCorners(plan.baselineRpm, 8, 250)

                    local settleDeadline = os.epoch("utc") + 40000
                    while os.epoch("utc") < settleDeadline do
                        banks.poll()
                        local y = craftY()
                        if y and (y - groundDatumY) < 0.05 then
                            break
                        end
                        sleep(0.25)
                    end

                    local restingY = craftY()
                    note(string.format("  back down at %.3f (%.2f blocks above datum)",
                        restingY or 0, (restingY or groundDatumY) - groundDatumY))

                    lifted = false
                    stride = plan.searchStepRpm
                    rpm = lastSafeRpm + stride
                    reseeded = true
                    groundY = craftY()
                    setAllCorners(lastSafeRpm, 12, 1500)
                else
                note("")
                note(string.format("LIFTOFF at %d rpm (previous %d rpm did not lift)",
                    rpm, lastSafeRpm))
                note(string.format("  hover RPM is bracketed: %d < hover <= %d",
                    lastSafeRpm, rpm))
                note("")
                note("WHICH THRUST MODEL FITS:")
                note(string.format("  raw thrust      predicted %.2f  (off by %+.1f rpm)",
                    predictedHover, rpm - predictedHover))
                if predictedHoverPressure then
                    note(string.format("  thrust x press. predicted %.2f  (off by %+.1f rpm)",
                        predictedHoverPressure, rpm - predictedHoverPressure))
                end
                note("")

                local rawErr = math.abs(rpm - predictedHover)
                local pressErr = predictedHoverPressure
                    and math.abs(rpm - predictedHoverPressure) or math.huge
                local tolerance = 2 * plan.searchStepRpm

                if pressErr <= tolerance and pressErr < rawErr then
                    note("  VERDICT: thrust scales with AIR DENSITY.")
                    note("  getThrust reports the value BEFORE the air-density")
                    note("  factor; the real force is getThrust * air_pressure.")
                    note("  Consequences: hover RPM is only valid at this altitude,")
                    note("  and because pressure falls as the craft climbs, thrust")
                    note("  falls with it -- so altitude is self-stabilising.")
                elseif rawErr <= tolerance then
                    note("  VERDICT: getThrust is already a force in the same unit")
                    note("  system as mass * gravity; no density correction needed.")
                else
                    note("  VERDICT: NEITHER model fits. Liftoff missed both")
                    note("  predictions by more than two search steps, so some")
                    note("  other force is acting. Do not build a controller yet.")
                end

                note(string.format("  implied correction factor: %.4f",
                    (weight / (fit.coefficient * rpm ^ fit.exponent))))
                if pressure then
                    note(string.format("  ground air pressure      : %.4f", pressure))
                    note("  (compare the two: a match means density is the factor)")
                end

                note("")
                note("settling back to " .. tostring(lastSafeRpm) .. " rpm")
                setAllCorners(lastSafeRpm, 8, 250)

                -- Report how far it actually went: the carrier is off the
                -- ground with no controller, so the pilot needs the number.
                local settledY = craftY()
                note(string.format("  altitude gained: %.2f blocks (now %.2f)",
                    (settledY or groundDatumY) - groundDatumY, settledY or groundDatumY))
                return
                end
            end

            -- Without the reseeded guard this promoted an RPM the craft was
            -- never held at to lastSafeRpm, and skipped the first fine probe:
            -- after a coarse lift at 120 with 112 safe, the refine step sets
            -- rpm=114, then the tail immediately made 114 "safe" and probed 116.
            if not lifted and not reseeded then
                lastSafeRpm = rpm
                rpm = rpm + stride
            end
        end

        error(string.format("reached the %d rpm ceiling without liftoff -- thrust and "
            .. "weight are NOT in the same unit system", plan.searchCeilingRpm), 0)
    end)
end

-- waitForAny, not waitForAll: the listener never returns on its own, so the
-- sweep finishing (or failing) is what ends the pair.
parallel.waitForAny(sweepLoop, listenLoop)

-- ---------------------------------------------------------------------------
-- Always leave the craft in a defined state.
-- ---------------------------------------------------------------------------

if not ok then
    note("")
    note("FAILED: " .. tostring(failure))
    if lifted then
        -- Airborne: lastSafeRpm is by construction just under hover, so this
        -- settles the craft. Commanding baselineRpm here would drop it.
        panic("run failed while airborne")
    else
        setAllCorners(plan.baselineRpm, 6, 250)
        note("props returned to baseline " .. tostring(plan.baselineRpm) .. " rpm")
    end
end

-- --- RR bearing report -----------------------------------------------------
note("")
note("PER-BEARING SUMMARY (last settled sample of each step is in the CSV)")
local final = readCorners()
for _, corner in ipairs(CORNERS) do
    local entry = final.corners[corner] or {}
    local b1 = (entry.bearings or {})[1] or {}
    local b2 = (entry.bearings or {})[2] or {}
    note(string.format("  %s  b1=%s  b2=%s  sail=%s  airflow=%s",
        corner,
        b1.thrust and string.format("%.3f", b1.thrust) or "nil",
        b2.thrust and string.format("%.3f", b2.thrust) or "nil",
        tostring(entry.sailPower), tostring(entry.airflow)))
end

writer.close()
writeSummary("/fcs/sweep_result.txt")
note("")
note("step CSV : " .. logPath)
note("summary  : /fcs/sweep_result.txt")

if not ok then
    error(failure, 0)
end
