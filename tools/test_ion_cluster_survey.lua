package.path = "pod-template/?.lua;pod-template/?/init.lua;" .. package.path

local survey = require("pod.ion_cluster_survey")

local checks = 0
local function assertTrue(value, message)
    checks = checks + 1
    if not value then
        error(message or "expected true", 0)
    end
end

local function assertEqual(actual, expected, message)
    checks = checks + 1
    if actual ~= expected then
        error((message or "values differ") .. ": expected "
            .. tostring(expected) .. ", got " .. tostring(actual), 0)
    end
end

local names = { "ion_d", "ion_b", "ion_a", "ion_c" }
local methods = {
    "setPowerNormalized",
    "getPower",
    "getCurrentThrustKN",
}
local fakePeripheral = {
    isPresent = function()
        return true
    end,
    hasType = function(_, wanted)
        return wanted == "ion_thruster"
    end,
    getMethods = function()
        return methods
    end,
}

local entries, manifestErrors = survey.validateManifest(
    names, 4, fakePeripheral)
assertEqual(manifestErrors, nil, "valid manifest")
assertEqual(#entries, 4, "manifest entry count")
assertEqual(entries[1].name, "ion_a", "inventory order is deterministic")
assertEqual(entries[4].name, "ion_d", "inventory sort upper bound")

local _, countErrors = survey.validateManifest(names, 32, nil)
assertTrue(countErrors ~= nil, "wrong thruster count rejected")
assertTrue(string.find(table.concat(countErrors, " "), "count mismatch", 1, true)
    ~= nil, "count mismatch explains failure")

local duplicateEntries, duplicateErrors = survey.validateManifest(
    { "ion_a", "ion_a" }, 2, nil)
assertTrue(duplicateEntries ~= nil, "duplicate inventory retained for report")
assertTrue(duplicateErrors ~= nil, "duplicate manifest rejected")

local template = survey.layoutTemplate(names)
assertTrue(string.find(template, "approved = false", 1, true) ~= nil,
    "generated layout starts unapproved")
assertTrue(string.find(template, "ion_a", 1, true) ~= nil,
    "generated layout includes peripheral names")
assertTrue(string.find(template, "UNMAPPED", 1, true) ~= nil,
    "generated layout requires physical mapping")

local layout = {
    version = 1,
    approved = true,
    thrusters = {
        { name = "ion_a", mapped = true, x = -1, y = 0, z = -1,
            mirror = "ion_d", bank = "A" },
        { name = "ion_b", mapped = true, x = 1, y = 0, z = -1,
            mirror = "ion_c", bank = "B" },
        { name = "ion_c", mapped = true, x = -1, y = 0, z = 1,
            mirror = "ion_b", bank = "B" },
        { name = "ion_d", mapped = true, x = 1, y = 0, z = 1,
            mirror = "ion_a", bank = "A" },
    },
    patterns = {
        checker_a = { "ion_a", "ion_d" },
        checker_b = { "ion_b", "ion_c" },
    },
}

local patternReports, layoutErrors, layoutWarnings = survey.validateLayout(
    layout, names, true)
assertEqual(layoutErrors, nil, "balanced approved layout")
assertEqual(#patternReports, 2, "two balanced patterns")
assertEqual(#layoutWarnings, 0, "balanced layout has no warnings")
assertEqual(patternReports[1].sumX, 0, "pattern x balance")
assertEqual(patternReports[1].sumZ, 0, "pattern z balance")

local unapproved = {
    version = layout.version,
    approved = false,
    thrusters = layout.thrusters,
    patterns = layout.patterns,
}
local _, approvalErrors = survey.validateLayout(unapproved, names, true)
assertTrue(approvalErrors ~= nil, "powered survey rejects unapproved layout")
assertTrue(string.find(table.concat(approvalErrors, " "),
    "not approved", 1, true) ~= nil, "approval failure is explicit")

local unbalanced = {
    version = 1,
    approved = true,
    thrusters = layout.thrusters,
    patterns = {
        bad = { "ion_a", "ion_b" },
        good = { "ion_a", "ion_d" },
    },
}
local _, balanceErrors = survey.validateLayout(unbalanced, names, true)
assertTrue(balanceErrors ~= nil, "unbalanced pattern rejected")
assertTrue(string.find(table.concat(balanceErrors, " "),
    "center of thrust", 1, true) ~= nil,
    "unbalanced failure explains center of thrust")

local levels, allocation = survey.patternLevels(
    names, layout.patterns.checker_a, 2, 3)
assertEqual(levels.ion_a, 3 / 15, "selected ion uses high level")
assertEqual(levels.ion_d, 3 / 15, "opposite ion uses high level")
assertEqual(levels.ion_b, 2 / 15, "unselected ion uses base level")
assertEqual(levels.ion_c, 2 / 15, "other unselected ion uses base level")
assertEqual(allocation.highCount, 2, "high count recorded")
assertEqual(allocation.totalQuanta, 10, "total quanta recorded")
assertEqual(allocation.averageLevel, 2.5, "average analog level")
assertEqual(allocation.averagePower, 2.5 / 15, "average normalized power")

local ok = pcall(survey.patternLevels, names,
    layout.patterns.checker_a, 3, 2)
assertTrue(not ok, "high level below base rejected")

local names32 = {}
local checker16 = {}
for index = 1, 32 do
    names32[index] = string.format("ion_%02d", index)
    if index % 2 == 0 then
        checker16[#checker16 + 1] = names32[index]
    end
end
local _, allocation32 = survey.patternLevels(names32, checker16, 2, 3)
assertEqual(allocation32.highCount, 16, "32-ion checkerboard high count")
assertEqual(allocation32.totalQuanta, 80, "32-ion checkerboard quanta")
assertEqual(allocation32.averageLevel, 2.5,
    "32-ion checkerboard produces half-level resolution")

print("ion cluster survey tests: " .. tostring(checks) .. " checks passed")
