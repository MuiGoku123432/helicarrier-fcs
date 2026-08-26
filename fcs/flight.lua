-- Shared flight primitives: arming, the hold loop, altitude trim, descent, and
-- the quantisation facts everything depends on.
--
-- Extracted from fcs/axisresponse.lua so that tool and fcs/rolldrift.lua share
-- ONE copy of the safety-critical paths. The descent was rewritten after it was
-- found to produce a 17.8 blocks/s crash landing; a second, divergent copy of
-- that logic is precisely how one copy gets fixed and the other does not.
--
-- Every tool that flies the carrier should go through this module.
--
-- ---------------------------------------------------------------------------
-- ION POWER IS QUANTISED -- this governs everything below
--
-- Measured: applied = floor(commanded * 15) / 15, 14 of 14 steps exact
-- (flight-logs/thrustprobe_FL.txt). With props at 64 RPM, in units of weight:
--
--     level 0 -> 0.5210   net -5.27 blocks/s^2
--     level 1 -> 0.7438   net -2.82
--     level 2 -> 0.9666   net -0.37     <- gentle descent, SURVIVABLE
--     level 3 -> 1.1893   net +2.08     <- climb
--
-- There is no hover level. Holding altitude means dithering between 2 and 3 at
-- roughly a 15% duty cycle on 3.
--
-- LEVEL 2 IS THE SAFE RESTING STATE IN FLIGHT: 0.37 blocks/s^2 down, arriving
-- from +30 blocks at about 4.7 blocks/s. Level 0 free-falls at 5.27 and
-- arrives at 17.8. The pod's own commsLossPower (0.195) floors to level 2, so
-- the failsafe and this module agree.
-- ---------------------------------------------------------------------------

local banks = require("fcs.banks")
local sensors = require("fcs.sensors")
local actuators = require("fcs.actuators")
local mixer = require("fcs.mixer")
local attitude = require("fcs.attitude")

local flight = {}

flight.CORNERS = { "FL", "FR", "RL", "RR" }
flight.ION_LEVELS = 15
flight.SURVIVABLE_LEVEL = 2

function flight.levelFor(commandedPower)
    return math.floor((commandedPower or 0) * flight.ION_LEVELS)
end

-- The power the thrusters ACTUALLY apply for a commanded value.
--
-- setPowerNormalized quantises: applied = floor(commanded * 15) / 15. A pod's
-- reported currentPower is what it was COMMANDED to hold, not what it applies,
-- and the two differ by up to a full level. Dividing a measured force by
-- commanded power is the documented way to get force-per-power wrong -- it
-- produced ~2.4x once and 2.30x again, against a true 3.342x.
function flight.appliedPower(commandedPower)
    return flight.levelFor(commandedPower) / flight.ION_LEVELS
end

-- The middle of a level, so floating point cannot land it on the wrong side of
-- a boundary.
function flight.commandForLevel(level)
    return (level + 0.5) / flight.ION_LEVELS
end

flight.SURVIVABLE_COMMAND = flight.commandForLevel(flight.SURVIVABLE_LEVEL)

-- ---------------------------------------------------------------------------

local Session = {}
Session.__index = Session

function flight.new(options)
    local session = setmetatable({}, Session)

    session.config = options.config
    session.profile = options.profile
    session.atmosphere = options.atmosphere
    session.note = options.note or print

    session.sampleSeconds = options.sampleSeconds or 0.25
    session.keepAliveMs = options.keepAliveMs or 180
    session.maxTiltDegrees = options.maxTiltDegrees or 20
    session.maxAltitudeGain = options.maxAltitudeGain or 60
    session.minAltitudeGain = options.minAltitudeGain or -5

    session.commanded = { collective = 0, roll = 0, pitch = 0, yaw = 0 }
    session.hoverTrim = 0.195
    session.aborted = nil
    session.groundY = nil

    return session
end

function Session:read()
    return sensors.read(self.config, self.atmosphere)
end

