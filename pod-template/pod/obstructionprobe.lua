-- THROWAWAY PROBE -- handoff step 6, getObstruction()'s inverted sense.
--
-- Read-only. Touches no setter, arms nothing, commands nothing. Safe to run at
-- any time, in any craft state.
--
-- ---------------------------------------------------------------------------
-- WHAT IS ALREADY ESTABLISHED, AND WHAT IS NOT
--
-- Established: the derived flag is wrong. Every flight CSV records
-- *_pod_obstructed_thrusters = 32 -- all of them -- across runs where the ion
-- banks demonstrably produced 516,096 kN and lifted the carrier. A thruster
-- cannot be blocked and lifting at the same time, so `clearance <= 0` in
-- thrusters.telemetry() is mislabelling every thruster on the craft.
--
-- NOT established: what getObstruction actually returns. HANDOFF.md says "0
-- evidently means CLEAR", but that is an inference from the flag being stuck
-- on, not a measurement -- the raw value is recorded nowhere. It is not in the
-- flight CSVs (only the derived count is), not in ionsweep_result.txt, and the
-- pods' device_report.txt does not dump ion_thruster's method list.
--
-- That distinction decides the fix, and the two candidates disagree:
--
--   * if the value is a CLEARANCE DISTANCE, then bigger is freer, and 0 means
--     blocked -- the current predicate is RIGHT and something else is wrong
--   * if the value is a DISTANCE TO AN OBSTRUCTION, then 0 means "nothing
--     found", i.e. clear, and the predicate must be inverted
--
-- Guessing between those is how the original bug got written. So: measure.
--
-- Three claims in HANDOFF.md were overturned by measurement today
-- (getThrustVector "nil", bearing_rpm "always 0", RR-only airflow), every one
-- of them a value that had been reasoned about rather than read.
-- ---------------------------------------------------------------------------
--
-- CC resolves a relative require against the running program's directory, so
-- root package.path at / -- bug 1 in HANDOFF.md.
package.path = "/?.lua;/?/init.lua;" .. package.path

local config = require("pod.config")

local REPORT_PATH = "/pod/obstructionprobe.txt"

local lines = {}
local function note(text)
    lines[#lines + 1] = text
    print(text)
end

local function render(value)
    local kind = type(value)
    if kind == "nil" then return "nil" end
    if kind == "number" then return string.format("%.6f", value) end
    if kind == "boolean" then return tostring(value) end
    if kind == "string" then return string.format("%q", value) end
    if kind == "table" then
        local parts = {}
        for key, entry in pairs(value) do
            parts[#parts + 1] = tostring(key) .. "=" .. tostring(entry)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return "<" .. kind .. ">"
end

if not fs.exists(config.manifestPath) then
    error("thruster manifest is missing: " .. config.manifestPath, 0)
end
local names = dofile(config.manifestPath)
if type(names) ~= "table" or #names == 0 then
    error("thruster manifest did not return a list", 0)
end

note("=== getObstruction probe ===")
note("corner    " .. tostring(config.corner))
note("thrusters " .. #names)
note("time      " .. tostring(os.epoch("utc")))

-- ---------------------------------------------------------------------------
-- What does an ion thruster actually expose? device_report.txt never dumped
-- this, so the project has been using whatever getters it happened to know.
-- There may be a better obstruction method sitting right there -- an
-- isObstructed boolean would settle the semantics on its own.
-- ---------------------------------------------------------------------------

note("")
note("-- methods on " .. names[1] .. " --")
local methods = peripheral.getMethods(names[1])
if methods then
    table.sort(methods)
    note("  " .. table.concat(methods, ", "))
else
    note("  peripheral.getMethods returned nil")
end

-- ---------------------------------------------------------------------------
-- Read every thruster. Power and thrust come along because they are the
-- correlation that matters: a thruster flagged obstructed while producing
-- thrust proves the flag is wrong, in this run rather than by reference to an
-- old CSV.
-- ---------------------------------------------------------------------------

note("")
note("-- per-thruster readings --")
note(string.format("  %-22s %14s %12s %14s", "name", "obstruction", "power", "thrustKN"))

local histogram, order = {}, {}
local faults = 0

for _, name in ipairs(names) do
    if not peripheral.isPresent(name) then
        note(string.format("  %-22s MISSING", name))
        faults = faults + 1
    else
        local device = peripheral.wrap(name)
        local ok, reading = pcall(function()
            return {
                obstruction = device.getObstruction(),
                power = device.getPower(),
                thrust = device.getCurrentThrustKN(),
            }
        end)

        if not ok then
            note(string.format("  %-22s ERROR %s", name, tostring(reading)))
            faults = faults + 1
        else
            local key = render(reading.obstruction) .. "  (" .. type(reading.obstruction) .. ")"
            if not histogram[key] then
                histogram[key] = 0
                order[#order + 1] = key
            end
            histogram[key] = histogram[key] + 1

            note(string.format("  %-22s %14s %12s %14s", name,
                render(reading.obstruction), render(reading.power), render(reading.thrust)))
        end
    end
end

-- ---------------------------------------------------------------------------

note("")
note("-- distinct obstruction values --")
table.sort(order)
for _, key in ipairs(order) do
    note(string.format("  %-34s x%d", key, histogram[key]))
end
if #order == 1 then
    note("")
    note("  All thrusters agree. A value identical across 32 devices in")
    note("  different positions and orientations is a CONSTANT, not a")
    note("  measurement -- which would mean the getter reports something other")
    note("  than per-thruster clearance, and no predicate over it can be right.")
elseif #order > 1 then
    note("")
    note("  Values DIFFER between thrusters, so the getter is measuring")
    note("  something real and per-device. The spread above is the scale.")
end

note("")
note("read errors: " .. faults)

local file = fs.open(REPORT_PATH, "w")
file.write(table.concat(lines, "\n"))
file.close()
print("")
print("Report written to " .. REPORT_PATH)
