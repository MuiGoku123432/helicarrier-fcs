-- Does thrust vectoring work on this craft, and how hard does it push?
--
--     /fcs/vectorprobe.lua                 phase A only -- GROUND, will not fly
--     /fcs/vectorprobe.lua --hover         phase A, then fly if A passes
--
-- Run it in the FCS-DEV "Flight Tools" tab. Running it in the telemetry tab
-- kills the logger, and this tool's whole value is in the numbers it writes.
--
-- ---------------------------------------------------------------------------
-- WHAT IS BEING ANSWERED, AND WHY IT BLOCKS EVERYTHING
--
-- Position hold, the strafe fix and yaw all want the same actuator: the
-- gyroscopic propeller bearings. The ions cannot do the job -- one ion level is
-- 7.42 deg/s^2 of attitude command against a damping action that needs
-- 0.268 deg/s^2, so they are 28x too coarse, and 166-333x too coarse to hold a
-- small tilt. Bearing tilt is continuous. It is the only actuator with the
-- resolution, which makes this measurement the critical path.
--
-- But each corner is a COUNTER-ROTATING PAIR: thrust vectors {0,1,0} and
-- {0,-1,0} with thrusts +13960.98 and -13960.98, which multiply out to both
-- pushing UP. Tilt them both and the vertical components keep agreeing, while
-- the LATERAL components may add or may cancel. props.lua says exactly this and
-- stops: "the mapping from a commanded tilt to a lateral force direction is
-- UNVERIFIED".
--
-- If they CANCEL, common-mode tilt produces no translation at all and the plan
-- needs another route. That is one subtraction and it gates the rest, so phase
-- A does it ON THE GROUND and phase B refuses to fly if the answer is no.
--
-- ---------------------------------------------------------------------------
-- WHY PHASE A NEEDS THE PROPS TURNING
--
-- It would be safer still to do this dead, and that does not work:
--
--     "At 0 RPM the target is stored and completely ignored: getTiltAngle
--      stays 0 and getThrustVector does not move."   -- props.lua
--
-- The bearing must be ACTIVE. So phase A runs the props at 16 RPM, which is
-- 13.0% of craft weight -- nowhere near the ~122 RPM that lifts, so the hull
-- stays on the ground. One corner is tilted at a time, so the largest lateral
-- force in play is about 1% of weight against a grounded craft.
--
-- THE RULE applies throughout: an inactive bearing reading proves nothing.
-- Four separate "findings" in HANDOFF turned out to be readings taken while
-- isActive was false. Every reading here is gated on `active` first.
-- ---------------------------------------------------------------------------

if package then
    package.path = "/?.lua;/?/init.lua;" .. package.path
end

local config = require("fcs.config")
local banks = require("fcs.banks")
local profile = require("fcs.mixer_profile")
local atmosphere = require("fcs.atmosphere")
local flight = require("fcs.flight")
local actuators = require("fcs.actuators")
local vectoring = require("fcs.vectoring")
local lateralhold = require("fcs.lateralhold")

