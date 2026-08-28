-- How this program is started decides whether it has require() at all.
-- shell.run and shell.openTab wrap a program in a shell env, which injects
-- require/package. multishell.launch goes straight to os.run() and injects
-- neither, so touching package.path there throws on a nil global. Build them
-- when missing, rooted at "/" so "pod.x" resolves to /pod/x.lua.
if package then
    package.path = "/?.lua;/?/init.lua;" .. package.path
else
    require, package = dofile("/rom/modules/main/cc/require.lua").make(_ENV, "/")
end

local config = require("pod.config")
local protocol = require("pod.protocol")
local thrusters = require("pod.thrusters")
local props = require("pod.props")
local payload = require("pod.payload")

local VALID_CORNERS = { FL = true, FR = true, RL = true, RR = true }
if not VALID_CORNERS[config.corner] then
    error("set /pod/config.lua corner to FL, FR, RL, or RR", 0)
end
if config.hostname ~= "ENG-" .. config.corner then
    error("pod hostname must be ENG-" .. config.corner, 0)
end
if not protocol.validPower(config.fallbackPower) then
    error("fallbackPower must be a finite number", 0)
end
if config.fallbackPower < config.minimumPower or config.fallbackPower > config.maximumPower then
    error("fallbackPower is outside the configured power limits", 0)
end
if not protocol.validPower(config.commsLossPower) then
    error("commsLossPower must be a finite number", 0)
end
if config.commsLossPower < config.minimumPower or config.commsLossPower > config.maximumPower then
    error("commsLossPower is outside the configured power limits", 0)
end
if config.maximumChangePerCommand <= 0 then
    error("maximumChangePerCommand must be greater than zero", 0)
end

-- ---------------------------------------------------------------------------
-- ONE MODEM, WIRED OR WIRELESS, AND THE POD SAYS WHICH.
--
-- This used to REJECT any modem that was not wireless, which made a wired bus
-- impossible to try. It is now the transport under test.
--
-- WHY, measured 2026-08-28: in flight, commands FCS->pod stopped arriving for
-- about six seconds on ALL FOUR pods at once while pod->FCS telemetry kept
-- flowing and the FCS loop stayed healthy. The craft runs Ender modems, which
-- are interdimensional and skip CC:Tweaked's distance check entirely, so no
-- distance can explain it -- what is left is the receiver not being in the set
-- the transmit iterated, which is Sable sublevel/registration state. A wired
-- network is a connected graph rather than a spatial query and does not go
-- through that code at all.
--
-- EXACTLY ONE MODEM IS OPENED, deliberately. rednet.receive cannot say which
-- modem a message arrived on, so a pod listening on both transports that
-- survives an outage proves nothing about which one delivered. One pod, one
-- transport, or there is no A/B. Redundant delivery with sequence-gate dedup
-- is the right PRODUCTION design and the wrong experiment.
--
-- Set `modemName` in pod/config.lua to pick the side. `wirelessModemName` is
-- still honoured so existing pod configs keep working.
-- ---------------------------------------------------------------------------
local function modemsPresent()
    local found = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "modem") then
            local modem = peripheral.wrap(name)
            local wireless = nil
            if type(modem.isWireless) == "function" then
                local ok, value = pcall(modem.isWireless)
                if ok then wireless = value and true or false end
            end
            found[#found + 1] = { name = name, wireless = wireless }
        end
    end
    return found
end

local function findModem()
    local configured = config.modemName or config.wirelessModemName

    -- "wired" / "wireless" pick the first modem OF THAT KIND rather than
    -- naming a side. Which side a pod's wired modem sits on is a fact about
    -- how the hull was built, and having to look it up per corner is one more
    -- thing to get wrong -- so the config says what it wants, not where it is.
    if configured == "wired" or configured == "wireless" then
        local want = (configured == "wireless")
        for _, entry in ipairs(modemsPresent()) do
            if entry.wireless == want then return entry.name end
        end
        error("no " .. configured .. " modem on this pod", 0)
    end

    if configured then
        if not peripheral.isPresent(configured) then
            error("configured modem is missing: " .. tostring(configured), 0)
        end
        if not peripheral.hasType(configured, "modem") then
            error("configured peripheral is not a modem: " .. tostring(configured), 0)
        end
        return configured
    end

    -- Nothing configured: prefer wireless, which is what every pod did before
    -- and what an un-wired corner still needs. A wired bus is opt-in per pod.
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "modem") then
            local modem = peripheral.wrap(name)
            if type(modem.isWireless) == "function" and modem.isWireless() then
                return name
            end
        end
    end
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "modem") then return name end
    end
    error("no modem is attached", 0)
end

