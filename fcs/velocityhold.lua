-- Layer 2: hold VELOCITY at zero with common-mode bearing tilt.
--
-- ---------------------------------------------------------------------------
-- THE PLANT CHANGES SIGN BETWEEN FAST AND SLOW, AND THAT IS THE WHOLE FILE.
--
-- A commanded bearing tilt does two things to the craft's velocity, and as of
-- 2026-08-27 both halves are measured:
--
--   DIRECT, and it is FAST.  The bearings make a horizontal force. Terminal
--   drift +0.8165 blocks/s per commanded degree, from the live per-bearing
--   getThrust at 64 rpm (see fcs/bearinggain.lua). Velocity reaches it with
--   drag's time constant, 1/0.09 = about 11 s.
--
--   THROUGH THE HULL, and it is SLOW AND BIGGER. The two props of a corner sit
--   at the same height, so the same command also ROLLS the craft -- and a
--   leaning hull points its lift sideways, which is worth 2.13 blocks/s per
--   HULL degree. The coupling is measured per axis, and the two axes disagree:
--
--       roll   -0.8205 hull deg per commanded deg  ->  -1.751 blocks/s per deg
--       pitch  +0.5588                             ->  -1.192
--
--   This arrives on the hull's own timescale: roll rings at 32.7 s, pitch
--   settles overdamped in about 30 s.
--
-- Add them up and the NET is INVERTED on both axes:
--
--       roll axis    +0.8165 - 1.7505  =  -0.934 blocks/s per commanded degree
--       pitch axis   +0.8165 - 1.1921  =  -0.376
--
-- **Commanding a tilt that pushes starboard moves the craft PORT**, once the
-- hull has caught up. For the first few seconds it moves STARBOARD.
--
-- THAT IS THE RUNAWAY, and it is no longer a mystery. A loop that closes on
-- the fast response sees the craft move the right way, then watches it reverse,
-- and answers by commanding harder. 1.76 -> 11.5 blocks/s in ten seconds, roll
-- climbing monotonically the whole way.
--
-- ---------------------------------------------------------------------------
-- SO: SLOW, AND ON A MEASURED NET GAIN
--
-- Two rules follow directly, and both are enforced here rather than left to
-- the caller:
--
--   1. THE LOOP MUST BE SLOWER THAN THE HULL. If the command changes faster
--      than the hull's ~30 s response, the loop is chasing the transient --
--      the half of the plant with the WRONG SIGN. `slewPerSecond` rate-limits
--      the commanded tilt, and the default is deliberately sluggish.
--
--   2. THE GAIN IS MEASURED, NEVER MODELLED. The numbers above are a
--      PREDICTION built from three separate measurements; the product of three
--      measured quantities is not a measurement. /fcs/velocityholdflight.lua
--      measures the net response per axis by reverse pairs at steady state and
--      the loop refuses to run without it.
--
-- WHAT THIS SUPERSEDES. `fcs/lateralhold.lua` answered the runaway by making
-- ROLL the controlled variable and tilt the thing that holds it. That was a
-- reasonable response to an unexplained event; with the plant measured, the
-- simpler statement is that the actuator is inverted and slow, and a loop that
-- respects both works. lateralhold's geometry helpers are still the truth
-- about azimuths and body velocity, and are used here.

local lateralhold = require("fcs.lateralhold")

local velocityhold = {}

velocityhold.ENVIRONMENT = {
    gravity = 11.0,
    universalDrag = 0.09,
}

-- Terminal drift from a HULL tilt: lift leans, drag balances. 2.13 blocks/s
-- per degree on this craft, and it is the term that dominates everything here.
function velocityhold.hullDriftPerDegree(options)
    options = options or {}
    local gravity = options.gravity or velocityhold.ENVIRONMENT.gravity
    local drag = options.universalDrag or velocityhold.ENVIRONMENT.universalDrag
    if drag <= 0 then return nil end
    return gravity * math.tan(math.rad(1)) / drag
end

