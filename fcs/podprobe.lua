-- Why one pod stops answering: a comms diagnostic for "no reply from the FR
-- pod within 1000 ms".
--
--   /fcs/podprobe.lua            census + 10 ack round trips per corner
--   /fcs/podprobe.lua 25         25 round trips per corner
--   /fcs/podprobe.lua --force    run even with a bank armed or holding thrust
--
-- FR has needed two attempts on nearly every command for a session and now
-- fails outright. That symptom has three structurally different causes, and
-- they need OPPOSITE fixes, so guessing is expensive:
--
--   1. A GHOST HOST. Another computer still hosts ENG-FR (an old pod that was
--      replaced, or a second copy left running). rednet.lookup returns
--      whichever answers first, so a fresh program is a coin flip -- and once
--      it caches the dead one, EVERY command in that run times out, which is
--      exactly "intermittent for a session, then outright". Worse, banks.lua
--      then rejects the live pod's telemetry on senderMismatch, so the pod
--      looks silent while it is broadcasting happily.
--      Fix: unhost the ghost. Raising the timeout would do nothing.
--
--   2. A SLOW POD. statusMessage() is 32 thrusters x 5 getters, ~250 ms of
--      main-thread work, and the pod's networkLoop is single-threaded. A
--      command that lands behind one of those waits it out. If the ack simply
--      arrives at 1100 ms, REPLY_TIMEOUT_MS is the bug.
--      Fix: raise the timeout (or stop blocking on acks in loops).
--
--   3. REAL PACKET LOSS. Neither of the above: the command never lands.
--      Fix: retry policy, and look at range/chunk loading.
--
-- This tells them apart, and it does it without flying:
--
--   RESOLUTION  what rednet.lookup hands us per corner
--   CENSUS      who is ACTUALLY transmitting as that corner, passively
--   ACK         round-trip time for the real failing command path, set_rpm
--
-- A ghost shows as census id ~= lookup id. A slow pod shows as one id and long
-- latencies. Loss shows as one id, short latencies, and timeouts anyway.
--
-- SAFETY: the ack test sends each corner ITS OWN current target RPM -- a real
-- set_rpm down the same path the flight loop uses, but a no-op at the
-- propeller. It refuses to run a corner whose RPM it has not heard, because
-- guessing zero there is the documented way to cut the props in the air.

if package then
    package.path = "/?.lua;/?/init.lua;" .. package.path
end

local config = require("fcs.config")
local network = require("fcs.network")
local protocol = require("fcs.protocol")

local CORNERS = { "FL", "FR", "RL", "RR" }
local CENSUS_MS = 6000

-- Deliberately LONGER than actuators.REPLY_TIMEOUT_MS. The question this tool
-- answers is "how late is the ack", and a 1000 ms window cannot tell 1100 ms
-- apart from never.
local ACK_TIMEOUT_MS = 4000

local args = { ... }
local force, pings = false, 10
for _, arg in ipairs(args) do
    if arg == "--force" then
        force = true
    elseif tonumber(arg) then
        pings = math.floor(tonumber(arg))
    end
end

local lines = {}