-- Wireless, wired, or a modem that will not say. Reported rather than assumed:
-- the whole point of the A/B is that the log states the transport instead of
-- relying on anyone remembering which corners were wired.
local function modemIsWireless(name)
    local modem = peripheral.wrap(name)
    if not modem or type(modem.isWireless) ~= "function" then return nil end
    local ok, wireless = pcall(modem.isWireless)
    if not ok then return nil end
    return wireless and true or false
end

thrusters.load()
thrusters.applyExact(config.fallbackPower)

-- Degrades instead of erroring: a broken prop must not stop the ion bank.
props.load()

local wirelessModem = findModem()
local modemWireless = modemIsWireless(wirelessModem)

-- CLOSE EVERYTHING FIRST, then open exactly one.
--
-- A modem's open channels are state on the MODEM, not on the computer, so they
-- outlive a reboot. FR and RR were moved to the wired bus, both rednet.open
-- calls on the pod correctly chose the wired modem, and the pods still reported
-- modems_open=top,back across three reboots -- `back` had been opened by the
-- code that ran BEFORE the config change and nothing ever closed it.
--
-- rednet.receive takes messages from ANY open modem, so a leftover channel puts
-- the pod on a transport main.lua never chose. That is not a tidiness problem:
-- it silently destroys the wired/wireless A/B, because a corner surviving an
-- outage proves nothing about the wire if it was also on the radio.
--
-- Forcing the invariant is cheaper than reasoning about who opened what.
pcall(rednet.close)
rednet.open(wirelessModem)
pcall(rednet.unhost, config.protocol, config.hostname)
rednet.host(config.protocol, config.hostname)

local state = {
    -- Stamped once at startup and published in telemetry. A restart is
    -- otherwise surprisingly hard to observe from outside: counters only reset
    -- if they had counted anything, and mere presence looks the same as a pod
    -- that ignored the reboot entirely.
    bootedAt = os.epoch("utc"),
    armed = false,
    currentPower = config.fallbackPower,
    lastCommandAt = nil,
    lastSequence = -1,
    session = nil,
    trustedMainId = config.mainComputerId,
    faults = {},
    telemetrySends = 0,
    lastSendAt = nil,
    repliesSent = 0,
    -- Where commands go. The FCS could previously only observe "no reply", which
    -- is indistinguishable from a lost packet -- so measure it at the pod, which
    -- is the only place that knows.
    commandsSeen = 0,
    commandsApplied = 0,
    commandsRejected = 0,
    untrusted = 0,
    -- EVERY MESSAGE rednet.receive HANDED THIS POD, before any judgement.
    --
    -- Without this the FCS can see "I sent 549, the pod counted 406" and
    -- CANNOT tell three completely different faults apart:
    --   never transmitted / lost on the wire
    --   arrived at the computer and dropped by CC's 256-event queue
    --   arrived at networkLoop and discarded there
    -- All three read as loss, and only the third is anything this code can
    -- fix. `received` splits the first two from the third.
    received = 0,
    -- Discarded by protocol.validate: wrong magic, wrong version, unknown
    -- type. networkLoop had `if valid then ... end` with NO else, so these
    -- vanished uncounted -- the same silent-drop shape as rejectReply
    -- recording no fault, which hid 98 refusals per pod for two flights.
    invalid = 0,
    lastInvalid = nil,
    -- Messages that were valid and NOT commands: ping and status_request.
    -- Counted so received can be reconciled exactly rather than approximately.
    nonCommand = 0,
    lastReject = nil,
    -- What the BEARINGS did with the last set_tilt, as opposed to what the pod
    -- was asked for. See noteTiltResult.
    lastTiltBearings = nil,
    lastTiltAccepted = nil,
    lastTiltError = nil,
}

-- Faults were an UNBOUNDED list, appended to and never cleared.
--
-- statusMessage copies the whole list into EVERY telemetry message, and
-- fcs/main.lua writes it into EVERY CSV row. After ~74 minutes the four pods
-- had accumulated 1716 COMMAND_TIMEOUTs between them, which is 30 KB of
-- repeated strings PER ROW. Flight logs then rotated every ~17 seconds at 20
-- rows each, so the pulse data a run existed to capture was gone before it
-- could be pulled -- six runs' worth.
--
-- Capped and run-length collapsed: "COMMAND_TIMEOUT x429" carries strictly
-- more information than 429 copies of it, in 20 bytes instead of 6 KB. The
-- running total is kept separately so nothing is lost by trimming.
local FAULT_LIMIT = 12

