-- THROWAWAY PROBE -- does anything resist the craft rolling over?
--
--     /pod/stabprobe.lua
--
-- Read-only. Calls no setter, arms nothing, commands nothing. Safe grounded,
-- safe in flight, safe at any time.
--
-- ---------------------------------------------------------------------------
-- THE QUESTION, AND WHY IT GATES FLYING AT ALL
--
-- RR's bearing_5 is 1.121% down, which is a STANDING roll torque of about
-- 0.073% of craft weight. The smallest ion trim available on a corner is one
-- power level = 5.57% of weight, because setPowerNormalized quantises to 15
-- levels. Needed / available = 0.013 -- the correction is 76x smaller than the
-- finest available control input, so ion power CANNOT cancel it.
--
-- Unopposed, that torque integrates:
--
--     after  30 s ->   5.0 deg
--     after  60 s ->  20.1 deg
--     after 120 s ->  80.4 deg
--     after 180 s -> 180.9 deg   (inverted)
--
-- tools/cc_harness.lua reproduces exactly this: a full axis-response run ends
-- at roll -203 deg. It lands gently, and upside down.
--
-- But the harness deliberately models NO restoring moment, because nobody has
-- measured one. So the harness is the WORST CASE, not necessarily the truth.
-- If something resists rotation, the drift is bounded and flying is fine. If
-- nothing does, no flight test is safe until fine attitude trim exists.
--
-- ---------------------------------------------------------------------------
-- WHAT THIS CAN AND CANNOT SETTLE
--
-- CAN settle, decisively, for free:
--   * whether getStabilizationStrength is zero. Zero is a definitive "nothing
--     is holding the bearing", and no flight is needed to learn it.
--   * whether the physics config carries any angular damping term at all.
--   * the inertia tensor's ACTUAL axis mapping, via getInertiaTensor -- which
--     HANDOFF.md has never pinned down (it reports Ixx/Iyy/Izz and separately
--     that "roll is ~4.5x cheaper", without saying which index is roll).
--
-- CANNOT settle:
--   * whether the CRAFT self-levels. Note carefully that
--     getStabilizationStrength is a method on the BEARING, so it most likely
--     describes how firmly the bearing holds its OWN angle -- not whether the
--     hull returns to level. A nonzero reading is therefore NOT proof of
--     self-levelling.
--   * the magnitude of any restoring moment. That needs a deliberate tilt in
--     flight, watching whether the rate plateaus (damping), decays (restoring)
--     or grows without limit (nothing).
--
-- `universalDrag` is worth attention: if it applies to ANGULAR velocity, the
-- roll reaches a terminal rate instead of accelerating, and the angle grows
-- linearly rather than quadratically. That is not self-levelling, but it is
-- the difference between "inverted in 3 minutes" and "manageable".
-- ---------------------------------------------------------------------------

package.path = "/?.lua;/?/init.lua;" .. package.path

local config = require("pod.config")

local REPORT_PATH = "/pod/stabprobe.txt"