-- ATTITUDE-ONLY read, for inner loops that cannot afford a full sample.
--
-- sensors.read makes about a dozen blocking main-thread Sable calls at ~50 ms
-- each. That is fine for logging and fatal for measurement: the axis-response
-- pulse runs 3.3 s and collected TWO samples, so its "quadratic fit" was the
-- endpoint formula, and consecutive runs disagreed by 27% on roll authority.
--
-- This reads the pose (position AND orientation in one call) plus linear
-- velocity -- two Sable calls -- which is everything checkLimits and trim()
-- need. It deliberately omits angular velocity: Session:rates is unreliable at
-- this loop period anyway (it read exactly 0.0000 in a third of samples), and
-- the pulse fit uses ANGLES, taking its start rate from one full read before
-- the pulse begins.
--
-- Marked `cheap` so anything downstream can tell what it is holding.
function Session:readCheap()
    if not sublevel then return { valid = false, cheap = true } end

    local ok, pose = pcall(sublevel.getLogicalPose)
    if not ok or type(pose) ~= "table" then return { valid = false, cheap = true } end

    local state = { valid = true, cheap = true, errors = {} }
    state.position = sensors.plainVector(pose.position)
    state.quaternion = sensors.plainQuaternion(pose.orientation)

    if state.quaternion then
        local derivedOk, derived =
            pcall(attitude.fromQuaternion, state.quaternion, self.config.axes)
        if derivedOk and derived then
            state.roll, state.pitch, state.yaw = derived.roll, derived.pitch, derived.yaw
        end
    end

    local velocityOk, velocity = pcall(sublevel.getLinearVelocity)
    if velocityOk then state.linearVelocityWorld = sensors.plainVector(velocity) end

    -- Without a position or an attitude this is not a usable sample, and
    -- calling it valid would let checkLimits wave through a craft it cannot
    -- actually see.
    if not state.position or not state.roll then state.valid = false end
    return state
end

function Session:craftY(state)
    return state and state.position and state.position.y or nil
end

-- Body-frame angular rates in DEGREES/second. CC:Sable reports radians.
function Session:rates(state)
    local angular = state and state.angularVelocityBody
    if not angular then return nil end
    return {
        roll = math.deg(angular.x),
        pitch = math.deg(angular.z),
        yaw = math.deg(angular.y),
    }
end

-- ---------------------------------------------------------------------------
-- Commanding. Every ion command goes through the mixer, so a sign error in the
-- corner table shows up against an abort limit rather than during a manoeuvre.
-- ---------------------------------------------------------------------------

function Session:send()
    local allocated = mixer.allocate(self.profile, self.commanded)
    self.lastPlan = allocated
    for _, corner in ipairs(flight.CORNERS) do
        banks.send(corner, "set_power", { power = allocated.ions[corner] })
    end
    return allocated
end

function Session:arm(timeoutSeconds)
    local deadline = os.epoch("utc") + (timeoutSeconds or 12) * 1000
    repeat
        for _, corner in ipairs(flight.CORNERS) do
            banks.send(corner, "arm")
        end
        sleep(0.2)
        banks.poll()

        local armed = 0
        for _, corner in ipairs(flight.CORNERS) do
            local pod = banks.getState()[corner]
            if pod and pod.armed then armed = armed + 1 end
        end
        if armed == #flight.CORNERS then return true end
    until os.epoch("utc") > deadline
    return false
end

function Session:disarm()
    for _, corner in ipairs(flight.CORNERS) do
        banks.send(corner, "disarm")
    end
end

-- Prop commands are idempotent, so a lost packet deserves a retry rather than
-- an abandoned run. Without this a single dropped set_rpm ends the flight.
function Session:setProps(corner, rpm, attempts)
    attempts = attempts or 3
    local lastError
    for attempt = 1, attempts do
        local ok, err = pcall(actuators.setPropellerRpm, corner, rpm)
        if ok then
            if attempt > 1 then
                self.note(string.format("  %s props took %d attempts", corner, attempt))
            end
            return true
        end
        lastError = err
        sleep(0.3)
    end
    return false, lastError
end

