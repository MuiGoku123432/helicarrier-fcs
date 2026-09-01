local survey = {}

local EXPECTED_THRUSTERS = 32
local CONFIG_FILENAME = "config.lua"
local DEFAULT_LAYOUT = "/pod/ion-layout.lua"
local REPORT_PREFIX = "/pod/ion-cluster-survey"
local ZERO_EPSILON = 1e-6
local BALANCE_EPSILON = 1e-6
local TIMING_CONFIRMATION = "ZERO-WRITE-TIMING"
local RESTRAINED_CONFIRMATION = "RESTRAINED-ION-SURVEY"
local IDENTIFY_CONFIRMATION = "RESTRAINED-ION-IDENTIFY"
local IDENTIFY_LEVEL = 1
local IDENTIFY_PULSE_SECONDS = 0.25

local function finite(value)
    return type(value) == "number"
        and value == value
        and value > -math.huge
        and value < math.huge
end

local function copyArray(values)
    local result = {}
    for index, value in ipairs(values or {}) do
        result[index] = value
    end
    return result
end

function survey.numericPeripheralId(name)
    if type(name) ~= "string" then
        return nil
    end
    return tonumber(string.match(name, "_(%d+)$"))
end

function survey.sortedThrusterNames(names)
    local ordered = copyArray(names)
    table.sort(ordered, function(left, right)
        local leftId = survey.numericPeripheralId(left)
        local rightId = survey.numericPeripheralId(right)
        if leftId and rightId and leftId ~= rightId then
            return leftId < rightId
        end
        if leftId and not rightId then
            return true
        end
        if rightId and not leftId then
            return false
        end
        return tostring(left) < tostring(right)
    end)
    return ordered
end

function survey.classifyIdentifyResponse(response)
    local text = tostring(response or "")
    text = string.match(text, "^%s*(.-)%s*$")
    local lowered = string.lower(text)
    if text == "" then
        return nil, "enter a position label, R, S, or Q"
    elseif lowered == "r" or lowered == "repeat" then
        return { action = "repeat" }
    elseif lowered == "s" or lowered == "skip" then
        return { action = "skip" }
    elseif lowered == "q" or lowered == "quit" then
        return { action = "quit" }
    end
    return { action = "label", label = text }
end

