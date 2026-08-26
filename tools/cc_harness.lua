-- A ComputerCraft stand-in, good enough to run /fcs/sweep.lua on a desktop.
--
-- Exists because CC's failure modes are invisible in-game and cost a session
-- each to discover. Model the four pods, the craft physics, and CC's coroutine
-- scheduling here, and a structural bug shows up in a second instead of after a
-- reboot and a walk out to the carrier.
--
-- The scheduling detail that matters: CC delivers an event to a coroutine only
-- when it matches that coroutine's filter, and DROPS it otherwise. That single
-- rule is what caused the 96% message loss (bug 6) and the false "pods offline"
-- report. It is reproduced faithfully below -- so a program that receives on a
-- blocking loop goes deaf here exactly as it does in game.

local harness = {}

-- --- virtual clock ---------------------------------------------------------
local now = 1787666000000
local timers, nextTimer = {}, 1

-- --- scheduler -------------------------------------------------------------
-- Each coroutine yields the event filter it is waiting for, exactly like
-- os.pullEventRaw. The scheduler resumes it only for matching events.
local tasks = {}
local current = nil

local function queue(event)
    for _, task in ipairs(tasks) do
        if task.dead ~= true then
            task.inbox[#task.inbox + 1] = event
        end
    end
end

-- --- pods ------------------------------------------------------------------
local POD_IDS = { FL = 2, FR = 3, RL = 4, RR = 5 }
local HOSTNAMES = { FL = "ENG-FL", FR = "ENG-FR", RL = "ENG-RL", RR = "ENG-RR" }

-- Real readings from the live carrier, so the simulated numbers match the ones
-- the sweep will actually see.
local BASE_BEARING_16 = 13960.983782400237
-- The pre-repair RR reading, kept ONLY so the asymmetry can be re-enabled for
-- regression. bearing_5 was repaired and verified 2026-08-26: all four corners
-- now read BASE_BEARING_16. See harness.model.rrDeficit below.
local RR5_BEARING_16_PREREPAIR = 13804.412918506092

harness.model = {
    exponent = 2.0,          -- true thrust curve
    -- bearing_5 repaired and verified 2026-08-26; the craft is symmetric.
    rrDeficit = false,
    telemetryPeriodMs = 1000,
    replyLatencyMs = 60,
    -- Per-corner override, for the "one pod is slow" hypothesis. A pod's
    -- networkLoop is single-threaded and statusMessage() is ~250 ms of
    -- main-thread work, so a command landing behind one waits it out -- which
    -- looks identical to a lost packet from the sender's side.
    podReplyLatencyMs = {},
    -- A second computer still hosting a pod's rednet hostname: an old pod that
    -- was replaced and left running. rednet.lookup answers with whichever
    -- responds first, so this is the shape of "intermittent for a session,
    -- then outright" -- and no timeout change can fix it.
    --   { corner = "FR", id = 13, transmits = false }
    ghostHost = nil,
    -- Drivetrain ceiling: above this the RSC cannot reach the commanded speed.
    maxAchievableRpm = math.huge,
    overstressAboveRpm = math.huge,
    podsSilent = false,
    -- Model the live failure: the pod silently swallows a set_rpm, applying
    -- nothing and replying nothing. Counted rather than randomised so runs
    -- stay reproducible.
    dropEveryNthCommand = 0,
    -- Create Aeronautics scales propeller thrust by air density. When true the
    -- craft feels getThrust * pressure while the pods keep REPORTING the raw
    -- getThrust -- which is exactly the discrepancy the live carrier showed.
    densityScalesThrust = true,
    -- Ion banks. Calibrated to the MEASURED hover point rather than to a round
    -- number: ions at power 0.195 carried 0.446 of craft weight, so full power
    -- is 0.446/0.195 = 2.287x weight.
    --
    -- It used to be 1.0x weight ("chosen so full power alone equals the
    -- craft's weight"). That made the harness's ions 2.29x weaker than the
    -- real ones, so any power-derived quantity checked against it -- the RR
    -- bias, hover power, liftoff power -- came out wrong by that factor and
    -- looked like a bug in the code under test.
    --
    -- With this value the harness hovers at ~0.196 with props at 64 RPM, which
    -- is the measured 0.195.
    --
    -- CAVEAT: 2.287x is the hover-point figure. HANDOFF.md separately states
    -- ~3.5x, and the two have never been reconciled -- that is exactly what
    -- phase A of fcs/axisresponse.lua measures. If phase A says otherwise,
    -- change this AND re-derive the RR bias in mixer_profile.lua, which is
    -- computed from the same coefficient.
    ionForceAtFullTotal = 105299.39999999988 * 11.0 * 3.342,

    -- ION POWER IS QUANTISED: applied = floor(commanded * 15) / 15.
    --
    -- Measured on FL, 14 of 14 steps exact (flight-logs/thrustprobe_FL.txt).
    -- Modelling ion thrust as CONTINUOUS is what let a crash-landing descent
    -- pass every harness run: a gradual power ramp is a gentle descent under
    -- continuous thrust and a staged free-fall under quantised thrust
    -- (level 2 -0.37, level 1 -2.82, level 0 -5.27 blocks/s^2).
    --
    -- A harness only tests what you already believe about the hardware. This
    -- is the belief that was wrong.
    ionPowerLevels = 15,
    ionKnAtFullPerPod = 500.0,
    ionMaxChangePerCommand = 0.05,
    ionCommandTimeoutMs = 750,
    -- Mirrors pod/config.lua commsLossPower: the measured hover ion power, held
    -- when an armed bank stops hearing commands. Not zero -- see watchdogLoop
    -- below.
    ionCommsLossPower = 0.195,
    ionThrustersPerPod = 32,
    -- Blocks of altitude per e-fold of pressure. MEASURED, no longer a guess:
    -- aero.getRaw().pressureFunction.getPoints() gives the whole curve, and
    -- every segment below y=280 has slope/value = -0.004, i.e. H = 250.
    -- (Above 280 it collapses to exactly 0 at y=320 -- a hard ceiling this
    -- simple exponential does not model. The test craft flies near y=-26, far
    -- below that, so it does not matter here.)
    pressureScaleHeight = 250,

    -- --- rotation ---------------------------------------------------------
    -- Per-axis inertia. HANDOFF.md reports Ixx/Iyy/Izz = 3.89e8/4.36e8/8.68e7
    -- and separately that "roll is ~4.5x cheaper than pitch/yaw" -- and
    -- 3.89e8/8.68e7 = 4.48, so the SMALLEST tensor component is the roll axis.
    -- Which of Ixx/Iyy/Izz that is depends on an axis convention nobody has
    -- confirmed, so name them by axis here rather than by tensor index.
    --
    -- Resolving that mapping is a bonus output of the axis-response run:
    -- measured angular acceleration per unit torque IS the effective inertia
    -- per axis.
    rollInertia = 8.68e7,
    pitchInertia = 3.89e8,
    yawInertia = 4.36e8,

    -- Distance from the rotation point to a corner's thrust centroid. A GUESS
    -- -- this is precisely the quantity nobody has measured, and the reason
    -- Aroll/Apitch are uncalibrated in the first place.
    --
    -- So be clear about what the harness can and cannot prove: it validates
    -- the TOOL -- sequencing, pulse reversal, abort paths, the arithmetic that
    -- turns angular rates into a coefficient -- and it cannot validate the
    -- coefficient itself. Only the live run does that.
    cornerArmBlocks = 20,

    -- Restoring moment and angular damping, BOTH ZERO BY DEFAULT.
    --
    -- Nobody has measured either. getStabilizationStrength reads 1.0 on every
    -- bearing when active, but that is a BEARING method and may only mean the
    -- bearing holds its own angle. Assuming a restoring moment that may not
    -- exist would make the harness forgiving in exactly the way that wrecks a
    -- carrier, so the default is the worst case.
    --
    -- tools/run_rolldrift_harness.lua sets these under `stable` to model the
    -- opposite world, so the diagnostic can be shown to reach BOTH verdicts.
    rollRestoring = 0.0,        -- deg/s^2 per degree of tilt
    rollDamping = 0.0,          -- 1/s on angular rate
}

local commandCount = 0

local pods = {}
for corner, id in pairs(POD_IDS) do
    pods[corner] = { corner = corner, id = id, targetRpm = 16, nextTelemetry = now,
        armed = false, currentPower = 0, lastCommandAt = nil }
end

local function achievedRpm(target)
    return math.min(math.abs(target), harness.model.maxAchievableRpm) * (target < 0 and -1 or 1)
end

local function bearingThrust(corner, index, rpm)
    local scale = (math.abs(rpm) / 16) ^ harness.model.exponent
    local deficient = harness.model.rrDeficit and corner == "RR" and index == 1
    local magnitude = deficient
        and RR5_BEARING_16_PREREPAIR * scale or BASE_BEARING_16 * scale
    -- getThrust is signed by handedness: the pair reports +x and -x.
    return index == 1 and -magnitude or magnitude
end

local function podTelemetry(corner, messageType)
    local pod = pods[corner]
    local rpm = achievedRpm(pod.targetRpm)
    local b1, b2 = bearingThrust(corner, 1, rpm), bearingThrust(corner, 2, rpm)

    return {
        magic = "HELICARRIER_FCS",
        version = 2,
        type = messageType,
        corner = corner,
        hostname = HOSTNAMES[corner],
        sentAt = now,
        online = true,
        bootedAt = pod.bootedAt or 1,
        commandsSeen = pod.commandsSeen or 0,
        commandsApplied = pod.commandsApplied or 0,
        commandsRejected = pod.commandsRejected or 0,
        armed = pod.armed,
        -- currentPower is the pod's own unsnapped target; averagePower comes
        -- from getPower() on the hardware and is therefore SNAPPED. They are
        -- different numbers and only the snapped one explains the thrust.
        currentPower = pod.currentPower,
        averagePower = harness.snapPower(pod.currentPower),
        fallbackPower = 0.0,
        commsLossPower = harness.model.ionCommsLossPower,
        healthyThrusters = harness.model.ionThrustersPerPod,
        expectedThrusters = harness.model.ionThrustersPerPod,
        obstructedThrusters = 0,
        totalThrustKN = harness.snapPower(pod.currentPower) * harness.model.ionKnAtFullPerPod,
        energyFE = 1000000,
        energyCapacityFE = 1000000,
        prop = {
            controllerPresent = true,
            bearingPresent = true,
            bearingCount = 2,
            targetRpm = pod.targetRpm,
            controllerRpm = rpm,
            hasSource = true,
            overstressed = math.abs(rpm) > harness.model.overstressAboveRpm,
            thrust = math.abs(b1) + math.abs(b2),
            thrustImbalance = b1 + b2,
            sailPower = corner == "RR" and 532 or 534,
            airflow = corner == "RR" and 0.049051138064220012 or 0,
            bearingRpm = 0,
            perBearing = {
                { name = "bearing_a", thrust = b1, assembled = true },
                { name = "bearing_b", thrust = b2, assembled = true },
            },
            faults = {},
        },
    }
end

-- --- craft physics ---------------------------------------------------------
local GROUND_Y = -26.573583602905273

harness.craft = {
    mass = 105299.39999999988,
    gravity = -11.0,
    y = GROUND_Y,
    vy = 0,
    grounded = true,
    -- Measured on the live carrier at y = -26.5736. Independently confirmed:
    -- fcs/atmosphere.lua, built from the mod's own control points, predicts
    -- 1.430872 at that altitude.
    groundPressure = 1.430871623616917,

    -- Attitude, in degrees, and body angular rates in degrees/second. Small
    -- angles are all the pulse test needs, so euler integration is honest
    -- here; do not reuse this for large-angle manoeuvres.
    roll = 0, pitch = 0, yaw = 0,
    rollRate = 0, pitchRate = 0, yawRate = 0,
}

local function pressureAt(y)
    return harness.craft.groundPressure
        * math.exp(-(y - GROUND_Y) / harness.model.pressureScaleHeight)
end

local function totalThrust()
    local total = 0
    for corner in pairs(pods) do
        local rpm = achievedRpm(pods[corner].targetRpm)
        total = total + math.abs(bearingThrust(corner, 1, rpm))
            + math.abs(bearingThrust(corner, 2, rpm))
    end
    return total
end

-- Rigid-body rotation driven by the ion banks' corner differential.
--
-- Sign conventions follow fcs/config.lua and fcs/mixer_profile.lua: +X bow,
-- +Y up, +Z starboard; positive roll is starboard-low, so the PORT corners
-- (FL, RL) pushing harder rolls positive. Positive pitch is bow-high, so the
-- AFT corners (RL, RR) pushing harder pitches positive.
--
-- Deliberately NOT modelled: any restoring moment. The bearings expose
-- getStabilizationStrength, so the real craft may well self-level, but nobody
-- has measured it. Assuming a restoring moment that does not exist would make
-- the harness forgiving in exactly the way that gets a carrier wrecked, so
-- this integrates freely and lets a runaway run away.
-- The applied power the MOD actually uses, as opposed to the value the pod
-- thinks it commanded. getPower() reports this snapped value; the pod's own
-- state.currentPower is the unsnapped one, and confusing the two is what made
-- phase A of axisresponse pair a fine "applied" figure with a coarse thrust.
local function snapPower(power)
    local levels = harness.model.ionPowerLevels
    if not levels or levels <= 0 then return power end
    local snapped = math.floor((power or 0) * levels) / levels
    if snapped < 0 then return 0 end
    return snapped
end
harness.snapPower = snapPower

local function stepRotation(dt)
    local craft = harness.craft

    -- Total vertical force at a corner: ions PLUS propellers.
    --
    -- The propeller half is not decoration. Omitting props here made the
    -- harness show a corner CORRECTION as an uncorrected asymmetry -- a
    -- symmetric climb rolled to -20 degrees and aborted.
    --
    -- RR's bearing_1 used to be modelled 1.121% down, a standing roll/pitch
    -- torque. That defect was physically repaired and verified 2026-08-26, so
    -- it is now OFF by default: modelling a torque the craft does not have
    -- would corrupt exactly the axis-response calibration this harness is next
    -- needed for. Set harness.model.rrDeficit = true to restore it.
    local function cornerForce(corner)
        local pod = pods[corner]
        local power = snapPower((pod and pod.currentPower) or 0)
        local ion = (power / 4) * harness.model.ionForceAtFullTotal

        local rpm = achievedRpm(pod and pod.targetRpm or 0)
        local prop = math.abs(bearingThrust(corner, 1, rpm))
            + math.abs(bearingThrust(corner, 2, rpm))
        if harness.model.densityScalesThrust then
            prop = prop * pressureAt(harness.craft.y)
        end

        return ion + prop
    end

    local fl, fr = cornerForce("FL"), cornerForce("FR")
    local rl, rr = cornerForce("RL"), cornerForce("RR")

    local arm = harness.model.cornerArmBlocks
    -- roll: port (FL, RL) minus starboard (FR, RR). Port pushing harder raises
    -- port, drops starboard, and positive roll is starboard-low. Correct.
    local rollTorque = arm * ((fl + rl) - (fr + rr))

    -- pitch: FORWARD minus aft. This was (aft - forward), which had the
    -- harness believing that pushing the stern up raises the bow. It matched
    -- mixer_profile.lua's inverted pitch signs, so the two agreed with each
    -- other and both disagreed with the craft -- the same way the harness's
    -- axis labels matched attitude.lua's wrong ones. Measured in flight:
    -- a +0.3 pitch demand produced -2.12 deg/s^2.
    local pitchTorque = arm * ((fl + fr) - (rl + rr))

    -- Grounded, the ground carries the moment: a resting craft does not tip
    -- from a small thrust differential. This is why the pulse test has to fly.
    if craft.grounded then
        craft.rollRate, craft.pitchRate = 0, 0
        return
    end

    craft.rollRate = craft.rollRate + math.deg(rollTorque / harness.model.rollInertia) * dt
    craft.pitchRate = craft.pitchRate + math.deg(pitchTorque / harness.model.pitchInertia) * dt

    -- Optional restoring moment (returns toward level) and angular damping
    -- (opposes rate). Both zero unless a runner turns them on.
    local restoring = harness.model.rollRestoring or 0
    local damping = harness.model.rollDamping or 0
    if restoring ~= 0 then
        craft.rollRate = craft.rollRate - restoring * craft.roll * dt
        craft.pitchRate = craft.pitchRate - restoring * craft.pitch * dt
    end
    if damping ~= 0 then
        craft.rollRate = craft.rollRate - damping * craft.rollRate * dt
        craft.pitchRate = craft.pitchRate - damping * craft.pitchRate * dt
    end

    craft.roll = craft.roll + craft.rollRate * dt
    craft.pitch = craft.pitch + craft.pitchRate * dt
end

-- Orientation as CC:Sable reports it: {v = <vector>, a = <w>}, NOT {x,y,z,w}
-- (bug 3). Built so that fcs/attitude.lua reads back the same roll and pitch
-- the harness is holding.
--
-- THIS USED TO ENCODE THE WRONG CONVENTION. It built roll about body X and
-- pitch about body Z, matching attitude.lua's old assumption -- so the harness
-- agreed with the flight code and both were wrong together. The craft's bow is
-- +Z and its port side is +X (measured 2026-08-26), which means:
--
--     roll  = rotation about the BOW axis  (+Z)
--     pitch = rotation about the PORT axis (-X, so the bow rises)
--
-- A harness that shares the flight code's mistaken axis labels cannot catch a
-- transposed axis, which is precisely the bug that shipped.
function harness.orientation()
    local craft = harness.craft
    local roll, pitch = math.rad(craft.roll), math.rad(craft.pitch)

    local cr, sr = math.cos(roll * 0.5), math.sin(roll * 0.5)
    local cp, sp = math.cos(pitch * 0.5), math.sin(pitch * 0.5)

    -- q = q_pitch(about -X) * q_roll(about +Z), expanded. The ORDER is not
    -- cosmetic: the reverse order round-trips to 4.75 deg of error at large
    -- combined angles, this one is exact to 1e-9 across the range tested.
    return {
        v = {
            x = -sp * cr,
            y =  sp * sr,
            z =  cp * sr,
        },
        a = cp * cr,
    }
end

local function stepPhysics(dtMs)
    local craft = harness.craft
    local weight = craft.mass * math.abs(craft.gravity)
    local lift = totalThrust()
    if harness.model.densityScalesThrust then
        lift = lift * pressureAt(craft.y)
    end

    -- Ion thrust does not depend on air density, which is exactly why it is
    -- wanted as the altitude-independent half of the lift budget.
    local ionPower = 0
    for _, pod in pairs(pods) do
        ionPower = ionPower + snapPower(pod.currentPower or 0)
    end
    lift = lift + (ionPower / 4) * harness.model.ionForceAtFullTotal

    local net = lift - weight

    local dt = dtMs / 1000

    if craft.grounded and net <= 0 then
        craft.vy = 0
        return
    end

    craft.grounded = false
    craft.vy = craft.vy + (net / craft.mass) * dt
    craft.y = craft.y + craft.vy * dt
    -- Track the worst descent rate seen, so a harness run can be judged on
    -- whether the LANDING was survivable, not merely on whether it ended.
    if craft.vy < (craft.peakDescent or 0) then craft.peakDescent = craft.vy end

    stepRotation(dt)
    -- Peak altitude is the number that decides whether a run was safe.
    if craft.peakY == nil or craft.y > craft.peakY then
        craft.peakY = craft.y
        craft.peakAt = now
    end
    if harness.trace then
        harness.traceLog[#harness.traceLog + 1] = { t = now, y = craft.y, vy = craft.vy }
    end

    if craft.y <= GROUND_Y then
        craft.y = GROUND_Y
        craft.vy = 0
        craft.grounded = true
    end
end

-- --- advancing time --------------------------------------------------------
local function advance(ms)
    local remaining = ms
    while remaining > 0 do
        local slice = math.min(remaining, 50)  -- one Minecraft tick
        now = now + slice
        remaining = remaining - slice
        stepPhysics(slice)

        for id, timer in pairs(timers) do
            if now >= timer then
                timers[id] = nil
                queue({ "timer", id })
            end
        end

        -- watchdogLoop: armed banks that stop hearing commands fall back to
        -- commsLossPower -- NOT to zero. The pod splits the two: fallbackPower
        -- (0.0) means everything is off, commsLossPower means we were flying
        -- and the link dropped. The bank disarms either way, so it ends up
        -- DISARMED AND STILL HOLDING THRUST, which is the state fcs/reboot.lua
        -- has to notice.
        for _, pod in pairs(pods) do
            if pod.armed and pod.lastCommandAt
                and (now - pod.lastCommandAt) > harness.model.ionCommandTimeoutMs then
                pod.armed = false
                pod.currentPower = harness.model.ionCommsLossPower
            end
        end

        if not harness.model.podsSilent then
            for corner, pod in pairs(pods) do
                if now >= pod.nextTelemetry then
                    pod.nextTelemetry = now + harness.model.telemetryPeriodMs
                    queue({ "rednet_message", pod.id, podTelemetry(corner, "status"),
                            "helicarrier.fcs.v1" })
                    -- A ghost that still resolved FCS-MAIN keeps transmitting
                    -- as its corner too, so the corner has two senders on the
                    -- wire. A ghost that never resolved main is silent and can
                    -- only be caught by addressing it -- both are modelled.
                    local ghost = harness.model.ghostHost
                    if ghost and ghost.transmits and ghost.corner == corner then
                        queue({ "rednet_message", ghost.id,
                                podTelemetry(corner, "status"), "helicarrier.fcs.v1" })
                    end
                end
            end
        end
    end
end

-- --- CC global APIs --------------------------------------------------------
function harness.install(env)
    env.os = env.os or {}
    local realOs = os
    env.os.epoch = function() return now end
    env.os.getComputerID = function() return 1 end
    env.os.clock = function() return now / 1000 end
    env.os.time = realOs.time
    env.os.date = realOs.date
    env.os.startTimer = function(seconds)
        local id = nextTimer
        nextTimer = nextTimer + 1
        timers[id] = now + math.floor((seconds or 0) * 1000)
        return id
    end
    env.os.pullEventRaw = function(filter)
        return coroutine.yield(filter)
    end
    env.os.pullEvent = env.os.pullEventRaw
    env.os.queueEvent = function(...) queue({ ... }) end

    env.sleep = function(seconds)
        local id = env.os.startTimer(seconds)
        repeat
            local event, param = coroutine.yield("timer")
        until param == id
    end

    -- terminal
    env.term = {
        clear = function() end,
        setCursorPos = function() end,
        setTextColour = function() end,
        setTextColor = function() end,
    }
    env.write = function(text) io.write(tostring(text)) end
    env.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        io.write(table.concat(parts, "\t"), "\n")
    end
    env.printError = env.print
    env.read = function() return harness.readAnswer or "" end

    -- filesystem, backed by real files under a sandbox directory
    local root = harness.root or "/tmp/cc_harness_fs"
    os.execute("mkdir -p '" .. root .. "'")
    local function real(path)
        return root .. "/" .. tostring(path):gsub("^/", "")
    end
    env.fs = {
        combine = function(a, b)
            return ((tostring(a) .. "/" .. tostring(b)):gsub("//+", "/"))
        end,
        makeDir = function(path) os.execute("mkdir -p '" .. real(path) .. "'") end,
        exists = function(path)
            local handle = io.open(real(path), "r")
            if handle then handle:close() return true end
            return false
        end,
        list = function(path)
            local names, pipe = {}, io.popen("ls -1 '" .. real(path) .. "' 2>/dev/null")
            if pipe then
                for name in pipe:lines() do names[#names + 1] = name end
                pipe:close()
            end
            return names
        end,
        delete = function(path) os.execute("rm -rf '" .. real(path) .. "'") end,
        getSize = function(path)
            local handle = io.open(real(path), "r")
            if not handle then return 0 end
            local size = handle:seek("end")
            handle:close()
            return size
        end,
        open = function(path, mode)
            os.execute("mkdir -p '" .. real(path):match("(.*)/") .. "'")
            local handle = io.open(real(path), mode)
            if not handle then return nil, "cannot open" end
            return {
                write = function(text) handle:write(text) end,
                writeLine = function(text) handle:write(text, "\n") end,
                flush = function() handle:flush() end,
                close = function() handle:close() end,
                readAll = function() return handle:read("*a") end,
            }
        end,
    }

    -- peripherals: one wireless modem
    env.peripheral = {
        getNames = function() return { "top" } end,
        isPresent = function(name) return name == "top" end,
        hasType = function(name, kind) return name == "top" and kind == "modem" end,
        wrap = function(name)
            if name ~= "top" then return nil end
            return { isWireless = function() return true end }
        end,
    }

    -- rednet
    local opened = {}
    env.rednet = {
        open = function(name) opened[name] = true end,
        isOpen = function(name) return opened[name] == true end,
        close = function(name) opened[name] = nil end,
        host = function() end,
        unhost = function() end,
        lookup = function(_, hostname)
            -- The ghost wins the race. That is not pessimism: rednet.lookup
            -- returns the first host to answer, and a program has no way to
            -- tell which one it got.
            local ghost = harness.model.ghostHost
            if ghost and HOSTNAMES[ghost.corner] == hostname then
                return ghost.id
            end
            for corner, name in pairs(HOSTNAMES) do
                if name == hostname then return POD_IDS[corner] end
            end
            return nil
        end,
        send = function(recipient, message, protocol)
            -- The pod applies the command and acks after a short latency.
            for corner, pod in pairs(pods) do
                local dropped, rejected = false, nil
                if pod.id == recipient and message.type == "set_rpm" then
                    commandCount = commandCount + 1
                    if harness.model.dropEveryNthCommand > 0
                        and commandCount % harness.model.dropEveryNthCommand == 0 then
                        dropped = true   -- applied nothing, and says nothing
                    else
                        pod.targetRpm = message.rpm
                    end
                elseif pod.id == recipient and message.type == "arm" then
                    commandCount = commandCount + 1
                    if harness.model.dropEveryNthCommand > 0
                        and commandCount % harness.model.dropEveryNthCommand == 0 then
                        dropped = true
                    else
                        pod.armed = true
                        pod.lastCommandAt = now
                    end
                elseif pod.id == recipient and message.type == "reboot" then
                    -- A real pod restarts: counters reset, banks disarm and
                    -- thrusters fall to fallbackPower. Props keep their RPM,
                    -- because the RSC is a Create block, not pod state.
                    pod.armed = false
                    pod.currentPower = 0
                    pod.commandsSeen = 0
                    pod.commandsApplied = 0
                    pod.commandsRejected = 0
                    pod.rebooted = (pod.rebooted or 0) + 1
                    pod.bootedAt = now
                elseif pod.id == recipient and message.type == "disarm" then
                    pod.armed = false
                    pod.currentPower = 0
                elseif pod.id == recipient and message.type == "set_power" then
                    commandCount = commandCount + 1
                    pod.commandsSeen = (pod.commandsSeen or 0) + 1
                    if harness.model.dropEveryNthCommand > 0
                        and commandCount % harness.model.dropEveryNthCommand == 0 then
                        dropped = true
                    elseif pod.armed then
                        -- applyCommand walks toward the target by at most
                        -- maximumChangePerCommand, it does not jump.
                        local limit = harness.model.ionMaxChangePerCommand
                        local delta = message.power - pod.currentPower
                        if delta > limit then delta = limit end
                        if delta < -limit then delta = -limit end
                        pod.currentPower = pod.currentPower + delta
                        if pod.currentPower < 0 then pod.currentPower = 0 end
                        if pod.currentPower > 1 then pod.currentPower = 1 end
                        pod.lastCommandAt = now
                        pod.commandsApplied = (pod.commandsApplied or 0) + 1
                    else
                        -- Not armed. The pod now DECLINES OUT LOUD rather than
                        -- dropping silently, so model the fault reply -- that is
                        -- what the FCS has to cope with.
                        rejected = "not_armed"
                    end
                elseif pod.id == recipient and message.type ~= "status_request" then
                    -- other command types are ignored by this model
                end
                if pod.id == recipient and not harness.model.podsSilent and not dropped then
                    local reply = podTelemetry(corner,
                        rejected and "fault"
                        or (message.type == "set_rpm" and "ack" or "status"))
                    reply.rejected = rejected
                    reply.commandsSeen = (pod.commandsSeen or 0)
                    reply.commandsApplied = (pod.commandsApplied or 0)
                    reply.commandsRejected = (pod.commandsRejected or 0)
                    reply.lastReject = rejected
                    -- Deliver on the next advance, not instantly, so a caller
                    -- that never yields cannot see its own reply.
                    harness.pending[#harness.pending + 1] =
                        { at = now + (harness.model.podReplyLatencyMs[corner]
                                      or harness.model.replyLatencyMs),
                          event = { "rednet_message", pod.id, reply, protocol } }
                end
            end
        end,
        -- Real rednet.receive pulls events UNFILTERED and sorts them itself,
        -- so it also sees the timer that bounds its own timeout. Yielding with
        -- a "rednet_message" filter instead would drop that timer and block
        -- forever -- which in turn makes banks.poll()'s drain loop, whose exit
        -- condition is a nil return, spin without end.
        receive = function(protocolFilter, timeout)
            local timerId = timeout and env.os.startTimer(timeout) or nil
            while true do
                local e1, e2, e3, e4 = coroutine.yield(nil)
                if e1 == "rednet_message" then
                    if protocolFilter == nil or e4 == protocolFilter then
                        return e2, e3, e4
                    end
                elseif e1 == "timer" and e2 == timerId then
                    return nil
                end
            end
        end,
    }

    -- parallel
    env.parallel = {
        waitForAny = function(...)
            local fns = { ... }
            harness.run(fns, true)
        end,
        waitForAll = function(...)
            local fns = { ... }
            harness.run(fns, false)
        end,
    }

    -- CC:Sable
    env.sublevel = {
        isInPlotGrid = function() return true end,
        getUniqueId = function() return "harness-craft" end,
        getName = function() error("no name on this sublevel", 0) end,
        getMass = function() return harness.craft.mass end,
        getLogicalPose = function()
            return { position = { x = 0, y = harness.craft.y, z = 0 },
                     orientation = harness.orientation(),
                     rotationPoint = { x = 0, y = 0, z = 0 } }
        end,
        getLinearVelocity = function() return { x = 0, y = harness.craft.vy, z = 0 } end,
        getVelocity = function() return { x = 0, y = harness.craft.vy, z = 0 } end,
        -- World-frame angular velocity in RADIANS/second, matching CC:Sable.
        -- The craft stores degrees/second because that is what the report
        -- reads in; converting here rather than there keeps the stub honest to
        -- the real API instead of to the harness's convenience.
        getAngularVelocity = function()
            local craft = harness.craft
            return {
                x = math.rad(craft.rollRate),
                y = math.rad(craft.yawRate),
                z = math.rad(craft.pitchRate),
            }
        end,
        getCenterOfMass = function() return { x = 0, y = 0, z = 0 } end,

        -- The real craft's measured tensor, returned BODY-FRAME: constant
        -- regardless of attitude. Whether the live mod does the same is the
        -- open question the flight logging exists to answer -- so a harness
        -- test that passes here proves the PLUMBING, not the mod's frame.
        -- rows/columns are dimension counts (3.0), not containers, matching
        -- what CC:Sable actually returns.
        getInertiaTensor = function()
            return {
                rows = 3.0, columns = 3.0,
                [1] = { [1] = 389348390.47, [2] =  2804477.48, [3] = -4623985.48 },
                [2] = { [1] =   2804477.48, [2] = 435866268.08, [3] = 27995138.25 },
                [3] = { [1] =  -4623985.48, [2] =  27995138.25, [3] = 86744908.79 },
            }
        end,
    }
    env.aero = {
        getGravity = function() return { x = 0, y = harness.craft.gravity, z = 0 } end,
        -- Honours the queried position, like the real API: airprofile.lua
        -- samples pressure at arbitrary altitudes, and a stub that ignored the
        -- argument returned a flat profile that exercised nothing.
        getAirPressure = function(position)
            return pressureAt(position and position.y or harness.craft.y)
        end,
        getUniversalDrag = function() return 0.09 end,
    }
    env.vector = { new = function(x, y, z) return { x = x, y = y, z = z } end }
    env.textutils = { serialize = function(v) return tostring(v) end }
end

harness.pending = {}
harness.traceLog = {}
harness.trace = false

-- --- the scheduler proper --------------------------------------------------
-- Round-robin the coroutines, delivering only events that match each one's
-- filter and dropping the rest, which is CC's actual behaviour.
function harness.run(fns, anyEnds)
    local locals = {}
    for index, fn in ipairs(fns) do
        locals[index] = { co = coroutine.create(fn), inbox = {}, filter = nil }
    end

    local saved = tasks
    tasks = locals

    -- prime
    for _, task in ipairs(locals) do
        local ok, filter = coroutine.resume(task.co)
        if not ok then tasks = saved; error(filter, 0) end
        task.filter = filter
        if coroutine.status(task.co) == "dead" then
            task.dead = true
            if anyEnds then tasks = saved; return end
        end
    end

    local guard = 0
    while true do
        guard = guard + 1
        if guard > 4000000 then tasks = saved; error("harness: no progress", 0) end

        local delivered = false
        for _, task in ipairs(locals) do
            if not task.dead and #task.inbox > 0 then
                local event = table.remove(task.inbox, 1)
                -- CC drops non-matching events rather than queuing them.
                if task.filter == nil or task.filter == event[1] then
                    delivered = true
                    local unpack = table.unpack or _G.unpack
                    local ok, filter = coroutine.resume(task.co, unpack(event))
                    if not ok then tasks = saved; error(filter, 0) end
                    task.filter = filter
                    if coroutine.status(task.co) == "dead" then
                        task.dead = true
                        if anyEnds then tasks = saved; return end
                    end
                end
            end
        end

        local allDead = true
        for _, task in ipairs(locals) do
            if not task.dead then allDead = false end
        end
        if allDead then tasks = saved; return end

        if not delivered then
            -- Nobody had a deliverable event: let virtual time move.
            for index = #harness.pending, 1, -1 do
                local item = harness.pending[index]
                if now >= item.at then
                    queue(item.event)
                    table.remove(harness.pending, index)
                end
            end
            advance(10)
        end
    end
end

function harness.advance(ms) advance(ms) end
function harness.now() return now end
function harness.pods() return pods end

return harness
