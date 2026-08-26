-- THROWAWAY PROBE -- is ion thrust genuinely quantised, or just coarsely
-- reported?
--
--     /pod/thrustprobe.lua
--
-- Drives THIS POD's thrusters directly through a small power staircase and
-- reads all four thrust getters at each step. Runs on the ground with the
-- banks DISARMED and no FCS commanding, so nothing fights it for the
-- actuators.
--
-- ---------------------------------------------------------------------------
-- THE QUESTION
--
-- /fcs/axisresponse.lua --ground-only, sampling only settled points, produced
-- a staircase in getCurrentThrustKN:
--
--     applied 0.0003 ->        0.0
--     applied 0.0603 ->        0.0        <- 6% power, zero thrust
--     applied 0.0903 ->   258048.0
--     applied 0.1203 ->   258048.0        <- same as 0.09
--     applied 0.1503 ->   516096.0
--
-- Every value an exact multiple of 258,048 kN = 2016 kN/thruster = 22.3% of
-- craft weight per step. Nothing in between, ever.
--
-- HANDOFF.md records "force quantised at 22% of weight" as a WRONG claim,
-- dismissed as an artifact of sampling only settled points. This sampled only
-- settled points on purpose and got exactly that. One of the two readings is
-- wrong and it matters enormously:
--
--   * If the FORCE is quantised at 22% of weight, ion thrust is not "fine
--     enough for trim" as HANDOFF.md states, and the mixer's whole premise --
--     ions as the fast fine-trim layer -- is unsound.
--   * If only the READOUT is coarse, nothing about the craft changes and the
--     mixer is fine; we simply need a better getter.
--
-- Evidence for the second: the hover point was bracketed to 0.005 in power and
-- behaved smoothly, which a 22%-of-weight force step makes impossible.
--
-- ---------------------------------------------------------------------------
-- WHY FOUR GETTERS MATTER
--
-- An ion thruster exposes getCurrentThrustKN, getCurrentThrustPN,
-- getDisplayedThrustKN and getDisplayedThrustPN. The project has only ever
-- read the first. If the mod holds thrust finely and rounds when converting to
-- kilonewtons, the PN variant shows the true value -- and "quantised force"
-- becomes "coarse readout".
--
-- getPower is read back too: if IT is quantised, the mod is snapping the
-- commanded power itself, which is a third possibility again.
--
-- ---------------------------------------------------------------------------
-- SAFETY
--
--   * Props must be at 0 and the ion banks DISARMED before running. With the
--     banks disarmed nothing else writes to the thrusters, so this owns them.
--   * Powers are capped at 0.15, below the 0.195 hover, so with props stopped
--     the craft cannot lift.
--   * Returns every thruster to 0.0 on the way out, including on error.
-- ---------------------------------------------------------------------------

package.path = "/?.lua;/?/init.lua;" .. package.path

local config = require("pod.config")

local REPORT_PATH = "/pod/thrustprobe.txt"

-- Fine steps: the point is to find the smallest change that moves a reading.
local POWERS = {
    0.00, 0.02, 0.04, 0.05, 0.06, 0.07, 0.08,
    0.09, 0.10, 0.11, 0.12, 0.13, 0.14, 0.15,
}
local SETTLE_SECONDS = 2.0

local lines = {}
local function note(text)
    lines[#lines + 1] = text
    print(text)
end

local function number(value)
    if type(value) ~= "number" then return tostring(value) end
    return string.format("%.4f", value)
end

if not fs.exists(config.manifestPath) then
    error("thruster manifest is missing: " .. config.manifestPath, 0)
end
local names = dofile(config.manifestPath)
if type(names) ~= "table" or #names == 0 then
    error("thruster manifest did not return a list", 0)
end

local devices = {}
for _, name in ipairs(names) do
    if peripheral.isPresent(name) then
        devices[#devices + 1] = peripheral.wrap(name)
    end
end
if #devices == 0 then
    error("no thrusters present", 0)
end

note("=== ion thrust resolution probe ===")
note("corner    " .. tostring(config.corner))
note("thrusters " .. #devices)
note("time      " .. tostring(os.epoch("utc")))
note("")
note("REQUIRES: props at 0, ion banks DISARMED, craft grounded.")
note("Powers capped at 0.15, below the 0.195 hover.")

local first = devices[1]
local getters = {
    "getCurrentThrustKN", "getCurrentThrustPN",
    "getDisplayedThrustKN", "getDisplayedThrustPN",
}

local available = {}
for _, getter in ipairs(getters) do
    available[getter] = type(first[getter]) == "function"
    if not available[getter] then
        note("  NOTE: " .. getter .. " is absent on this thruster")
    end
end

local function applyAll(power)
    local jobs = {}
    for index, device in ipairs(devices) do
        jobs[index] = function() device.setPowerNormalized(power) end
    end
    parallel.waitForAll(table.unpack(jobs))
end

note("")
note(string.format("  %8s %10s %16s %16s %16s %16s", "cmd", "getPower",
    "current_KN", "current_PN", "displayed_KN", "displayed_PN"))

local rows = {}

local ok, err = pcall(function()
    for _, power in ipairs(POWERS) do
        applyAll(power)
        sleep(SETTLE_SECONDS)

        local reading = { commanded = power }
        local okRead = pcall(function()
            reading.power = first.getPower()
            for _, getter in ipairs(getters) do
                if available[getter] then
                    reading[getter] = first[getter]()
                end
            end
        end)

        if okRead then
            rows[#rows + 1] = reading
            note(string.format("  %8.3f %10s %16s %16s %16s %16s",
                power, number(reading.power),
                number(reading.getCurrentThrustKN), number(reading.getCurrentThrustPN),
                number(reading.getDisplayedThrustKN), number(reading.getDisplayedThrustPN)))
        else
            note(string.format("  %8.3f  READ FAILED", power))
        end
    end
end)

-- Always return the bank to rest, error or not.
pcall(applyAll, 0.0)

if not ok then
    note("")
    note("ERROR during staircase: " .. tostring(err))
end

-- ---------------------------------------------------------------------------
-- The verdict: how many DISTINCT values did each getter produce?
--
-- A getter with as many distinct values as there are power steps is tracking
-- power. One with a handful is quantised. Comparing them against getPower
-- separates "the mod snapped the power" from "the readout is coarse".
-- ---------------------------------------------------------------------------

note("")
note("-- distinct values per getter (over " .. #rows .. " power steps) --")

local function distinctCount(key)
    local seen, count = {}, 0
    for _, row in ipairs(rows) do
        local value = row[key]
        if value ~= nil and not seen[value] then
            seen[value] = true
            count = count + 1
        end
    end
    return count
end

note(string.format("  %-22s %s", "getPower", distinctCount("power")))
for _, getter in ipairs(getters) do
    if available[getter] then
        note(string.format("  %-22s %s", getter, distinctCount(getter)))
    end
end

note("")
note("READING THIS:")
note("  getPower coarse            -> the mod snaps commanded power itself.")
note("  getPower fine, all thrust")
note("    getters coarse           -> force really is quantised; the mixer's")
note("                                fine-trim premise needs rethinking.")
note("  some thrust getter fine    -> only the readout was coarse. Use that")
note("                                getter and nothing else changes.")

local file = fs.open(REPORT_PATH, "w")
file.write(table.concat(lines, "\n"))
file.close()
print("")
print("Report written to " .. REPORT_PATH)
