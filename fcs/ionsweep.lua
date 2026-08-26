-- Ion thruster characterisation: thrust and power draw against commanded power.
--
-- The propeller sweep answered what the props can lift. This answers what the
-- ion banks can, which is what the "props capped at 64 RPM, ions do the rest"
-- plan depends on: at 64 RPM the props carry ~52% of weight, so the banks must
-- find the other ~48%.
--
-- Three things make this different from the prop sweep, all of them from the
-- pod's own code rather than guesswork:
--
--   1. set_power is gated on state.armed, so the banks must be armed first.
--   2. watchdogLoop disarms and drops to fallbackPower (0.0) after
--      commandTimeoutMs (750 ms) without a command. So this must KEEP SENDING
--      or the bank quietly falls to zero mid-measurement.
--   3. thrusters.applyCommand moves at most maximumChangePerCommand (0.05)
--      toward the target per command, so power is walked, not jumped. Repeating
--      the same target both ramps it and feeds the watchdog.
--
-- Units warning: ion thrust is reported by getCurrentThrustKN in kN, which is
-- NOT the unit the propellers' getThrust uses. The two can only be tied
-- together by a liftoff, where both are known against mass * gravity.

if package then
    package.path = "/?.lua;/?/init.lua;" .. package.path
else
    require, package = dofile("/rom/modules/main/cc/require.lua").make(_ENV, "/")
end

local config = require("fcs.config")
local banks = require("fcs.banks")
local csv = require("fcs.csv")

local CORNERS = { "FL", "FR", "RL", "RR" }

local plan = {
    -- Props are parked low for the whole run so the ion banks are measured on
    -- their own. 16 RPM is ~13% of weight, which leaves the banks most of the
    -- envelope to be characterised in before anything leaves the ground.
    -- IMPORTANT: the prop sweep leaves the props at ~122 RPM, a hair under
    -- hover. Arming the ions on top of that would fly the craft immediately.
    -- Props at the plan's ceiling. This is now a test OF the intended
    -- configuration rather than a characterisation in isolation: props carry
    -- 52.1% of weight at 64 RPM, so the ions have to find the other 47.9% and
    -- liftoff lands inside the power band being swept.
    --
    -- It also settles the question the getter cannot. Reported ion thrust is
    -- quantised to 258,048 kN steps (~22% of craft weight) -- 0.223, 0.446,
    -- 0.668 of weight and nothing between. If the FORCE were quantised too the
    -- craft would jump from not-lifting to lifting across one of those steps.
    -- If it lifts at a power BETWEEN them, only the reporting is quantised and
    -- the banks can trim smoothly, which is what a mixer needs.
    propRpm = 64,

    -- Fine steps through where liftoff is expected. With props at 64 RPM the
    -- ions need ~47.9% of weight; the reported quanta bracket that (0.446 at
    -- 0.14-0.18, 0.668 at 0.20+), so liftoff should fall in 0.16..0.22.
    -- Total sits at 0.967 of weight with ions at 0.14, so liftoff is just
    -- above. Single-hundredth steps through the gap: if the craft lifts at a
    -- power where reported thrust is still 516,096 kN, the force is continuous
    -- and only the reporting is quantised.
    powerSteps = { 0.0, 0.12, 0.14, 0.15, 0.16, 0.17,
                   0.18, 0.19, 0.20, 0.22, 0.24 },

    -- Long enough for applyCommand's 0.05-per-command walk to reach the target
    -- from the step below, plus settling.
    dwellSeconds = 12,
    settleSeconds = 6,
    sampleSeconds = 0.5,

    -- Watchdog is 750 ms, and commands are dropped silently often enough that
    -- two consecutive misses at 400 ms opened a gap wide enough to disarm a
    -- bank several times per step -- even after the pod ack was made cheap, so
    -- the ack cost was not the cause. At 200 ms it takes FOUR consecutive
    -- losses to time out, which is ~0.4% at the observed ~25% loss rate.
    -- With ~13% measured command loss, four sends inside the 750 ms window
    -- needs all four to fail before a disarm: ~0.03%.
    keepAliveMs = 180,

    -- Liftoff must clear the contact compliance. At 96.7% of weight (props 64
    -- + ions 0.14) the carrier rose 0.077 blocks WITHOUT flying -- the contact
    -- unloading, not lift. 0.30 sits well clear of that while staying far under
    -- the abort ceiling; a real liftoff accelerates through it.
    climbDetectBlocks = 0.30,
    abortClimbBlocks = 3.0,

    -- Report-only here. In the prop sweep this stops the ground phase before it
    -- flies; in this tool reaching liftoff IS the measurement, and a 0.02 guard
    -- ended a run at the exact point it was becoming informative.
    unloadBlocks = 0.02,
}

