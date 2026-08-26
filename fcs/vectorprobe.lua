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

local plan = {
    -- Enough for isActive without approaching lift. 16 RPM measures 13.0% of
    -- craft weight; props-only hover needs 122-124.
    groundRpm = 16,

    -- Tilt steps for phase A. Small, and well inside props.lua's own 15 degree
    -- clamp. Three of them so a bad single reading cannot carry the verdict.
    groundTilts = { 4, 8, 12 },

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
    holdSeconds = 6,
    settleTimeoutSeconds = 90.0,

    -- B1: common-mode tilt, all four corners, symmetric so it makes force
    -- rather than torque.
    --
    -- Budgeted: props at 64 RPM carry 52% of weight, so 3 degrees gives
    -- 0.52 * sin(3) * 11 = 0.30 blocks/s^2. Over a 2 s pulse that is
    -- 0.6 blocks/s and ~0.6 blocks travelled, and arresting it sweeps about as
    -- far again -- call it 2.4 blocks. The abort sits at 25.
    lateralTilt = 3.0,
    lateralSeconds = 2.0,

    -- B2: differential tilt staircase -> roll torque. THE DAMPER'S GAIN.
    --
    -- A staircase rather than one pulse, through the origin, because that is
    -- what phase A of axisresponse.lua does and it is the part of that tool
    -- that never gave trouble.
    --
    -- Continuous actuation is the point here. The ion pulse could not go below
    -- 7.42 deg/s^2, which crossed the 6 degree cap in under a second and left
    -- roll with 6 samples -- the direct cause of runs 18 and 19. A small tilt
    -- can be chosen to keep alpha near 2 deg/s^2, so the 6 degree budget lasts
    -- ~2.5 s and yields ~14 samples on the SAME axis that kept failing.
    torqueTilts = { 2, 4, 8 },
    torqueSeconds = 2.5,
    torqueMaxAngle = 6.0,
    torqueSampleSeconds = 0.12,
    torqueMinSamples = 5,
    cancelTimeoutSeconds = 6.0,

    maxHorizontalDrift = 25,
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

    note("")
    note(string.format("  %6s %10s %12s %12s %11s %s",
        "tilt", "reported", "lift", "lateral", "coherence", "verdict"))

    local verdicts, samples = {}, {}
    for _, angle in ipairs(plan.groundTilts) do
        local applied, tiltErr = pcall(actuators.setTilt, corner, angle,
            plan.groundAzimuth)
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
        note("  *** THE PAIR CANCELS. Common-mode tilt makes NO lateral force. ***")
        note("  Vectoring cannot translate this craft as built. Phase B is")
        note("  pointless and will not run.")
        note("")
        note("  This is a real answer, not a failure: it was the thing worth")
        note("  knowing, and it cost no flight. The remaining routes are")
        note("  setThrustHandedness reaction torque, or re-mounting one bearing")
        note("  of each pair so the pair no longer mirrors.")
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
    if drift and drift > plan.maxHorizontalDrift then
        for _, corner in ipairs(flight.CORNERS) do
            pcall(actuators.setTilt, corner, 0, 0)
        end
        session.aborted = string.format("horizontal drift %.1f blocks", drift)
        note(string.format("  *** ABORT: drifted %.1f blocks (limit %d) ***",
            drift, plan.maxHorizontalDrift))
        return "drift abort"
    end
    return nil
end

local function clearAllTilts()
    for _, corner in ipairs(flight.CORNERS) do
        pcall(actuators.setTilt, corner, 0, 0)
    end
end

-- B1: common-mode tilt on all four corners -> lateral force, minimal torque.
local function runLateral()
    note("")
    note("== PHASE B1: common-mode tilt -> lateral force ==")

    local before = session:read()
    local startSpeed = horizontalSpeed(before) or 0

    for _, corner in ipairs(flight.CORNERS) do
        local ok, err = pcall(actuators.setTilt, corner, plan.lateralTilt,
            plan.groundAzimuth)
        if not ok then note("  " .. corner .. " tilt failed: " .. tostring(err)) end
    end

    local samples = {}
    local startAt = os.epoch("utc")
    session:hold(plan.lateralSeconds, function(state, now)
        session:trim(plan.climbGain, flight.MAX_CLIMB_RATE, 0, state)
        local stop = driftAbort(state)
        if stop then return stop end
        local speed = horizontalSpeed(state)
        if speed then
            samples[#samples + 1] = { t = (now - startAt) / 1000, speed = speed }
        end
        return nil
    end)

    clearAllTilts()

    local after = session:read()
    local endSpeed = horizontalSpeed(after) or 0
    local elapsed = #samples > 0 and samples[#samples].t or plan.lateralSeconds

    if elapsed > 0.2 then
        local accel = (endSpeed - startSpeed) / elapsed
        note(string.format("  speed %.3f -> %.3f blocks/s over %.2f s (%d samples)",
            startSpeed, endSpeed, elapsed, #samples))
        note(string.format("  lateral acceleration = %.4f blocks/s^2", accel))
        note(string.format("  per degree of tilt   = %.4f blocks/s^2",
            accel / plan.lateralTilt))
        results.hover.lateralPerDegree = accel / plan.lateralTilt

        -- Terminal speed follows from universalDrag = 0.09: a tilt does not
        -- integrate away, it cruises. This is the number position hold needs.
        note(string.format("  implied terminal speed at %.0f deg = %.2f blocks/s",
            plan.lateralTilt, accel / 0.09))
    else
        note("  pulse too short to fit an acceleration")
    end

    -- Arrest before doing anything else. A residual lateral rate here becomes
    -- displacement during B2, and B2 is the longer phase.
    note("  arresting lateral motion")
    for _, corner in ipairs(flight.CORNERS) do
        pcall(actuators.setTilt, corner, plan.lateralTilt,
            (plan.groundAzimuth + 180) % 360)
    end
    session:hold(plan.cancelTimeoutSeconds, function(state, now)
        session:trim(plan.climbGain, flight.MAX_CLIMB_RATE, 0, state)
        local stop = driftAbort(state)
        if stop then return stop end
        local speed = horizontalSpeed(state)
        if speed and speed <= startSpeed + 0.05 then return "arrested" end
        return nil
    end)
    clearAllTilts()

    local settled = session:read()
    note(string.format("  residual horizontal speed: %.3f blocks/s",
        horizontalSpeed(settled) or -1))
    return true
end

-- B2: differential tilt staircase -> roll torque. The damper's gain.
local function runTorqueStep(angle)
    local other = "pitch"

    -- Port pair one way, starboard the other: a roll couple.
    for _, corner in ipairs(flight.CORNERS) do
        local sign = profile.corners[corner].roll >= 0 and 1 or -1
        local ok, err = pcall(actuators.setTilt, corner, sign * angle,
            plan.groundAzimuth)
        if not ok then note("  " .. corner .. " tilt failed: " .. tostring(err)) end
    end

    local samples = {}
    local startState = session:readCheap()
    local startAngle = startState and startState.roll or 0
    local startAt = os.epoch("utc")
    local restore = session.sampleSeconds
    session.sampleSeconds = plan.torqueSampleSeconds

    session:hold(plan.torqueSeconds, function(state, now)
        session:trim(plan.climbGain, flight.MAX_CLIMB_RATE, 0, state)
        local stop = driftAbort(state)
        if stop then return stop end
        if state and state.roll then
            samples[#samples + 1] = {
                t = (now - startAt) / 1000,
                angle = state.roll - startAngle,
            }
            local swept = math.abs(state.roll - startAngle)
            if swept >= plan.torqueMaxAngle and #samples >= plan.torqueMinSamples then
                return "angle reached"
            end
        end
        return nil
    end)
    session.sampleSeconds = restore

    -- Cancel with the reversed couple, ending when the rate is arrested rather
    -- than after a fixed time. Equal-and-opposite for equal time only nulls the
    -- rate if the torque actually applied for that time -- the assumption that
    -- took two axisresponse runs past 40 degrees of roll.
    for _, corner in ipairs(flight.CORNERS) do
        local sign = profile.corners[corner].roll >= 0 and 1 or -1
        pcall(actuators.setTilt, corner, -sign * angle, plan.groundAzimuth)
    end
    local lastAngle, lastAt = nil, nil
    session:hold(plan.cancelTimeoutSeconds, function(state, now)
        session:trim(plan.climbGain, flight.MAX_CLIMB_RATE, 0, state)
        local stop = driftAbort(state)
        if stop then return stop end
        if state and state.roll then
            if lastAngle and now > lastAt then
                local rate = (state.roll - lastAngle) / ((now - lastAt) / 1000)
                -- Differenced from the angle, not from Session:rates: the Sable
                -- angular channel reads exactly 0.0000 in about a third of
                -- samples at this loop period, and a cancel must never be
                -- steered by a channel that reports "stopped" when it is not.
                if rate * (samples[#samples] and samples[#samples].angle or 1) <= 0 then
                    return "rate arrested"
                end
            end
            lastAngle, lastAt = state.roll, now
        end
        return nil
    end)
    clearAllTilts()

    if #samples < 3 then return nil, #samples end

    -- alpha from a quadratic through the origin: angle = 0.5*alpha*t^2 + w0*t.
    -- Two unknowns, so at least three points, and more is better -- this is the
    -- exact fit that ion quantisation starved down to six.
    local s11, s12, s22, y1, y2 = 0, 0, 0, 0, 0
    for _, sample in ipairs(samples) do
        local a, b = 0.5 * sample.t ^ 2, sample.t
        s11 = s11 + a * a
        s12 = s12 + a * b
        s22 = s22 + b * b
        y1 = y1 + a * sample.angle
        y2 = y2 + b * sample.angle
    end
    local determinant = s11 * s22 - s12 * s12
    if math.abs(determinant) < 1e-12 then return nil, #samples end
    local alpha = (y1 * s22 - y2 * s12) / determinant
    return alpha, #samples
end

local function runTorque()
    note("")
    note("== PHASE B2: differential tilt -> roll torque (the damper's gain) ==")
    note(string.format("  %8s %10s %14s", "tilt", "samples", "alpha deg/s^2"))

    local points = {}
    for _, angle in ipairs(plan.torqueTilts) do
        local alpha, sampleCount = runTorqueStep(angle)
        if alpha then
            note(string.format("  %8.1f %10d %14.4f", angle, sampleCount, alpha))
            points[#points + 1] = { x = angle, y = alpha }
        else
            note(string.format("  %8.1f %10s   no fit", angle,
                tostring(sampleCount)))
        end
        -- Let the hull settle between steps; the self-levelling spring has a
        -- 42 s period, so a step started mid-swing measures the swing.
        session:hold(plan.holdSeconds, function(state)
            session:trim(plan.climbGain, flight.MAX_CLIMB_RATE, 0, state)
            return nil
        end)
    end

    local slope, worst = vectoring.fitThroughOrigin(points)
    if slope then
        note("")
        note(string.format("  ROLL TORQUE = %.4f deg/s^2 per degree of differential tilt",
            slope))
        note(string.format("  worst residual = %.1f%%", worst * 100))
        results.hover.rollPerDegree = slope
        results.hover.rollResidual = worst

        -- What the damper needs, stated in the units the damper is written in.
        -- Critical damping for the measured spring (k = 0.0223 deg/s^2 per deg,
        -- period 42.1 s against a measured ~42 s) is 2*sqrt(k) = 0.2987
        -- deg/s^2 per deg/s.
        local criticalDamping = 2 * math.sqrt(0.0223)
        note("")
        note(string.format("  critical damping needs %.4f deg/s^2 per deg/s,", criticalDamping))
        note(string.format("  so the damper wants %.3f DEGREES OF TILT per deg/s of roll rate.",
            criticalDamping / slope))
        note(string.format("  At the strafe's 0.90 deg/s peak that is %.2f degrees of tilt --",
            0.90 * criticalDamping / slope))
        note("  compare props.lua's 15 degree clamp for the headroom.")
    else
        note("  NOT ENOUGH STEPS FIT. Do not quote a gain from this run.")
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

    runLateral()
    if not session.aborted then runTorque() end

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
note("pair coherence      : " .. tostring(results.ground.verdict or "not measured"))
if results.hover.lateralPerDegree then
    note(string.format("lateral force       : %.4f blocks/s^2 per degree of common tilt",
        results.hover.lateralPerDegree))
end
if results.hover.rollPerDegree then
    note(string.format("roll torque         : %.4f deg/s^2 per degree of differential tilt",
        results.hover.rollPerDegree))
    note(string.format("  worst residual    : %.1f%%", (results.hover.rollResidual or 0) * 100))
    note("")
    note("THIS IS THE DAMPER'S GAIN. Before writing it into a controller, get a")
    note("SECOND run agreeing within a few percent -- every authority number in")
    note("this project looked solid in isolation and the roll figure ranged")
    note("3.98 to 86.03 across nine flights that each looked fine at the time.")
else
    note("roll torque         : not measured")
end

writeReport()
note("")
note("Report written to /fcs/vectorprobe_result.txt")