-- The PREDICTED net gain for one axis, in blocks/s of terminal drift per
-- degree of commanded tilt. A hypothesis to fly against, never a gain to
-- command with -- it multiplies three measured numbers together.
--
-- `sense` is which way a positive hull angle pushes the craft along this axis:
-- positive roll is starboard-low so it drifts to starboard (+1 on the starboard
-- axis); positive pitch is bow-high so it drifts aft (-1 on the bow axis).
function velocityhold.predictNet(directPerDegree, coupling, sense, options)
    if type(directPerDegree) ~= "number" or type(coupling) ~= "number" then
        return nil
    end
    local hull = velocityhold.hullDriftPerDegree(options)
    if not hull then return nil end
    local hullTerm = coupling * hull * (sense or 1)
    return directPerDegree + hullTerm, hullTerm
end

-- Body-frame horizontal velocity as { bow, starboard }.
--
-- Body frame, not world, and this is not a detail: the bearings are bolted to
-- the hull, so a loop that skips the conversion steers by whatever heading the
-- craft happened to launch on. Starboard is -X because port is +X.
function velocityhold.components(state, axes)
    local body = lateralhold.bodyVelocity(state)
    if not body then return nil end
    axes = axes or {}
    local bowAxis = axes.bowAxis or "z"
    local portAxis = axes.portAxis or "x"
    local bow = body[bowAxis]
    local port = body[portAxis]
    if type(bow) ~= "number" or type(port) ~= "number" then return nil end
    return { bow = bow, starboard = -port }
end

velocityhold.DEFAULTS = {
    -- Far below the 15 degree hardware clamp and equal to the trim clamp. The
    -- runaway happened at a saturated 12.
    maxTiltDegrees = 4.0,
    -- Below this speed the loop commands nothing. Every degree of tilt costs
    -- lift as cos(angle), and chattering the bearings to chase 0.1 blocks/s
    -- trades altitude for nothing.
    deadbandSpeed = 0.10,
    -- Fraction of the correction to apply. Under-relaxed on purpose: the gain
    -- is measured with error bars and a full-strength correction on a plant
    -- that inverts is the shape of the runaway.
    relaxation = 0.5,
    -- THE RATE LIMIT, in degrees per second of commanded tilt. The hull takes
    -- about 30 s to answer a tilt; at 0.05 deg/s a full 4 degree command takes
    -- 80 s to build, so the loop can never outrun the half of the plant that
    -- makes it stable.
    slewPerSecond = 0.05,
    -- A net gain smaller than this is not distinguishable from the craft
    -- drifting on its own, and dividing by it produces a saturated command
    -- built out of noise. Same guard as trim.tiltFor.
    minimumUsableGain = 0.10,
    -- Abort limits.
    abortSpeed = 8.0,
    abortTilt = 6.0,
}

-- The tilt that cancels a velocity, given the MEASURED net gain for that axis.
--
-- Returns tilt, reason. Refuses rather than guesses: a nil gain returns zero
-- and says so, because every other outcome is a command derived from a number
-- nobody measured.
--
-- The sign takes care of itself. netGain is signed and measured; the craft's
-- inverted plant shows up as a negative gain, and dividing by it produces a
-- command in the direction that actually works. Nothing here needs to know
-- which way the bearings "should" push.
function velocityhold.tiltFor(velocity, netGain, options)
    options = options or {}
    local maxTilt = options.maxTiltDegrees or velocityhold.DEFAULTS.maxTiltDegrees
    local deadband = options.deadbandSpeed or velocityhold.DEFAULTS.deadbandSpeed
    local minimum = options.minimumUsableGain or velocityhold.DEFAULTS.minimumUsableGain
    local relaxation = options.relaxation or velocityhold.DEFAULTS.relaxation

    if type(netGain) ~= "number" then
        return 0, "no measured net gain for this axis"
    end
    if math.abs(netGain) < minimum then
        return 0, string.format("net gain %.4f is below the %.2f needed to trust it",
            netGain, minimum)
    end
    velocity = velocity or 0
    if math.abs(velocity) < deadband then return 0, "inside the deadband" end

    -- Cancel it: command the tilt whose steady drift is the negative of the
    -- velocity we have.
    local tilt = (-velocity / netGain) * relaxation
    if tilt > maxTilt then return maxTilt, "clamped" end
    if tilt < -maxTilt then return -maxTilt, "clamped" end
    return tilt, nil
end

