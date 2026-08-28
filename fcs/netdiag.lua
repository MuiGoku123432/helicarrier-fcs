-- WHICH POD IS ON WHICH WIRE? Read-only. Commands nothing that moves.
--
--     /fcs/netdiag.lua           the full matrix, about 30 seconds
--     /fcs/netdiag.lua --quick   skip the per-transport matrix
--     /fcs/netdiag.lua --force   run even if a bank is armed
--
-- Run it in the FCS-DEV "Flight Tools" tab.
--
-- ---------------------------------------------------------------------------
-- WHY THIS EXISTS
--
-- On 2026-08-28 a flight caught the fault that has blocked this project all
-- week: air confirm 1 got 0/4 with commandedTilt never leaving 0.00 on any
-- corner, commandsRejected flat, no bearing storing a target, and four
-- COMMAND_TIMEOUTs. The pods never saw a set_tilt. All four went deaf at once
-- for about six seconds while their telemetry kept arriving and the FCS loop
-- stayed healthy. One transmitter, four receivers, downlink unaffected.
--
-- The fix under test is a WIRED bus for some corners. But "I ran a cable" and
-- "the command travels on that cable" are different claims, and this project
-- has lost more time to the gap between a belief and a measurement than to any
-- actual bug. So before any flight: which modem is each pod actually listening
-- on, and does a command reach it over that path?
--
-- WHAT IT MEASURES, and how, because the honest version is not obvious.
--
-- Downlink is easy: pods push telemetry about once a second unprompted, so
-- with one modem open, a corner whose receivedAt advances is reachable on that
-- transport.
--
-- Uplink is the hard half, because if the DOWNLINK is dead on a transport you
-- cannot read the answer while you are testing it. The trick is that
-- commandsSeen is CUMULATIVE: snapshot it with everything open, send the
-- probes with only one modem open, then re-open everything and read it again.
-- The delta says how many probes landed during the isolated phase whether or
-- not anything could be heard at the time.
--
-- THE PROBE IS `set_tilt` AT ANGLE ZERO. Harmless -- the bearings are already
-- there -- but counted by the pod, and it is the exact command type that goes
-- missing. A status_request would NOT do: pod/main.lua hands it to the sampler
-- without incrementing commandsSeen, so it is invisible to this measurement.
-- ---------------------------------------------------------------------------

if package then
    package.path = "/?.lua;/?/init.lua;" .. package.path
end

local config = require("fcs.config")
local banks = require("fcs.banks")
local network = require("fcs.network")
local flight = require("fcs.flight")

local plan = {
    probesPerCorner = 5,
    probeSpacing = 0.2,
    -- Long enough for at least two of the pods' ~1 s telemetry pushes, so a
    -- corner is not called unreachable for having been read between beats.
    settleSeconds = 2.5,
    listenSeconds = 2.0,
}

local args = { ... }
local quick, force = false, false
for _, argument in ipairs(args) do
    if argument == "--quick" then quick = true
    elseif argument == "--force" then force = true end
end

