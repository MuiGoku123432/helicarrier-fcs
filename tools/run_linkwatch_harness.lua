-- Fly /fcs/linkwatch.lua against the CC harness.
--
--   luajit tools/run_linkwatch_harness.lua works      healthy link, zero gaps
--   luajit tools/run_linkwatch_harness.lua blackout   6 s outage, WIRELESS
--                                                     corners only -- the
--                                                     answer the flight wants
--   luajit tools/run_linkwatch_harness.lua allfour    6 s outage on ALL FOUR,
--                                                     across both transports --
--                                                     the outcome that kills
--                                                     the wired-bus fix
--   luajit tools/run_linkwatch_harness.lua downlink   the pods go SILENT for
--                                                     6 s while the uplink is
--                                                     fine -- must NOT be
--                                                     reported as uplink outage
--   luajit tools/run_linkwatch_harness.lua noise      the steady ~1% command
--                                                     loss alone -- must report
--                                                     ZERO gaps
--   luajit tools/run_linkwatch_harness.lua bursty     short losses on BOTH
--                                                     transports, every one
--                                                     under the gap floor --
--                                                     what the craft actually
--                                                     did. Zero gaps, many
--                                                     COMMAND_TIMEOUTs, and
--                                                     the verdict must REFUSE
--                                                     to call it clean
--   luajit tools/run_linkwatch_harness.lua flight     climb, hold, land
--   luajit tools/run_linkwatch_harness.lua all
--
-- WHAT THIS CAN AND CANNOT PROVE. The harness does not route by transport --
-- every pod hears every send whatever modem is open -- so it cannot show a
-- cable outliving a radio for any physical reason. What it CAN do is decide,
-- per corner, whether a set_tilt was delivered, and that is the thing linkwatch
-- measures. So these modes prove the DETECTOR: that a 6 s outage is found and
-- sized, that it is attributed to the right corners, that the transport split
-- and the concurrency verdict come out right, that a downlink failure is not
-- reported as an uplink one, and that the steady baseline loss produces no gap
-- at all.
--
-- That last one is the important negative. A gap detector that fires on normal
-- packet loss would report outage on every flight and answer nothing.
--
-- THE MODES RUN --ground-only. The fault being modelled is a time window, not
-- an altitude, so the ground watch exercises every code path in the detector
-- without spending a simulated climb on it -- and `flight` covers the
-- sequencing separately.
package.path = "./?.lua;./?/init.lua;" .. package.path
local harness = require("tools.cc_harness")

local MODES = { "works", "blackout", "allfour", "downlink", "noise", "bursty", "flight" }
local mode = arg[1] or "works"

if mode == "all" then
    local failures = 0
    for _, each in ipairs(MODES) do
        io.write(("="):rep(72), "\nMODE: ", each, "\n", ("="):rep(72), "\n")
        io.flush()
        local ok = os.execute(("luajit %s %s"):format(arg[0], each))
        if ok ~= true and ok ~= 0 then failures = failures + 1 end
    end
    os.exit(failures == 0 and 0 or 1)
end

harness.root = "/tmp/cc_harness_linkwatch"
os.execute("rm -rf /tmp/cc_harness_linkwatch")

harness.model.exponent = 1.0
harness.model.propRollScale = 0.347
harness.model.rollRestoring = 0.0223
harness.model.rollDamping = 0
harness.model.pitchRestoring = 0.0223
harness.model.pitchDamping = 0.30
harness.model.rollEquilibrium = 0.30
harness.model.pitchEquilibrium = -0.55
harness.craft.roll = 0.30
harness.craft.pitch = -0.55

-- THE WIRED BUS AS IT STANDS ON THE CRAFT. Every mode carries it, so the
-- report's transport split is exercised even when nothing is wrong.
harness.model.wiredCorners = { FR = true, RR = true }
harness.model.modems = {
    { name = "back", wireless = true },
    { name = "top", wireless = false, networkName = "computer_1",
      remote = { "modem_3", "modem_5" } },
}

