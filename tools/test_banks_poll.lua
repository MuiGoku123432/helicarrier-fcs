-- Does the FCS ask the pods for anything it is already being told?
--
-- WHY THIS EXISTS. A status_request is not free any more. Since the pods grew a
-- central sampler it forces a FRESH ~250 ms read -- deliberately, so a caller
-- reading back its own command is not served a value from before it. banks.tick
-- used to send one to all four corners every 2 s regardless, and its timer is
-- per PROCESS, so the forced-sample rate scaled with how many tabs happened to
-- be open. Two tabs doubled it. Nobody would choose that, and nothing would
-- have shown it: the pods just quietly did twice the work.
--
-- The pods push full telemetry every ~1 s, so the poll is redundant except when
-- a corner has actually gone quiet. That policy is what is pinned here, in both
-- directions -- a healthy corner must be asked NOTHING, and a silent one must
-- be asked promptly. Getting either half wrong is silent in game.
--
--     luajit tools/test_banks_poll.lua
package.path = "./?.lua;./?/init.lua;" .. package.path
local harness = require("tools.cc_harness")

harness.root = "/tmp/cc_harness_banks_poll"
os.execute("rm -rf /tmp/cc_harness_banks_poll")
harness.install(_G)
_G.package = package
package.path = "./?.lua;./?/init.lua;" .. package.path

local config = require("fcs.config")

-- Mirror the DEPLOYED config, which pins podIds (FL=2 FR=3 RL=4 RR=5). The repo
-- template leaves them nil, and with nil ids banks.tick cannot address a poll at
-- all -- so an unpinned test would "pass" by never sending anything, which is
-- the one result this file must not be able to reach by accident.
config.wireless.podIds = { FL = 2, FR = 3, RL = 4, RR = 5 }

local banks = require("fcs.banks")

-- Count what actually goes out, by type and corner.
local sent = {}
local realSend = rednet.send
rednet.send = function(recipient, message, protocolName)
    if type(message) == "table" and message.type then
        sent[message.type] = (sent[message.type] or 0) + 1
    end
    return realSend(recipient, message, protocolName)
end

local passed, failed = 0, 0
local function checkEqual(label, got, want)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL %-56s got %s want %s",
            label, tostring(got), tostring(want)))
    end
end
local function checkAtMost(label, got, limit)
    if type(got) == "number" and got <= limit then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL %-56s got %s want <= %s",
            label, tostring(got), tostring(limit)))
    end
end

local function requests()
    return sent.status_request or 0
end

-- Drive banks the way a flight tool actually does: a DEDICATED LISTENER
-- coroutine plus a loop that ticks and sleeps.
--
-- Not one loop doing both. CC drops events that do not match a filtered wait,
-- and sleep() waits on "timer" -- so a single coroutine that polls and then
-- sleeps throws away the telemetry it just asked for. That is bug 6, it is
-- faithfully reproduced by the harness, and it is why every flight tool in this
-- repo runs banks.listen in its own coroutine. A test shaped the other way
-- measures the bug instead of the policy.
local function run(ms, step)
    step = step or 100
    harness.run({
        function()
            while true do
                if not banks.listen(1) then sleep(0.05) end
            end
        end,
        function()
            local elapsed = 0
            while elapsed < ms do
                banks.poll()
                sleep(step / 1000)
                elapsed = elapsed + step
            end
        end,
    }, true)
end

-- --- a fresh program probes IMMEDIATELY ------------------------------------
--
-- Never heard from is infinitely quiet. Waiting out a first interval before
-- asking anything would make every tool start blind for two seconds.

run(300)
checkAtMost("startup probes at most once per corner", requests(), 4)
local afterStartup = requests()

-- --- a corner being PUSHED to is never asked --------------------------------
--
-- The whole point. The harness pods push telemetry every telemetryPeriodMs,
-- exactly as the real ones do.

sent.status_request = 0
run(12000)
checkEqual("12 s of healthy pushes -> zero requests", requests(), 0)
checkEqual("...and the pods are online", banks.getState().FL.online, true)
checkEqual("...all four", banks.getState().RR.online, true)

-- Under the old policy this window alone would have sent 24.
checkEqual("old policy would have sent 24; new sends", requests(), 0)

-- --- a corner that goes QUIET is asked, and rate-limited ---------------------

harness.model.podsSilent = true
sent.status_request = 0
run(10000)

-- quietPollAfterMs 2500 then one per corner per statusRequestPeriodMs 2000:
-- roughly (10000 - 2500) / 2000 = 3-4 rounds of 4.
local silentRequests = requests()
if silentRequests >= 4 then
    passed = passed + 1
else
    failed = failed + 1
    print(string.format("FAIL %-56s got %s want >= 4",
        "a silent corner IS probed", tostring(silentRequests)))
end
checkAtMost("silent probing stays rate-limited", silentRequests, 24)
checkEqual("a silent pod is marked offline", banks.getState().FL.online, false)

-- --- and stops again the moment the push returns ----------------------------

harness.model.podsSilent = false
run(3000)              -- let the pushes resume and the quiet timer clear
sent.status_request = 0
run(8000)
checkEqual("recovered corner is asked nothing again", requests(), 0)
checkEqual("recovered pod is online again", banks.getState().FL.online, true)

-- --- the config invariants the policy rests on ------------------------------
--
-- quietPollAfterMs sits BETWEEN the push period and offlineAfterMs. Above the
-- push period or a healthy pod is polled forever; below offlineAfterMs or a pod
-- is declared dead before anyone has asked it anything.

local quiet = config.wireless.quietPollAfterMs
local podPushMs = 1000        -- pod config telemetryPeriodSeconds = 1.00
if quiet > podPushMs then
    passed = passed + 1
else
    failed = failed + 1
    print("FAIL quietPollAfterMs must exceed the pod push period")
end
if quiet < config.wireless.offlineAfterMs then
    passed = passed + 1
else
    failed = failed + 1
    print("FAIL quietPollAfterMs must be below offlineAfterMs")
end

print(string.format("%d passed, %d failed (startup probes: %d)",
    passed, failed, afterStartup))
if failed > 0 then os.exit(1) end
