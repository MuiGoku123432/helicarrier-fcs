-- Does the pod's telemetry assembly stay honest once the reading is CACHED?
--
-- The sampler moved the hardware read off networkLoop, which is what fixed the
-- measured 2.5-5% command loss. But caching a reading changes what the
-- assembly code is allowed to do with it, and two of the changes are silent:
--
--   1. The old code appended state.faults into the table thrusters.telemetry()
--      returned. That was harmless while the table was built fresh and thrown
--      away. Against a cached table the same line appends to the SAME list on
--      every message, forever -- which is the unbounded-fault-list bug that
--      destroyed six runs of flight data, reintroduced by changing nothing but
--      the lifetime of a table.
--
--   2. armed and currentPower must NOT come from the sample. They change on
--      command boundaries, and fcs/reboot.lua decides whether rebooting a pod
--      will drop lift by reading exactly those. A one-second-old arm state is
--      a safety-relevant lie.
--
-- Neither shows up in game until it has already cost a run, and neither is
-- visible in a diff. So they are pinned here.
--
--     luajit tools/test_pod_payload.lua
package.path = "./?.lua;./?/init.lua;./pod-template/?.lua;" .. package.path

local payload = require("pod.payload")

local passed, failed = 0, 0
local function checkEqual(label, got, want)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL %-58s got %s want %s",
            label, tostring(got), tostring(want)))
    end
end

local function context()
    return {
        sample = {
            at = 1000,
            thrusters = {
                healthyThrusters = 32,
                expectedThrusters = 32,
                averagePower = 0.2,
                totalThrustKN = 4321.5,
                faults = { "THRUSTER_7_OBSTRUCTED" },
            },
            props = { targetRpm = 64, controllerRpm = 64 },
            count = 5,
        },
        state = {
            armed = true,
            currentPower = 0.195,
            lastCommandAt = 1500,
            bootedAt = 10,
            commandsSeen = 7,
            commandsApplied = 6,
            commandsRejected = 1,
            lastReject = "not_armed",
            lastTilt = 3.5,
            lastTiltAzimuth = 90,
            faults = { "COMMAND_TIMEOUT x3" },
        },
        config = {
            corner = "FR",
            hostname = "ENG-FR",
            fallbackPower = 0.0,
            commsLossPower = 0.195,
        },
        computerId = 3,
        now = 1200,
    }
end

-- --- the sampled half is copied through -----------------------------------

local ctx = context()
local message = payload.status("status", ctx)

checkEqual("sampled healthyThrusters", message.healthyThrusters, 32)
checkEqual("sampled averagePower", message.averagePower, 0.2)
checkEqual("sampled totalThrustKN", message.totalThrustKN, 4321.5)
checkEqual("prop passed through", message.prop.targetRpm, 64)
checkEqual("type is set", message.type, "status")
checkEqual("type defaults to status", payload.status(nil, context()).type, "status")
checkEqual("ack keeps its type", payload.status("ack", context()).type, "ack")

-- --- staleness is VISIBLE --------------------------------------------------
--
-- Without this a consumer cannot tell a live reading from one taken before its
-- own command, and this project has already lost four runs to a telemetry
-- field that did not report what it looked like.

checkEqual("sampleAt reported", message.sampleAt, 1000)
checkEqual("sampleAgeMs computed", message.sampleAgeMs, 200)

local noSample = payload.status("status", {
    sample = {}, state = {}, config = {}, computerId = 1, now = 1200,
})
checkEqual("no sample yet -> no age", noSample.sampleAgeMs, nil)
checkEqual("no sample yet -> no sampleAt", noSample.sampleAt, nil)
checkEqual("no sample still answers", noSample.type, "status")
checkEqual("no sample -> empty fault list", #noSample.faults, 0)

-- --- RULE 1: the snapshot is never mutated ---------------------------------

ctx = context()
local first = payload.status("status", ctx)
local second = payload.status("status", ctx)

checkEqual("faults: thruster + state", #first.faults, 2)
checkEqual("fault order: thruster first", first.faults[1], "THRUSTER_7_OBSTRUCTED")
checkEqual("fault order: state second", first.faults[2], "COMMAND_TIMEOUT x3")
-- The regression this file exists for. Before the copy, this was 4, then 6,
-- then 8 -- 30 KB a row inside an hour.
checkEqual("second message does NOT accumulate", #second.faults, 2)
checkEqual("snapshot fault list untouched", #ctx.sample.thrusters.faults, 1)
checkEqual("state fault list untouched", #ctx.state.faults, 1)

first.healthyThrusters = 999
checkEqual("snapshot not aliased by the message",
    ctx.sample.thrusters.healthyThrusters, 32)
checkEqual("messages are independent tables", second.healthyThrusters, 32)

-- --- RULE 2: the cheap scalars are LIVE, not sampled ------------------------
--
-- The sample is a second old; the arm state must be this instant's.

ctx = context()
ctx.state.armed = false
ctx.state.currentPower = 0.0
local afterDisarm = payload.status("status", ctx)
checkEqual("armed is live", afterDisarm.armed, false)
checkEqual("currentPower is live", afterDisarm.currentPower, 0.0)

ctx.state.armed = true
ctx.state.currentPower = 0.42
local afterArm = payload.status("status", ctx)
checkEqual("armed follows state", afterArm.armed, true)
checkEqual("currentPower follows state", afterArm.currentPower, 0.42)

-- A sampled averagePower and a live currentPower are DIFFERENT numbers and
-- both must survive: only the snapped hardware reading explains thrust, and
-- only the live one says what was commanded.
checkEqual("sampled and live power coexist", afterArm.averagePower, 0.2)

checkEqual("corner", afterArm.corner, "FR")
checkEqual("hostname", afterArm.hostname, "ENG-FR")
checkEqual("podComputerId", afterArm.podComputerId, 3)
checkEqual("bootedAt", afterArm.bootedAt, 10)
checkEqual("commandsSeen is live", afterArm.commandsSeen, 7)
checkEqual("commandsApplied is live", afterArm.commandsApplied, 6)
checkEqual("commandsRejected is live", afterArm.commandsRejected, 1)
checkEqual("lastReject is live", afterArm.lastReject, "not_armed")
checkEqual("lastCommandAt is live", afterArm.lastCommandAt, 1500)
checkEqual("commandedTilt is live", afterArm.commandedTilt, 3.5)
checkEqual("commandedTiltAzimuth is live", afterArm.commandedTiltAzimuth, 90)
checkEqual("fallbackPower from config", afterArm.fallbackPower, 0.0)
checkEqual("commsLossPower from config", afterArm.commsLossPower, 0.195)

-- --- a failed read must not erase the previous one -------------------------
--
-- refreshSample keeps the last good half rather than publishing nil, because
-- banks.acceptStatus copies keys over stored state: nil-ing a half would
-- silently freeze it with nothing to show why. sampleAgeMs is the only tell,
-- so it has to keep advancing.

local stale = payload.status("status", {
    sample = { at = 1000, thrusters = { healthyThrusters = 32, faults = {} },
               props = nil },
    state = { faults = {} },
    config = { corner = "FR" },
    computerId = 3,
    now = 9000,
})
checkEqual("stale sample still reports its age", stale.sampleAgeMs, 8000)
checkEqual("missing prop half is absent, not invented", stale.prop, nil)

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