-- WHERE THE FAULT WINDOW GOES, and why these numbers.
--
-- Ground-only sequences: preflight (~2 s), spin-up 6 s, then the ground watch.
-- So the watch is running by about t+8 s. A window at 20..26 s sits well
-- inside a 60 s watch with room either side for the detector to establish a
-- cadence first and to see the recovery after.
local WINDOW = { from = 20000, to = 26000 }
local GROUND_SECONDS = 60
local EXPECT = {}

if mode == "works" then
    GROUND_SECONDS = 40
    EXPECT.uplinkGaps = 0
    EXPECT.downGaps = 0
elseif mode == "blackout" then
    harness.model.uplinkBlackout = { from = WINDOW.from, to = WINDOW.to }
    EXPECT.gappedCorners = { FL = true, RL = true }
    EXPECT.cleanCorners = { FR = true, RR = true }
    EXPECT.verdict = "THE RADIO IS THE FAULT"
elseif mode == "allfour" then
    harness.model.uplinkBlackout = { from = WINDOW.from, to = WINDOW.to,
        wiredToo = true }
    EXPECT.gappedCorners = { FL = true, RL = true, FR = true, RR = true }
    EXPECT.verdict = "THE BLACKOUT IS NOT THE TRANSPORT"
elseif mode == "downlink" then
    -- The uplink is untouched: every probe lands and every counter advances.
    -- Only the reporting stops. Calling this an uplink outage is the exact
    -- misdiagnosis the tool is built to refuse.
    harness.model.podsSilentBetween = { from = WINDOW.from, to = WINDOW.to }
    EXPECT.uplinkGaps = 0
    EXPECT.someDownGaps = true
elseif mode == "noise" then
    -- One command in a hundred, which is the measured baseline. At 5 Hz that
    -- is a single loss about every 20 s and never two in a row.
    GROUND_SECONDS = 40
    harness.model.dropEveryNthCommand = 100
    EXPECT.uplinkGaps = 0
elseif mode == "bursty" then
    -- 0.8 s deaf every 3.5 s, on BOTH transports -- the shape the first real
    -- flight produced. Each burst is far below the gap floor the 1000 ms
    -- harness cadence yields, so the gap count stays zero and the only
    -- evidence is the timeout counter and the loss rate. The tool used to
    -- print "NO UPLINK OUTAGE" over exactly this.
    harness.model.uplinkBurstLoss = { everyMs = 3500, durationMs = 800,
        wiredToo = true }
    EXPECT.uplinkGaps = 0
    EXPECT.someTimeouts = true
    EXPECT.verdict = "THE LINK LOST COMMANDS AND NO GAP WAS LONG ENOUGH"
elseif mode == "flight" then
    GROUND_SECONDS = 10
elseif mode ~= "works" then
    error("unknown mode " .. tostring(mode))
end

for _, pod in pairs(harness.pods()) do
    pod.targetRpm = 0
    pod.armed = false
    pod.currentPower = 0
end

harness.install(_G)
_G.package = package
package.path = "./?.lua;./?/init.lua;" .. package.path

print(("harness: mode=%s"):format(mode))
print(("-"):rep(72))

