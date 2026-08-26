-- THROWAWAY PROBE -- handoff step 2.
--
-- This is a diagnostic, not a component. Delete it once the question is
-- answered, or promote what it learned into props.lua.
--
-- ---------------------------------------------------------------------------
-- WHAT RUN 1 ESTABLISHED (0 RPM, FL, 2026-08-25)
--
-- The original question was "does getThrustVector populate once a manual
-- target is set?" That question is dead. **getThrustVector was never nil.**
-- At zero RPM, zero thrust, no manual target, bearing_1 returned:
--
--     getThrustVector   {1=0.000000, 2=1.000000, 3=0.000000}
--
-- An ARRAY table indexed 1/2/3 -- not {x=,y=,z=}. Reading .x/.y/.z off it
-- yields three nils, which is exactly how it came to be recorded as nil in
-- HANDOFF.md, and exactly the mistake bug 3 documents for the {v=,a=}
-- quaternion. Two shape errors, same root cause.
--
-- It also agrees exactly with getBlockNormal and getFacingVector, and it reads
-- {0,-1,0} on the counter-rotating partner. So it is GEOMETRIC -- a direction,
-- not a force -- and it is not gated on thrust. That kills the "maybe it needs
-- thrust to populate" alternative too, and it means the remaining question is
-- answerable with the props stopped.
--
-- Run 1 also pinned setManualTarget's signature by elimination:
--   numbers        -> "bad argument #1 (table expected, got number)"
--   {x=,y=,z=}     -> "expected number at index 1"
-- so it wants an ARRAY vector: setManualTarget({0, 1, 0}).
--
-- ---------------------------------------------------------------------------
-- THE QUESTION NOW: does getThrustVector TRACK a commanded tilt?
--
-- If the vector moves with the target, vectoring is closed-loop and yaw is
-- solvable by pointing the bearings. If it does not move, the vector is
-- decorative geometry, vectoring stays open-loop guessing, and
-- setThrustHandedness reaction torque becomes the better route.
--
-- Safe at 0 RPM -- the vector is geometric, so no thrust is needed to see it
-- move. This script never commands RPM, so it cannot move the craft on its
-- own. Keep the ion banks DISARMED.
-- ---------------------------------------------------------------------------
--
-- CC resolves a relative require against the running program's directory, so
-- root package.path at / -- bug 1 in HANDOFF.md.
package.path = "/?.lua;/?/init.lua;" .. package.path

local config = require("pod.config")

local REPORT_PATH = "/pod/yawprobe.txt"
local SETTLE_SECONDS = 1.5

local lines = {}