local plan = {
    -- Enough for isActive without approaching lift. 16 RPM measures 13.0% of
    -- craft weight; props-only hover needs 122-124.
    groundRpm = 16,

    -- Tilt steps for phase A. Small, and well inside props.lua's own 15 degree
    -- clamp. Three of them so a bad single reading cannot carry the verdict.
    -- Capped at 8. The first ground run commanded 12 and the bearing reported
    -- 10.84 -- it did not reach, so a 12 degree row measures an unknown angle.
    groundTilts = { 4, 6, 8 },

    -- Azimuth to probe on the ground. NOT assumed to mean anything: props.lua's
    -- tiltTarget comment claims azimuth 0 points at the bow, but that comment
    -- predates the axis correction and +X is PORT. The probe MEASURES which way
    -- the force actually goes and prints the mapping.
    groundAzimuth = 0,

    -- Which corner phase A tilts. One at a time keeps the ground force small
    -- and isolates the reading.
    groundCorner = "FL",

    -- How long to let a commanded tilt settle before believing the telemetry.
    -- Confirmed from reportedTilt, never from the ack -- an ack says only that
    -- the message was accepted.
    tiltSettleSeconds = 2.5,

    -- Phase B.
    climbGain = 20,          -- run 19 held +20.0 cleanly; the ceiling is ~+23
    climbTimeoutSeconds = 90,
    propRpm = 64,            -- 52.1% of weight, the standard flight setting

    -- B1: common-mode tilt, all four corners, symmetric so it makes force
    -- rather than torque.
    --
    -- Budgeted: props at 64 RPM carry 52% of weight, so 3 degrees gives
    -- 0.52 * sin(3) * 11 = 0.30 blocks/s^2. Over a 2 s pulse that is
    -- 0.6 blocks/s and ~0.6 blocks travelled, and arresting it sweeps about as
    -- far again -- call it 2.4 blocks. The abort sits at 25.
    arrestSeconds = 20.0,
    restThreshold = 0.25,
    stepTilt = 8.0,
    stepSeconds = 2.0,
    holdStationSeconds = 30.0,

    -- B2 USED TO BE a differential-tilt staircase measuring roll torque, and it
    -- is gone because it measured the wrong thing. Port and starboard corners
    -- were commanded at OPPOSITE azimuths, which makes port push starboard and
    -- starboard push port -- a YAW couple. Differential azimuth cannot produce
    -- roll at all: vertical thrust goes as cos(tilt), which is identical for
    -- +tilt and -tilt. It duly measured alpha = -0.055 deg/s^2, correctly, of
    -- an axis it was not driving.
    --
    -- Roll from the bearings needs differential tilt MAGNITUDE, and that is
    -- marginal anyway: 0.084 deg/s^2 at 8 degrees, 0.295 at the 15 degree
    -- clamp, against the 0.268 critical damping wants. The lateral force is the
    -- strong axis of this actuator, so the tool now measures and uses that.

    -- Raised from 25. The craft ARRIVES at hover already drifting ~1.7
    -- blocks/s, so a 25 block budget was consumed during the settle itself and
    -- fired before any measurement began. This is a runaway guard, not a
    -- station-keeping tolerance -- B3 reports the actual drift.
    maxHorizontalDrift = 60,
    abortArrestSeconds = 15.0,
}

local args = { ... }
local doHover = false
for _, argument in ipairs(args) do
    if argument == "--hover" then doHover = true end
end

