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

local function findWirelessModem()
    if config.wirelessModemName then
        if not peripheral.isPresent(config.wirelessModemName) then
            error("configured wireless modem is missing", 0)
        end
        local modem = peripheral.wrap(config.wirelessModemName)
        if type(modem.isWireless) ~= "function" or not modem.isWireless() then
            error("configured modem is not wireless", 0)
        end
        return config.wirelessModemName
    end

    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "modem") then
            local modem = peripheral.wrap(name)
            if type(modem.isWireless) == "function" and modem.isWireless() then
                return name
            end
        end
    end
    error("no wireless modem is attached", 0)
end

thrusters.load()
thrusters.applyExact(config.fallbackPower)

-- Degrades instead of erroring: a broken prop must not stop the ion bank.
props.load()

local wirelessModem = findWirelessModem()
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
    lastReject = nil,
}

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

local function statusMessage(messageType)
    local telemetry = thrusters.telemetry()
    telemetry.corner = config.corner
    telemetry.hostname = config.hostname
    telemetry.armed = state.armed
    telemetry.currentPower = state.currentPower
    telemetry.fallbackPower = config.fallbackPower
    telemetry.commsLossPower = config.commsLossPower
    telemetry.commandedTilt = state.lastTilt
    telemetry.commandedTiltAzimuth = state.lastTiltAzimuth
    telemetry.lastCommandAt = state.lastCommandAt
    telemetry.podComputerId = os.getComputerID()
    -- Cheap scalars, so the FCS can see where commands went without reading
    -- /pod/heartbeat.txt over SSH.
    telemetry.bootedAt = state.bootedAt
    telemetry.commandsSeen = state.commandsSeen
    telemetry.commandsApplied = state.commandsApplied
    telemetry.commandsRejected = state.commandsRejected
    telemetry.lastReject = state.lastReject
    telemetry.prop = props.telemetry()

    for _, fault in ipairs(state.faults) do
        telemetry.faults[#telemetry.faults + 1] = fault
    end

    return protocol.message(messageType or "status", telemetry)
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
    while true do
        local senderId, message = rednet.receive(config.protocol)
        local valid = protocol.validate(message)
        if valid then
            local trusted = resolveMain()
            local addressedHere = trusted and senderId == trusted
                and (not message.corner or message.corner == config.corner)
            if not addressedHere then
                state.untrusted = state.untrusted + 1
            end
            if addressedHere then
                if message.type == "ping" or message.type == "status_request" then
                    reply(senderId, "status")

                elseif message.type == "arm" then
                    state.commandsSeen = state.commandsSeen + 1
                    local fresh, why = isNewCommand(message)
                    if not fresh then
                        rejectReply(senderId, why)
                    else
                        acceptCommand(message)
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
                        local ok, applied = pcall(thrusters.applyCommand, message.power)
                        if ok then
                            acceptCommand(message)
                            state.currentPower = applied
                            state.lastCommandAt = os.epoch("utc")
                            lightReply(senderId, "ack")
                        else
                            state.faults[#state.faults + 1] = "SET_POWER: " .. tostring(applied)
                            state.armed = false
                            state.currentPower = thrusters.applyExact(config.fallbackPower)
                            reply(senderId, "fault")
                        end
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
                            state.faults[#state.faults + 1] = "SET_RPM: " .. tostring(applied)
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
                            message.angle, message.azimuth, message.bearing)
                        if ok then
                            acceptCommand(message)
                            state.lastTilt = applied and applied.angle
                            state.lastTiltAzimuth = applied and applied.azimuth
                            lightReply(senderId, "ack")
                        else
                            state.faults[#state.faults + 1] = "SET_TILT: " .. tostring(applied)
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
                            state.faults[#state.faults + 1] = "CLEAR_TILT: " .. tostring(err)
                            reply(senderId, "fault")
                        end
                    end

                elseif message.type == "disarm" then
                    state.commandsSeen = state.commandsSeen + 1
                    -- Never gated on sequence. Disarm is the safe direction, and
                    -- refusing one as a replay would leave the banks live.
                    acceptCommand(message)
                    state.armed = false
                    state.currentPower = thrusters.applyExact(config.fallbackPower)
                    lightReply(senderId, "ack")
                end
            end
        end
    end
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
            state.faults[#state.faults + 1] = "COMMAND_TIMEOUT"
        end
        sleep(0.05)
    end
end

local function telemetryLoop()
    while true do
        local mainId = resolveMain()
        if mainId then
            rednet.send(mainId, statusMessage("status"), config.protocol)
            state.telemetrySends = state.telemetrySends + 1
            state.lastSendAt = os.epoch("utc")
        end
        sleep(config.telemetryPeriodSeconds)
    end
end

local function displayLoop()
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
            writeReport("/pod/heartbeat.txt", {
                "utc_ms=" .. tostring(os.epoch("utc")),
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
                "untrusted_msgs=" .. tostring(state.untrusted),
                "wireless_modem=" .. tostring(wirelessModem),
                "rednet_open=" .. tostring(rednet.isOpen(wirelessModem)),
                "telemetry_sends=" .. tostring(state.telemetrySends),
                "replies_sent=" .. tostring(state.repliesSent),
                "last_send_at=" .. tostring(state.lastSendAt),
                "thrusters=" .. tostring(#thrusters.devices),
                "prop_controller=" .. tostring(props.controllerName),
                "prop_bearings=" .. tostring(props.bearingName),
                "prop_diag=" .. (function()
                    local t = props.telemetry()
                    return string.format(
                        "bearings=%d assembled=%s thrust=%s rot=%s angular=%s kinetic=%s airflow=%s sail=%s",
                        t.bearingCount or 0, tostring(t.bearingsAssembled),
                        tostring(t.thrust), tostring(t.bearingRpm),
                        tostring(t.bearingAngularSpeed), tostring(t.bearingKineticSpeed),
                        tostring(t.airflow), tostring(t.sailPower))
                end)(),
                "prop_per_bearing=" .. (function()
                    local t, out = props.telemetry(), {}
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

        sleep(0.25)
    end
end

local ok, reason = pcall(function()
    parallel.waitForAll(networkLoop, watchdogLoop, telemetryLoop, displayLoop)
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
