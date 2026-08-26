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
local rolldamp = require("fcs.rolldamp")

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

    -- ALL FOUR CORNERS, one at a time.
    --
    -- The first two ground runs measured FL only and the code then commanded
    -- all four identically. That extrapolation is what the hover run cashed in:
    -- the loop pushed to oppose the drift and the craft accelerated instead,
    -- rolling POSITIVE where opposing the drift required NEGATIVE. FL's own
    -- reading is solid (-13958.80 x +0.1392 = -1943 in X, and -X is starboard),
    -- so the corners must not agree with each other.
    --
    -- One corner at a time also keeps the ground force to ~1% of weight.
    groundCorners = { "FL", "FR", "RL", "RR" },

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
    -- Outer-loop gain: how hard to decelerate, in blocks/s^2 per blocks/s.
    -- 0.15 asks for 0.25 blocks/s^2 against the 1.67 blocks/s drift, which
    -- rollForLateral turns into 1.3 degrees -- inside the 2 degree limit, so
    -- the loop is not fighting its own clamp at the speeds it will actually see.
    velocityGain = 0.15,
    -- B0, the couple. 6 degrees is well inside the clamp, and the roll budget
    -- is 3 degrees -- half the 6 degree abort, and a ninth of the 28 the
    -- runaway reached.
    -- B0, the differential-RPM staircase. Predicted 0.2712 deg/s^2 per RPM,
    -- so 3 RPM sweeps the 3 degree budget in about 2.7 s -- long enough for
    -- ~20 samples at 0.12 s, which is what the ion pulse could never buy.
    rpmSteps = { 2, 3 },
    -- Within this of ground counts as down, for deciding whether it is safe to
    -- cut the propellers.
    groundedGain = 1.5,
    rpmStepSeconds = 4.0,
    rpmMaxAngle = 3.0,
    rpmSampleSeconds = 0.12,
    rpmReachSeconds = 4.0,
    rpmTolerance = 1.5,
    rpmSettleSeconds = 6.0,
    -- Long enough for the propellers to reach a steady getThrust. They climb
    -- over a second or more, and comparing corners mid-ramp is what produced
    -- a 29%-of-the-strongest false fault.
    thrustSettleSeconds = 8.0,
    -- Below this the step measured nothing and the fit is reading noise.
    rpmMinSweep = 0.25,
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

    local set, err = session:setAllProps(plan.groundRpm)
    if not set then
        note("  FAILED to start props: " .. tostring(err))
        return false
    end
    waitSeconds(plan.tiltSettleSeconds)

    -- One sweep of one corner, at the mirrored setting only. The unmirrored
    -- comparison is kept for FL alone -- it is the control that proves the rig
    -- still reproduces the original CANCELS, and repeating it on four corners
    -- costs four times the airtime for the same one bit of information.
    local function sweepCorner(corner, mirror, label)
        note("")
        note("  --- " .. corner .. " " .. label .. " ---")
        local baseline, reason = readCorner(corner)
        if not baseline then
            note("    cannot read " .. corner .. ": " .. tostring(reason))
            return nil
        end

        local verdicts, headings = {}, {}
        for _, angle in ipairs(plan.groundTilts) do
            local ok, tiltErr = pcall(actuators.setTilt, corner, angle,
                plan.groundAzimuth, nil, mirror)
            if not ok then
                note("    tilt " .. angle .. " failed: " .. tostring(tiltErr))
            else
                waitSeconds(plan.tiltSettleSeconds)
                local reading = readCorner(corner)
                if reading and reading.force then
                    local verdict = vectoring.verdict(reading.force)
                    local heading = vectoring.headingFromBow(reading.force.force,
                        config.axes)
                    verdicts[#verdicts + 1] = verdict
                    if heading then headings[#headings + 1] = heading end
                    note(string.format("    %4.1f deg  rep %5s  lift %10.1f  lateral %9.1f  coh %5s  %-8s %s",
                        angle,
                        reading.tiltAngle and string.format("%.2f", reading.tiltAngle) or "--",
                        reading.force.vertical, reading.force.lateralOfSum,
                        reading.force.coherence
                            and string.format("%.3f", reading.force.coherence) or "--",
                        verdict,
                        heading and string.format("-> %3.0f deg %s", heading,
                            vectoring.describeHeading(heading)) or ""))
                    for _, bearing in ipairs(reading.bearings) do
                        note(string.format("             %-30s t %11.2f  vec {%+.4f, %+.4f, %+.4f}",
                            bearing.name, bearing.thrust,
                            bearing.thrustVector[1], bearing.thrustVector[2],
                            bearing.thrustVector[3]))
                    end
                else
                    note(string.format("    %4.1f deg   -- no usable reading --", angle))
                end
            end
        end
        pcall(actuators.setTilt, corner, 0, 0)
        waitSeconds(1.0)

        local agreed = verdicts[1]
        for _, verdict in ipairs(verdicts) do
            if verdict ~= agreed then agreed = nil end
        end
        -- Mean heading, taken on the unit circle so 359 and 1 average to 0
        -- rather than to 180.
        local sumSin, sumCos = 0, 0
        for _, heading in ipairs(headings) do
            sumSin = sumSin + math.sin(math.rad(heading))
            sumCos = sumCos + math.cos(math.rad(heading))
        end
        local meanHeading = #headings > 0
            and (math.deg(math.atan2(sumSin, sumCos)) % 360) or nil
        return { verdict = agreed, heading = meanHeading, steps = #verdicts }
    end

    -- The FL control: unmirrored must still CANCEL.
    local control = sweepCorner("FL", false, "UNMIRRORED (control)")
    if control and control.verdict ~= vectoring.CANCELS then
        note("")
        note("  WARNING: the unmirrored control did NOT cancel (" ..
            tostring(control.verdict) .. ").")
        note("  That reading has been reproducible across three runs, so the rig")
        note("  has changed. Treat everything below as suspect.")
    end
    results.ground.unmirrored = control and control.verdict

    local perCorner = {}
    for _, corner in ipairs(plan.groundCorners) do
        perCorner[corner] = sweepCorner(corner, true, "MIRRORED")
    end
    pcall(session.setAllProps, session, 0)

    -- THE TABLE THIS RUN EXISTS FOR.
    note("")
    note("  === PER-CORNER RESPONSE TO AZIMUTH " .. plan.groundAzimuth .. " ===")
    note(string.format("  %-6s %-10s %-8s %s", "corner", "verdict", "heading", "pushes toward"))
    local verdicts, headings = {}, {}
    for _, corner in ipairs(plan.groundCorners) do
        local entry = perCorner[corner]
        if entry and entry.verdict and entry.heading then
            verdicts[#verdicts + 1] = entry.verdict
            headings[corner] = entry.heading
            note(string.format("  %-6s %-10s %6.0f   %s", corner, entry.verdict,
                entry.heading, vectoring.describeHeading(entry.heading)))
        else
            note(string.format("  %-6s %-10s %8s", corner,
                entry and tostring(entry.verdict) or "NO DATA", "--"))
        end
    end
    results.ground.headings = headings

    -- Do the corners agree? This is the question the hover runaway asked.
    local reference, spread = nil, 0
    for _, corner in ipairs(plan.groundCorners) do
        local heading = headings[corner]
        if heading then
            if not reference then reference = heading end
            local difference = math.abs((heading - reference + 540) % 360 - 180)
            if difference > spread then spread = difference end
        end
    end

    note("")
    if not reference then
        note("  NO CORNER PRODUCED A USABLE HEADING. Nothing is known.")
        return false
    elseif spread > 30 then
        note(string.format("  *** THE CORNERS DISAGREE BY UP TO %.0f DEGREES ***", spread))
        note("  Commanding one azimuth to all four does NOT produce one force.")
        note("  This is the hover runaway explained: the loop pushed to oppose")
        note("  the drift, the corners fought, and the net force landed on the")
        note("  wrong side -- roll went POSITIVE where opposing required")
        note("  NEGATIVE, and the craft accelerated from 1.76 to 11.5 blocks/s.")
        note("")
        note("  Each corner needs its own azimuth offset, listed above. Wire")
        note("  those into the controller before any further hover attempt.")
        results.ground.headingSpread = spread
        return false
    end

    note(string.format("  All four corners agree within %.0f degrees.", spread))
    results.ground.headingSpread = spread
    results.ground.meanHeading = reference

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

    note("")
    note(string.format("  AZIMUTH %d DEGREES PUSHES TOWARD %.0f deg = %s",
        plan.groundAzimuth, reference, vectoring.describeHeading(reference)))
    return true
end

-- ---------------------------------------------------------------------------
-- Phase B: hover
-- ---------------------------------------------------------------------------

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

-- Send a translation demand and an attitude demand to every corner, resolved
-- per bearing. mirror=false because the azimuths already carry the polarity --
-- the pod's own mirror flag would flip them a second time.
local function commandSuperposed(translation, attitude)
    for _, corner in ipairs(flight.CORNERS) do
        local reading = readCorner(corner)
        local commands = reading and lateralhold.bearingCommands(
            translation, attitude, reading.bearings)
        if commands then
            for _, command in ipairs(commands) do
                banks.send(corner, "set_tilt", {
                    angle = command.tilt, azimuth = command.azimuth,
                    bearing = command.index, mirror = false,
                })
            end
        end
    end
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
-- ROLL RATE by differencing the angle, not from Session:rates.
--
-- rates() needs angular velocity, which the cheap read omits, and the Sable
-- angular channel reads exactly 0.0000 in about a third of samples at this
-- loop period. A damping term steered by a channel that reports "stopped"
-- when it is not would inject the oscillation it exists to remove.
local lastRoll, lastRollAt = nil, nil

local function rollRateOf(state, now)
    if not state or not state.roll then return 0 end
    local rate = 0
    if lastRoll and now and lastRollAt and now > lastRollAt then
        rate = (state.roll - lastRoll) / ((now - lastRollAt) / 1000)
    end
    lastRoll, lastRollAt = state.roll, now
    return rate
end

-- THE CASCADE. Outer loop picks a small roll target from the velocity error;
-- inner loop uses tilt to hold that roll and damp its rate.
--
-- The previous version commanded tilt straight from velocity, which is
-- positive feedback through the 8.6 block moment arm: tilt rolls the craft,
-- roll accelerates it, the loop asks for more tilt. Roll is the controlled
-- variable now, and it is limited to 2 degrees -- which already holds against
-- 4.2 blocks/s, twice the strafe's peak.
local function cascadeCommand(state, now)
    local body = lateralhold.bodyVelocity(state)
    local heading, speed = lateralhold.headingOf(body, config.axes)
    local rollRate = rollRateOf(state, now)

    local targetRoll = 0
    if heading and speed and speed >= lateralhold.DEFAULTS.deadbandSpeed then
        -- Decelerate at up to what the roll limit allows. Sign: a POSITIVE roll
        -- (starboard low) accelerates the craft to STARBOARD, so to oppose a
        -- drift running to starboard we want NEGATIVE roll.
        local wanted = -speed * plan.velocityGain
        local towardStarboard = math.sin(math.rad(heading))
        targetRoll = lateralhold.rollForLateral(wanted * towardStarboard)
    end

    local tilt = lateralhold.rollTilt(state and state.roll or 0, rollRate, targetRoll)
    -- rollTilt is signed; the actuator takes a magnitude and a direction.
    local azimuth = lateralhold.azimuthForHeading(tilt >= 0 and 90 or 270)
    return {
        tilt = math.abs(tilt), azimuth = azimuth, targetRoll = targetRoll,
        rollRate = rollRate, speed = speed, heading = heading,
    }
end

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
        -- Saturated cascade: still through the roll loop, because the runaway
        -- proved that commanding raw tilt is how the craft gets INTO this.
        local command = cascadeCommand(now, os.epoch("utc"))
        commandAllTilts(command.tilt, command.azimuth)
        session:trim(plan.climbGain, flight.MAX_CLIMB_RATE, 0, now)
        session:send()
    end
    clearAllTilts()
    note(string.format("  abort arrest finished at %.3f blocks/s",
        horizontalSpeed(session:readCheap()) or -1))
    return "drift abort"
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
        if lateralhold.rollAbort(state and state.roll) then
            clearAllTilts()
            session.aborted = string.format("roll %.1f deg", state.roll)
            note(string.format("  *** ABORT: roll %.1f deg exceeds %.0f ***",
                state.roll, lateralhold.DEFAULTS.rollAbortDegrees))
            return "roll abort"
        end

        local command = cascadeCommand(state, now)
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

-- B0: ROLL AUTHORITY FROM DIFFERENTIAL PROPELLER RPM, and the sign gate.
--
-- The bearing couple is retired. It was predicted strong and measured
-- 0.07 degrees of roll in 3 seconds, because its torque needs a VERTICAL
-- moment arm nobody had measured -- the same unknown that inverted the sign
-- and ran the craft to 11.5 blocks/s the run before.
--
-- Differential RPM makes a VERTICAL force at a LATERAL arm: the geometry
-- craftgeom solves from the inertia tensor, validated by runs 9 and 10 at 97%
-- and 102% of its ceiling. Predicted 0.2712 deg/s^2 per RPM, 91% of critical
-- damping. This phase is the check on that prediction.
--
-- A STAIRCASE, and a fit that must AGREE WITH THE SWEEP. The couple phase
-- reported alpha = +0.0884 from a quadratic fit while the craft rolled 0.07
-- degrees -- that alpha implies 0.38 degrees, five times what happened. The
-- fit was reading noise, the sign gate believed it, and B1 was allowed to fly.
-- Every step here is cross-checked against the angle actually swept.
local function runRpmStep(differential)
    local before = session:readCheap()
    local startRoll = before and before.roll or 0

    local target = rolldamp.cornerRpm(plan.propRpm, differential)
    for corner, rpm in pairs(target) do
        local ok, err = session:setProps(corner, rpm, 2)
        if not ok then note("    " .. corner .. " rpm failed: " .. tostring(err)) end
    end

    -- WAIT FOR THE PROPS TO REACH IT. Propellers spin up over a second or
    -- more, and timing a torque across the ramp is distortion #4 from the
    -- axis-response campaign -- the one that made nominally identical runs
    -- scatter 2x. Confirmed from bearing RPM telemetry, never from the ack.
    local reached = false
    session:hold(plan.rpmReachSeconds, function(state, now)
        session:trim(plan.climbGain, flight.MAX_CLIMB_RATE, 0, state)
        local settled = true
        for corner, rpm in pairs(target) do
            local pod = banks.getState()[corner]
            -- controllerRpm, NOT bearingRpm. bearingRpm reads 0 in every
            -- sample ever logged -- including with the props verifiably
            -- turning at 64 -- so gating on it could never succeed and every
            -- step reported "props never reached the commanded rpm".
            -- controllerRpm tracks the target exactly.
            local actual = pod and pod.prop and pod.prop.controllerRpm
            if not actual or math.abs(actual - rpm) > plan.rpmTolerance then
                settled = false
            end
        end
        if settled then reached = true; return "reached" end
        return nil
    end)

    local samples = {}
    local startAt = os.epoch("utc")
    local restore = session.sampleSeconds
    session.sampleSeconds = plan.rpmSampleSeconds
    local marker = session:readCheap()
    startRoll = marker and marker.roll or startRoll

    session:hold(plan.rpmStepSeconds, function(state, now)
        session:trim(plan.climbGain, flight.MAX_CLIMB_RATE, 0, state)
        if lateralhold.rollAbort(state and state.roll) then
            return "roll abort"
        end
        if state and state.roll then
            samples[#samples + 1] =
                { t = (now - startAt) / 1000, angle = state.roll - startRoll }
            if math.abs(state.roll - startRoll) >= plan.rpmMaxAngle
                and #samples >= 5 then
                return "angle reached"
            end
        end
        return nil
    end)
    session.sampleSeconds = restore

    -- Back to level RPM, and let the rate settle before the next step.
    for corner in pairs(target) do
        session:setProps(corner, plan.propRpm, 2)
    end

    if #samples < 3 then return nil, "too few samples", reached end

    local s11, s12, s22, y1, y2 = 0, 0, 0, 0, 0
    for _, sample in ipairs(samples) do
        local a, b = 0.5 * sample.t ^ 2, sample.t
        s11 = s11 + a * a; s12 = s12 + a * b; s22 = s22 + b * b
        y1 = y1 + a * sample.angle; y2 = y2 + b * sample.angle
    end
    local determinant = s11 * s22 - s12 * s12
    if math.abs(determinant) < 1e-12 then return nil, "degenerate fit", reached end
    local alpha = (y1 * s22 - y2 * s12) / determinant

    -- THE CROSS-CHECK. What the fitted alpha says the craft should have swept,
    -- against what it actually swept. A fit reading noise fails here.
    local elapsed = samples[#samples].t
    local swept = samples[#samples].angle
    local implied = 0.5 * alpha * elapsed ^ 2
    return {
        alpha = alpha, swept = swept, implied = implied, samples = #samples,
        elapsed = elapsed, reached = reached,
        consistent = math.abs(swept) > plan.rpmMinSweep
            and math.abs(implied - swept) <= math.abs(swept) * 0.6 + 0.15,
    }
end

local function runRollAuthority()
    note("")
    note("== PHASE B0: roll authority from DIFFERENTIAL RPM ==")
    local predicted = rolldamp.authorityPerRpm()
    note(string.format("  predicted %.4f deg/s^2 per RPM (%.0f%% of critical damping)",
        predicted, predicted / rolldamp.criticalDamping() * 100))
    note("  each level flown +N then -N; alpha is half the difference")
    note(string.format("  %6s %8s %9s %9s %9s %s",
        "rpm", "samples", "swept+", "swept-", "alpha", "verdict"))

    -- REVERSE PAIRS. Each level is flown +N then -N, and the answer is half
    -- the difference.
    --
    -- The craft carries the strafe oscillation into every step: 42 s period,
    -- peak rate 0.90 deg/s, so up to 3.6 degrees of hull motion inside a 4 s
    -- window. Against a signal of 2.2 degrees at 1 rpm, THE DISTURBANCE IS
    -- BIGGER THAN WHAT IS BEING MEASURED. That is why the single-sided run
    -- produced 0.1060, 0.2556 and 0.3335 for 1, 2 and 3 rpm -- rising, but not
    -- in the 1:2:3 the physics requires -- and why two of three were caught by
    -- the sweep cross-check.
    --
    -- Two adjacent 4 s windows sit at nearly the same phase of a 42 s
    -- oscillation, so the hull's own contribution is very nearly identical in
    -- both while the commanded torque flips sign. Differencing cancels it to
    -- first order and doubles the signal. Averaging more single-sided steps
    -- would not: the contamination is not zero-mean over a few samples.
    local points = {}
    for _, differential in ipairs(plan.rpmSteps) do
        local forward = runRpmStep(differential)
        session:hold(plan.rpmSettleSeconds, function(state)
            session:trim(plan.climbGain, flight.MAX_CLIMB_RATE, 0, state)
            return nil
        end)
        local reverse = runRpmStep(-differential)

        if not forward or not reverse then
            note(string.format("  %6d %8s   one half of the pair did not fit",
                differential, "-"))
        else
            local alpha = (forward.alpha - reverse.alpha) / 2
            -- Both halves must have reached their commanded RPM, and the pair
            -- must be roughly antisymmetric. A pair that is NOT antisymmetric
            -- is one where something other than the commanded torque moved the
            -- craft, and no amount of differencing rescues it.
            local common = (forward.alpha + reverse.alpha) / 2
            local antisymmetric = math.abs(alpha) > math.abs(common)
            note(string.format("  %6d %8d %9.2f %9.2f %9.4f %s",
                differential, forward.samples + reverse.samples,
                forward.swept, reverse.swept, alpha,
                (forward.reached and reverse.reached and antisymmetric) and "ok"
                    or "discarded"))
            note(string.format("         +%d gave %+.4f, -%d gave %+.4f, common-mode %+.4f",
                differential, forward.alpha, differential, reverse.alpha, common))
            if not (forward.reached and reverse.reached) then
                note("         (a half never reached the commanded rpm)")
            elseif not antisymmetric then
                note("         (common-mode exceeds the signal -- the hull moved")
                note("          more than the command did)")
            else
                points[#points + 1] = { x = differential, y = alpha }
            end
        end
        session:hold(plan.rpmSettleSeconds, function(state)
            session:trim(plan.climbGain, flight.MAX_CLIMB_RATE, 0, state)
            return nil
        end)
    end

    if #points < 2 then
        note("")
        note("  NOT ENOUGH USABLE STEPS. No authority measured, and nothing")
        note("  will be closed on a guess. Landing.")
        return false
    end

    local slope, worst = vectoring.fitThroughOrigin(points)
    if not slope then
        note("  staircase would not fit. Landing.")
        return false
    end

    note("")
    note(string.format("  MEASURED %.4f deg/s^2 per RPM  (predicted %.4f = %.0f%%)",
        slope, predicted, slope / predicted * 100))
    note(string.format("  worst residual %.0f%%", worst * 100))
    results.hover.rollPerRpm = slope
    results.hover.rollPerRpmPredicted = predicted

    -- THE SIGN. A positive differential raises the PORT corners, which is a
    -- positive roll demand, so alpha must be positive. Inverted here means the
    -- damper would drive the oscillation instead of killing it.
    if slope < 0 then
        note("")
        note("  *** THE SIGN IS INVERTED. A positive differential rolls the")
        note("  craft the wrong way. Flip the corner map in rolldamp.cornerRpm")
        note("  and re-run. NOT closing the loop.")
        return false
    end
    note(string.format("  one RPM is %.0f%% of critical damping -- the damper is %s.",
        slope / rolldamp.criticalDamping() * 100,
        slope >= rolldamp.criticalDamping() * 0.5 and "WRITABLE"
            or "too weak to be useful"))
    return slope >= rolldamp.criticalDamping() * 0.5
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

        if lateralhold.rollAbort(state and state.roll) then
            clearAllTilts()
            session.aborted = string.format("roll %.1f deg", state.roll)
            note(string.format("  *** ABORT: roll %.1f deg exceeds %.0f ***",
                state.roll, lateralhold.DEFAULTS.rollAbortDegrees))
            return "roll abort"
        end
        local command = cascadeCommand(state, now)
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

    -- DRIVETRAIN CHECK, WITH THE PROPS TURNING.
    --
    -- FR flew a whole staircase with its Rotation Speed Controller reporting
    -- hasSource = FALSE. It was healthy in phase A on the ground and dead by
    -- the measurement, and the craft flew with one corner contributing nothing
    -- and a standing torque nobody had accounted for.
    --
    -- Checking it at rest is not enough. hasSource and getThrust are STATIC
    -- getters -- they read the same whether or not the shaft is turning, which
    -- is exactly why the archived probes could compare structural values at
    -- rest. So a drivetrain with a source that STALLS or SLIPS under load
    -- passes a stationary check and fails in the air.
    --
    -- So spin them up first, and require every corner to actually REACH the
    -- commanded RPM and report active. That is a load test, not an inventory.
    -- 16 rpm is 13% of craft weight, nowhere near lift.
    -- STATIC thrust first, props stopped. This is the reading that actually
    -- discriminates: it caught the dead FR at 7.6e-32 against 111688 on the
    -- others, and passed all four at 111687-111688 once repaired.
    local staticThrust = {}
    for _, corner in ipairs(flight.CORNERS) do
        local pod = banks.getState()[corner]
        local prop = pod and pod.prop
        if prop and type(prop.thrust) == "number" then
            staticThrust[corner] = prop.thrust
        end
    end

    local spun, spinError = session:setAllProps(plan.groundRpm)
    if not spun then
        note("  PREFLIGHT FAILED to start props: " .. tostring(spinError))
        return
    end

    local reached = {}
    session:hold(plan.rpmReachSeconds, function(state, now)
        local settled = true
        for _, corner in ipairs(flight.CORNERS) do
            local pod = banks.getState()[corner]
            local actual = pod and pod.prop and pod.prop.controllerRpm
            if actual and math.abs(actual - plan.groundRpm) <= plan.rpmTolerance then
                reached[corner] = actual
            else
                settled = false
            end
        end
        if settled then return "spun up" end
        return nil
    end)

    -- NO THRUST COMPARISON WHILE SPINNING. It was tried and it does not work.
    --
    -- Two ground runs ten minutes apart, same craft, nothing touched between:
    --
    --     run A   FL 100%   FR  66%   RL 100%   RR 100%
    --     run B   FL 100%   FR  97%   RL  19%   RR   0%
    --
    -- Three different corners "failed". The per-bearing values do not
    -- reconcile with the corner totals either -- RR read 0.00 while its two
    -- bearings read +/-9917.72 -- and rot reads 0 on all eight while active is
    -- true. getThrust is not a stable quantity under rotation: it oscillates,
    -- and the aggregate and per-bearing reads are taken at different moments.
    --
    -- A "settle" of 2% across three rounds passed on luck and produced three
    -- consecutive FALSE FAULTS, which is worse than no check -- it is the
    -- cry-wolf failure this file already learned about from the ratio bound.
    --
    -- So thrust is compared at REST, where it discriminated correctly, and the
    -- spun-up pass tests only what is reliable under load: a kinetic source,
    -- reaching the commanded RPM, active bearings, and no overstress.

    -- Collect the per-corner verdict from the SETTLED readings.
    local thrusts, dead = {}, {}
    for _, corner in ipairs(flight.CORNERS) do
        local pod = banks.getState()[corner]
        local prop = pod and pod.prop
        if not prop then
            dead[#dead + 1] = corner .. " (no telemetry)"
        else
            if prop.hasSource == false then
                dead[#dead + 1] = corner .. " (no kinetic source)"
            end
            if not reached[corner] then
                dead[#dead + 1] = string.format("%s (rpm %s, wanted %d)", corner,
                    tostring(prop.controllerRpm), plan.groundRpm)
            end
            if prop.active == false then
                dead[#dead + 1] = corner .. " (bearings inactive)"
            end
            if prop.bearingOverstressed then
                dead[#dead + 1] = corner .. " (OVERSTRESSED)"
            end
            -- The AT-REST reading, taken before the props were started.
            if type(staticThrust[corner]) == "number" then
                thrusts[corner] = staticThrust[corner]
            end
        end
    end

    -- WHAT GATES THE FLIGHT, AND WHY IT IS NOT THRUST.
    --
    -- TOPOLOGY: each corner has ONE Rotation Speed Controller driving BOTH of
    -- its bearings. The pair always turns together at whatever the RSC
    -- delivers -- RPM is a per-corner control, never per-bearing. So the RSC's
    -- own reported speed is the authoritative health signal for that corner,
    -- and the per-bearing thrust readings are downstream of it.
    --
    -- getThrust is not comparable across corners in any state, and four runs
    -- were spent proving it:
    --
    --   spinning   oscillates; three runs named three different corners
    --              (FR 66%, then RL 19% and RR 0%, nothing touched between)
    --   at rest    denormal noise ~1e-20, so the percentages are ratios of
    --              nothing -- the last run printed "thrust 0.00 (43%)"
    --
    -- The one reading that ever discriminated -- 7.6e-32 against 111688 on the
    -- genuinely dead FR -- caught a state where three corners happened to
    -- retain a value from recent rotation and the dead one could not. That was
    -- luck, not a measurement, and it is not a check.
    --
    -- The discrete signals ARE reliable and are what gate the flight: a
    -- missing kinetic source is what FR's real failure actually looked like,
    -- and a stalled or stress-starved drivetrain cannot reach its commanded
    -- RPM on the RSC. Thrust is printed for information only.
    note("  drivetrain (source/rpm/active gate the flight; thrust is FYI):")
    for _, corner in ipairs(flight.CORNERS) do
        local pod = banks.getState()[corner]
        local prop = pod and pod.prop
        local thrust = thrusts[corner]
        note(string.format("    %-4s source %-5s rpm %5s active %-5s thrust %12s",
            corner, tostring(prop and prop.hasSource),
            reached[corner] and string.format("%.0f", reached[corner]) or "--",
            tostring(prop and prop.active),
            (thrust and math.abs(thrust) > 1)
                and string.format("%.0f", thrust) or "~0"))
    end

    -- Leave them as they were found. runGround starts them again itself, and a
    -- craft left with its props turning after a preflight abort is a craft
    -- nobody is watching that is still burning stress.
    pcall(session.setAllProps, session, 0)

    if #dead > 0 then
        note("")
        note("  *** DRIVETRAIN FAULT: " .. table.concat(dead, ", ") .. " ***")

        -- PER-BEARING DETAIL, so the fault names something repairable rather
        -- than just a corner. A pair that splits unevenly is one bearing's
        -- drivetrain; a pair that is evenly low is the corner's RSC or its
        -- supply. Printed here because preflight aborts before phase A, which
        -- is otherwise the only place these numbers appear.
        note("")
        note("  per-bearing, at " .. plan.groundRpm .. " rpm:")
        for _, corner in ipairs(flight.CORNERS) do
            local pod = banks.getState()[corner]
            local prop = pod and pod.prop
            local perBearing = prop and prop.perBearing
            if type(perBearing) == "table" then
                for index, bearing in ipairs(perBearing) do
                    -- Thrust only. bearingAngularSpeed reads 0 on all eight
                    -- bearings even at 16 rpm with active true, the same way
                    -- bearingRpm does, so printing it just invites someone to
                    -- read a fault into a field that never reports.
                    note(string.format("    %-4s %-30s thrust %14s",
                        corner, tostring(bearing.name or index),
                        type(bearing.thrust) == "number"
                            and string.format("%.2f", bearing.thrust) or "--"))
                end
            end
        end
        note("")
        note("  These are AT-REST readings. A pair that splits UNEVENLY is one")
        note("  bearing's drivetrain -- the bearing_5 defect had exactly that")
        note("  shape, 13804 against 13961 on its own partner. A pair that is")
        note("  evenly low is the corner's controller or its supply.")
        note("  A corner that makes no thrust is a standing torque, and every")
        note("  number measured afterwards is of that rather than of whatever")
        note("  was commanded. Repair it in-world before flying this again.")
        return
    end

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

    if (results.ground.headingSpread or 0) > 30 then
        note("  NOT FLYING: the corners disagree (see phase A).")
        session:descend()
        return
    end

    if not runRollAuthority() then
        note("")
        note("  Phase B0 did not clear. Landing without closing any loop.")
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

-- SHUTDOWN RUNS UNDER THE LISTENER TOO.
--
-- parallel.waitForAny kills listenLoop the moment mainLoop returns, so
-- everything after it used to run with NOTHING pumping the rednet queue. Any
-- command that waits for a reply -- which set_rpm does -- could not possibly
-- receive one:
--
--     WARNING: props left ASYMMETRIC -- RR: no reply within 1000 ms,
--                                       FR: no reply, RL: no reply
--
-- Three corners kept their old RPM while one was zeroed, which is the same
-- large roll couple that has ended several runs on the craft's side. The
-- retry logic added for this could not help: no number of retries produces a
-- reply when nothing is listening.
--
-- AND DO NOT CUT THE PROPS IN THE AIR. They carry ~52% of craft weight at 64
-- rpm. Zeroing them at +4.7 blocks removes that support while the ions are
-- deliberately left at level 2, so the craft drops. Props come off only once
-- the hull is actually down.
local function shutdown()
    clearAllTilts()

    local state = session:read()
    local altitude = state and session:craftY(state)
    local gain = (altitude and session.groundY) and (altitude - session.groundY) or nil

    if gain and gain > plan.groundedGain then
        note("")
        note(string.format("  STILL AIRBORNE at +%.1f -- leaving props at %d rpm.",
            gain, plan.propRpm))
        note("  Cutting them here removes ~52% of the lift while the banks are")
        note("  deliberately held at level 2, which is a drop, and cutting them")
        note("  UNEVENLY is the roll that has put this craft on its side more")
        note("  than once. Land it with /fcs/bankctl.lua; the props are level.")
    else
        local stopped, reason = session:setAllProps(0)
        if not stopped then
            note("  WARNING: could not stop all props -- " .. tostring(reason))
        end
    end

    pcall(session.finish, session)
end

pcall(parallel.waitForAny, shutdown, listenLoop)

note("")
note("=== SUMMARY ===")
note("pair coherence      : " .. tostring(results.ground.verdict or "not measured")
    .. "   (unmirrored: " .. tostring(results.ground.unmirrored or "--") .. ")")
if results.hover.rollPerRpm then
    note(string.format("roll authority      : %.4f deg/s^2 per RPM differential",
        results.hover.rollPerRpm))
    note(string.format("  predicted %.4f, so %.0f%% of prediction",
        results.hover.rollPerRpmPredicted,
        results.hover.rollPerRpm / results.hover.rollPerRpmPredicted * 100))
end
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