local report = {}
local function note(text)
    report[#report + 1] = text
    print(text)
end

local function writeReport()
    local file = fs.open("/fcs/vectorprobe_result.txt", "w")
    if file then
        file.write(table.concat(report, "\n"))
        file.close()
    end
end

local atmosphereModel = atmosphere.load()

local session = flight.new({
    config = config,
    profile = profile,
    atmosphere = atmosphereModel,
    note = note,
    maxTiltDegrees = 28,
    maxAltitudeGain = 60,
    minAltitudeGain = -5,
})
session.cheapRead = true

local results = { ground = {}, hover = {} }

-- ---------------------------------------------------------------------------
-- Reading the bearings
-- ---------------------------------------------------------------------------

-- Per-bearing telemetry as it arrives from the pod: props.telemetry fills
-- perBearing[i] = { name, thrust, assembled, handedness, vx, vy, vz }.
local function readCorner(corner)
    local pod = banks.getState()[corner]
    local prop = pod and pod.prop
    if not prop then return nil, "no prop telemetry" end

    -- THE RULE. An inactive bearing reports a stored target it is ignoring.
    if not prop.active then return nil, "bearings not active" end
    if prop.bearingsAssembled == false then return nil, "bearings not assembled" end

    local perBearing = prop.perBearing
    if type(perBearing) ~= "table" or #perBearing == 0 then
        return nil, "no per-bearing data"
    end

    local bearings = {}
    for index, bearing in ipairs(perBearing) do
        if type(bearing.thrust) == "number" and type(bearing.vy) == "number" then
            bearings[#bearings + 1] = {
                name = bearing.name or ("bearing " .. index),
                thrust = bearing.thrust,
                thrustVector = { bearing.vx or 0, bearing.vy, bearing.vz or 0 },
            }
        end
    end
    if #bearings == 0 then return nil, "no bearing reported thrust and a vector" end

    return {
        bearings = bearings,
        tiltAngle = prop.tiltAngle,
        force = vectoring.cornerForce(bearings),
    }, nil
end

local function waitSeconds(seconds)
    local deadline = os.epoch("utc") + seconds * 1000
    while os.epoch("utc") < deadline do
        session:hold(0.25, function() return nil end)
    end
end

-- ---------------------------------------------------------------------------
-- Phase A: ground. Do the pair's lateral components add or cancel?
-- ---------------------------------------------------------------------------

local function runGround()
    note("")
    note("== PHASE A: bearing pair coherence (GROUND, will not fly) ==")
    note("  props at " .. plan.groundRpm .. " rpm -- 13% of weight, cannot lift.")
    note("  ions stay disarmed; one corner tilted at a time.")

    local corner = plan.groundCorner
    local set, err = session:setAllProps(plan.groundRpm)
    if not set then
        note("  FAILED to start props: " .. tostring(err))
        return false
    end
    waitSeconds(plan.tiltSettleSeconds)

    local baseline, reason = readCorner(corner)
    if not baseline then
        note("  cannot read " .. corner .. ": " .. tostring(reason))
        note("  Without an ACTIVE bearing every reading below would be a")
        note("  stored target the hardware is ignoring. Stopping.")
        return false
    end

    note("")
    note(string.format("  %s neutral: %d bearings, lift %.1f, lateral %.1f",
        corner, baseline.force.bearings, baseline.force.vertical,
        baseline.force.lateralOfSum))
    for _, bearing in ipairs(baseline.bearings) do
        note(string.format("    %-28s thrust %12.2f  vec {%.3f, %.3f, %.3f}",
            bearing.name, bearing.thrust, bearing.thrustVector[1],
            bearing.thrustVector[2], bearing.thrustVector[3]))
    end

    -- BOTH MODES, same corner, same angles, back to back.
    --
    -- The first ground run measured coherence 0.000 with every bearing sent the
    -- same azimuth, and the mirrored command is predicted to fix it. Measuring
    -- them in ONE run is what makes that a comparison rather than two readings
    -- taken minutes apart under conditions nobody wrote down -- and if mirroring
    -- does nothing, the unmirrored rows prove the rig still reproduces the
    -- original result rather than having quietly broken.
    local function sweep(mirror, label)
        note("")
        note("  --- " .. label .. " ---")
        note(string.format("  %6s %10s %12s %12s %11s %s",
            "tilt", "reported", "lift", "lateral", "coherence", "verdict"))

        local verdicts, samples = {}, {}
        for _, angle in ipairs(plan.groundTilts) do
            local applied, tiltErr = pcall(actuators.setTilt, corner, angle,
                plan.groundAzimuth, nil, mirror)
            if not applied then
                note("    tilt " .. angle .. " failed: " .. tostring(tiltErr))
            else
                waitSeconds(plan.tiltSettleSeconds)
                local reading = readCorner(corner)
                if reading and reading.force then
                    local verdict = vectoring.verdict(reading.force)
                    verdicts[#verdicts + 1] = verdict
                    note(string.format("  %6.1f %10s %12.1f %12.1f %11s %s",
                        angle,
                        reading.tiltAngle and string.format("%.2f", reading.tiltAngle)
                            or "--",
                        reading.force.vertical, reading.force.lateralOfSum,
                        reading.force.coherence
                            and string.format("%.3f", reading.force.coherence) or "--",
                        verdict))

                    -- THE PER-BEARING VECTORS ARE THE EVIDENCE for the headline
                    -- claim, and the first run printed them only for the neutral
                    -- baseline -- so "the laterals cancel" had to be taken on
                    -- trust. Printed at every step now.
                    for _, bearing in ipairs(reading.bearings) do
                        note(string.format("           %-30s t %11.2f  vec {%+.4f, %+.4f, %+.4f}",
                            bearing.name, bearing.thrust,
                            bearing.thrustVector[1], bearing.thrustVector[2],
                            bearing.thrustVector[3]))
                    end

                    local heading = vectoring.headingFromBow(reading.force.force,
                        config.axes)
                    samples[#samples + 1] = {
                        angle = angle, heading = heading,
                        lateral = reading.force.lateralOfSum,
                        reported = reading.tiltAngle,
                    }
                else
                    note(string.format("  %6.1f   -- no usable reading --", angle))
                end
            end
        end
        pcall(actuators.setTilt, corner, 0, 0)
        waitSeconds(1.0)
        return verdicts, samples
    end

    local plainVerdicts = sweep(false, "UNMIRRORED (both bearings same azimuth)")
    local verdicts, samples = sweep(true, "MIRRORED (down-facing bearing flipped 180)")

    results.ground.unmirrored = plainVerdicts[1]

    pcall(session.setAllProps, session, 0)

    -- The verdict has to be unanimous. A tool that averages ADDS and CANCELS
    -- into a recommendation is worse than one that refuses to answer.
    local agreed = verdicts[1]
    for _, verdict in ipairs(verdicts) do
        if verdict ~= agreed then agreed = nil end
    end

    note("")
    if #verdicts == 0 then
        note("  NO USABLE READINGS. Nothing is known; do not fly phase B.")
        return false
    elseif not agreed then
        note("  VERDICTS DISAGREE ACROSS TILT STEPS -- " ..
            table.concat(verdicts, ", "))
        note("  That is not a measurement. Suspect a bearing that did not")
        note("  reach its target; check reported tilt against commanded.")
        return false
    end

    results.ground.verdict = agreed
    results.ground.samples = samples

    if agreed == vectoring.CANCELS then
        note("  *** THE PAIR CANCELS EVEN MIRRORED. No lateral force. ***")
        note("  Mirroring the down-facing bearing was the fix predicted from the")
        note("  first run's measured vectors, and it did not take. Compare the")
        note("  two sweeps above: if the vectors are identical in both, the")
        note("  mirror flag never reached props.lua -- check that the pods are")
        note("  running the build that accepts message.mirror. If the vectors")
        note("  DID change and the laterals still cancel, the model is wrong")
        note("  and the routes left are setThrustHandedness reaction torque or")
        note("  re-mounting one bearing of each pair.")
        return false
    elseif agreed == vectoring.PARTIAL then
        note("  PARTIAL coherence. Some lateral force survives, but the pair")
        note("  is fighting itself. Phase B would measure a number that")
        note("  depends on the mismatch rather than on the tilt. Not flying.")
        return false
    end

    note("  THE PAIR ADDS. Common-mode tilt produces real lateral force.")

    -- The azimuth mapping, measured rather than assumed.
    local heading = samples[#samples] and samples[#samples].heading
    if heading then
        note("")
        note(string.format("  AZIMUTH %d DEGREES PUSHES TOWARD %.0f deg = %s",
            plan.groundAzimuth, heading, vectoring.describeHeading(heading)))
        note("  props.lua's tiltTarget comment says azimuth 0 is toward the")
        note("  BOW. It predates the axis correction: +X is PORT, not the bow.")
        note("  Believe this line, not that comment.")
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Phase B: hover
-- ---------------------------------------------------------------------------

local function horizontalSpeed(state)
    local velocity = state and state.linearVelocityWorld
    if not velocity then return nil end
    return math.sqrt((velocity.x or 0) ^ 2 + (velocity.z or 0) ^ 2)
end

-- HORIZONTAL ABORT. Session:checkLimits guards attitude and altitude, and
-- neither notices a craft flying calmly and level into the distance -- which is
-- the failure mode UNIQUE to this tool, because it is the first one that
-- commands lateral force on purpose.
--
-- Anchored where phase B starts, not at ground level, so the arrest leg is
-- measured against the hover position rather than the launch point.
local hoverOrigin = nil

local function horizontalDrift(state)
    local position = state and state.position
    if not position or not hoverOrigin then return nil end
    return math.sqrt((position.x - hoverOrigin.x) ^ 2
        + (position.z - hoverOrigin.z) ^ 2)
end

-- Returns a stop reason when the craft has gone too far, for use inside any
-- hold() callback. Clears the tilts itself: whatever is being measured matters
-- less than removing the force that is carrying the craft away.
local function driftAbort(state)
    local drift = horizontalDrift(state)
    if not drift or drift <= plan.maxHorizontalDrift then return nil end

    -- CLEARING THE TILTS IS NOT AN ABORT. The last run proved it: the limit
    -- tripped at 25.3 blocks and the craft carried on to 65.1, because nothing
    -- was left opposing a velocity it already had. Drag alone takes ~11 s to
    -- bleed 1.7 blocks/s.
    --
    -- So the abort now uses the actuator this whole tool exists to
    -- characterise: full opposing tilt, held until the craft is slow, and only
    -- then neutral. It is the same law the hold loop runs, saturated.
    session.aborted = string.format("horizontal drift %.1f blocks", drift)
    note(string.format("  *** ABORT: drifted %.1f blocks (limit %d) -- arresting ***",
        drift, plan.maxHorizontalDrift))

    local deadline = os.epoch("utc") + plan.abortArrestSeconds * 1000
    while os.epoch("utc") < deadline do
        local now = session:readCheap()
        local speed = horizontalSpeed(now)
        if not speed or speed < plan.restThreshold then break end
        local command = lateralhold.command(now, config.axes,
            { gainDegreesPerSpeed = 99 })   -- saturate: this is not the moment to be gentle
        commandAllTilts(command.tilt, command.azimuth)
        session:trim(plan.climbGain, flight.MAX_CLIMB_RATE, 0, now)
        session:send()
    end
    clearAllTilts()
    note(string.format("  abort arrest finished at %.3f blocks/s",
        horizontalSpeed(session:readCheap()) or -1))
    return "drift abort"
end

-- FIRE AND FORGET. actuators.setTilt blocks up to 1000 ms waiting for a reply,
-- and the first hover run showed exactly what that costs inside a control
-- loop: "no reply from the FR pod within 1000 ms" four times, each one a
-- second in which no command of any kind went out.
--
-- set_tilt has no arm gate and no watchdog pod-side -- it is set-and-hold, by
-- design -- so a dropped tilt is re-sent on the next iteration a fifth of a
-- second later, which is a far better failure mode than stalling the loop.
-- Confirmation still comes from telemetry (prop.tiltAngle), never the ack.
local function sendTilt(corner, angle, azimuth)
    return banks.send(corner, "set_tilt", {
        angle = angle, azimuth = azimuth, bearing = nil, mirror = true,
    })
end

local function commandAllTilts(angle, azimuth)
    for _, corner in ipairs(flight.CORNERS) do
        sendTilt(corner, angle, azimuth)
    end
end

local function clearAllTilts()
    for _, corner in ipairs(flight.CORNERS) do
        sendTilt(corner, 0, 0)
    end
end

-- Drive the lateral-hold loop for a while, reporting what it achieved.
--
-- Returns the peak and final speed so a caller can gate on it. This is both the
-- SETTLE step and the DELIVERABLE: arresting the drift and holding station are
-- the same loop run for different reasons.
local function holdLateral(seconds, label)
    note("")
    note("  " .. label)

    local peakSpeed, finalSpeed, peakTilt = 0, nil, 0
    local samples, saturatedSamples = 0, 0
    local startAt = os.epoch("utc")
    local lastAzimuth, lastTilt = nil, nil

    session:hold(seconds, function(state, now)
        session:trim(plan.climbGain, flight.MAX_CLIMB_RATE, 0, state)
        local stop = driftAbort(state)
        if stop then return stop end

        local command = lateralhold.command(state, config.axes)
        if command.speed then
            samples = samples + 1
            finalSpeed = command.speed
            if command.speed > peakSpeed then peakSpeed = command.speed end
            if command.saturated then saturatedSamples = saturatedSamples + 1 end
            if command.tilt > peakTilt then peakTilt = command.tilt end
        end

        -- Re-send only when the command has actually moved. The pods hold a
        -- tilt indefinitely, so re-issuing an identical one every iteration is
        -- pure rednet traffic competing with the ion commands the watchdog is
        -- counting.
        local changed = not lastTilt
            or math.abs(command.tilt - lastTilt) > 0.25
            or (lastAzimuth and math.abs((command.azimuth - lastAzimuth + 540) % 360 - 180) > 5)
        if changed then
            commandAllTilts(command.tilt, command.azimuth)
            lastTilt, lastAzimuth = command.tilt, command.azimuth
        end
        return nil
    end)

    local elapsed = (os.epoch("utc") - startAt) / 1000
    note(string.format("    %.1f s, %d samples, peak %.3f -> final %.3f blocks/s",
        elapsed, samples, peakSpeed, finalSpeed or -1))
    note(string.format("    peak tilt %.1f deg, saturated on %d of %d samples",
        peakTilt, saturatedSamples, samples))
    return finalSpeed, peakSpeed
end

-- B1: can the loop bring a drifting craft to rest?
--
-- The craft arrives at hover already strafing -- the last run reached the hold
-- at 1.758 blocks/s -- so this runs FIRST, and everything after it depends on
-- it succeeding. The previous version measured acceleration by differencing
-- speed against a 1.758 blocks/s background and got a meaningless number.
local function runArrest()
    note("")
    note("== PHASE B1: arrest the drift ==")
    local before = session:read()
    local startSpeed = horizontalSpeed(before) or 0
    note(string.format("  arriving at %.3f blocks/s", startSpeed))
    note(string.format("  the 12 deg clamp holds against %.2f blocks/s",
        (lateralhold.terminalSpeed(lateralhold.DEFAULTS.maxTiltDegrees))))

    local finalSpeed = holdLateral(plan.arrestSeconds, "closing the loop")
    clearAllTilts()

    results.hover.arriveSpeed = startSpeed
    results.hover.arrestedSpeed = finalSpeed
    if finalSpeed and startSpeed > 0.2 then
        note(string.format("  arrested %.0f%% of the arrival drift",
            (1 - finalSpeed / startSpeed) * 100))
    end
    return finalSpeed
end

-- B2: from REST, an open-loop step -- the in-flight check on the ground number.
--
-- Phase A measured lateral force geometrically (2*T*sin(tilt), linear to
-- 0.06%). This is the only step that confirms the craft actually accelerates
-- the way that force says it should, and it is worth having because every
-- geometric measurement in this project has needed exactly one flight to catch
-- what the geometry did not know about.
local function runStep(restSpeed)
    note("")
    note("== PHASE B2: open-loop step from rest ==")
    if not restSpeed or restSpeed > plan.restThreshold then
        note(string.format("  SKIPPED: still moving at %.3f (need < %.2f).",
            restSpeed or -1, plan.restThreshold))
        note("  An acceleration differenced against a moving start is the")
        note("  contaminated number the previous run reported. Not repeating it.")
        return
    end

    local predicted = select(2, lateralhold.terminalSpeed(plan.stepTilt))
    note(string.format("  %.0f deg for %.1f s; phase A predicts %.4f blocks/s^2",
        plan.stepTilt, plan.stepSeconds, predicted))

    local before = session:read()
    local startSpeed = horizontalSpeed(before) or 0
    commandAllTilts(plan.stepTilt, plan.groundAzimuth)

    local samples = 0
    local startAt = os.epoch("utc")
    session:hold(plan.stepSeconds, function(state, now)
        session:trim(plan.climbGain, flight.MAX_CLIMB_RATE, 0, state)
        local stop = driftAbort(state)
        if stop then return stop end
        samples = samples + 1
        return nil
    end)
    local elapsed = (os.epoch("utc") - startAt) / 1000
    clearAllTilts()

    local after = session:read()
    local endSpeed = horizontalSpeed(after) or 0
    if elapsed > 0.2 then
        local measured = (endSpeed - startSpeed) / elapsed
        note(string.format("  speed %.3f -> %.3f over %.2f s (%d samples)",
            startSpeed, endSpeed, elapsed, samples))
        note(string.format("  measured %.4f blocks/s^2 vs %.4f predicted = %.0f%%",
            measured, predicted, predicted > 0 and (measured / predicted * 100) or 0))
        results.hover.stepMeasured = measured
        results.hover.stepPredicted = predicted
    end

    -- Always hand back a stationary craft, whatever the step did.
    holdLateral(plan.arrestSeconds, "re-arresting after the step")
    clearAllTilts()
end

-- B3: THE DELIVERABLE. Hold station and report the drift that accumulates.
local function runHold()
    note("")
    note("== PHASE B3: station keeping ==")
    local anchor = session:read()
    local origin = anchor and anchor.position
    if not origin then
        note("  no position fix; cannot measure station keeping")
        return
    end

    local maxDrift = 0
    local startAt = os.epoch("utc")
    session:hold(plan.holdStationSeconds, function(state, now)
        session:trim(plan.climbGain, flight.MAX_CLIMB_RATE, 0, state)
        local stop = driftAbort(state)
        if stop then return stop end

        local command = lateralhold.command(state, config.axes)
        commandAllTilts(command.tilt, command.azimuth)

        local position = state and state.position
        if position then
            local drift = math.sqrt((position.x - origin.x) ^ 2
                + (position.z - origin.z) ^ 2)
            if drift > maxDrift then maxDrift = drift end
        end
        return nil
    end)
    local elapsed = (os.epoch("utc") - startAt) / 1000
    clearAllTilts()

    local final = session:read()
    local finalDrift = 0
    if final and final.position then
        finalDrift = math.sqrt((final.position.x - origin.x) ^ 2
            + (final.position.z - origin.z) ^ 2)
    end
    results.hover.holdSeconds = elapsed
    results.hover.holdMaxDrift = maxDrift
    results.hover.holdFinalDrift = finalDrift

    note(string.format("  held %.1f s: max drift %.1f blocks, final %.1f blocks",
        elapsed, maxDrift, finalDrift))
    -- The passive baseline: 81 blocks in 48 s, i.e. ~1.67 blocks/s of drift.
    local baseline = 1.67 * elapsed
    note(string.format("  passive drift over the same time would be ~%.0f blocks",
        baseline))
    if baseline > 0 then
        note(string.format("  station keeping cut the drift by %.0f%%",
            (1 - finalDrift / baseline) * 100))
    end
end

-- ---------------------------------------------------------------------------
-- Run
-- ---------------------------------------------------------------------------

-- banks.getState() is only populated while something is pumping the rednet
-- queue, so the probe body and the listener run under parallel.waitForAny --
-- exactly as axisresponse.lua does. Every reading in phase A comes from pod
-- telemetry, so without this the tool would report "bearings not active"
-- forever and look like a hardware fault.
local function listenLoop()
    while true do
        banks.listen(1)
    end
end

local function mainLoop()
    note("=== vectoring probe ===")
    note("started " .. tostring(os.epoch("utc")))
    note(doHover and "MODE: --hover (phase A, then WILL FLY if A passes)"
        or "MODE: ground only (phase A) -- will not fly")

    local ok, reason = session:preflight()
    if not ok then
        note("PREFLIGHT FAILED: " .. tostring(reason))
        return
    end
    note(string.format("preflight: 4/4 pods online, ground y = %.4f", session.groundY))

    if not runGround() then
        note("")
        note("Phase A did not clear. Not flying.")
        return
    end
    if not doHover then
        note("")
        note("Phase A passed. Re-run with --hover to measure the forces.")
        return
    end

    note("")
    note("== PHASE B: climb to +" .. plan.climbGain .. " ==")
    if not session:arm(12) then
        note("  FAILED: banks would not arm")
        return
    end
    local set, err = session:setAllProps(plan.propRpm)
    if not set then
        note("  FAILED to park props: " .. tostring(err))
        session:descend()
        return
    end
    note("  props parked at " .. plan.propRpm .. " rpm")

    local climbed, why = session:climb(plan.climbGain, plan.climbTimeoutSeconds)
    if not climbed then
        note("  climb did not complete: " .. tostring(why))
        session:descend()
        return
    end
    note(string.format("  holding at +%.1f, collective %.3f",
        (session:craftY(session:read()) or session.groundY) - session.groundY,
        session.commanded.collective))

    -- Anchor the drift origin HERE, at the hover, so B1 and B2 are both
    -- measured against the station they are supposed to hold.
    local anchor = session:read()
    hoverOrigin = anchor and anchor.position
    if not hoverOrigin then
        note("  no position fix at hover; cannot enforce the drift abort")
        session:descend()
        return
    end

    local restSpeed = runArrest()
    if not session.aborted then runStep(restSpeed) end
    if not session.aborted then runHold() end

    note("")
    note("== descend and land ==")
    session:descend()
end

local ok, err = pcall(parallel.waitForAny, mainLoop, listenLoop)
if not ok then
    note("")
    note("PROBE ERROR: " .. tostring(err))
end

-- Tilts cleared on every exit path, including an error. A bearing left tilted
-- is a standing lateral force on a craft nobody is watching.
clearAllTilts()
pcall(session.setAllProps, session, 0)
pcall(session.finish, session)

note("")
note("=== SUMMARY ===")
note("pair coherence      : " .. tostring(results.ground.verdict or "not measured")
    .. "   (unmirrored: " .. tostring(results.ground.unmirrored or "--") .. ")")
if results.hover.arriveSpeed then
    note(string.format("arrived drifting    : %.3f blocks/s", results.hover.arriveSpeed))
    note(string.format("after the arrest    : %.3f blocks/s",
        results.hover.arrestedSpeed or -1))
end
if results.hover.stepMeasured then
    note(string.format("step response       : %.4f measured vs %.4f predicted (%.0f%%)",
        results.hover.stepMeasured, results.hover.stepPredicted,
        results.hover.stepMeasured / results.hover.stepPredicted * 100))
end
if results.hover.holdMaxDrift then
    note(string.format("station keeping     : max %.1f blocks, final %.1f, over %.0f s",
        results.hover.holdMaxDrift, results.hover.holdFinalDrift,
        results.hover.holdSeconds))
    note("  passive drift over the same window is ~1.67 blocks/s.")
    note("")
    note("Before writing any of this into a controller, get a SECOND run")
    note("agreeing within a few percent. Every authority number in this project")
    note("looked solid in isolation, and the roll figure ranged 3.98 to 86.03")
    note("across nine flights that each looked fine at the time.")
else
    note("station keeping     : not measured")
end

writeReport()
note("")
note("Report written to /fcs/vectorprobe_result.txt")