-- EVERY corner, even after one fails.
--
-- This used to return on the first failure, leaving the rest untouched -- and
-- a partial application is worse than either extreme. Propellers carry ~52% of
-- craft weight at 64 rpm, so three corners at 64 against one at 0 is a large
-- roll couple.
--
-- Measured 2026-08-26. The craft had LANDED cleanly (y -26.47 against a ground
-- of -26.578, roll -0.00, speed 0.09) when the end-of-run cleanup called
-- setAllProps(0). FR was cut, a later corner failed, the other three stayed at
-- 64, and the craft rolled to 29 degrees and lifted back off the ground:
--
--     t=219.1  roll -0.00   FL 64  FR  0  RL 64  RR 64
--     t=225.4  roll 14.01
--     t=228.1  roll 29.35   speed 7.0   airborne again
--
-- It then thrashed for seventy seconds before settling on its side. That is
-- the "stuck sideways at the end of a run" symptom, and it is this function.
--
-- So: try all four, retry the ones that failed, and only then report. Leaving
-- the props ASYMMETRIC is the outcome to avoid at almost any cost -- a craft
-- with all four at the wrong speed is level, which is recoverable.
function Session:setAllProps(rpm)
    local failed = {}
    for _, corner in ipairs(flight.CORNERS) do
        local ok, err = self:setProps(corner, rpm)
        if not ok then failed[corner] = tostring(err) end
    end

    -- A second pass over just the stragglers. FR has needed two attempts on
    -- most runs, so one flaky corner should not decide the craft's attitude.
    for corner, previousError in pairs(failed) do
        local ok, err = self:setProps(corner, rpm, 4)
        if ok then
            failed[corner] = nil
        else
            failed[corner] = tostring(err or previousError)
        end
    end

    local reasons = {}
    for corner, err in pairs(failed) do
        reasons[#reasons + 1] = corner .. ": " .. err
    end
    if #reasons > 0 then
        -- Say so loudly: the craft is now asymmetric and that is a roll torque.
        if self.note then
            self.note("  WARNING: props left ASYMMETRIC -- " ..
                table.concat(reasons, ", "))
        end
        return false, table.concat(reasons, ", ")
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Limits
-- ---------------------------------------------------------------------------

function Session:checkLimits(state)
    if not state or not state.valid then
        return nil                      -- a bad sample is not an abort by itself
    end

    -- Once an abort has tripped, STOP re-aborting. The limits are on attitude
    -- and altitude and neither un-trips by itself, so a second abort fires on
    -- the first sample of the very next hold() -- the recovery descent -- and
    -- the craft is never brought down.
    if self.aborted then
        return nil
    end

    if state.roll and math.abs(state.roll) > self.maxTiltDegrees then
        return string.format("roll %.1f deg exceeded %.0f", state.roll, self.maxTiltDegrees)
    end
    if state.pitch and math.abs(state.pitch) > self.maxTiltDegrees then
        return string.format("pitch %.1f deg exceeded %.0f", state.pitch, self.maxTiltDegrees)
    end

    local y = self:craftY(state)
    if y and self.groundY then
        local gain = y - self.groundY
        if gain > self.maxAltitudeGain then
            return string.format("altitude +%.1f exceeded +%.0f", gain, self.maxAltitudeGain)
        end
        if gain < self.minAltitudeGain then
            return string.format("altitude %.1f below %.0f", gain, self.minAltitudeGain)
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- The hold loop.
--
-- Send cadence and sample cadence run on SEPARATE clocks: a sleep at the
-- bottom of a loop caps every other rate in it, which is how a 200 ms keepalive
-- silently became ~550 ms against a 750 ms watchdog and produced 79 straight
-- COMMAND_TIMEOUT faults.
-- ---------------------------------------------------------------------------

function Session:hold(seconds, onSample)
    local endAt = os.epoch("utc") + seconds * 1000
    local nextSend, nextSample = 0, 0

    while os.epoch("utc") < endAt do
        local now = os.epoch("utc")

        if now >= nextSend then
            -- Re-arm inline, never by a blocking arm(): while that blocks, no
            -- set_power goes out, which guarantees the watchdog fires.
            for _, corner in ipairs(flight.CORNERS) do
                local pod = banks.getState()[corner]
                if pod and not pod.armed then
                    banks.send(corner, "arm")
                end
            end
            self:send()
            nextSend = now + self.keepAliveMs
        end

        if now >= nextSample then
            local state = self.cheapRead and self:readCheap() or self:read()
            local limit = self:checkLimits(state)
            if limit then
                self.aborted = limit
                -- Go to the survivable level immediately and zero attitude
                -- demand. Whatever collective was doing when the limit tripped
                -- is not a state to leave the craft in.
                self.commanded.roll, self.commanded.pitch, self.commanded.yaw = 0, 0, 0
                self.commanded.collective =
                    math.max(self.commanded.collective, flight.SURVIVABLE_COMMAND)
                self.hoverTrim = math.max(self.hoverTrim, flight.SURVIVABLE_COMMAND)
                pcall(function() self:send() end)
                return "abort: " .. limit
            end
            if onSample then
                local stop = onSample(state, now)
                if stop then return stop end
            end
            nextSample = now + self.sampleSeconds * 1000
        end

        sleep(0.05)
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Altitude hold: cascaded PI, proportional acting DIRECTLY on collective.
--
-- Two earlier shapes failed. Flat proportional on POSITION never limits climb
-- rate, so the craft sails through the capture window and overshoots. Cascaded
-- but ACCUMULATING every correction into collective degenerates into bang-bang,
-- because rate errors routinely exceed the per-step clamp.
--
-- hoverTrim is a slow integral that learns what collective actually hovers at
-- THIS altitude -- which is not 0.195, since pressure falls with height and
-- hover ions rise. The proportional term rides on top and never accumulates.
-- ---------------------------------------------------------------------------

local MAX_CLIMB_RATE = 0.8
local RATE_PER_ERROR = 0.12
local POWER_PER_RATE = 0.020
local TRIM_PER_RATE = 0.0040
local MAX_PROPORTIONAL = 0.06

flight.MAX_CLIMB_RATE = MAX_CLIMB_RATE

-- `floor` is a minimum COMMANDED power: the descent uses it so it can never
-- walk below the survivable level while still airborne.
-- `state` is optional: pass the sample the caller already has.
--
-- Without it this makes its OWN full sensors.read, so every hold() tick that
-- trims paid for two complete reads -- roughly two dozen blocking Sable calls
-- where one dozen would do. That is half the reason the pulse measurement was
-- starved of samples.
function Session:trim(targetGain, maxRate, floor, state)
    maxRate = maxRate or MAX_CLIMB_RATE
    floor = floor or 0

    state = state or self:read()
    local y = self:craftY(state)
    if not y or not state.linearVelocityWorld then return end

    local error = (self.groundY + targetGain) - y
    local vy = state.linearVelocityWorld.y

    local targetRate = RATE_PER_ERROR * error
    if targetRate > maxRate then targetRate = maxRate end
    if targetRate < -maxRate then targetRate = -maxRate end

    local rateError = targetRate - vy

    self.hoverTrim = self.hoverTrim + TRIM_PER_RATE * rateError * self.sampleSeconds
    if self.hoverTrim < 0 then self.hoverTrim = 0 end
    if self.hoverTrim > 0.50 then self.hoverTrim = 0.50 end

    local proportional = POWER_PER_RATE * rateError
    if proportional > MAX_PROPORTIONAL then proportional = MAX_PROPORTIONAL end
    if proportional < -MAX_PROPORTIONAL then proportional = -MAX_PROPORTIONAL end

    self.commanded.collective =
        math.max(floor, math.min(0.60, self.hoverTrim + proportional))
end

-- ---------------------------------------------------------------------------

function Session:preflight()
    banks.poll()
    sleep(1.0)
    banks.poll()

    local online = 0
    for _, corner in ipairs(flight.CORNERS) do
        local pod = banks.getState()[corner]
        if pod and pod.online then online = online + 1 end
    end
    if online < #flight.CORNERS then
        return false, "only " .. online .. "/4 pods online"
    end

    local state = self:read()
    self.groundY = self:craftY(state)
    if not self.groundY then
        return false, "no craft position"
    end

    return true
end

-- `onSample` is optional and receives every sample during the climb. Passive
-- observations need it: the craft drifts DURING the climb, so a tool that only
-- starts recording once it is level has already missed the interesting part --
-- and if an abort fires on the way up it would otherwise have no data at all.
-- "At altitude and stable" must be judged over a WINDOW, not an instant.
--
-- The original test required instantaneous |vy| < 0.10 with the altitude
-- within 2.0 blocks. On a quantised lift system that is UNSATISFIABLE, and
-- the 2026-08-26 run proves it: the craft held station with a mean vertical
-- velocity of +0.0001 blocks/s -- a textbook hold -- and the test failed with
-- "did not stabilise at altitude".
--
-- The reason is that there is no hover level. With props at 64 RPM the craft
-- dithers between ion level 2 and level 3 (measured: 50.5% / 49.5% of samples
-- at +23 blocks), so vy is a sawtooth swinging -1.56 .. +2.04 and the
-- altitude runs a slow limit cycle of about +/-4 blocks with a ~20 s period.
-- Only 12 of 95 samples had |vy| < 0.10 and only ONE met both conditions at
-- once. The craft cannot rest, because no combination of levels holds weight.
--
-- So the honest criterion is the MEAN over at least one limit-cycle period:
-- the mean rate is what says whether the craft is holding station, while the
-- instantaneous rate only says where it is in the dither.
flight.STABLE_WINDOW_SECONDS = 20.0   -- one measured limit-cycle period
flight.STABLE_MEAN_RATE = 0.10        -- blocks/s, on the MEAN not the sample
flight.STABLE_ALTITUDE_TOLERANCE = 5.0 -- measured limit cycle is about +/-4
flight.STABLE_MIN_SAMPLES = 5

-- Trim `window` so that window[1] is the NEWEST sample still at least
-- windowMs old, and return the span it covers. Extracted so it can be tested
-- directly -- a test that reimplemented this would have agreed with the bug.
--
-- THE BUG THIS REPLACES, because it is easy to write again: dropping
-- everything older than windowMs leaves span <= windowMs, while the caller
-- needs span >= windowMs. The two meet only when a sample lands exactly on the
-- boundary, which happens iff the loop period divides windowMs. At 250, 500,
-- 1000 or 2000 ms it passes and looks fine; at 950, 1600 or 3000 ms it NEVER
-- passes -- not in 200 ticks, not in 200,000. A run on 2026-08-26 failed with
-- "no full window sampled" while earlier runs at a friendlier loop period had
-- passed, which is the worst way for a bug to behave.
function flight.trimWindow(window, now, windowMs)
    while #window > 2 and (now - window[2].t) >= windowMs do
        table.remove(window, 1)
    end
    return now - window[1].t
end

function Session:climb(targetGain, timeoutSeconds, onSample)
    self.commanded.collective = 0.195
    if not self:arm(12) then
        return false, "banks would not arm"
    end

    local reached = false
    local window = {}
    local best, bestRate = nil, nil

    self:hold(timeoutSeconds or 150, function(state, now)
        self:trim(targetGain, MAX_CLIMB_RATE, 0)
        if onSample then onSample(state, now) end

        local y = self:craftY(state)
        if not y then return nil end
        local vy = state.linearVelocityWorld and state.linearVelocityWorld.y or 0

        -- `now` is os.epoch("utc") -- MILLISECONDS. Comparing it against a
        -- constant named ...SECONDS would satisfy the window in 20 ms and
        -- report a 20-second stable hold that never happened.
        local windowMs = flight.STABLE_WINDOW_SECONDS * 1000

        window[#window + 1] = { t = now, gain = y - self.groundY, vy = vy }

        local span = flight.trimWindow(window, now, windowMs)
        if span < windowMs or #window < flight.STABLE_MIN_SAMPLES then
            return nil
        end

        local gainSum, rateSum = 0, 0
        for _, sample in ipairs(window) do
            gainSum = gainSum + sample.gain
            rateSum = rateSum + sample.vy
        end
        local meanGain = gainSum / #window
        local meanRate = rateSum / #window

        -- Track the best window by EACH criterion separately.
        --
        -- Reporting only the closest-by-altitude hid the real situation on the
        -- 2026-08-26 run: it named a window at +27.57 sinking at -0.85 blocks/s
        -- and said nothing about the many windows holding to within
        -- 0.01 blocks/s slightly lower down. Two failures with one number
        -- between them is one number too few.
        local miss = math.abs(meanGain - targetGain)
        if best == nil or miss < best.miss then
            best = { miss = miss, gain = meanGain, rate = meanRate }
        end
        if bestRate == nil or math.abs(meanRate) < math.abs(bestRate.rate) then
            bestRate = { miss = miss, gain = meanGain, rate = meanRate }
        end

        if miss < flight.STABLE_ALTITUDE_TOLERANCE
            and math.abs(meanRate) < flight.STABLE_MEAN_RATE then
            reached = true
            self.holdMeanGain, self.holdMeanRate = meanGain, meanRate
            return "at altitude"
        end
        return nil
    end)

    if self.aborted then return false, self.aborted end
    if not reached then
        -- Say WHICH condition failed. "did not stabilise" hid a successful
        -- hold at the wrong altitude behind the same words as a runaway.
        if best then
            local why = string.format(
                "did not stabilise over %.0f s. Closest to target: %+.2f blocks (off %.2f) at %+.4f blocks/s",
                flight.STABLE_WINDOW_SECONDS, best.gain, best.miss, best.rate)
            if bestRate and bestRate ~= best then
                why = why .. string.format(
                    "; steadiest: %+.2f blocks (off %.2f) at %+.4f blocks/s",
                    bestRate.gain, bestRate.miss, bestRate.rate)
            end
            -- Name the criterion that actually failed. A steady hold at the
            -- wrong altitude and a runaway are different problems.
            if bestRate and math.abs(bestRate.rate) < flight.STABLE_MEAN_RATE then
                why = why .. " -- HELD STEADY, but never within "
                    .. string.format("%.1f", flight.STABLE_ALTITUDE_TOLERANCE)
                    .. " blocks of target. Lower the target, not the tolerance."
            end
            return false, why
        end
        return false, "did not stabilise at altitude (no full window sampled)"
    end
    return true
end

-- Rate-controlled descent, NOT a power ramp.
--
-- The first version walked collective down with no rate feedback. Under
-- CONTINUOUS ion thrust that is a gentle descent, and it passed every harness
-- run -- because the harness shared the wrong belief. Quantised, a power ramp
-- walks DOWN THROUGH THE LEVELS: 0.37, then 2.82, then 5.27 blocks/s^2. From
-- +30 blocks that reaches the ground at 17.8 blocks/s, and no abort catches it
-- because minAltitudeGain is below ground.
function Session:descend(descentRate, timeoutSeconds)
    descentRate = descentRate or 0.5

    self.commanded.roll, self.commanded.pitch, self.commanded.yaw = 0, 0, 0

    local landed = false
    self:hold(timeoutSeconds or 180, function(state)
        local y = self:craftY(state)
        local gain = y and (y - self.groundY) or 0

        if gain > 1.5 then
            self:trim(0, descentRate, flight.SURVIVABLE_COMMAND)
        else
            self.hoverTrim = math.max(0, self.hoverTrim - 0.004)
            self.commanded.collective = self.hoverTrim
        end

        if y and gain < 0.5 then
            local vy = state.linearVelocityWorld and state.linearVelocityWorld.y or -1
            if math.abs(vy) < 0.05 then
                landed = true
                return "grounded"
            end
        end
        return nil
    end)

    return landed
end

-- Land it safely whatever happened, and NEVER disarm while airborne:
-- fallbackPower is 0.0, so disarming in flight drops the ion half of the lift.
function Session:finish()
    local state = self:read()
    local y = self:craftY(state)
    local airborne = y and self.groundY and (y - self.groundY) > 1.0

    if airborne then
        self.commanded.roll, self.commanded.pitch, self.commanded.yaw = 0, 0, 0
        self.commanded.collective =
            math.max(self.commanded.collective, flight.SURVIVABLE_COMMAND)
        pcall(function() self:send() end)

        self.note("")
        self.note(string.format("STILL AIRBORNE at +%.1f blocks.", y - self.groundY))
        self.note("NOT disarming: fallbackPower is 0.0 and disarming here would drop it.")
        self.note(string.format("Banks left at collective %.3f = ion LEVEL %d of %d.",
            self.commanded.collective, flight.levelFor(self.commanded.collective),
            flight.ION_LEVELS))
        self.note("Do NOT command below that level while airborne.")
        self.note("Land it with /fcs/bankctl.lua, or let commsLossPower settle it.")
        return false
    end

    pcall(function() self:disarm() end)
    self.note("grounded: banks disarmed")
    return true
end

return flight