-- ---------------------------------------------------------------------------
-- Craft state
-- ---------------------------------------------------------------------------

local function craftY()
    if not sublevel then return nil end
    local ok, pose = pcall(sublevel.getLogicalPose)
    if not ok or not pose or not pose.position then return nil end
    return pose.position.y
end

local function craftPressure()
    if not aero or not sublevel then return nil end
    local ok, pose = pcall(sublevel.getLogicalPose)
    if not ok or not pose or not pose.position then return nil end
    local got, pressure = pcall(aero.getAirPressure,
        vector.new(pose.position.x, pose.position.y, pose.position.z))
    return got and pressure or nil
end

local summary = {}
local function note(line)
    summary[#summary + 1] = line
    print(line)
end

local function writeReport(path, lines)
    local ok, file = pcall(fs.open, path, "w")
    if ok and file then
        file.write(table.concat(lines, "\n"))
        file.close()
    end
end

-- ---------------------------------------------------------------------------
-- Sampling
-- ---------------------------------------------------------------------------

local function readPods()
    local state = banks.getState()
    local sample = {
        corners = {}, totalThrustKN = 0, sawThrust = false,
        allArmed = true, anyArmed = false,
        totalEnergyFE = 0, obstructed = 0, minPower = nil, maxPower = nil,
        minClearance = nil,
    }

    for _, corner in ipairs(CORNERS) do
        local pod = state[corner] or {}
        local entry = {
            online = pod.online,
            armed = pod.armed,
            rejected = pod.rejected,
            commandsSeen = pod.commandsSeen,
            commandsApplied = pod.commandsApplied,
            commandsRejected = pod.commandsRejected,
            lastReject = pod.lastReject,
            currentPower = pod.currentPower,
            averagePower = pod.averagePower,
            totalThrustKN = pod.totalThrustKN,
            healthyThrusters = pod.healthyThrusters,
            expectedThrusters = pod.expectedThrusters,
            obstructedThrusters = pod.obstructedThrusters,
            energyFE = pod.energyFE,
            energyCapacityFE = pod.energyCapacityFE,
        }

        if type(pod.totalThrustKN) == "number" then
            sample.sawThrust = true
            sample.totalThrustKN = sample.totalThrustKN + pod.totalThrustKN
        end
        if type(pod.energyFE) == "number" then
            sample.totalEnergyFE = sample.totalEnergyFE + pod.energyFE
        end
        if type(pod.obstructedThrusters) == "number" then
            sample.obstructed = sample.obstructed + pod.obstructedThrusters
        end
        if type(pod.minimumClearance) == "number" then
            sample.minClearance = sample.minClearance
                and math.min(sample.minClearance, pod.minimumClearance)
                or pod.minimumClearance
        end
        if type(pod.currentPower) == "number" then
            sample.minPower = sample.minPower and math.min(sample.minPower, pod.currentPower)
                or pod.currentPower
            sample.maxPower = sample.maxPower and math.max(sample.maxPower, pod.currentPower)
                or pod.currentPower
        end
        if pod.armed then sample.anyArmed = true else sample.allArmed = false end

        sample.corners[corner] = entry
    end

    return sample
end

-- ---------------------------------------------------------------------------
-- Commanding
-- ---------------------------------------------------------------------------

-- Confirm from telemetry, never from an ack. The prop sweep established that a
-- pod drops set_rpm silently -- newCommand()'s replay guard and an invalid
-- value both skip the reply -- and set_power sits behind the same guard.
local function armAll(timeoutSeconds)
    local deadline = os.epoch("utc") + ((timeoutSeconds or 10) * 1000)
    local nextSendAt = 0

    while true do
        if os.epoch("utc") >= nextSendAt then
            for _, corner in ipairs(CORNERS) do
                local pod = banks.getState()[corner] or {}
                if not pod.armed then
                    banks.send(corner, "arm")
                end
            end
            nextSendAt = os.epoch("utc") + 1000
        end

        banks.poll()

        local pending = {}
        for _, corner in ipairs(CORNERS) do
            if not (banks.getState()[corner] or {}).armed then
                pending[#pending + 1] = corner
            end
        end
        if #pending == 0 then return true, {} end
        if os.epoch("utc") > deadline then return false, pending end

        sleep(0.1)
    end
end

local function disarmAll()
    for _ = 1, 4 do
        for _, corner in ipairs(CORNERS) do
            banks.send(corner, "disarm")
        end
        banks.poll()
        sleep(0.2)
    end
end

-- Hold a power target for a duration, resending continuously. The resend is not
-- redundancy -- it is what walks applyCommand's 0.05-per-command limit to the
-- target AND what stops watchdogLoop disarming the bank underneath us.
-- Returns the final sample plus altitude movement, or a watch verdict.
local function holdPower(target, seconds, settleSeconds, watch, onSample)
    local startedAt = os.epoch("utc")
    local settledAt = startedAt + (settleSeconds or 0) * 1000
    local endsAt = startedAt + seconds * 1000
    local nextSendAt = 0

    local baseY = craftY()
    local peakY = baseY
    local latest, reArms = nil, 0
    local nextSampleAt = 0

    while os.epoch("utc") < endsAt do
        if os.epoch("utc") >= nextSendAt then
            for _, corner in ipairs(CORNERS) do
                banks.send(corner, "set_power", { power = target })
            end
            nextSendAt = os.epoch("utc") + plan.keepAliveMs
        end

        banks.poll()

        local y = craftY()
        if y and (peakY == nil or y > peakY) then peakY = y end

        local now = os.epoch("utc")
        local live = readPods()
        live.y = y
        if now >= settledAt then
            latest = live
        end

        -- Record samples paired with the power actually applied. A bank that
        -- disarms mid-step resets power to fallback, so fitting against
        -- COMMANDED power turns that into corrupt data (an early run logged
        -- 0.00 kN at a commanded 0.05); fitting against MEASURED power turns it
        -- into extra data points. Sampling is now on its own clock so it cannot
        -- throttle the command rate.
        if onSample and now >= nextSampleAt then
            onSample(live, y)
            nextSampleAt = now + plan.sampleSeconds * 1000
        end

        -- Re-arm by firing a single message, never by calling armAll() here.
        -- armAll blocks until every bank confirms, and while it blocks NO
        -- set_power goes out -- which guarantees the 750 ms COMMAND_TIMEOUT
        -- that disarms the bank, which trips this check again. The first live
        -- run cycled that way ~6 times per step and never got power off zero,
        -- with the pods logging 79 straight COMMAND_TIMEOUT faults.
        if not live.allArmed then
            reArms = reArms + 1
            for _, corner in ipairs(CORNERS) do
                if not (banks.getState()[corner] or {}).armed then
                    banks.send(corner, "arm")
                end
            end
        end

        if watch then
            local stopped = watch(y, baseY, peakY)
            if stopped then
                return latest, baseY, y, peakY, stopped, reArms
            end
        end

        -- Sleep only until the next thing is actually due.
        --
        -- This used to be an unconditional sleep(sampleSeconds) = 0.5 s, which
        -- capped commands at ~1 per 0.55 s no matter what keepAliveMs said --
        -- so the "200 ms keepalive" never existed. Against a 750 ms watchdog
        -- that leaves no margin: one lost command opens a >1 s gap and the bank
        -- disarms. Measured at 0.5 s cadence: 171 of ~196 commands arrived
        -- (~13% radio loss) and banks still disarmed 2-6 times per step.
        local due = math.min(nextSendAt, nextSampleAt)
        local wait = (due - os.epoch("utc")) / 1000
        sleep(math.max(0.05, math.min(wait, plan.sampleSeconds)))
    end

    return latest, baseY, craftY(), peakY, nil, reArms
end

-- ---------------------------------------------------------------------------
-- Reporting
-- ---------------------------------------------------------------------------

local columns = { "step", "utc_ms", "commanded_power", "applied_power", "all_armed",
    "y", "air_pressure", "total_thrust_kn", "min_power", "max_power",
    "total_energy_fe", "obstructed", "min_clearance" }
for _, corner in ipairs(CORNERS) do
    local prefix = string.lower(corner)
    columns[#columns + 1] = prefix .. "_armed"
    columns[#columns + 1] = prefix .. "_current_power"
    columns[#columns + 1] = prefix .. "_average_power"
    columns[#columns + 1] = prefix .. "_thrust_kn"
    columns[#columns + 1] = prefix .. "_healthy"
    columns[#columns + 1] = prefix .. "_obstructed"
    columns[#columns + 1] = prefix .. "_energy_fe"
end

-- Mean power actually applied across the four banks. This, not the commanded
-- value, is the x-axis of the thrust curve.
local function appliedPower(sample)
    if not sample then return nil end
    local total, count = 0, 0
    for _, corner in ipairs(CORNERS) do
        local entry = sample.corners[corner]
        if entry and type(entry.currentPower) == "number" then
            total = total + entry.currentPower
            count = count + 1
        end
    end
    return count > 0 and (total / count) or nil
end

local function stepRow(step, power, sample, y)
    local row = {
        step = step,
        utc_ms = os.epoch("utc"),
        commanded_power = power,
        applied_power = appliedPower(sample),
        all_armed = sample and sample.allArmed or nil,
        y = y,
        air_pressure = craftPressure(),
        total_thrust_kn = sample and sample.sawThrust and sample.totalThrustKN or nil,
        min_power = sample and sample.minPower or nil,
        max_power = sample and sample.maxPower or nil,
        total_energy_fe = sample and sample.totalEnergyFE or nil,
        obstructed = sample and sample.obstructed or nil,
        min_clearance = sample and sample.minClearance or nil,
    }

    for _, corner in ipairs(CORNERS) do
        local prefix = string.lower(corner) .. "_"
        local entry = (sample and sample.corners[corner]) or {}
        row[prefix .. "armed"] = entry.armed
        row[prefix .. "current_power"] = entry.currentPower
        row[prefix .. "average_power"] = entry.averagePower
        row[prefix .. "thrust_kn"] = entry.totalThrustKN
        row[prefix .. "healthy"] = entry.healthyThrusters
        row[prefix .. "obstructed"] = entry.obstructedThrusters
        row[prefix .. "energy_fe"] = entry.energyFE
    end

    return row
end

-- ---------------------------------------------------------------------------
-- Preflight
-- ---------------------------------------------------------------------------

term.clear()
term.setCursorPos(1, 1)
print("ION THRUSTER CHARACTERISATION")
print("")
print("This ARMS the ion banks and ramps them to full power.")
print("Propellers are parked at " .. plan.propRpm .. " rpm for the whole run,")
print("so the banks are measured on their own.")
print("")
print("Ctrl+T aborts. On any exit the banks are DISARMED, which")
print("returns them to fallbackPower (0.0).")
print("")

if not sublevel then
    error("CC:Sable sublevel API unavailable; run this on the carrier", 0)
end

local mass = select(2, pcall(sublevel.getMass))
local gravity = aero and select(2, pcall(aero.getGravity)) or nil
if type(mass) ~= "number" or not gravity or type(gravity.y) ~= "number" then
    error("cannot read mass/gravity; refusing to run blind", 0)
end
local weight = mass * math.abs(gravity.y)

print(string.format("mass   = %.1f", mass))
print(string.format("weight = %.1f", weight))
print("")
write("Type IONS to begin: ")
if read() ~= "IONS" then
    print("Cancelled. Nothing was commanded.")
    return
end

local startedAt = os.epoch("utc")
fs.makeDir(config.logDirectory)
local logPath = fs.combine(config.logDirectory, "ionsweep_" .. tostring(startedAt) .. ".csv")
local writer = csv.open(logPath, columns, 1)

note("ion sweep started utc_ms=" .. tostring(startedAt))
note(string.format("mass=%.3f weight=%.3f", mass, weight))
note("log=" .. logPath)

local points = {}
local stableFor = 0
local ok, failure

-- The listener exists for the reason documented as bug 6 in HANDOFF.md: CC
-- delivers an event to a coroutine only when it matches that coroutine's
-- filter and DROPS it otherwise, and every wait here is filtered.
local function listenLoop()
    while true do
        if not banks.listen(1) then
            sleep(0.05)
        end
    end
end

local function ionLoop()
    ok, failure = pcall(function()
        -- Wait for pods. A fresh process starts with every corner marked
        -- offline and nothing received, and the prompt above discarded
        -- everything that arrived while it was being typed.
        write("waiting for pods")
        local deadline = os.epoch("utc") + config.wireless.offlineAfterMs + 3000
        while true do
            banks.poll()
            local missing = {}
            for _, corner in ipairs(CORNERS) do
                if not (banks.getState()[corner] or {}).online then
                    missing[#missing + 1] = corner
                end
            end
            print("")
            if #missing == 0 then break end
            if os.epoch("utc") > deadline then
                error("no telemetry from: " .. table.concat(missing, ", "), 0)
            end
            sleep(0.25)
        end
        for _, corner in ipairs(CORNERS) do
            note(string.format("  %s online", corner))
        end

        -- Park the props FIRST. The prop sweep leaves them near hover.
        note("")
        note("parking propellers at " .. plan.propRpm .. " rpm")
        local propDeadline = os.epoch("utc") + 15000
        local nextSend = 0
        while true do
            if os.epoch("utc") >= nextSend then
                for _, corner in ipairs(CORNERS) do
                    banks.send(corner, "set_rpm", { rpm = plan.propRpm })
                end
                nextSend = os.epoch("utc") + 1500
            end
            banks.poll()
            local pending = {}
            for _, corner in ipairs(CORNERS) do
                local prop = (banks.getState()[corner] or {}).prop or {}
                if type(prop.targetRpm) ~= "number"
                    or math.abs(prop.targetRpm - plan.propRpm) >= 0.5 then
                    pending[#pending + 1] = corner
                end
            end
            if #pending == 0 then break end
            if os.epoch("utc") > propDeadline then
                error("could not park propellers on: " .. table.concat(pending, ", ")
                    .. " -- refusing to arm ions with props at an unknown RPM", 0)
            end
            sleep(0.1)
        end
        note("  propellers parked")

        -- Let the props actually spin down to the parked RPM before arming.
        note("  waiting for prop speed to settle")
        holdPower(0.0, 8, 8, nil)

        note("")
        note("arming ion banks")
        local armed, notArmed = armAll(12)
        if not armed then
            error("could not arm: " .. table.concat(notArmed, ", "), 0)
        end
        note("  all four banks armed")

        local groundY = craftY()

        note("")
        note("POWER RAMP")
        for step, power in ipairs(plan.powerSteps) do
            note(string.format("  step %d/%d: power %.2f", step, #plan.powerSteps, power))
            stableFor = 0

            local sample, yStart, yEnd, yPeak, stopped, reArms = holdPower(
                power, plan.dwellSeconds, plan.settleSeconds,
                function(y, baseY)
                    if not y or not baseY then return nil end
                    if (y - groundY) > plan.abortClimbBlocks then return "abort_ceiling" end
                    if (y - baseY) > plan.climbDetectBlocks then return "liftoff" end
                    return nil
                end,
                function(live, y)
                    writer.write(stepRow(step, power, live, y))
                    -- Pair thrust with the power that was actually applied, and
                    -- only when every bank is armed -- a mid-disarm sample is a
                    -- real reading of a bank that is coasting to zero.
                    -- Only pair thrust with power once power has SETTLED at the
                    -- commanded value. The cheap ack refreshes currentPower on
                    -- every command but totalThrustKN only on the 1 Hz status,
                    -- so during a ramp the two are up to a second out of step --
                    -- which produced rows reading "applied 0.10, thrust 258048"
                    -- while the craft was actually climbing on more than that.
                    local applied = appliedPower(live)
                    local settled = applied and math.abs(applied - power) < 0.005
                    if settled then
                        stableFor = (stableFor or 0) + 1
                    else
                        stableFor = 0
                    end
                    if live.allArmed and live.sawThrust and settled
                        and stableFor >= 3 then
                        points[#points + 1] = { power = applied, kn = live.totalThrustKN }
                    end
                end)

            if reArms and reArms > 0 then
                local why = {}
                for _, corner in ipairs(CORNERS) do
                    local entry = (sample and sample.corners[corner]) or {}
                    if entry.lastReject then
                        why[#why + 1] = corner .. ":" .. tostring(entry.lastReject)
                    end
                end
                note(string.format("    re-armed %d time(s)%s", reArms,
                    #why > 0 and ("  last rejects: " .. table.concat(why, " ")) or ""))
            end

            local kn = sample and sample.sawThrust and sample.totalThrustKN or nil
            note(string.format("    thrust = %s kN   power applied %s..%s",
                kn and string.format("%.2f", kn) or "nil",
                sample and sample.minPower and string.format("%.2f", sample.minPower) or "?",
                sample and sample.maxPower and string.format("%.2f", sample.maxPower) or "?"))

            -- Not warned about any more. All 128 report "obstructed" while the
            -- banks demonstrably lift the carrier, so thrusters.lua's
            -- `clearance <= 0 means blocked` test has the sense inverted --
            -- getObstruction() evidently returns 0 for a CLEAR thruster. The
            -- raw value is in the CSV as min_clearance; judge from that.
            if sample and sample.minClearance and sample.minClearance > 0 then
                note(string.format("    min clearance %.3f -- a real obstruction",
                    sample.minClearance))
            end

            if stopped == "liftoff" then
                note("")
                note(string.format("LIFTOFF at ion power %.2f with props at %d rpm",
                    power, plan.propRpm))
                local kn = sample and sample.sawThrust and sample.totalThrustKN or nil
                if kn then
                    note(string.format("  ion thrust reported %.0f kN = %.3f of weight",
                        kn, kn / weight))
                    note(string.format("  quantum multiple: %.2f x 258048",
                        kn / 258048.016))
                    note("  A whole multiple means force may be quantised too;")
                    note("  a fractional one means only the REPORTING is.")
                end
                note("  Props at 64 rpm carry ~52.1% of weight, so this is the")
                note("  intended flight configuration, not a synthetic test.")
                break
            end
            if stopped == "abort_ceiling" then
                error("climbed past the altitude ceiling during the ion ramp", 0)
            end

            if yStart and yPeak and (yPeak - yStart) > plan.unloadBlocks then
                note(string.format(
                    "    craft rose %.3f blocks -- unloading its ground contact",
                    yPeak - yStart))
            end
        end
    end)
end

parallel.waitForAny(ionLoop, listenLoop)

-- ---------------------------------------------------------------------------
-- Always disarm. fallbackPower is 0.0, so this is the safe resting state --
-- and unlike the props, dropping ion power on the ground costs nothing.
-- ---------------------------------------------------------------------------
-- Close the loop: the pod counts what it received and what it acted on, so
-- "command loss" can finally be measured instead of inferred from silence.
note("")
note("COMMAND ACCOUNTING (per pod)")
do
    local final = readPods()
    for _, corner in ipairs(CORNERS) do
        local e = final.corners[corner] or {}
        local seen = tonumber(e.commandsSeen)
        local applied = tonumber(e.commandsApplied)
        local rejected = tonumber(e.commandsRejected)
        if seen and applied and rejected then
            note(string.format("  %s seen=%d applied=%d rejected=%d (%.1f%% rejected) last=%s",
                corner, seen, applied, rejected,
                seen > 0 and (100 * rejected / seen) or 0, tostring(e.lastReject)))
        else
            note(string.format("  %s no command counters (pod not updated?)", corner))
        end
    end
    note("  Sent-but-not-seen is true radio loss; seen-but-rejected is a guard.")
end

note("")
note("disarming ion banks")
pcall(disarmAll)

if not ok then
    note("FAILED: " .. tostring(failure))
end

-- --- fit --------------------------------------------------------------------
if #points >= 2 then
    local n, sx, sy, sxx, sxy = 0, 0, 0, 0, 0
    for _, point in ipairs(points) do
        n = n + 1
        sx, sy = sx + point.power, sy + point.kn
        sxx, sxy = sxx + point.power ^ 2, sxy + point.power * point.kn
    end
    local denominator = n * sxx - sx * sx
    if math.abs(denominator) > 1e-12 then
        local slope = (n * sxy - sx * sy) / denominator
        local intercept = (sy - slope * sx) / n
        note("")
        note("ION THRUST vs COMMANDED POWER")
        note(string.format("  kN = %.3f * power + %.3f", slope, intercept))
        note(string.format("  full power (1.0) => %.2f kN across %d thrusters",
            slope + intercept, 128))
        note("")
        note("To use this for the 'props at 64 rpm, ions do the rest' plan the")
        note("kN must be converted into the same force units as mass * gravity.")
        note("Only a liftoff gives that conversion -- if this run did not lift,")
        note("raise plan.propRpm and run again so the ions have less to find.")
    end
end

writer.close()
writeReport("/fcs/ionsweep_result.txt", summary)
note("")
note("csv    : " .. logPath)
note("summary: /fcs/ionsweep_result.txt")

if not ok then
    error(failure, 0)
end