local function recordFault(text)
    state.faultTotal = (state.faultTotal or 0) + 1

    local last = state.faults[#state.faults]
    if last then
        local base, count = last:match("^(.*) x(%d+)$")
        if base == text then
            state.faults[#state.faults] = text .. " x" .. (tonumber(count) + 1)
            return
        elseif last == text then
            state.faults[#state.faults] = text .. " x2"
            return
        end
    end

    state.faults[#state.faults + 1] = text
    while #state.faults > FAULT_LIMIT do
        table.remove(state.faults, 1)
    end
end


-- ---------------------------------------------------------------------------
-- WHAT THE BEARINGS ACTUALLY DID WITH A TILT.
--
-- props.setTilt returns a PER-BEARING report -- setManualTarget wrapped in a
-- pcall for each bearing -- and this handler used to keep only `.angle`, the
-- number the pod was ASKED for, and throw the report away. A bearing whose
-- setManualTarget threw, or that had no such method, therefore reported a
-- clean success up the wire and logged nothing at all.
--
-- THAT IS NOT HYPOTHETICAL. On 2026-08-28 a ground run read FL 8.00 with
-- FR/RL/RR at 0.00, while all four pods' own counters showed every command
-- SEEN and APPLIED -- seen minus applied equalled rejected to the message on
-- every corner. The commands arrived, the pods accepted them, three corners'
-- bearings did not move, and the one error that could have named why was
-- discarded here.
--
-- recordFault collapses repeats into "x N" and is capped at FAULT_LIMIT, so
-- calling this on every set_tilt cannot run the fault list away -- which it
-- once did, destroying six runs of flight data.
--
-- WHAT THIS STILL CANNOT SAY: setManualTarget returning without throwing does
-- not mean the bearing moved. Only getTiltAngle says that, and it is sampled
-- elsewhere. This closes the case where the mod refuses OUT LOUD.
local function noteTiltResult(applied)
    local bearings = applied and applied.bearings
    if type(bearings) ~= "table" then
        state.lastTiltBearings, state.lastTiltAccepted = 0, 0
        state.lastTiltError = "no per-bearing report"
        recordFault("SET_TILT: no per-bearing report")
        return
    end

    local total, accepted, firstError = 0, 0, nil
    for index, result in pairs(bearings) do
        total = total + 1
        local failure = type(result) == "table" and result.error or nil
        if failure then
            if not firstError then
                firstError = tostring(index) .. ": " .. tostring(failure)
            end
            recordFault("SET_TILT bearing " .. tostring(index) .. ": "
                .. tostring(failure))
        else
            accepted = accepted + 1
        end
    end

    state.lastTiltBearings = total
    state.lastTiltAccepted = accepted
    state.lastTiltError = firstError

    -- NOT ONE BEARING TOOK IT. Said separately from the per-bearing faults:
    -- this is the whole corner refusing, which is the shape the ground run saw.
    if total > 0 and accepted == 0 then
        recordFault("SET_TILT: no bearing on this corner accepted the target")
    end
end

-- Written to disk so a pod that is running but silent can be diagnosed without
-- standing in front of its screen. A crash leaves last_error.txt; a live pod
-- refreshes heartbeat.txt, and the send counters show whether telemetryLoop is
-- actually transmitting or merely alive.
local beat = 0

local function writeReport(path, lines)
    local ok, file = pcall(fs.open, path, "w")
    if ok and file then
        file.write(table.concat(lines, "\n"))
        file.close()
    end
end

local function resolveMain()
    if not state.trustedMainId then
        state.trustedMainId = rednet.lookup(config.protocol, config.mainHostname)
    end
    return state.trustedMainId
end

-- ---------------------------------------------------------------------------
-- THE SAMPLE: the one place this pod reads its hardware.
--
-- Everything else -- replies, telemetry sends, the display, the heartbeat --
-- reads this table and touches no peripheral. That is not tidiness; it is the
-- fix for a measured 2.5-5% command loss. See pod/payload.lua for the
-- mechanism and the numbers.
--
-- Held as ONE table replaced wholesale rather than fields updated in place, so
-- a reader can never catch a half-written sample: taking a local reference to
-- `sample` gives a consistent set of readings for as long as it is held.
-- ---------------------------------------------------------------------------

local sample = { at = nil, thrusters = nil, props = nil, count = 0 }

-- Recipients waiting for a FRESH status. A status_request is a request for
-- data, so it is answered from a new sample rather than from the cache --
-- ionsweep and axisresponse command a power and then read it back, and a
-- cached averagePower would hand them the value from BEFORE their own command.
-- It costs no more than the old code did: the same ~250 ms read, on a
-- coroutine that is not listening for commands.
local pendingStatus = {}

local function refreshSample()
    local at = os.epoch("utc")
    local okThrusters, thrusterReading = pcall(thrusters.telemetry)
    local okProps, propReading = pcall(props.telemetry)

    if not okThrusters then
        recordFault("SAMPLE_THRUSTERS: " .. tostring(thrusterReading))
    end
    if not okProps then
        recordFault("SAMPLE_PROPS: " .. tostring(propReading))
    end

    -- A failed read keeps the PREVIOUS reading rather than publishing nil.
    -- Absent keys leave the FCS's stored pod state intact (banks.acceptStatus
    -- copies keys over), so nil-ing a half would silently freeze half the
    -- telemetry with no way to tell. sampleAgeMs is what reveals a stuck
    -- sampler, and it only works if `at` advances honestly.
    sample = {
        at = at,
        thrusters = okThrusters and thrusterReading or sample.thrusters,
        props = okProps and propReading or sample.props,
        count = sample.count + 1,
        healthy = okThrusters and okProps,
    }
end

local function statusMessage(messageType)
    return protocol.message(messageType or "status", payload.status(messageType, {
        sample = sample,
        state = state,
        config = config,
        computerId = os.getComputerID(),
        modemName = wirelessModem,
        modemWireless = modemWireless,
        now = os.epoch("utc"),
    }))
end

local function reply(recipient, messageType)
    rednet.send(recipient, statusMessage(messageType), config.protocol)
    state.repliesSent = state.repliesSent + 1
end

-- Acknowledge without sweeping the thrusters.
--
-- statusMessage() calls thrusters.telemetry(), which is 32 devices x 5 getters
-- -- five rounds of main-thread tasks, ~250 ms. Paying that on every command
-- ack means a pod driven at any real rate falls behind, state.lastCommandAt
-- goes stale, and watchdogLoop disarms the bank on wall-clock even though the
-- commands are arriving. An ion characterisation run logged 79 consecutive
-- COMMAND_TIMEOUT faults that way and never got power off zero.
--
-- Deliberately omits `prop` and the thruster fields rather than sending
-- partial ones: banks.acceptStatus copies message keys over the stored pod
-- table, so a truncated `prop` here would wipe the thrust readings a sweep is
-- collecting. Absent keys leave the last full status intact.
local function lightReply(recipient, messageType)
    rednet.send(recipient, protocol.message(messageType, {
        corner = config.corner,
        hostname = config.hostname,
        armed = state.armed,
        currentPower = state.currentPower,
        podComputerId = os.getComputerID(),
        lastCommandAt = state.lastCommandAt,
        light = true,
    }), config.protocol)
    state.repliesSent = state.repliesSent + 1
end

-- Decline out loud. A silent drop is indistinguishable from a lost packet, and
-- that ambiguity has now caused two wrong diagnoses: the FCS saw "no reply
-- within 1000 ms" and could not tell whether the radio ate the command or the
-- pod refused it. Carries `rejected` so the sender learns which.
local function rejectReply(recipient, reason)
    state.commandsRejected = state.commandsRejected + 1
    state.lastReject = reason
    rednet.send(recipient, protocol.message("fault", {
        corner = config.corner,
        hostname = config.hostname,
        armed = state.armed,
        currentPower = state.currentPower,
        podComputerId = os.getComputerID(),
        rejected = reason,
        light = true,
    }), config.protocol)
    state.repliesSent = state.repliesSent + 1
end

-- Split into a CHECK and a COMMIT.
--
-- The old newCommand() did both at once: it advanced lastSequence and returned
-- true, after which the caller could still discard the command (not armed,
-- invalid value) -- burning a sequence number for a command that never ran, and
-- rejecting as a replay anything that arrived behind it. A set_power sent during
-- the disarm window did exactly that, and the arm that followed could be refused
-- on sequence grounds.
--
-- Now a sequence is only consumed when the command is actually applied.
local function isNewCommand(message)
    if type(message.session) ~= "string" then
        return false, "no_session"
    end
    -- A new session resets the counter, so it is always fresh.
    if message.session ~= state.session then
        return true
    end
    if type(message.sequence) ~= "number" then
        return false, "no_sequence"
    end
    if message.sequence <= state.lastSequence then
        return false, "replay"
    end
    return true
end

local function acceptCommand(message)
    if message.session ~= state.session then
        state.session = message.session
        state.lastSequence = -1
    end
    state.lastSequence = message.sequence
    state.commandsApplied = state.commandsApplied + 1
end

local function networkLoop()
    -- Receipt and hardware application deliberately run in separate coroutines.
    -- A peripheral setter may yield; it must never delay rednet receipt or make
    -- watchdog freshness depend on actuator latency.
    local pendingPower = nil

    local function applyPowerLoop()
        while true do
            os.pullEvent("pod_apply_power")
            while pendingPower do
                local pending = pendingPower
                pendingPower = nil

                -- A disarm that arrives while an apply is pending wins. Do not
                -- re-energize from a command accepted before that disarm.
                if state.armed then
                    local ok, applied = pcall(thrusters.applyCommand, pending.power)
                    if ok then
                        if state.armed and state.powerSession == pending.powerSession
                            and not pendingPower then
                            state.currentPower = applied
                            state.lastPowerAppliedAt = os.epoch("utc")
                            state.powerApplications = (state.powerApplications or 0) + 1
                        elseif not pendingPower then
                            -- The apply completed after a disarm/re-arm or after
                            -- newer receipt was superseded. Reassert fallback
                            -- rather than leaving stale hardware power live.
                            state.currentPower = thrusters.applyExact(config.fallbackPower)
                        end
                    else
                        recordFault("SET_POWER: " .. tostring(applied))
                        state.armed = false
                        pendingPower = nil
                        state.currentPower = thrusters.applyExact(config.fallbackPower)
                        reply(pending.senderId, "fault")
                    end
                end
            end
        end
    end

    local function receiveLoop()
        while true do
        local senderId, message = rednet.receive(config.protocol)
        -- COUNTED BEFORE ANY JUDGEMENT. This is the pod's own answer to "did
        -- it arrive", and it is the only place that answer exists.
        state.received = state.received + 1
        local valid, why = protocol.validate(message)
        if not valid then
            state.invalid = state.invalid + 1
            state.lastInvalid = why
        end
        if valid then
            local trusted = resolveMain()
            local addressedHere = trusted and senderId == trusted
                and (not message.corner or message.corner == config.corner)
            if not addressedHere then
                state.untrusted = state.untrusted + 1
            end
            if addressedHere then
                if message.type == "ping" or message.type == "status_request" then
                    state.nonCommand = state.nonCommand + 1
                end
                if message.type == "ping" then
                    -- Liveness, not data. Answered immediately from the cache:
                    -- making a caller wait a sample for "are you there" would
                    -- be the wrong trade, and the cheap scalars in it (armed,
                    -- currentPower) are live regardless.
                    reply(senderId, "status")

                elseif message.type == "status_request" then
                    -- A request for DATA. Handed to the sampler, which takes a
                    -- fresh reading and answers. networkLoop does no peripheral
                    -- work here -- doing it inline is what made the pod deaf
                    -- for ~250 ms per poll and cost 2.5-5% of all commands.
                    pendingStatus[#pendingStatus + 1] = senderId
                    os.queueEvent("pod_sample_request")

                elseif message.type == "arm" then
                    state.commandsSeen = state.commandsSeen + 1
                    local fresh, why = isNewCommand(message)
                    if not fresh then
                        rejectReply(senderId, why)
                    else
                        acceptCommand(message)
                        if not state.armed then
                            state.powerSession = (state.powerSession or 0) + 1
                        end
                        state.armed = true
                        -- Refreshed even when already armed: a repeated arm is a
                        -- legitimate keepalive against watchdogLoop.
                        state.lastCommandAt = os.epoch("utc")
                        lightReply(senderId, "ack")
                    end

                elseif message.type == "set_power" then
                    state.commandsSeen = state.commandsSeen + 1
                    local fresh, why = isNewCommand(message)
                    if not fresh then
                        rejectReply(senderId, why)
                    elseif not state.armed then
                        rejectReply(senderId, "not_armed")
                    elseif not protocol.validPower(message.power) then
                        rejectReply(senderId, "bad_power")
                    else
                        -- Ack means valid receipt, not hardware completion. Keep
                        -- the newest setpoint only: it is the only one worth
                        -- applying after a yielding peripheral operation returns.
                        local receivedAt = os.epoch("utc")
                        acceptCommand(message)
                        state.lastCommandAt = receivedAt
                        pendingPower = {
                            power = message.power,
                            senderId = senderId,
                            receivedAt = receivedAt,
                            powerSession = state.powerSession or 0,
                        }
                        os.queueEvent("pod_apply_power")
                        lightReply(senderId, "ack")
                    end

                elseif message.type == "set_rpm" then
                    -- No arm gate and no watchdog: propeller RPM is set-and-hold.
                    state.commandsSeen = state.commandsSeen + 1
                    local fresh, why = isNewCommand(message)
                    if not fresh then
                        rejectReply(senderId, why)
                    elseif not protocol.validPower(message.rpm) then
                        rejectReply(senderId, "bad_rpm")
                    else
                        local ok, applied = pcall(props.setRpm, message.rpm)
                        if ok then
                            acceptCommand(message)
                            state.lastPropRpm = applied
                            lightReply(senderId, "ack")
                        else
                            recordFault("SET_RPM: " .. tostring(applied))
                            reply(senderId, "fault")
                        end
                    end

                elseif message.type == "set_tilt" then
                    -- Thrust vectoring. Like set_rpm this has NO arm gate and
                    -- NO watchdog, and for the same reason: a tilt is a trim,
                    -- and snapping it back to neutral on a dropped packet
                    -- would inject exactly the disturbance it exists to
                    -- remove. It is set-and-hold.
                    --
                    -- props.setTilt clamps to +/-15 degrees. A tilt costs
                    -- vertical thrust as cos(angle) -- 15 degrees sheds 3.4%
                    -- of that corner's lift -- so the clamp is a lift budget,
                    -- not just a sanity check.
                    state.commandsSeen = state.commandsSeen + 1
                    local fresh, why = isNewCommand(message)
                    if not fresh then
                        rejectReply(senderId, why)
                    elseif not protocol.validPower(message.angle) then
                        rejectReply(senderId, "bad_tilt")
                    else
                        local ok, applied = pcall(props.setTilt,
                            message.angle, message.azimuth, message.bearing,
                            message.mirror)
                        if ok then
                            acceptCommand(message)
                            state.lastTilt = applied and applied.angle
                            state.lastTiltAzimuth = applied and applied.azimuth
                            -- The half this used to throw away.
                            noteTiltResult(applied)
                            lightReply(senderId, "ack")
                        else
                            recordFault("SET_TILT: " .. tostring(applied))
                            reply(senderId, "fault")
                        end
                    end

                elseif message.type == "clear_tilt" then
                    state.commandsSeen = state.commandsSeen + 1
                    local fresh, why = isNewCommand(message)
                    if not fresh then
                        rejectReply(senderId, why)
                    else
                        local ok, err = pcall(props.clearTilt, message.bearing)
                        if ok then
                            acceptCommand(message)
                            state.lastTilt = nil
                            lightReply(senderId, "ack")
                        else
                            recordFault("CLEAR_TILT: " .. tostring(err))
                            reply(senderId, "fault")
                        end
                    end

                elseif message.type == "disarm" then
                    state.commandsSeen = state.commandsSeen + 1
                    -- Never gated on sequence. Disarm is the safe direction, and
                    -- refusing one as a replay would leave the banks live.
                    acceptCommand(message)
                    state.armed = false
                    pendingPower = nil
                    state.currentPower = thrusters.applyExact(config.fallbackPower)
                    lightReply(senderId, "ack")
                end
            end
        end
    end
    end

    parallel.waitForAll(receiveLoop, applyPowerLoop)
end

local function watchdogLoop()
    while true do
        local now = os.epoch("utc")
        if state.armed and state.lastCommandAt and now - state.lastCommandAt > config.commandTimeoutMs then
            -- commsLossPower, NOT fallbackPower. This is the one path that
            -- means "we were flying and the link dropped", and it is the only
            -- place the distinction matters: every other fallback site (boot,
            -- disarm, apply failure, exit) means "everything is off" and must
            -- stay at zero.
            --
            -- Note the bank still DISARMS. It holds thrust while disarmed, so
            -- anything that reasons about live lift must check currentPower,
            -- not armed -- see the guard in fcs/reboot.lua.
            state.armed = false
            state.currentPower = thrusters.applyExact(config.commsLossPower)
            recordFault("COMMAND_TIMEOUT")
        end
        sleep(0.05)
    end
end

-- THE CENTRAL DATA LOOP.
--
-- Samples the hardware, publishes the sample, sends it to the FCS, and answers
-- anyone who asked for a fresh one. It is the only coroutine that touches a
-- peripheral for reading, so it is the only one that can go deaf -- and it
-- listens for nothing, so being deaf costs nothing. Run 3 measured exactly
-- that: this loop was building a payload 20% of the time and networkLoop lost
-- 0 of 80 commands.
local function samplerLoop()
    while true do
        refreshSample()

        local mainId = resolveMain()
        if mainId then
            rednet.send(mainId, statusMessage("status"), config.protocol)
            state.telemetrySends = state.telemetrySends + 1
            state.lastSendAt = os.epoch("utc")
        end

        -- Drained AFTER the sample, and coalesced: four requests arriving
        -- together are served by one read rather than four. Anything that
        -- arrived DURING the sample is served here too -- it is at most a few
        -- hundred ms old, and fresher than the reply the old code sent.
        if #pendingStatus > 0 then
            -- Safe without a lock: coroutines here are cooperative, and there
            -- is no yield between reading the queue and replacing it, so
            -- networkLoop cannot append to a list that is about to be dropped.
            local waiting = pendingStatus
            pendingStatus = {}
            for _, recipient in ipairs(waiting) do
                reply(recipient, "status")
            end
        end

        -- Wake on the period OR on a request, whichever comes first, so a
        -- status_request is not held for up to a whole telemetry period.
        -- Pulling unfiltered is deliberate: a filtered wait would drop the
        -- other event, and this loop must not care which one it got.
        -- The QUEUE is the state; the event is only a wakeup. A request that
        -- lands while this loop is sampling or replying has its event dropped
        -- (that work yields on task_complete, and parallel discards what does
        -- not match) -- so the loop condition reads the queue rather than
        -- trusting the event to arrive. Without that, a request landing in
        -- that narrow window waits a full telemetry period instead of ~250 ms.
        local timer = os.startTimer(config.telemetryPeriodSeconds)
        while #pendingStatus == 0 do
            local event, id = os.pullEvent()
            if event == "pod_sample_request" then
                break
            elseif event == "timer" and id == timer then
                break
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- THE QUIET FLAG: /pod/quiet
--
-- displayLoop is the only loop on this pod that does UNYIELDING work. The
-- sampler's ~160 Sable getters are main-thread peripheral calls and every one
-- of them yields, so networkLoop runs between them. term.* and fs.* do not
-- yield at all -- so everything from one sleep(0.25) to the next is a single
-- uninterruptible block, and every eighth pass that block contains a fifty
-- field synchronous write of heartbeat.txt.
--
-- WHAT THAT PREDICTS, and why it is worth a flag rather than an argument.
-- Two linkwatch flights measured a COMMAND_TIMEOUT per corner every 3.5 s and
-- every 2.7 s. This loop's heartbeat period is 8 x 0.25 s ~= 2 s. The pod's
-- watchdog fires on 750 ms of wall-clock silence whether the commands are lost
-- or merely QUEUED behind a block -- and the pods' last_reject is `not_armed`,
-- which is what a watchdog disarm followed by the next set_power looks like.
--
-- A deaf window of fixed duration at fixed frequency also does not care how
-- fast the FCS sends, and halving the send rate did NOT reduce the timeout
-- rate -- it rose slightly, 0.288/s to 0.376/s. Load-induced loss cannot do
-- that; a fixed periodic block can.
--
-- So: an A/B, not a rewrite. Touch /pod/quiet and this loop stops rendering
-- and stops writing. Delete it and the pod is exactly what it was. Nothing
-- else in this file changes, so the experiment has ONE variable.
--
-- A MARKER FILE RATHER THAN A CONFIG FIELD, deliberately: all four pods'
-- config.lua differ from each other and from the repo -- each carries its own
-- corner and hostname -- so pod/config.lua is as undeployable as fcs/config.lua
-- and must never be overwritten to set a flag.
-- ---------------------------------------------------------------------------

local quiet = false
do
    local ok, exists = pcall(fs.exists, "/pod/quiet")
    quiet = (ok and exists) and true or false
end

-- Extracted from displayLoop so the quiet path can write exactly ONE heartbeat
-- at boot -- proof the flag took, without any periodic work to contaminate the
-- measurement. A stale heartbeat.txt from a previous run reads as a live one,
-- so "wrote nothing at all" would be indistinguishable from "flag ignored".
local function writeHeartbeat()
    writeReport("/pod/heartbeat.txt", {
        "utc_ms=" .. tostring(os.epoch("utc")),
        -- WHETHER /pod/quiet WAS PRESENT AT BOOT. Read this before trusting an
        -- A/B: a quiet pod writes exactly one heartbeat and then stops, so a
        -- stale file from the previous run is indistinguishable from a flag
        -- that was ignored -- except by this field and the utc_ms beside it.
        "quiet=" .. tostring(quiet),
        "computer_id=" .. tostring(os.getComputerID()),
        "corner=" .. tostring(config.corner),
        "hostname=" .. tostring(config.hostname),
        "armed=" .. tostring(state.armed),
        "current_power=" .. tostring(state.currentPower),
        "trusted_main_id=" .. tostring(state.trustedMainId),
        "booted_at=" .. tostring(state.bootedAt),
        "commands_seen=" .. tostring(state.commandsSeen),
        "commands_applied=" .. tostring(state.commandsApplied),
        "commands_rejected=" .. tostring(state.commandsRejected),
        "last_reject=" .. tostring(state.lastReject),
        "last_tilt=" .. tostring(state.lastTilt),
        "tilt_bearings=" .. tostring(state.lastTiltBearings),
        "tilt_accepted=" .. tostring(state.lastTiltAccepted),
        "last_tilt_error=" .. tostring(state.lastTiltError),
        "untrusted_msgs=" .. tostring(state.untrusted),
        "modem=" .. tostring(wirelessModem),
        "modem_wireless=" .. tostring(modemWireless),
        "transport=" .. (modemWireless == false and "WIRED"
            or modemWireless == true and "wireless" or "unknown"),
        -- EVERY modem this pod has, so which sides exist is a reading
        -- rather than something to be looked up on the hull.
        -- WHICH MODEMS THIS POD ACTUALLY HAS OPEN. rednet's open set is
        -- per COMPUTER, not per tab, so any other tab calling
        -- rednet.open puts this pod on a transport main.lua never
        -- chose -- and that silently destroys the wired/wireless A/B.
        -- Reported rather than reasoned about.
        "modems_open=" .. (function()
            local parts = {}
            for _, entry in ipairs(modemsPresent()) do
                if rednet.isOpen(entry.name) then
                    parts[#parts + 1] = entry.name
                end
            end
            return #parts > 0 and table.concat(parts, ",") or "none"
        end)(),
        "modems_present=" .. (function()
            local parts = {}
            for _, entry in ipairs(modemsPresent()) do
                parts[#parts + 1] = entry.name .. ":"
                    .. (entry.wireless == false and "wired"
                        or entry.wireless == true and "wireless" or "?")
            end
            return #parts > 0 and table.concat(parts, ",") or "none"
        end)(),
        "rednet_open=" .. tostring(rednet.isOpen(wirelessModem)),
        "telemetry_sends=" .. tostring(state.telemetrySends),
        "replies_sent=" .. tostring(state.repliesSent),
        "last_send_at=" .. tostring(state.lastSendAt),
        "thrusters=" .. tostring(#thrusters.devices),
        "prop_controller=" .. tostring(props.controllerName),
        "prop_bearings=" .. tostring(props.bearingName),
        "sample_at=" .. tostring(sample.at),
        "sample_age_ms=" .. tostring(sample.at and (os.epoch("utc") - sample.at)),
        "sample_count=" .. tostring(sample.count),
        "sample_healthy=" .. tostring(sample.healthy),
        "pending_status=" .. tostring(#pendingStatus),
        -- Read from the SAMPLE, not from the hardware. This used to
        -- call props.telemetry() twice per heartbeat, which is a
        -- second sampler nobody declared and a second answer that
        -- could disagree with the one being transmitted.
        "prop_diag=" .. (function()
            local t = sample.props or {}
            return string.format(
                "bearings=%d assembled=%s thrust=%s rot=%s angular=%s kinetic=%s airflow=%s sail=%s",
                t.bearingCount or 0, tostring(t.bearingsAssembled),
                tostring(t.thrust), tostring(t.bearingRpm),
                tostring(t.bearingAngularSpeed), tostring(t.bearingKineticSpeed),
                tostring(t.airflow), tostring(t.sailPower))
        end)(),
        "prop_per_bearing=" .. (function()
            local t, out = sample.props or {}, {}
            for i, b in ipairs(t.perBearing or {}) do
                out[#out + 1] = string.format(
                    "[%d %s thrust=%s asm=%s hand=%s vec=%s,%s,%s]",
                    i, tostring(b.name), tostring(b.thrust), tostring(b.assembled),
                    tostring(b.handedness), tostring(b.vx), tostring(b.vy), tostring(b.vz))
            end
            return table.concat(out, " ")
        end)(),
        "faults=" .. table.concat(state.faults, " | "),
    })
end

local function displayLoop()
    -- QUIET: one heartbeat so the flag is verifiable, then no terminal work
    -- and no file writes for the rest of the run. The coroutine stays in the
    -- parallel set -- removing it would change the scheduler's shape, which is
    -- a second variable.
    if quiet then
        writeHeartbeat()
        while true do
            sleep(5)
        end
    end

    while true do
        term.clear()
        term.setCursorPos(1, 1)
        print("ION POD " .. config.corner)
        print("Computer: " .. os.getComputerID())
        print("Host: " .. config.hostname)
        print("Mode: " .. (state.armed and "ARMED" or "FALLBACK"))
        print(string.format("Power: %.3f", state.currentPower))
        print(string.format("Fallback: %.3f", config.fallbackPower))
        print("Main: " .. tostring(state.trustedMainId or "searching"))
        print("Prop: " .. (props.controller
            and string.format("%s rpm", tostring(state.lastPropRpm or "?"))
            or "none"))
        print("Thrusters: " .. tostring(#thrusters.devices))
        print("Faults: " .. tostring(#state.faults))
        print("Sent: " .. tostring(state.telemetrySends))

        beat = beat + 1
        if beat % 8 == 1 then
            writeHeartbeat()
        end

        sleep(0.25)
    end
end

-- One sample before anything can be asked for one. Without it the first
-- replies carry no thruster or prop fields at all, and the FCS would show a
-- pod that is online with no hardware behind it for the first second.
refreshSample()

local ok, reason = pcall(function()
    parallel.waitForAll(networkLoop, watchdogLoop, samplerLoop, displayLoop)
end)

-- waitForAll returning without an error means a loop exited on its own, which
-- is just as broken as a crash and otherwise leaves no trace at all.
writeReport("/pod/last_error.txt", {
    "utc_ms=" .. tostring(os.epoch("utc")),
    "computer_id=" .. tostring(os.getComputerID()),
    "corner=" .. tostring(config.corner),
    "outcome=" .. (ok and "loops returned without error" or "error"),
    "reason=" .. tostring(reason),
    "telemetry_sends=" .. tostring(state.telemetrySends),
    "replies_sent=" .. tostring(state.repliesSent),
    "armed=" .. tostring(state.armed),
    "faults=" .. table.concat(state.faults, " | "),
})

-- Any program error or termination attempts to restore the local fallback.
pcall(thrusters.applyExact, config.fallbackPower)
pcall(rednet.unhost, config.protocol, config.hostname)
if not ok then
    error(reason, 0)
end