local lines = {}
local function note(text)
    lines[#lines + 1] = text
    print(text)
end

local function save()
    local ok, file = pcall(fs.open, "/fcs/netdiag_result.txt", "w")
    if ok and file then
        file.write(table.concat(lines, "\n"))
        file.close()
        print("")
        print("Saved to /fcs/netdiag_result.txt")
    end
end

local function wait(seconds)
    local deadline = os.epoch("utc") + seconds * 1000
    while os.epoch("utc") < deadline do
        sleep(0.05)
    end
end

-- ---------------------------------------------------------------------------
-- Local modems
-- ---------------------------------------------------------------------------

local function modemKind(name)
    local modem = peripheral.wrap(name)
    if not modem then return "?", nil end
    if type(modem.isWireless) ~= "function" then return "?", modem end
    local ok, wireless = pcall(modem.isWireless)
    if not ok then return "?", modem end
    return (wireless and "wireless" or "wired"), modem
end

local function localModems()
    local found = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "modem") then
            local kind, modem = modemKind(name)
            found[#found + 1] = { name = name, kind = kind, modem = modem }
        end
    end
    return found
end

local function describeWired(entry)
    local modem = entry.modem
    if not modem or entry.kind ~= "wired" then return nil end

    -- getNameLocal is nil until the modem is attached to a cable network AND
    -- switched on. That distinction is the single most common reason a wired
    -- bus silently is not one.
    local okLocal, localName = pcall(function() return modem.getNameLocal() end)
    local okRemote, remote = pcall(function() return modem.getNamesRemote() end)
    return {
        localName = okLocal and localName or nil,
        remote = (okRemote and type(remote) == "table") and remote or nil,
    }
end

-- ---------------------------------------------------------------------------
-- Pods
-- ---------------------------------------------------------------------------

local function podSnapshot()
    local snap = {}
    for _, corner in ipairs(flight.CORNERS) do
        local pod = banks.getState()[corner]
        snap[corner] = {
            online = pod and pod.online or false,
            receivedAt = pod and pod.receivedAt or nil,
            commandsSeen = pod and tonumber(pod.commandsSeen) or nil,
            armed = pod and pod.armed or false,
            modemName = pod and pod.modemName or nil,
            modemWireless = pod and pod.modemWireless,
            podComputerId = pod and pod.podComputerId or nil,
        }
    end
    return snap
end

local function transportOf(entry)
    if entry.modemWireless == false then return "wired" end
    if entry.modemWireless == true then return "wireless" end
    return "?"
end

-- ---------------------------------------------------------------------------
-- Opening one modem at a time.
--
-- network.openedModem is set alongside, because banks.send calls network.open()
-- and that returns early only when the modem it remembers is already open. Skip
-- this and the very next send re-opens every modem and destroys the isolation
-- the measurement depends on.
-- ---------------------------------------------------------------------------

local function openOnly(name)
    pcall(rednet.close)
    local ok = pcall(rednet.open, name)
    network.openedModem = ok and name or nil
    network.openedModems = ok and { { name = name, kind = (modemKind(name)) } } or {}
    return ok
end

local function openAll()
    pcall(rednet.close)
    network.openedModem = nil
    network.openedModems = {}
    return network.open()
end

local function probeAll()
    for _ = 1, plan.probesPerCorner do
        for _, corner in ipairs(flight.CORNERS) do
            -- ANGLE ZERO. The bearings are already there, so this moves
            -- nothing -- and the pod counts it.
            banks.send(corner, "set_tilt",
                { angle = 0, azimuth = 0, bearing = nil, mirror = true })
        end
        wait(plan.probeSpacing)
    end
end

-- ---------------------------------------------------------------------------

local function report(modems, matrix)
    note("")
    note("== WHAT EACH POD SAYS ==")
    note("")
    note("  corner  id    modem      transport")
    local snap = podSnapshot()
    for _, corner in ipairs(flight.CORNERS) do
        local entry = snap[corner]
        note(string.format("  %-6s  %-4s  %-9s  %s%s", corner,
            entry.podComputerId and tostring(entry.podComputerId) or "--",
            entry.modemName or "--", transportOf(entry),
            entry.online and "" or "   (OFFLINE)"))
    end
    if snap.FL.modemName == nil then
        note("")
        note("  ** NO POD IS REPORTING ITS MODEM. The pods are running firmware")
        note("  ** older than pod/main.lua in the repo. Redeploy pod-template and")
        note("  ** reboot with /fcs/reboot.lua all, or every transport claim below")
        note("  ** is guesswork.")
    end

    if not matrix then return end

    note("")
    note("== REACHABILITY, ONE TRANSPORT AT A TIME ==")
    note("")
    note("  up = probes the pod COUNTED (of " .. plan.probesPerCorner
        .. "); down = telemetry arrived")
    note("")
    local header = "  modem            kind      "
    for _, corner in ipairs(flight.CORNERS) do
        header = header .. string.format("%-12s", corner)
    end
    note(header)
    for _, row in ipairs(matrix) do
        local line = string.format("  %-16s %-9s ", row.name, row.kind)
        for _, corner in ipairs(flight.CORNERS) do
            local cell = row.corners[corner]
            line = line .. string.format("%-12s",
                string.format("up%s down%s",
                    cell.up and tostring(cell.up) or "?",
                    cell.down and "Y" or "n"))
        end
        note(line)
    end

    note("")
    note("== VERDICT ==")
    note("")
    for _, corner in ipairs(flight.CORNERS) do
        local claimed = transportOf(snap[corner])
        local reachedOn = {}
        for _, row in ipairs(matrix) do
            local cell = row.corners[corner]
            if cell.up and cell.up > 0 then
                reachedOn[#reachedOn + 1] = string.format("%s(%s)", row.name, row.kind)
            end
        end
        if #reachedOn == 0 then
            note(string.format("  %s  ** UNREACHABLE on every modem. It counted no probe on any",
                corner))
            note("      transport, so nothing below can be trusted about this corner.")
        else
            note(string.format("  %-4s claims %-9s  reached on: %s", corner, claimed,
                table.concat(reachedOn, " ")))
        end
    end

    -- The mismatch that matters: a corner the config calls wired but which is
    -- only reachable on the radio has not actually moved onto the bus.
    note("")
    local mismatched, wiredWorking = 0, 0
    for _, corner in ipairs(flight.CORNERS) do
        local claimed = transportOf(snap[corner])
        local onWired, onWireless = false, false
        for _, row in ipairs(matrix) do
            local cell = row.corners[corner]
            if cell.up and cell.up > 0 then
                if row.kind == "wired" then onWired = true end
                if row.kind == "wireless" then onWireless = true end
            end
        end
        if claimed == "wired" then
            if onWired then
                wiredWorking = wiredWorking + 1
            else
                mismatched = mismatched + 1
                note(string.format("  ** %s SAYS WIRED BUT IS NOT REACHABLE ON THE WIRE.", corner))
                note("  **   The pod opened a wired modem and no command arrives on it, so")
                note("  **   this corner is DEAF in the air. Check the cable reaches it and")
                note("  **   that the modem is switched on, then reboot the pod.")
            end
        end
        if claimed == "wired" and onWireless then
            note(string.format("  ** %s is reachable on the RADIO while claiming wired. The A/B", corner))
            note("  **   cannot attribute a survival to the wire; a pod must open exactly one.")
        end
    end

    if mismatched == 0 and wiredWorking > 0 then
        note(string.format("  %d corner(s) are genuinely on the wired bus and answer on it.",
            wiredWorking))
        note("  The transport A/B is set up correctly. Fly /fcs/tiltcheck.lua.")
    elseif wiredWorking == 0 and mismatched == 0 then
        note("  No corner is on a wired bus. Every pod is on the radio, which is the")
        note("  configuration the 2026-08-28 blackout happened in.")
    end
end

-- ---------------------------------------------------------------------------

local function mainLoop()
    note("NET DIAG -- which pod is on which wire")
    note("utc_ms=" .. tostring(os.epoch("utc")))
    note("")

    if not network.open() then
        note("NO MODEM COULD BE OPENED. Nothing can be measured.")
        return
    end

    note("== MODEMS ON THIS COMPUTER ==")
    note("")
    local modems = localModems()
    if #modems == 0 then
        note("  none. This computer cannot talk to anything.")
        return
    end
    for _, entry in ipairs(modems) do
        note(string.format("  %-16s %-9s rednet %s", entry.name, entry.kind,
            rednet.isOpen(entry.name) and "OPEN" or "closed"))
        local wired = describeWired(entry)
        if wired then
            note(string.format("      network name: %s",
                wired.localName or "NONE -- not attached to a cable network"))
            if wired.remote then
                note(string.format("      peripherals on the cable: %d%s",
                    #wired.remote,
                    #wired.remote > 0 and ("  " .. table.concat(wired.remote, " ")) or ""))
            end
            if not wired.localName then
                note("      ** A wired modem with no network name is not on a bus.")
                note("      ** Check the cable connects, and that the modem is switched ON")
                note("      ** (right-click it -- an inactive modem joins nothing).")
            end
        end
    end

    note("")
    note("== POLLING PODS ==")
    banks.poll()
    wait(plan.settleSeconds)

    local snap = podSnapshot()
    local armed = 0
    for _, corner in ipairs(flight.CORNERS) do
        if snap[corner].armed then armed = armed + 1 end
    end
    if armed > 0 and not force then
        note("")
        note(string.format("  ** %d BANK(S) ARE ARMED. NOT RUNNING THE MATRIX.", armed))
        note("  ** It closes modems one at a time, and a pod that hears nothing for")
        note("  ** 750 ms disarms and drops to comms-loss power. Land and disarm,")
        note("  ** or pass --force if the craft is on the ground and you mean it.")
        report(modems, nil)
        return
    end

    if quick then
        report(modems, nil)
        return
    end

    note("")
    note("== MATRIX: one modem open at a time ==")
    local matrix = {}
    for _, entry in ipairs(modems) do
        note("")
        note(string.format("  -- %s (%s) --", entry.name, entry.kind))

        openAll()
        wait(plan.settleSeconds)
        local before = podSnapshot()

        if not openOnly(entry.name) then
            note("     could not open it; skipped.")
        else
            local during = podSnapshot()
            probeAll()
            wait(plan.listenSeconds)
            local after = podSnapshot()

            openAll()
            wait(plan.settleSeconds)
            local counted = podSnapshot()

            local row = { name = entry.name, kind = entry.kind, corners = {} }
            for _, corner in ipairs(flight.CORNERS) do
                local base = before[corner].commandsSeen
                local final = counted[corner].commandsSeen
                row.corners[corner] = {
                    -- CUMULATIVE, so it is readable after the fact even if the
                    -- pod could not be heard while the probes were going out.
                    up = (base and final) and (final - base) or nil,
                    down = (after[corner].receivedAt and during[corner].receivedAt)
                        and (after[corner].receivedAt > during[corner].receivedAt)
                        or false,
                }
            end
            matrix[#matrix + 1] = row

            local shown = {}
            for _, corner in ipairs(flight.CORNERS) do
                local cell = row.corners[corner]
                shown[#shown + 1] = string.format("%s up%s down%s", corner,
                    cell.up and tostring(cell.up) or "?", cell.down and "Y" or "n")
            end
            note("     " .. table.concat(shown, "   "))
        end
    end

    openAll()
    wait(plan.settleSeconds)
    report(modems, matrix)
end

local function listenLoop()
    while true do
        if not banks.listen(1) then sleep(0.05) end
    end
end

local ok, err = pcall(parallel.waitForAny, mainLoop, listenLoop)
if not ok then
    note("")
    note("RUN ERROR: " .. tostring(err))
end

-- Never leave the FCS with a single modem open because the run stopped early.
pcall(openAll)
save()