local function note(text)
    lines[#lines + 1] = text
    print(text)
end

-- ---------------------------------------------------------------------------
-- Rendering unknown return values
--
-- Nobody knows what shape these getters return. Quaternions on this mod are
-- {v = <vector>, a = <w>} rather than {x,y,z,w} -- bug 3 in HANDOFF.md, four
-- nils that passed every guard -- so render structure faithfully instead of
-- assuming a shape and printing nil.
-- ---------------------------------------------------------------------------

local function render(value, depth)
    depth = depth or 0
    local kind = type(value)

    if kind == "nil" then return "nil" end
    if kind == "number" then return string.format("%.6f", value) end
    if kind == "string" then return string.format("%q", value) end
    if kind == "boolean" then return tostring(value) end
    if kind ~= "table" then return "<" .. kind .. ">" end

    if depth > 2 then return "<table, deeper>" end

    -- Collect the real keys, not stringified copies: a numeric key turned into
    -- a string no longer indexes the table it came from, and the "fallback"
    -- that papers over that is how you end up printing nil for data that is
    -- present.
    local entries = {}
    for key, entry in pairs(value) do
        entries[#entries + 1] = { label = tostring(key), value = entry }
    end
    table.sort(entries, function(a, b) return a.label < b.label end)

    local parts = {}
    for _, entry in ipairs(entries) do
        parts[#parts + 1] = entry.label .. "=" .. render(entry.value, depth + 1)
    end
    if #parts == 0 then return "{}" end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function call(device, method, ...)
    if type(device[method]) ~= "function" then
        return false, "method absent"
    end
    local results = { pcall(device[method], ...) }
    if not results[1] then
        return false, tostring(results[2])
    end
    return true, render(results[2]), results[3] ~= nil and render(results[3]) or nil
end

-- The getters worth watching across the experiment. getThrustVector is the
-- question; the rest are the closed-loop feedback that would make vectoring
-- usable, and getThrust is the control -- if it moves, the bearing responded.
local WATCHED = {
    "getThrustVector", "getTiltAngle", "getAngle", "getAxis",
    "getBlockNormal", "getFacingVector", "getManualTarget",
    "getThrust", "getThrustHandedness", "isAssembled", "isActive",
    "getRotationSpeed", "getAirflow", "getSailPower",
}

local function snapshot(device, label)
    note("")
    note("-- " .. label .. " " .. string.rep("-", math.max(0, 60 - #label)))
    local values = {}
    for _, method in ipairs(WATCHED) do
        local succeeded, rendered = call(device, method)
        values[method] = succeeded and rendered or ("ERROR " .. rendered)
        note(string.format("  %-22s %s", method, values[method]))
    end
    return values
end

local function diff(before, after, label)
    note("")
    note("-- CHANGED: " .. label .. " ---------------------------------")
    local changed = 0
    for _, method in ipairs(WATCHED) do
        if before[method] ~= after[method] then
            changed = changed + 1
            note(string.format("  %-22s %s  ->  %s", method, before[method], after[method]))
        end
    end
    if changed == 0 then
        note("  (nothing changed)")
    end
    return changed
end

-- ---------------------------------------------------------------------------
-- setManualTarget's signature is unknown
--
-- /pod/device_report.txt lists method NAMES only -- no arity, no argument
-- types. So discover it: try each plausible shape with NEUTRAL values, and
-- record the error text of the ones that fail. CC peripheral errors usually
-- name the expected type, so the failures are as informative as the success.
--
-- Every candidate here is zero/identity on purpose. Discovery must not tilt
-- anything; the tilt comes afterwards, once the shape is known.
-- ---------------------------------------------------------------------------

local function discoverSignature(device)
    -- Run 1 narrowed this a long way. Numbers give "bad argument #1 (table
    -- expected, got number)"; {x=,y=,z=} gives "expected number at index 1".
    -- So it wants an ARRAY-form vector -- {0, 1, 0} -- which is also the shape
    -- every getter here returns. Array form leads now; the rest stay as
    -- evidence in case a different bearing disagrees.
    local candidates = {
        { label = "({0, 1, 0})  -- array vector", args = { { 0, 1, 0 } } },
        { label = "({0, 1, 0}, 0)", args = { { 0, 1, 0 }, 0 } },
        { label = "({x=0,y=1,z=0})", args = { { x = 0, y = 1, z = 0 } } },
        { label = "(vector.new(0,1,0))", args = { vector and vector.new and vector.new(0, 1, 0) or nil } },
        { label = "(0, 1, 0)", args = { 0, 1, 0 } },
        { label = "(0)", args = { 0 } },
    }

    note("")
    note("== setManualTarget signature discovery ==")

    local accepted = nil
    for _, candidate in ipairs(candidates) do
        if candidate.args[1] ~= nil or candidate.label == "()" then
            local succeeded, rendered = call(device, "setManualTarget", table.unpack(candidate.args))
            note(string.format("  %-26s %s", candidate.label,
                succeeded and ("OK -> " .. rendered) or ("rejected: " .. rendered)))
            if succeeded and not accepted then
                accepted = candidate
            end
        end
    end

    return accepted
end

-- ---------------------------------------------------------------------------

local function bearingNames()
    local configured = config.propBearing
    if type(configured) == "string" and configured ~= "" then
        return { configured }
    end
    if type(configured) == "table" then
        local names = {}
        for _, name in ipairs(configured) do
            if type(name) == "string" and name ~= "" then names[#names + 1] = name end
        end
        return names
    end
    return {}
end

local names = bearingNames()
if #names == 0 then
    error("this pod has no propBearing configured in /pod/config.lua", 0)
end

-- One bearing only. Each corner is a counter-rotating PAIR, so tilting just
-- one leaves the other as an in-place control: if both change, something other
-- than the manual target is responsible.
local targetName = names[1]
local controlName = names[2]

if not peripheral.isPresent(targetName) then
    error("bearing not present: " .. targetName, 0)
end

note("=== yaw probe: does getThrustVector populate with a manual target? ===")
note("corner      " .. tostring(config.corner))
note("target      " .. targetName)
note("control     " .. tostring(controlName))
note("time        " .. tostring(os.epoch("utc")))
note("")
note("Safe to run at 0 RPM: run 1 showed getThrustVector is geometric, not")
note("thrust-gated, so the tracking question is answerable with props stopped.")
note("Keep the ion banks DISARMED either way.")

local target = peripheral.wrap(targetName)
local control = controlName and peripheral.isPresent(controlName)
    and peripheral.wrap(controlName) or nil

local baseline = snapshot(target, "BASELINE (no manual target)")
local controlBaseline = control and snapshot(control, "BASELINE (control bearing)") or nil

local accepted = discoverSignature(target)

if not accepted then
    note("")
    note("RESULT: setManualTarget rejected every candidate signature.")
    note("The error text above is the finding -- it names what it wanted.")
else
    note("")
    note("Accepted signature: " .. accepted.label)

    local neutral = snapshot(target, "AFTER neutral target " .. accepted.label)
    diff(baseline, neutral, "neutral target set")

    -- Now an actual tilt. Small: this is a question, not a manoeuvre, and at
    -- 16 RPM the corner carries about 3% of craft weight, so redirecting it
    -- cannot do anything dramatic.
    local tilted = nil
    local tiltArgs = {}
    for index, value in ipairs(accepted.args) do
        tiltArgs[index] = value
    end

    -- ~10 degrees off vertical, tilted toward +X (bow). Small on purpose: this
    -- is a question, not a manoeuvre.
    local TILT = { 0.174, 0.985, 0 }

    if type(accepted.args[1]) == "table" then
        if type(accepted.args[1][1]) == "number" then
            tiltArgs[1] = TILT                              -- array form
        else
            tiltArgs[1] = { x = TILT[1], y = TILT[2], z = TILT[3] }
        end
    elseif #accepted.args == 3 then
        tiltArgs = { TILT[1], TILT[2], TILT[3] }
    elseif #accepted.args == 1 and type(accepted.args[1]) == "number" then
        tiltArgs[1] = 10                                    -- degrees, probably
    end

    if #tiltArgs > 0 then
        local succeeded, rendered = call(target, "setManualTarget", table.unpack(tiltArgs))
        note("")
        note("Tilt command " .. render(tiltArgs) .. " -> "
            .. (succeeded and ("OK " .. rendered) or ("rejected: " .. rendered)))

        if succeeded then
            sleep(SETTLE_SECONDS)
            tilted = snapshot(target, "AFTER tilt, settled " .. SETTLE_SECONDS .. "s")
            diff(baseline, tilted, "tilt applied")

            if control then
                local controlAfter = snapshot(control, "control bearing after tilt")
                diff(controlBaseline, controlAfter, "control bearing (should be unchanged)")
            end
        end
    end

    -- Always hand the bearing back, whatever happened above.
    local cleared, clearError = call(target, "clearManualTarget")
    note("")
    note("clearManualTarget -> " .. (cleared and "OK" or ("FAILED: " .. clearError)))
    sleep(SETTLE_SECONDS)
    local restored = snapshot(target, "AFTER clearManualTarget")
    diff(baseline, restored, "returned to baseline?")

    note("")
    if tilted then
        -- Run 1 already killed the original question: getThrustVector is NOT
        -- nil, it returns an array vector {1=,2=,3=} even at zero thrust, and
        -- it agrees exactly with getBlockNormal and getFacingVector. Whoever
        -- recorded it as nil was indexing .x/.y/.z on an array table -- the
        -- same shape mistake as the {v=,a=} quaternion in bug 3.
        --
        -- So the question is no longer "does it populate" but "does it TRACK".
        -- If the vector below moved with the commanded tilt, vectoring is
        -- closed-loop. If it did not move, the vector is decorative geometry
        -- and vectoring stays open-loop.
        note("ANSWER -- does getThrustVector track a commanded tilt?")
        note("  baseline      " .. tostring(baseline.getThrustVector))
        note("  commanded     " .. render(tiltArgs))
        note("  after tilt    " .. tostring(tilted.getThrustVector))
        note("  getTiltAngle  " .. tostring(baseline.getTiltAngle)
            .. "  ->  " .. tostring(tilted.getTiltAngle))
        note("  getAngle      " .. tostring(baseline.getAngle)
            .. "  ->  " .. tostring(tilted.getAngle))
    end
end

local file = fs.open(REPORT_PATH, "w")
file.write(table.concat(lines, "\n"))
file.close()
print("")
print("Report written to " .. REPORT_PATH)