local function sortedKeys(values)
    local result = {}
    for key in pairs(values or {}) do
        result[#result + 1] = key
    end
    table.sort(result)
    return result
end

local function contains(values, wanted)
    for _, value in ipairs(values or {}) do
        if value == wanted then
            return true
        end
    end
    return false
end

local function mean(values)
    if #values == 0 then
        return 0
    end
    local total = 0
    for _, value in ipairs(values) do
        total = total + value
    end
    return total / #values
end

local function percentile(values, fraction)
    if #values == 0 then
        return 0
    end
    local ordered = copyArray(values)
    table.sort(ordered)
    local index = math.max(1, math.min(#ordered,
        math.ceil(#ordered * fraction)))
    return ordered[index]
end

local function round(value, places)
    local scale = 10 ^ (places or 6)
    return math.floor(value * scale + 0.5) / scale
end

function survey.validateManifest(names, expectedCount, peripheralApi)
    local expected = expectedCount or EXPECTED_THRUSTERS
    local errors = {}
    local seen = {}
    local entries = {}

    if type(names) ~= "table" then
        return nil, { "manifest must return a table" }
    end
    if #names ~= expected then
        errors[#errors + 1] = "thruster count mismatch: expected "
            .. tostring(expected) .. ", found " .. tostring(#names)
    end

    for index, name in ipairs(names) do
        if type(name) ~= "string" or name == "" then
            errors[#errors + 1] = "manifest entry " .. tostring(index)
                .. " is not a non-empty peripheral name"
        elseif seen[name] then
            errors[#errors + 1] = "duplicate thruster name: " .. name
        else
            seen[name] = true
            local present = peripheralApi and peripheralApi.isPresent(name) or nil
            local correctType = peripheralApi
                and peripheralApi.hasType(name, "ion_thruster") or nil
            local methods = peripheralApi and peripheralApi.getMethods(name) or {}
            entries[#entries + 1] = {
                index = index,
                name = name,
                present = present,
                ionThruster = correctType,
                methods = methods or {},
            }
            if peripheralApi and not present then
                errors[#errors + 1] = "missing manifest thruster: " .. name
            elseif peripheralApi and not correctType then
                errors[#errors + 1] = "manifest device is not ion_thruster: " .. name
            elseif peripheralApi and not contains(methods, "setPowerNormalized") then
                errors[#errors + 1] = "thruster lacks setPowerNormalized: " .. name
            end
        end
    end

    table.sort(entries, function(left, right)
        return left.name < right.name
    end)
    if #errors > 0 then
        return entries, errors
    end
    return entries, nil
end

function survey.layoutTemplate(names)
    local ordered = copyArray(names)
    table.sort(ordered)
    local lines = {
        "-- Fill in the physical map, define balanced patterns, then set approved=true.",
        "-- x/z are block offsets from the pod cluster's thrust center.",
        "-- mirror must name the thruster at the opposite x/z position.",
        "return {",
        "    version = 1,",
        "    approved = false,",
        "    thrusters = {",
    }
    for _, name in ipairs(ordered) do
        lines[#lines + 1] = string.format(
            "        { name = %q, mapped = false, x = 0, y = 0, z = 0, mirror = %q, bank = %q },",
            name, "UNMAPPED", "UNMAPPED")
    end
    lines[#lines + 1] = "    },"
    lines[#lines + 1] = "    patterns = {"
    lines[#lines + 1] = "        -- checker_a = { \"thruster name\", ... },"
    lines[#lines + 1] = "        -- checker_b = { \"thruster name\", ... },"
    lines[#lines + 1] = "    },"
    lines[#lines + 1] = "}"
    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
end

local function indexManifest(manifestNames)
    local manifest = {}
    for _, name in ipairs(manifestNames or {}) do
        manifest[name] = true
    end
    return manifest
end

local function validateLayoutThrusters(layout, manifest, errors)
    local mapped = {}
    if type(layout.thrusters) ~= "table" then
        errors[#errors + 1] = "layout.thrusters must be a table"
        return mapped
    end

    for index, entry in ipairs(layout.thrusters) do
        local label = "layout thruster " .. tostring(index)
        if type(entry) ~= "table" or type(entry.name) ~= "string" then
            errors[#errors + 1] = label .. " has no name"
        elseif mapped[entry.name] then
            errors[#errors + 1] = "duplicate layout thruster: " .. entry.name
        else
            mapped[entry.name] = entry
            if not manifest[entry.name] then
                errors[#errors + 1] = "layout contains unknown thruster: "
                    .. entry.name
            end
            if entry.mapped ~= true then
                errors[#errors + 1] = "thruster is not physically mapped: "
                    .. entry.name
            end
            if not finite(entry.x) or not finite(entry.y) or not finite(entry.z) then
                errors[#errors + 1] = "thruster has invalid coordinates: "
                    .. entry.name
            end
            if type(entry.mirror) ~= "string" or entry.mirror == entry.name then
                errors[#errors + 1] = "thruster has invalid mirror: "
                    .. entry.name
            end
            if type(entry.bank) ~= "string" or entry.bank == "UNMAPPED" then
                errors[#errors + 1] = "thruster has no allocation bank: "
                    .. entry.name
            end
        end
    end
    for name in pairs(manifest) do
        if not mapped[name] then
            errors[#errors + 1] = "manifest thruster missing from layout: " .. name
        end
    end
    return mapped
end

local function validateMirrors(mapped, errors)
    for name, entry in pairs(mapped) do
        local opposite = mapped[entry.mirror]
        if not opposite then
            errors[#errors + 1] = "mirror not found for " .. name .. ": "
                .. tostring(entry.mirror)
        elseif opposite.mirror ~= name then
            errors[#errors + 1] = "mirror relationship is not reciprocal: "
                .. name .. " / " .. entry.mirror
        elseif finite(entry.x) and finite(entry.z)
                and finite(opposite.x) and finite(opposite.z)
                and (math.abs(entry.x + opposite.x) > BALANCE_EPSILON
                    or math.abs(entry.z + opposite.z) > BALANCE_EPSILON) then
            errors[#errors + 1] = "mirror coordinates are not opposed: "
                .. name .. " / " .. entry.mirror
        end
    end
end

local function validatePattern(patternName, members, mapped, errors, warnings)
    local report = {
        name = patternName,
        count = type(members) == "table" and #members or 0,
        sumX = 0,
        sumZ = 0,
        members = copyArray(members),
    }
    if type(members) ~= "table" or #members == 0 then
        errors[#errors + 1] = "pattern is empty or invalid: "
            .. tostring(patternName)
        return report
    end

    local patternSeen = {}
    for _, name in ipairs(members) do
        local entry = mapped[name]
        if patternSeen[name] then
            errors[#errors + 1] = "pattern contains duplicate "
                .. tostring(name) .. ": " .. tostring(patternName)
        elseif not entry then
            errors[#errors + 1] = "pattern contains unknown thruster "
                .. tostring(name) .. ": " .. tostring(patternName)
        else
            patternSeen[name] = true
            if finite(entry.x) and finite(entry.z) then
                report.sumX = report.sumX + entry.x
                report.sumZ = report.sumZ + entry.z
            end
        end
    end
    if math.abs(report.sumX) > BALANCE_EPSILON
            or math.abs(report.sumZ) > BALANCE_EPSILON then
        errors[#errors + 1] = "pattern center of thrust is not balanced: "
            .. tostring(patternName)
    end
    if #members % 2 ~= 0 then
        warnings[#warnings + 1] = "pattern has an odd member count: "
            .. tostring(patternName)
    end
    return report
end

local function validatePatterns(layout, mapped, errors, warnings)
    local reports = {}
    if type(layout.patterns) ~= "table" then
        errors[#errors + 1] = "layout.patterns must be a table"
        return reports
    end
    for _, patternName in ipairs(sortedKeys(layout.patterns)) do
        reports[#reports + 1] = validatePattern(
            patternName, layout.patterns[patternName], mapped, errors, warnings)
    end
    if #reports < 2 then
        warnings[#warnings + 1] = "define at least two complementary balanced patterns"
    end
    return reports
end

function survey.validateLayout(layout, manifestNames, requireApproval)
    local errors = {}
    local warnings = {}
    if type(layout) ~= "table" then
        return nil, { "layout must return a table" }, warnings
    end
    if layout.version ~= 1 then
        errors[#errors + 1] = "layout version must be 1"
    end
    if requireApproval and layout.approved ~= true then
        errors[#errors + 1] = "layout is not approved"
    end

    local manifest = indexManifest(manifestNames)
    local mapped = validateLayoutThrusters(layout, manifest, errors)
    validateMirrors(mapped, errors)
    local patternReports = validatePatterns(
        layout, mapped, errors, warnings)
    if #errors > 0 then
        return patternReports, errors, warnings
    end
    return patternReports, nil, warnings
end

function survey.patternLevels(names, members, baseLevel, highLevel)
    local base = tonumber(baseLevel)
    local high = tonumber(highLevel)
    if not finite(base) or not finite(high)
            or base < 0 or high < base or high > 15 then
        error("invalid analog levels", 0)
    end
    local selected = {}
    for _, name in ipairs(members or {}) do
        selected[name] = true
    end
    local levels = {}
    local total = 0
    for _, name in ipairs(names or {}) do
        local level = selected[name] and high or base
        levels[name] = level / 15
        total = total + level
    end
    return levels, {
        baseLevel = base,
        highLevel = high,
        highCount = #(members or {}),
        totalQuanta = total,
        averageLevel = #names > 0 and total / #names or 0,
        averagePower = #names > 0 and total / (#names * 15) or 0,
    }
end

function survey.identifyLevels(names, targetName)
    local levels = {}
    local matches = 0
    for _, name in ipairs(names or {}) do
        if name == targetName then
            levels[name] = IDENTIFY_LEVEL / 15
            matches = matches + 1
        else
            levels[name] = 0
        end
    end
    if matches ~= 1 then
        error("identify target must appear exactly once: "
            .. tostring(targetName), 0)
    end
    return levels
end

local function readGetter(device, methodName)
    if type(device[methodName]) ~= "function" then
        return nil, "unsupported"
    end
    local ok, value = pcall(device[methodName])
    if not ok then
        return nil, tostring(value)
    end
    return value, nil
end

local function readDevice(name, device)
    local power, powerError = readGetter(device, "getPower")
    local thrust, thrustError = readGetter(device, "getCurrentThrustKN")
    local energy, energyError = readGetter(device, "getEnergyAmountFe")
    local capacity, capacityError = readGetter(device, "getEnergyCapacityFe")
    local obstruction, obstructionError = readGetter(device, "getObstruction")
    return {
        name = name,
        power = power,
        powerError = powerError,
        thrustKN = thrust,
        thrustError = thrustError,
        energyFE = energy,
        energyError = energyError,
        capacityFE = capacity,
        capacityError = capacityError,
        obstruction = obstruction,
        obstructionError = obstructionError,
    }
end

local function runBatched(jobs, requestedSize)
    local size = math.max(1, math.floor(tonumber(requestedSize) or 1))
    for first = 1, #jobs, size do
        local batch = {}
        local last = math.min(first + size - 1, #jobs)
        for index = first, last do
            batch[#batch + 1] = jobs[index]
        end
        parallel.waitForAll(table.unpack(batch))
    end
end

local function wrapDevices(names)
    local devices = {}
    for _, name in ipairs(names) do
        local device = peripheral.wrap(name)
        if not device then
            error("failed to wrap thruster " .. name, 0)
        end
        devices[name] = device
    end
    return devices
end

local function applyLevels(names, devices, levels, batchSize)
    local results = {}
    local jobs = {}
    for index, name in ipairs(names) do
        jobs[index] = function()
            local started = os.epoch("utc")
            local ok, applyError = pcall(
                devices[name].setPowerNormalized,
                levels[name] or 0
            )
            results[index] = {
                name = name,
                requestedPower = levels[name] or 0,
                ok = ok,
                error = ok and nil or tostring(applyError),
                durationMs = os.epoch("utc") - started,
            }
        end
    end
    local started = os.epoch("utc")
    runBatched(jobs, batchSize)
    local elapsed = os.epoch("utc") - started
    for _, result in ipairs(results) do
        if not result.ok then
            error("ion write failed for " .. result.name .. ": "
                .. tostring(result.error), 0)
        end
    end
    return results, elapsed
end

local function readAll(names, devices, batchSize)
    local results = {}
    local jobs = {}
    for index, name in ipairs(names) do
        jobs[index] = function()
            results[index] = readDevice(name, devices[name])
        end
    end
    runBatched(jobs, batchSize)
    return results
end

local function readPowerAll(names, devices, batchSize)
    local results = {}
    local jobs = {}
    for index, name in ipairs(names) do
        jobs[index] = function()
            local power, powerError = readGetter(devices[name], "getPower")
            results[index] = {
                name = name,
                power = power,
                powerError = powerError,
            }
        end
    end
    runBatched(jobs, batchSize)
    return results
end

local function zeroAll(names, devices)
    local levels = {}
    for _, name in ipairs(names) do
        levels[name] = 0
    end
    local ok, result, elapsed = pcall(applyLevels,
        names, devices, levels, 32)
    return ok, result, elapsed
end

local function zeroVerified(readings)
    for _, reading in ipairs(readings or {}) do
        if not finite(reading.power)
                or math.abs(reading.power) > ZERO_EPSILON then
            return false, reading.name .. " reported nonzero/invalid power "
                .. tostring(reading.power)
        end
    end
    return true
end

local function loadManifest(path)
    if not fs.exists(path) then
        error("thruster manifest is missing: " .. path, 0)
    end
    local names = dofile(path)
    local entries, errors = survey.validateManifest(
        names, EXPECTED_THRUSTERS, peripheral)
    if errors then
        error(table.concat(errors, "; "), 0)
    end
    local ordered = {}
    for _, entry in ipairs(entries) do
        ordered[#ordered + 1] = entry.name
    end
    return ordered, entries
end

local function loadLayout(path, names, requireApproval)
    if not fs.exists(path) then
        error("ion layout is missing: " .. path, 0)
    end
    local layout = dofile(path)
    local reports, errors, warnings = survey.validateLayout(
        layout, names, requireApproval)
    if errors then
        error(table.concat(errors, "; "), 0)
    end
    return layout, reports, warnings
end

local function writeText(path, content)
    local handle, openError = fs.open(path, "w")
    if not handle then
        error("cannot write " .. path .. ": " .. tostring(openError), 0)
    end
    handle.write(content)
    handle.close()
end

local function serialize(value)
    if textutils.serialize then
        return textutils.serialize(value, { compact = false })
    end
    return tostring(value)
end

local function reportPath(stage)
    return REPORT_PREFIX .. "-" .. tostring(os.getComputerID()) .. "-"
        .. stage .. "-" .. tostring(os.epoch("utc")) .. ".txt"
end

local function saveReport(stage, report)
    local path = reportPath(stage)
    writeText(path, serialize(report))
    return path
end

local function requireTyped(phrase)
    print("Type " .. phrase .. " to continue:")
    local entered = read()
    if entered ~= phrase then
        error("confirmation did not match; no powered command sent", 0)
    end
end

local function inventory(manifestPath, layoutPath)
    local names, entries = loadManifest(manifestPath)
    local devices = wrapDevices(names)
    local readings = readAll(names, devices, 8)
    local templateCreated = false
    if not fs.exists(layoutPath) then
        writeText(layoutPath, survey.layoutTemplate(names))
        templateCreated = true
    end
    local report = {
        schema = "ion_cluster_survey",
        version = 1,
        stage = "inventory",
        computerId = os.getComputerID(),
        collectedAt = os.epoch("utc"),
        expectedThrusters = EXPECTED_THRUSTERS,
        manifestPath = manifestPath,
        layoutPath = layoutPath,
        layoutTemplateCreated = templateCreated,
        entries = entries,
        readings = readings,
        noActuation = true,
    }
    local path = saveReport("inventory", report)
    print("Inventory complete: " .. path)
    if templateCreated then
        print("Map physical positions in " .. layoutPath)
        print("Define balanced patterns, then set approved=true.")
    else
        print("Existing layout preserved: " .. layoutPath)
    end
end

local function validate(manifestPath, layoutPath)
    local names = loadManifest(manifestPath)
    local _, patterns, warnings = loadLayout(layoutPath, names, false)
    local report = {
        schema = "ion_cluster_survey",
        version = 1,
        stage = "layout_validation",
        computerId = os.getComputerID(),
        collectedAt = os.epoch("utc"),
        layoutPath = layoutPath,
        patterns = patterns,
        warnings = warnings,
        valid = true,
    }
    local path = saveReport("layout", report)
    print("Layout is structurally valid: " .. path)
    for _, warning in ipairs(warnings or {}) do
        print("WARNING: " .. warning)
    end
end

local function timing(manifestPath)
    local names = loadManifest(manifestPath)
    local devices = wrapDevices(names)
    print("ZERO-OUTPUT WRITE TIMING ONLY")
    print("Stop the normal pod controller before continuing.")
    print("All 32 requested outputs remain exactly zero.")
    requireTyped(TIMING_CONFIRMATION)

    local zero = {}
    for _, name in ipairs(names) do
        zero[name] = 0
    end

    local report = {
        schema = "ion_cluster_survey",
        version = 1,
        stage = "zero_write_timing",
        computerId = os.getComputerID(),
        collectedAt = os.epoch("utc"),
        noNonzeroActuation = true,
    }

    local ok, runError = xpcall(function()
        report.sequential, report.sequentialTotalMs = applyLevels(
            names, devices, zero, 1)
        report.parallel, report.parallelTotalMs = applyLevels(
            names, devices, zero, 32)
        report.batched8, report.batched8TotalMs = applyLevels(
            names, devices, zero, 8)
        report.finalReadings = readAll(names, devices, 8)
        report.zeroVerified, report.zeroError = zeroVerified(report.finalReadings)
        if not report.zeroVerified then
            error(report.zeroError, 0)
        end

        local sequentialDurations = {}
        local parallelDurations = {}
        local batchDurations = {}
        for _, entry in ipairs(report.sequential) do
            sequentialDurations[#sequentialDurations + 1] = entry.durationMs
        end
        for _, entry in ipairs(report.parallel) do
            parallelDurations[#parallelDurations + 1] = entry.durationMs
        end
        for _, entry in ipairs(report.batched8) do
            batchDurations[#batchDurations + 1] = entry.durationMs
        end
        report.summary = {
            sequentialMeanMs = round(mean(sequentialDurations)),
            sequentialP95Ms = round(percentile(sequentialDurations, 0.95)),
            parallelMeanMs = round(mean(parallelDurations)),
            parallelP95Ms = round(percentile(parallelDurations, 0.95)),
            batched8MeanMs = round(mean(batchDurations)),
            batched8P95Ms = round(percentile(batchDurations, 0.95)),
        }
    end, function(message)
        return tostring(message)
    end)

    local shutdownOk, shutdownResult, shutdownElapsed = zeroAll(names, devices)
    report.shutdownWriteOk = shutdownOk
    report.shutdownWriteResult = shutdownResult
    report.shutdownWriteElapsedMs = shutdownElapsed
    report.runError = ok and nil or runError
    report.overall = ok and shutdownOk and "PASS" or "FAIL"
    local path = saveReport("timing", report)
    print("Timing report: " .. path)
    print("overall=" .. report.overall)
    if report.runError then
        error(report.runError, 0)
    end
end

local function precheckZero(names, devices)
    local shutdownOk = zeroAll(names, devices)
    if not shutdownOk then
        error("initial exact-zero write failed", 0)
    end
    sleep(0.5)
    local initial = readAll(names, devices, 8)
    local initialZero, initialError = zeroVerified(initial)
    if not initialZero then
        error("initial zero verification failed: "
            .. tostring(initialError), 0)
    end
    return initial
end

local function applyAndReadPattern(names, devices, levels)
    local writes, writeTotalMs = applyLevels(names, devices, levels, 8)
    sleep(0.75)
    return writes, writeTotalMs, readAll(names, devices, 8)
end

local function resetAfterPattern(names, devices, patternName)
    local zeroOk, _, zeroElapsed = zeroAll(names, devices)
    if not zeroOk then
        error("exact-zero write failed after " .. patternName, 0)
    end
    sleep(0.5)
    local readings = readAll(names, devices, 8)
    local verified, verifyError = zeroVerified(readings)
    if not verified then
        error("zero verification failed after " .. patternName
            .. ": " .. tostring(verifyError), 0)
    end
    return zeroElapsed, readings
end

local function runRestrainedPattern(names, devices, patternName, members)
    local levels, allocation = survey.patternLevels(names, members, 2, 3)
    local entry = {
        name = patternName,
        allocation = allocation,
        members = copyArray(members),
    }
    entry.writes, entry.writeTotalMs, entry.readings =
        applyAndReadPattern(names, devices, levels)
    entry.zeroWriteElapsedMs, entry.zeroReadings = resetAfterPattern(
        names, devices, patternName)
    entry.zeroWriteOk = true
    entry.zeroVerified = true
    return entry
end

local function explainRestrained(warnings)
    print("RESTRAINED POWERED ION PATTERN SURVEY")
    print("Stop the normal FCS and pod controller first.")
    print("The craft must be physically restrained.")
    print("Each pattern uses base level 2/15 and selected level 3/15.")
    print("Exact zero is sent between patterns and during finalization.")
    for _, warning in ipairs(warnings or {}) do
        print("WARNING: " .. warning)
    end
end

local function newRestrainedReport(layoutPath, patternReports)
    return {
        schema = "ion_cluster_survey",
        version = 1,
        stage = "restrained_patterns",
        computerId = os.getComputerID(),
        collectedAt = os.epoch("utc"),
        layoutPath = layoutPath,
        baseLevel = 2,
        highLevel = 3,
        patternValidation = patternReports,
        patterns = {},
    }
end

local function runRestrainedSequence(names, devices, patterns, report)
    report.initialReadings = precheckZero(names, devices)
    for _, patternName in ipairs(sortedKeys(patterns)) do
        report.patterns[#report.patterns + 1] = runRestrainedPattern(
            names, devices, patternName, patterns[patternName])
    end
end

local function finalizeRestrained(names, devices, report, ok, runError)
    local shutdownOk, shutdownResult, shutdownElapsed = zeroAll(names, devices)
    report.shutdownWriteOk = shutdownOk
    report.shutdownWriteResult = shutdownResult
    report.shutdownWriteElapsedMs = shutdownElapsed
    report.finalReadings = readAll(names, devices, 8)
    report.shutdownVerified, report.shutdownError = zeroVerified(
        report.finalReadings)
    report.runError = ok and nil or runError
    report.overall = ok and shutdownOk and report.shutdownVerified
        and "PASS" or "FAIL"
end

local function restrained(manifestPath, layoutPath)
    local names = loadManifest(manifestPath)
    local layout, patternReports, warnings = loadLayout(
        layoutPath, names, true)
    local devices = wrapDevices(names)

    explainRestrained(warnings)
    requireTyped(RESTRAINED_CONFIRMATION)
    local report = newRestrainedReport(layoutPath, patternReports)
    local ok, runError = xpcall(function()
        runRestrainedSequence(names, devices, layout.patterns, report)
    end, function(message)
        return tostring(message)
    end)
    finalizeRestrained(names, devices, report, ok, runError)

    local path = saveReport("restrained", report)
    print("Restrained survey report: " .. path)
    print("overall=" .. report.overall)
    if report.runError then
        error(report.runError, 0)
    end
    if not report.shutdownVerified then
        error("final exact-zero verification failed: "
            .. tostring(report.shutdownError), 0)
    end
end

local function promptIdentifyResult()
    while true do
        print("Enter position label, R=repeat, S=skip, or Q=quit:")
        local classified, classifyError = survey.classifyIdentifyResponse(read())
        if classified then
            return classified
        end
        print("Invalid response: " .. tostring(classifyError))
    end
end

local function applyIdentifyPulse(names, devices, name, levels)
    local poweredStarted = os.epoch("utc")
    local writes, writeTotalMs = applyLevels(names, devices, levels, 32)
    sleep(IDENTIFY_PULSE_SECONDS)
    local reading = readDevice(name, devices[name])
    return writes, writeTotalMs, reading,
        os.epoch("utc") - poweredStarted
end

local function resetIdentifyPulse(names, devices, name)
    local zeroOk, zeroResult, zeroElapsed = zeroAll(names, devices)
    if not zeroOk then
        error("exact-zero write failed after identifying " .. name, 0)
    end
    local readings = readPowerAll(names, devices, 32)
    local verified, verifyError = zeroVerified(readings)
    if not verified then
        error("zero verification failed after identifying " .. name
            .. ": " .. tostring(verifyError), 0)
    end
    return zeroResult, zeroElapsed, readings
end

local function runIdentifyPulse(names, devices, name)
    local entry = {
        name = name,
        numericId = survey.numericPeripheralId(name),
        requestedLevel = IDENTIFY_LEVEL,
        requestedPower = IDENTIFY_LEVEL / 15,
        pulseSeconds = IDENTIFY_PULSE_SECONDS,
    }
    local levels = survey.identifyLevels(names, name)
    entry.writes, entry.writeTotalMs, entry.pulseReading,
        entry.poweredDurationMs = applyIdentifyPulse(
            names, devices, name, levels)
    entry.zeroWriteResult, entry.zeroWriteElapsedMs,
        entry.zeroReadings = resetIdentifyPulse(names, devices, name)
    entry.zeroWriteOk = true
    entry.zeroVerified = true
    return entry
end

local function identifyOne(names, devices, report, index, ordered, name)
    while true do
        print(string.format("[%d/%d] Pulsing %s (ID %s) at 1/15",
            index, #ordered, name,
            tostring(survey.numericPeripheralId(name) or "unknown")))
        local entry = runIdentifyPulse(names, devices, name)
        print("Pulse complete; all 32 ions verified at exact zero.")
        local response = promptIdentifyResult()
        entry.operatorAction = response.action
        entry.operatorLabel = response.label
        report.pulses[#report.pulses + 1] = entry

        if response.action == "repeat" then
            print("Repeating " .. name)
        else
            report.processedCount = index
            if response.action == "label" then
                report.labels[name] = response.label
            elseif response.action == "skip" then
                report.skipped[#report.skipped + 1] = name
            end
            return response.action
        end
    end
end

local function runIdentifySequence(names, devices, report)
    report.initialReadings = precheckZero(names, devices)
    local ordered = survey.sortedThrusterNames(names)
    report.order = copyArray(ordered)
    for index, name in ipairs(ordered) do
        local action = identifyOne(
            names, devices, report, index, ordered, name)
        if action == "quit" then
            report.operatorQuit = true
            return
        end
    end
    report.complete = true
end

local function finalizeIdentify(names, devices, report, ok, runError)
    local shutdownOk, shutdownResult, shutdownElapsed = zeroAll(names, devices)
    report.shutdownWriteOk = shutdownOk
    report.shutdownWriteResult = shutdownResult
    report.shutdownWriteElapsedMs = shutdownElapsed
    report.finalReadings = readPowerAll(names, devices, 32)
    report.shutdownVerified, report.shutdownError = zeroVerified(
        report.finalReadings)
    report.runError = ok and nil or runError
    report.overall = ok and shutdownOk and report.shutdownVerified
        and "PASS" or "FAIL"
end

local function explainIdentify()
    print("RESTRAINED SINGLE-ION IDENTIFICATION")
    print("Stop the normal FCS and pod controller first.")
    print("The craft must be physically restrained.")
    print("Exactly one named ion pulses at minimum level 1/15.")
    print("All 32 ions are verified at zero before every prompt.")
end

local function newIdentifyReport(manifestPath)
    return {
        schema = "ion_cluster_survey",
        version = 1,
        stage = "identify",
        computerId = os.getComputerID(),
        collectedAt = os.epoch("utc"),
        manifestPath = manifestPath,
        confirmation = IDENTIFY_CONFIRMATION,
        pulseLevel = IDENTIFY_LEVEL,
        pulseSeconds = IDENTIFY_PULSE_SECONDS,
        processedCount = 0,
        complete = false,
        operatorQuit = false,
        pulses = {},
        labels = {},
        skipped = {},
    }
end

local function saveIdentifyReport(report)
    local path = saveReport("identify", report)
    print("Identification report: " .. path)
    print("overall=" .. report.overall
        .. " complete=" .. tostring(report.complete))
    if report.runError then
        error(report.runError, 0)
    end
    if not report.shutdownVerified then
        error("final exact-zero verification failed: "
            .. tostring(report.shutdownError), 0)
    end
end

local function identify(manifestPath)
    local names = loadManifest(manifestPath)
    local devices = wrapDevices(names)
    explainIdentify()
    requireTyped(IDENTIFY_CONFIRMATION)

    local report = newIdentifyReport(manifestPath)
    local ok, runError = xpcall(function()
        runIdentifySequence(names, devices, report)
    end, function(message)
        return tostring(message)
    end)
    finalizeIdentify(names, devices, report, ok, runError)
    saveIdentifyReport(report)
end

local function usage()
    print("Ion cluster survey (32 individually addressable thrusters)")
    print("No command actuates by default.")
    print("Usage:")
    print("  /pod/ion_cluster_survey.lua inventory")
    print("  /pod/ion_cluster_survey.lua validate")
    print("  /pod/ion_cluster_survey.lua timing")
    print("  /pod/ion_cluster_survey.lua identify")
    print("  /pod/ion_cluster_survey.lua restrained")
    print("Optional paths:")
    print("  --manifest <path>  (defaults to pod.config.manifestPath)")
    print("  --layout /pod/ion-layout.lua")
end

function survey.siblingConfigPath(runningProgram, pathApi)
    local api = pathApi or fs
    if type(runningProgram) ~= "string" or runningProgram == "" then
        error("running program path is unavailable", 0)
    end
    if type(api) ~= "table" or type(api.getDir) ~= "function"
            or type(api.combine) ~= "function" then
        error("filesystem path API is unavailable", 0)
    end
    local absoluteProgram = runningProgram
    if string.sub(absoluteProgram, 1, 1) ~= "/" then
        absoluteProgram = "/" .. absoluteProgram
    end
    return api.combine(api.getDir(absoluteProgram), CONFIG_FILENAME)
end

local function loadSiblingConfig()
    if type(shell) ~= "table" or type(shell.getRunningProgram) ~= "function" then
        error("shell.getRunningProgram is unavailable", 0)
    end
    local configPath = survey.siblingConfigPath(shell.getRunningProgram(), fs)
    if not fs.exists(configPath) and fs.exists("/pod/config.lua") then
        configPath = "/pod/config.lua"
    end
    if not fs.exists(configPath) then
        error("sibling pod config is missing: " .. configPath, 0)
    end
    return dofile(configPath)
end

function survey.configuredManifestPath(loader)
    local configLoader = loader or loadSiblingConfig
    local ok, config = pcall(configLoader)
    if not ok then
        error("cannot load sibling pod config: " .. tostring(config), 0)
    end
    if type(config) ~= "table" or type(config.manifestPath) ~= "string"
            or config.manifestPath == "" then
        error("pod config manifestPath is missing or invalid", 0)
    end
    return config.manifestPath
end

local function parse(arguments)
    local result = {
        command = arguments[1],
        manifestPath = survey.configuredManifestPath(),
        layoutPath = DEFAULT_LAYOUT,
    }
    local index = 2
    while index <= #arguments do
        local argument = arguments[index]
        if argument == "--manifest" then
            index = index + 1
            result.manifestPath = arguments[index]
        elseif argument == "--layout" then
            index = index + 1
            result.layoutPath = arguments[index]
        else
            error("unknown option " .. tostring(argument), 0)
        end
        if not result.manifestPath or not result.layoutPath then
            error("option requires a path", 0)
        end
        index = index + 1
    end
    return result
end

function survey.main(arguments)
    local options = parse(arguments or {})
    if options.command == "inventory" then
        inventory(options.manifestPath, options.layoutPath)
    elseif options.command == "validate" then
        validate(options.manifestPath, options.layoutPath)
    elseif options.command == "timing" then
        timing(options.manifestPath)
    elseif options.command == "identify" then
        identify(options.manifestPath)
    elseif options.command == "restrained" then
        restrained(options.manifestPath, options.layoutPath)
    else
        usage()
        if options.command then
            error("unknown command " .. tostring(options.command), 0)
        end
    end
end

local invocation = { ... }
if invocation[1] == "pod.ion_cluster_survey" then
    return survey
end

survey.main(invocation)