-- Rate-limit a commanded tilt toward its target.
--
-- THE SINGLE MOST IMPORTANT LINE IN THIS FILE. The plant's fast half has the
-- opposite sign to its slow half, so a loop that moves quickly is closing on
-- the wrong sign. Limiting how fast the command may change is what keeps the
-- loop on the slow, stable half.
function velocityhold.slew(current, target, dt, options)
    options = options or {}
    local rate = options.slewPerSecond or velocityhold.DEFAULTS.slewPerSecond
    current = current or 0
    target = target or 0
    if not dt or dt <= 0 then return current end
    local step = rate * dt
    local delta = target - current
    if delta > step then return current + step end
    if delta < -step then return current - step end
    return target
end

-- ---------------------------------------------------------------------------
-- THE LOOP MUST NOT CHASE THE AC.
--
-- The velocity the craft reports is a DC drift with the hull's oscillation on
-- top of it -- roll rings at 32.7 s and swings the lift vector, so the velocity
-- swings with it. Feeding that straight into the loop makes the loop command
-- against the oscillation, and on a high-gain axis that INJECTS energy: the
-- harness produced a run where the loop acted properly, commanded a quarter of
-- a degree on average, and left the craft drifting twice as fast.
--
-- This is the same lesson trimflight learned about windows -- a 20 s window on
-- a 42 s oscillation read a standing pitch of +2.404 on a craft whose standing
-- pitch is -0.638 -- arriving at the control loop instead of the measurement.
--
-- So the loop sees a MEAN over a window comparable to the oscillation, and the
-- rate limit sits underneath that as the second line of defence. Both exist
-- because the plant has a fast half that the loop must not respond to.
-- ---------------------------------------------------------------------------

function velocityhold.newAverager(options)
    options = options or {}
    local averager = {
        windowSeconds = options.windowSeconds or 15,
        samples = {},
    }

    function averager:push(t, bow, starboard)
        if not t or not bow or not starboard then return end
        self.samples[#self.samples + 1] = { t = t, bow = bow, starboard = starboard }
        while #self.samples > 1 and (t - self.samples[1].t) > self.windowSeconds do
            table.remove(self.samples, 1)
        end
    end

    -- Returns nil until the window is actually full. A mean over two samples
    -- of a 33 s oscillation is not a DC estimate, and handing one to the loop
    -- is how the loop ends up chasing the AC anyway.
    function averager:mean()
        local n = #self.samples
        if n < 3 then return nil end
        local span = self.samples[n].t - self.samples[1].t
        if span < self.windowSeconds * 0.5 then return nil end
        local bow, starboard = 0, 0
        for _, sample in ipairs(self.samples) do
            bow = bow + sample.bow
            starboard = starboard + sample.starboard
        end
        return bow / n, starboard / n, n
    end

    function averager:count() return #self.samples end

    return averager
end

-- MEASURE the net gain from a reverse pair: mean body velocity at +T and at -T.
--
-- Reverse pairs for the same reason trim.staticGain uses them: the craft's
-- standing drift is comparable to the response being measured, and it cancels
-- in the difference while the response reverses and adds.
function velocityhold.netGain(positiveTilt, positiveVelocity, negativeTilt,
    negativeVelocity)
    if not (positiveTilt and positiveVelocity and negativeTilt and negativeVelocity) then
        return nil
    end
    local span = positiveTilt - negativeTilt
    if math.abs(span) < 1e-6 then return nil end
    return (positiveVelocity - negativeVelocity) / span
end

-- Is a measured gain safe to close a loop on?
function velocityhold.usable(netGain, options)
    options = options or {}
    local minimum = options.minimumUsableGain or velocityhold.DEFAULTS.minimumUsableGain
    if type(netGain) ~= "number" then return false, "not measured" end
    if math.abs(netGain) < minimum then
        return false, string.format("%.4f is below the %.2f floor", netGain, minimum)
    end
    return true, nil
end

-- NET DISPLACEMENT over a window, divided by its length -- not mean speed.
--
-- Mean speed is a MAGNITUDE, so an oscillating craft contributes to it even
-- when its mean velocity is exactly zero. Trim run 1 was judged on mean speed
-- and could not be: both windows sat on a 1.1 blocks/s floor that was pure AC.
-- What the loop is trying to change is where the craft ENDS UP.
function velocityhold.netDrift(firstX, firstZ, lastX, lastZ, seconds)
    if not (firstX and firstZ and lastX and lastZ) then return nil end
    if not seconds or seconds <= 0 then return nil end
    local dx, dz = lastX - firstX, lastZ - firstZ
    return math.sqrt(dx * dx + dz * dz) / seconds
end

return velocityhold
