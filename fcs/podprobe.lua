-- Why a pod stops answering: a comms diagnostic for "no reply from the <corner>
-- pod within 1000 ms".
--
--   /fcs/podprobe.lua            census + 10 ack round trips per corner
--   /fcs/podprobe.lua 25         25 round trips per corner
--   /fcs/podprobe.lua --force    run even with a bank armed or holding thrust
--
-- MEASURED 2026-08-26 (flight-logs/podprobe_result.txt), and it retired the
-- premise this tool was built on: FR IS NOT SPECIAL. All four corners resolve
-- correctly, all four transmit, acks land in ~51 ms -- and 4 of 40 commands
-- went unanswered, spread across FR, RL and RR. RL was the worst, not FR.
-- Whatever made FR look singular for a session, what is here now is a uniform
-- few-percent drop rate.
--
-- The symptom "no reply within 1000 ms" has four structurally different causes
-- and they need OPPOSITE fixes, so guessing is expensive:
--
--   1. A GHOST HOST. Another computer still hosts the corner's hostname (an
--      old pod that was replaced, or a second copy left running).
--      rednet.lookup returns whichever answers first, so a fresh program is a
--      coin flip -- and once it caches the dead one, EVERY command in that run
--      times out. Worse, banks.lua then rejects the live pod's telemetry on
--      senderMismatch, so the pod looks silent while it broadcasts happily.
--      Fix: unhost the ghost. Raising the timeout would do nothing.
--      (Not possible on the live craft while config pins podIds -- lookup is
--      never consulted. It is still checked, because that pin can go stale.)
--
--   2. A SLOW POD. statusMessage() is 32 thrusters x 5 getters, ~250 ms of
--      main-thread work, and the pod's networkLoop is single-threaded. A
--      command landing behind one waits it out. If the ack simply arrives at
--      1100 ms, REPLY_TIMEOUT_MS is the bug.
--      Fix: raise the timeout (or stop blocking on acks in loops).
--
--   3. COMMAND LOSS. The command never reached the pod: its counter did not
--      move, and the actuator did not either.
--      Fix: re-send. Waiting longer cannot help.
--
--   4. ACK LOSS. The command WAS applied and the reply was lost. Identical
--      from the sender's side, opposite in consequence -- a blocking waiter
--      reports failure for a command that succeeded, and a caller that then
--      "recovers" is acting on a false picture of where the actuator is.
--      Fix: confirm from telemetry, not from the ack.
--
-- 3 and 4 are indistinguishable from replies alone, so this reads BOTH SIDES:
-- the pod's own commandsSeen counter, sampled before and after the test.
--
-- This tells all four apart, and it does it without flying:
--
--   RESOLUTION  what the sender would address, pinned or looked up
--   CENSUS      who is ACTUALLY transmitting as that corner, passively
--   ACK         round-trip time for the real failing command path, set_rpm,
--               plus the pod's command counter either side of it
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
        -- The pod's own count of commands it has SEEN. Sampled here and again
        -- after the ack test, it says whether a missing ack means the command
        -- was lost or only the reply was -- which are opposite bugs: one left
        -- the actuator where it was, the other moved it.
        if type(message.commandsSeen) == "number" then
            entry.commandsSeen = message.commandsSeen
        end
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

-- commandsSeen rides only on the FULL status payload; lightReply omits it
-- deliberately, so this waits for ordinary telemetry (~815 ms apart) rather
-- than for a reply.
local function awaitCommandsSeen(corner, podId, timeoutMs)
    local seen = nil
    receiveUntil(os.epoch("utc") + timeoutMs, function(senderId, message)
        if senderId == podId and message.corner == corner
            and type(message.commandsSeen) == "number" then
            seen = message.commandsSeen
            return true
        end
        return false
    end)
    return seen
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

    if overRun > 0 then
        note(string.format("  %-3s SLOW POD. %d/%d acks landed after the 1000 ms"
            .. " actuators allows (worst %d ms), %d never landed. The commands"
            .. " ARE being applied; the timeout is what fails.",
            corner, overRun, pings, result.worst or -1, result.timeouts))
        return
    end

    -- Timeouts with FAST acks are loss, not slowness, and the first version of
    -- this tool called them SLOW POD -- printing "0/10 acks landed after the
    -- 1000 ms allowed (worst 67 ms)", which is self-contradictory and points
    -- at the one fix that cannot help. Raising a 1000 ms timeout does nothing
    -- for a reply that was never sent, and nothing at all for one that lands
    -- in 51 ms.
    if result.timeouts > 0 then
        local applied = result.applied
        if applied == nil then
            note(string.format("  %-3s LOSS, UNATTRIBUTED. %d/%d unanswered, but"
                .. " acks land in %d ms. The pod's command counter never"
                .. " arrived, so it is not known whether the command or the"
                .. " reply was lost.", corner, result.timeouts, pings,
                result.median))
        elseif applied >= pings then
            note(string.format("  %-3s ACK LOSS. All %d commands were APPLIED"
                .. " (counter +%d) and %d replies never arrived. The actuator"
                .. " moved; only the confirmation was lost -- so a blocking"
                .. " waiter fails a command that in fact succeeded.",
                corner, pings, applied, result.timeouts))
        else
            note(string.format("  %-3s COMMAND LOSS. The counter rose by %d of %d:"
                .. " %d command(s) never reached the pod. The actuator did NOT"
                .. " move. Re-send; do not merely wait longer.",
                corner, applied, pings, pings - applied))
        end
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
            local before = entry.commandsSeen
            local result = ackTest(corner, target, rpm)
            results[corner] = result
            -- Both sides of the link, which is the only way to attribute a
            -- missing ack. HANDOFF's rule: sample a counter on each side and
            -- compare, because static reasoning about CC has repeatedly been
            -- wrong here and measurement has not.
            if before and result.timeouts > 0 then
                local after = awaitCommandsSeen(corner, target, 4000)
                if after then
                    result.applied = after - before
                end
            end
            note(string.format(
                "  %-3s id=%-4s rpm=%-5s %d/%d acks  median=%-5s p95=%-5s worst=%-5s"
                .. " timeouts=%d faults=%d",
                corner, tostring(target), tostring(rpm), #result.latencies, pings,
                tostring(result.median), tostring(result.p95), tostring(result.worst),
                result.timeouts, result.faults))
            if result.applied then
                note(string.format("  %-3s pod command counter rose by %d of %d sent",
                    corner, result.applied, pings))
            end
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