local function note(text)
    lines[#lines + 1] = text
    print(text)
end

local function save()
    local ok, file = pcall(fs.open, "/fcs/podprobe.txt", "w")
    if ok and file then
        file.write(table.concat(lines, "\n"))
        file.close()
        print("")
        print("Saved to /fcs/podprobe.txt")
    end
end

-- ---------------------------------------------------------------------------
-- Raw receive. NOT banks.handle -- the whole point is to see the messages
-- banks throws away. A senderMismatch drop is invisible from inside banks, and
-- it is the signature of cause 1.
-- ---------------------------------------------------------------------------

local function receiveUntil(deadline, onMessage)
    while true do
        local remaining = deadline - os.epoch("utc")
        if remaining <= 0 then
            return
        end
        local senderId, message = rednet.receive(config.wireless.protocol,
            remaining / 1000)
        if senderId and type(message) == "table" then
            if onMessage(senderId, message) then
                return
            end
        end
    end
end

local function percentile(sorted, fraction)
    if #sorted == 0 then
        return nil
    end
    local index = math.ceil(fraction * #sorted)
    if index < 1 then index = 1 end
    if index > #sorted then index = #sorted end
    return sorted[index]
end

-- ---------------------------------------------------------------------------
-- Phase 1: resolution
-- ---------------------------------------------------------------------------

local function resolve()
    note("RESOLUTION -- what the sender would address")
    note("")
    local resolved = {}
    for _, corner in ipairs(CORNERS) do
        local hostname = config.wireless.podHostnames[corner]
        local pinned = config.wireless.podIds[corner]
        local found
        if pinned then
            found = pinned
        else
            found = rednet.lookup(config.wireless.protocol, hostname)
        end
        resolved[corner] = found
        note(string.format("  %-3s %-7s pinned=%-6s lookup=%s",
            corner, hostname, tostring(pinned), tostring(found)))
    end
    note("")
    return resolved
end

-- ---------------------------------------------------------------------------
-- Phase 2: passive census
--
-- Pods send telemetry DIRECTED to the main they resolved, every
-- telemetryPeriodSeconds. So listening says nothing about our sender and
-- everything about who is alive and claiming each corner -- which is the one
-- fact rednet.lookup cannot be trusted for.
-- ---------------------------------------------------------------------------

local function census()
    note(string.format("CENSUS -- who is transmitting, over %.0f s", CENSUS_MS / 1000))
    note("")

    local seen = {}
    for _, corner in ipairs(CORNERS) do seen[corner] = {} end
    local strangers, total = {}, 0

    receiveUntil(os.epoch("utc") + CENSUS_MS, function(senderId, message)
        total = total + 1
        local corner = message.corner
        if not seen[corner] then
            strangers[#strangers + 1] = string.format(
                "id %s claimed corner %s (hostname %s)",
                tostring(senderId), tostring(corner), tostring(message.hostname))
            return false
        end
        local entry = seen[corner][senderId]
        if not entry then
            entry = { count = 0, first = os.epoch("utc"), hostname = message.hostname }
            seen[corner][senderId] = entry
        end
        entry.count = entry.count + 1
        entry.last = os.epoch("utc")
        entry.hostname = message.hostname
        entry.podComputerId = message.podComputerId
        local prop = message.prop
        if type(prop) == "table" and type(prop.targetRpm) == "number" then
            entry.targetRpm = prop.targetRpm
        end
        return false
    end)

    note(string.format("  %d messages on %s", total, config.wireless.protocol))
    note("")

    local live = {}
    for _, corner in ipairs(CORNERS) do
        local ids = {}
        for senderId in pairs(seen[corner]) do ids[#ids + 1] = senderId end
        table.sort(ids)

        if #ids == 0 then
            note(string.format("  %-3s SILENT -- nothing transmitted as this corner", corner))
        end
        for _, senderId in ipairs(ids) do
            local entry = seen[corner][senderId]
            live[corner] = live[corner] or {}
            live[corner][#live[corner] + 1] = { id = senderId, entry = entry }
            note(string.format(
                "  %-3s id=%-4s %-7s %2d msgs (%.0f ms apart) reported_id=%s rpm=%s",
                corner, tostring(senderId), tostring(entry.hostname), entry.count,
                entry.count > 1 and (entry.last - entry.first) / (entry.count - 1) or 0,
                tostring(entry.podComputerId), tostring(entry.targetRpm)))
        end
        if #ids > 1 then
            note(string.format("  %-3s ** %d COMPUTERS ARE TRANSMITTING AS %s **",
                corner, #ids, corner))
        end
    end

    for _, stranger in ipairs(strangers) do
        note("  STRANGER: " .. stranger)
    end
    note("")
    return live
end

-- ---------------------------------------------------------------------------
-- Phase 3: ack round trips down the real command path
-- ---------------------------------------------------------------------------

local session = "podprobe:" .. tostring(os.getComputerID()) .. ":"
    .. tostring(os.epoch("utc"))
local sequence = 0

local function ackRoundTrip(corner, podId, rpm)
    sequence = sequence + 1
    local sentAt = os.epoch("utc")
    rednet.send(podId, protocol.message("set_rpm", {
        corner = corner,
        rpm = rpm,
        sequence = sequence,
        session = session,
    }), config.wireless.protocol)

    local result = nil
    receiveUntil(sentAt + ACK_TIMEOUT_MS, function(senderId, message)
        -- Only an ack or a fault answers a command. Unprompted telemetry
        -- arrives on the same wire and is NOT a reply -- reading pod.type is
        -- the trap documented in banks.lua, and it reads as a phantom 200 ms
        -- round trip here.
        if message.corner == corner
            and (message.type == "ack" or message.type == "fault") then
            result = {
                latency = os.epoch("utc") - sentAt,
                senderId = senderId,
                type = message.type,
                rejected = message.rejected,
            }
            return true
        end
        return false
    end)
    return result
end

local function ackTest(corner, podId, rpm)
    local latencies, timeouts, faults, wrongSender = {}, 0, 0, 0
    local firstFault = nil

    for _ = 1, pings do
        local reply = ackRoundTrip(corner, podId, rpm)
        if not reply then
            timeouts = timeouts + 1
        else
            latencies[#latencies + 1] = reply.latency
            if reply.senderId ~= podId then wrongSender = wrongSender + 1 end
            if reply.type == "fault" then
                faults = faults + 1
                firstFault = firstFault or tostring(reply.rejected)
            end
        end
        sleep(0.25)
    end

    table.sort(latencies)
    return {
        corner = corner,
        podId = podId,
        rpm = rpm,
        latencies = latencies,
        timeouts = timeouts,
        faults = faults,
        firstFault = firstFault,
        wrongSender = wrongSender,
        median = percentile(latencies, 0.5),
        p95 = percentile(latencies, 0.95),
        worst = latencies[#latencies],
    }
end

-- ---------------------------------------------------------------------------
-- Verdict
-- ---------------------------------------------------------------------------

local function verdict(corner, resolvedId, transmitters, result)
    local ids = transmitters or {}

    if #ids == 0 then
        note(string.format("  %-3s NOT TRANSMITTING. The pod is down, out of range, or"
            .. " never resolved FCS-MAIN.", corner))
        return
    end

    if #ids > 1 then
        note(string.format("  %-3s GHOST HOST. %d computers transmit as %s. Stop the"
            .. " duplicate; a longer timeout cannot help.", corner, #ids, corner))
        return
    end

    local liveId = ids[1].id
    if resolvedId ~= liveId then
        note(string.format("  %-3s GHOST HOST. lookup says %s, the live pod is %s."
            .. " Commands are addressed to a computer that is not answering,"
            .. " and banks rejects the real pod on senderMismatch.",
            corner, tostring(resolvedId), tostring(liveId)))
        return
    end

    if not result then
        note(string.format("  %-3s not ack-tested (see above)", corner))
        return
    end

    if result.faults > 0 then
        note(string.format("  %-3s REPLYING WITH FAULTS (%d/%d, first: %s). The link is"
            .. " fine; the pod is refusing the command.",
            corner, result.faults, pings, tostring(result.firstFault)))
        return
    end

    if #result.latencies == 0 then
        note(string.format("  %-3s TOTAL LOSS. Right id, transmitting, and %d/%d"
            .. " commands went unanswered for %d ms.",
            corner, result.timeouts, pings, ACK_TIMEOUT_MS))
        return
    end

    local overRun = 0
    for _, latency in ipairs(result.latencies) do
        if latency > 1000 then overRun = overRun + 1 end
    end

    if overRun > 0 or result.timeouts > 0 then
        note(string.format("  %-3s SLOW POD. %d/%d acks landed after the 1000 ms"
            .. " actuators allows (worst %d ms), %d never landed. The commands"
            .. " ARE being applied; the timeout is what fails.",
            corner, overRun, pings, result.worst or -1, result.timeouts))
        return
    end

    note(string.format("  %-3s HEALTHY. %d/%d acks, median %d ms, worst %d ms.",
        corner, #result.latencies, pings, result.median, result.worst))
end

-- ---------------------------------------------------------------------------

local function main()
    term.clear()
    term.setCursorPos(1, 1)

    note("POD COMMS PROBE")
    note("utc_ms=" .. tostring(os.epoch("utc"))
        .. "  computer=" .. tostring(os.getComputerID()))
    note("")

    local opened, reason = network.open()
    if not opened then
        note("NO NETWORK: " .. tostring(reason))
        save()
        return
    end
    note("modem=" .. tostring(network.openedModem)
        .. "  hosting=" .. config.wireless.mainHostname)
    note("")

    local resolved = resolve()
    local live = census()

    note(string.format("ACK ROUND TRIPS -- %d x set_rpm per corner, %d ms window",
        pings, ACK_TIMEOUT_MS))
    note("")

    local results = {}
    for _, corner in ipairs(CORNERS) do
        local transmitters = live[corner]
        local entry = transmitters and transmitters[1] and transmitters[1].entry
        local rpm = entry and entry.targetRpm
        local target = resolved[corner]

        -- Echo the corner's OWN rpm. A pod whose rpm never arrived is not
        -- ack-tested: sending 0 to a corner that might be lifting is how this
        -- craft ends a run on its side.
        if not target then
            note(string.format("  %-3s skipped: nothing to address", corner))
        elseif not rpm then
            note(string.format("  %-3s skipped: current RPM unknown, refusing to"
                .. " guess (would risk cutting a live propeller)", corner))
        elseif rpm ~= 0 and not force then
            note(string.format("  %-3s skipped: propeller is turning at %s RPM."
                .. " Ground the craft, or pass --force to echo it back.",
                corner, tostring(rpm)))
        else
            local result = ackTest(corner, target, rpm)
            results[corner] = result
            note(string.format(
                "  %-3s id=%-4s rpm=%-5s %d/%d acks  median=%-5s p95=%-5s worst=%-5s"
                .. " timeouts=%d faults=%d",
                corner, tostring(target), tostring(rpm), #result.latencies, pings,
                tostring(result.median), tostring(result.p95), tostring(result.worst),
                result.timeouts, result.faults))
            if result.wrongSender > 0 then
                note(string.format("  %-3s ** %d replies came from a DIFFERENT"
                    .. " computer than the one commanded **",
                    corner, result.wrongSender))
            end
        end
    end

    note("")
    note("VERDICT")
    note("")
    for _, corner in ipairs(CORNERS) do
        verdict(corner, resolved[corner], live[corner], results[corner])
    end

    save()
end

main()