-- CAPTURE THE OUTPUT. linkwatch wraps its main loop in a pcall and prints
-- "RUN ERROR" rather than propagating -- right on the craft, where an abort
-- must still land the craft and save its log, and wrong here: without this the
-- runner sees a clean exit on a tool that died at its first line.
local captured = {}
local realPrint = print
_G.print = function(...)
    local parts = {}
    for index = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(index, ...)))
    end
    captured[#captured + 1] = table.concat(parts, "\t")
    realPrint(...)
end

local ok, err = pcall(function()
    harness.run({ function()
        local chunk = assert(loadfile("fcs/linkwatch.lua"))
        if mode == "flight" then
            chunk("--hold", "40", "--ground", tostring(GROUND_SECONDS))
        else
            chunk("--ground-only", "--ground", tostring(GROUND_SECONDS))
        end
    end }, true)
end)

_G.print = realPrint

print(("-"):rep(72))
if not ok then
    print("raised: " .. tostring(err))
    os.exit(1)
end

-- --- ASSERTIONS ------------------------------------------------------------

local failures = {}
local function fail(text) failures[#failures + 1] = text end

local function findLine(pattern)
    for _, line in ipairs(captured) do
        if line:find(pattern) then return line end
    end
    return nil
end

if findLine("RUN ERROR") then
    fail("linkwatch reported a run error: " .. tostring(findLine("RUN ERROR")))
end

-- Parse the per-corner table. Columns:
--   corner transport modem probes sent counted loss% gaps outage_s longest_s timeouts
local rows = {}
for _, line in ipairs(captured) do
    local corner, transport, _, probes, _, counted, _, gaps, outage =
        line:match("^%s+(%u%u)%s+(%a+)%s+(%S+)%s+(%d+)%s+(%d+)%s+(%d+)%s+([%d%.]+)%s+(%d+)%s+([%d%.]+)")
    if corner and (corner == "FL" or corner == "FR" or corner == "RL" or corner == "RR") then
        rows[corner] = {
            transport = transport,
            probes = tonumber(probes),
            counted = tonumber(counted),
            gaps = tonumber(gaps),
            outage = tonumber(outage),
        }
    end
end

for _, corner in ipairs({ "FL", "FR", "RL", "RR" }) do
    if not rows[corner] then fail("no report row for " .. corner) end
end

if rows.FR and rows.FR.transport ~= "wired" then
    fail("FR should report the wired transport, got " .. tostring(rows.FR.transport))
end
if rows.FL and rows.FL.transport ~= "wireless" then
    fail("FL should report the wireless transport, got " .. tostring(rows.FL.transport))
end

-- Probes must actually have gone out; a tool that reports "no outage" because
-- it never sent anything would pass every assertion below it.
for corner, row in pairs(rows) do
    if row.probes < 20 then
        fail(("%s: only %d probes sent -- the watch barely ran"):format(corner, row.probes))
    end
end

if EXPECT.uplinkGaps == 0 then
    for corner, row in pairs(rows) do
        if row.gaps > 0 then
            fail(("%s: expected NO uplink gap, got %d totalling %.1f s")
                :format(corner, row.gaps, row.outage))
        end
    end
end

if EXPECT.gappedCorners then
    for corner in pairs(EXPECT.gappedCorners) do
        local row = rows[corner]
        if row and row.gaps == 0 then
            fail(corner .. ": expected an uplink gap, found none")
        elseif row and row.outage < 3.0 then
            fail(("%s: gap is %.1f s, expected roughly the 6 s modelled outage")
                :format(corner, row.outage))
        end
    end
end

if EXPECT.cleanCorners then
    for corner in pairs(EXPECT.cleanCorners) do
        local row = rows[corner]
        if row and row.gaps > 0 then
            fail(("%s is on the WIRE and must not gap, got %.1f s")
                :format(corner, row.outage))
        end
    end
end

if EXPECT.someDownGaps then
    if not findLine("DOWN ") then
        fail("expected a DOWNLINK gap row, found none")
    end
    if not findLine("DOWNLINK silence") then
        fail("expected the cross-check to name the downlink silence")
    end
end

if EXPECT.someTimeouts then
    local seen = 0
    for _, line in ipairs(captured) do
        local n = line:match("(%d+) COMMAND_TIMEOUTs")
        if n then seen = seen + tonumber(n) end
    end
    if seen == 0 then
        fail("expected COMMAND_TIMEOUTs from the burst loss, report showed none")
    end
end

if EXPECT.verdict and not findLine(EXPECT.verdict) then
    fail("expected the verdict to say: " .. EXPECT.verdict)
end

-- The craft must never be left tilted, and never with its props cut in the air.
local tilts = {}
for corner, pod in pairs(harness.pods()) do
    tilts[#tilts + 1] = corner .. "=" .. string.format("%.2f", pod.tiltAngle or 0)
    if math.abs(pod.tiltAngle or 0) > 0.01 then
        fail(corner .. " left tilted at " .. tostring(pod.tiltAngle))
    end
end
table.sort(tilts)
print("harness: bearing tilt " .. table.concat(tilts, " "))
print(("harness: roll=%.2f pitch=%.2f speed=%.3f y=%.1f"):format(
    harness.craft.roll, harness.craft.pitch, harness.groundSpeed(), harness.craft.y))

if #failures > 0 then
    print("")
    for _, text in ipairs(failures) do print("FAIL: " .. text) end
    os.exit(1)
end
print("harness: all assertions passed")