local lines = {}
local function note(text)
    lines[#lines + 1] = text
    print(text)
end

local function render(value, depth)
    depth = depth or 0
    local kind = type(value)
    if kind == "nil" then return "nil" end
    if kind == "number" then return string.format("%.8f", value) end
    if kind == "string" then return string.format("%q", value) end
    if kind == "boolean" then return tostring(value) end
    if kind == "function" then return "<function>" end
    if kind ~= "table" then return "<" .. kind .. ">" end
    if depth > 3 then return "<table, deeper>" end

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

local function try(label, callback)
    local ok, value = pcall(callback)
    if not ok then
        note(string.format("  %-30s ERROR %s", label, tostring(value)))
        return nil
    end
    note(string.format("  %-30s %s", label, render(value)))
    return value
end

-- Everything below runs inside a pcall so the report is written even when a
-- probe line raises. The first run died on the inertia tensor and took the
-- ENTIRE report with it, including the bearing readings that had already been
-- gathered -- which is the one thing a diagnostic must never do.
local function writeReportNow()
    local file = fs.open(REPORT_PATH, "w")
    if file then
        file.write(table.concat(lines, "\n"))
        file.close()
    end
end

local probeOk, probeErr = pcall(function()

note("=== stabilization probe ===")
note("corner " .. tostring(config.corner))
note("time   " .. tostring(os.epoch("utc")))

-- ---------------------------------------------------------------------------
-- The bearings
-- ---------------------------------------------------------------------------

local function bearingNames()
    local configured = config.propBearing
    if type(configured) == "string" and configured ~= "" then return { configured } end
    if type(configured) == "table" then
        local names = {}
        for _, name in ipairs(configured) do
            if type(name) == "string" and name ~= "" then names[#names + 1] = name end
        end
        return names
    end
    return {}
end

note("")
note("-- bearings on this pod --")

local anyStabilization = false
local anyActive = false
for _, name in ipairs(bearingNames()) do
    note("")
    note("  " .. name)
    if not peripheral.isPresent(name) then
        note("    NOT PRESENT")
    else
        local bearing = peripheral.wrap(name)
        for _, getter in ipairs({
            -- getThrust and getSailPower lead deliberately: they are the two
            -- numbers a sail-count repair is verified with, and this probe
            -- shipped without either, so the one reading that mattered most
            -- was the one it could not return.
            "getThrust", "getSailPower",
            "getStabilizationStrength", "isActive", "isAssembled",
            "getStressImpact", "getStressContribution", "getTiltAngle",
            "getAngle", "getAngularSpeed", "getRotationSpeed",
        }) do
            if type(bearing[getter]) == "function" then
                local ok, value = pcall(bearing[getter])
                note(string.format("    %-28s %s", getter, ok and render(value) or ("ERROR " .. tostring(value))))
                if getter == "getStabilizationStrength" and ok
                    and type(value) == "number" and value ~= 0 then
                    anyStabilization = true
                end
                if getter == "isActive" and ok and value == true then
                    anyActive = true
                end
            else
                note(string.format("    %-28s <absent>", getter))
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- The physics configuration
-- ---------------------------------------------------------------------------

note("")
note("-- aero physics config --")
if aero then
    local raw = try("aero.getRaw()", aero.getRaw)
    if raw then
        note("")
        note("  universalDrag = " .. render(raw.universalDrag))
        note("  If that applies to ANGULAR velocity the roll reaches a terminal")
        note("  rate and the angle grows linearly, not quadratically. This dump")
        note("  cannot tell which; only a flight can.")
    end
    if type(aero.getUniversalDrag) == "function" then
        try("aero.getUniversalDrag()", aero.getUniversalDrag)
    end
else
    note("  aero API unavailable")
end

-- ---------------------------------------------------------------------------
-- The craft: inertia tensor and current rates
--
-- HANDOFF.md reports Ixx/Iyy/Izz = 3.89e8/4.36e8/8.68e7 and, separately, that
-- "roll is ~4.5x cheaper than pitch/yaw" -- without ever saying which index is
-- roll. 3.89e8/8.68e7 = 4.48, so the SMALLEST component is the roll axis, but
-- which of x/y/z that is has never been pinned down. Everything that weights
-- roll against pitch depends on it.
-- ---------------------------------------------------------------------------

note("")
note("-- craft --")
if sublevel and sublevel.isInPlotGrid and sublevel.isInPlotGrid() then
    try("getMass()", sublevel.getMass)
    if type(sublevel.getInertiaTensor) == "function" then
        local tensor = try("getInertiaTensor()", sublevel.getInertiaTensor)
        if type(tensor) == "table" then
            -- `rows` and `columns` are DIMENSION COUNTS (3.0), not containers.
            -- Indexing them as tables is what crashed the first run of this
            -- probe with "attempt to index field 'rows' (a number value)".
            -- The matrix itself is tensor[i][j], as HANDOFF.md says.
            note("")
            note(string.format("  shape: rows=%s columns=%s",
                tostring(tensor.rows), tostring(tensor.columns)))

            local diagonal = {}
            note("  diagonal:")
            for index = 1, 3 do
                local row = tensor[index]
                local value = type(row) == "table" and row[index] or nil
                diagonal[index] = value
                note(string.format("    t[%d][%d] = %s", index, index, render(value)))
            end

            -- Which axis is cheap, and does it agree with what HANDOFF.md says?
            local smallest, smallestIndex = nil, nil
            for index = 1, 3 do
                if type(diagonal[index]) == "number"
                    and (not smallest or diagonal[index] < smallest) then
                    smallest, smallestIndex = diagonal[index], index
                end
            end
            if smallestIndex then
                local names = { "X (bow)", "Y (up)", "Z (starboard)" }
                local motion = { "ROLL", "YAW", "PITCH" }
                note("")
                note(string.format("  cheapest axis: index %d = %s -> %s",
                    smallestIndex, names[smallestIndex], motion[smallestIndex]))
                note("  ...IF fcs/config.lua's convention (+X bow, +Y up, +Z starboard)")
                note("  is correct. That config says to change signs only after an")
                note("  axis-calibration test, which has never been run -- so treat")
                note("  the LABEL as unverified even though the NUMBER is solid.")
                note("  HANDOFF.md calls the cheap axis roll; this says pitch.")
            end

            -- Products of inertia: how badly are the axes coupled?
            note("")
            note("  off-diagonal (axis coupling):")
            for _, pair in ipairs({ { 1, 2 }, { 1, 3 }, { 2, 3 } }) do
                local i, j = pair[1], pair[2]
                local rowI = tensor[i]
                local value = type(rowI) == "table" and rowI[j] or nil
                if type(value) == "number" and diagonal[i] and diagonal[j] then
                    local reference = math.min(diagonal[i], diagonal[j])
                    note(string.format("    t[%d][%d] = %16.2f  = %.2f%% of the smaller diagonal",
                        i, j, value, math.abs(value) / reference * 100))
                end
            end
            note("  A large product of inertia means the principal axes are NOT")
            note("  the body axes: torque about one axis rotates the craft about")
            note("  another. The allocator may ignore this; a controller cannot.")
        end
    else
        note("  getInertiaTensor <absent>")
    end

    -- Sample angular velocity twice. Grounded it should read zero twice; a
    -- nonzero or growing reading while supposedly at rest is itself a finding.
    local first = try("getAngularVelocity() #1", sublevel.getAngularVelocity)
    sleep(3)
    local second = try("getAngularVelocity() #2 (+3s)", sublevel.getAngularVelocity)
    if type(first) == "table" and type(second) == "table" then
        note(string.format("  change over 3 s: dx=%.6f dy=%.6f dz=%.6f",
            (second.x or 0) - (first.x or 0),
            (second.y or 0) - (first.y or 0),
            (second.z or 0) - (first.z or 0)))
    end
else
    note("  not on a Sable sublevel")
end

-- ---------------------------------------------------------------------------

note("")
note("=== VERDICT ===")

if not anyActive then
    note("INCONCLUSIVE -- every bearing reported isActive = false.")
    note("")
    note("getStabilizationStrength reads 0 here, but a ZERO FROM AN INACTIVE")
    note("BEARING PROVES NOTHING. This is the same confound that produced a")
    note("false null in the yaw probe: at 0 RPM the bearing accepted")
    note("setManualTarget and ignored it entirely, and only with isActive =")
    note("true did it actually track the target.")
    note("")
    note("Re-run with the propellers turning:")
    note("  /fcs/propctl.lua <corner> 16     then this probe again")
    note("16 RPM carries 13% of craft weight, against a props-only hover")
    note("bracketed at 122-124, so it cannot lift.")
elseif anyStabilization then
    note("Bearings are ACTIVE and getStabilizationStrength is NONZERO.")
    note("That is still NOT proof the hull self-levels -- it is a bearing")
    note("method and most likely describes how firmly the bearing holds its")
    note("own angle.")
    note("")
    note("Next: a short low-altitude flight, deliberately tilted, watching")
    note("whether the roll rate plateaus (damping), decays (restoring) or")
    note("grows without limit (nothing).")
else
    note("Bearings are ACTIVE and getStabilizationStrength is ZERO.")
    note("THIS is the decisive negative the inactive run could not give.")
    note("")
    note("Nothing holds the bearings, and ion power is 76x too coarse to trim")
    note("the RR deficit (needed 0.073% of weight, finest available 5.57%).")
    note("Working assumption: the craft WILL roll over, inverted in about 3")
    note("minutes unless universalDrag bounds the rate.")
    note("DO NOT FLY the axis-response run until fine attitude trim exists.")
end

end)

if not probeOk then
    note("")
    note("PROBE RAISED: " .. tostring(probeErr))
    note("Everything gathered before that point is above and still usable.")
end

writeReportNow()
print("")
print("Report written to " .. REPORT_PATH)
