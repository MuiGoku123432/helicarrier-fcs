local stationkeep = require("fcs.stationkeep_control")
local protocol = require("fcs.wired_stationkeep_protocol")
local mailboxModule = require("pod-template.pod.control_mailbox")
local applyModule = require("pod-template.pod.control_apply")

local function near(value, expected, tolerance, label)
    assert(math.abs(value - expected) <= tolerance,
        string.format("%s: expected %.6f, got %.6f", label, expected, value))
end

protocol.selfTest()

local identity = { w = 1, x = 0, y = 0, z = 0 }
local controller = stationkeep.new()
local first = controller.update({
    velocityX = 3,
    velocityZ = 0,
    positionErrorX = 0,
    positionErrorZ = 0,
    quaternion = identity,
}, 0.25)
assert(first.valid and first.tiltDegrees > 0, "right drift must command lateral tilt")
near(first.azimuthDegrees, 180, 1e-6, "right-drift wired-plant correction azimuth")

local recapture = stationkeep.new()
local recaptureOutput
for _ = 1, 40 do
    recaptureOutput = recapture.update({
        velocityX = 0,
        velocityZ = 0,
        positionErrorX = 20,
        positionErrorZ = 0,
        quaternion = identity,
    }, 0.25)
end
assert(recaptureOutput.valid)
assert(recaptureOutput.tiltDegrees >= 0.45
        and recaptureOutput.tiltDegrees <= 0.75,
    "20-block position recapture must be stronger but remain sub-degree: "
        .. tostring(recaptureOutput.tiltDegrees))
near(recaptureOutput.azimuthDegrees, 180, 1e-6,
    "position recapture wired-plant correction azimuth")

-- Deterministic biased plant: without control, 0.18 acceleration and 0.06
-- drag settle at +3 blocks/s. The controller must remove that velocity and
-- pull the craft back toward its captured X target.
controller.reset()
local velocityX, positionX = 3, 0
local dt = 0.25
for _ = 1, 1600 do
    local output = controller.update({
        velocityX = velocityX,
        velocityZ = 0,
        positionErrorX = positionX,
        positionErrorZ = 0,
        quaternion = identity,
    }, dt)
    assert(output.valid)
    local acceleration = 0.18 - 0.06 * velocityX - 0.30 * output.commandX
    velocityX = velocityX + acceleration * dt
    positionX = positionX + velocityX * dt
end
assert(math.abs(velocityX) < 0.20,
    "3 blocks/s right drift did not converge: " .. tostring(velocityX))
assert(math.abs(positionX) < 6,
    "position hold did not recover toward capture point: " .. tostring(positionX))

local saturated = stationkeep.new()
for _ = 1, 2000 do
    local output = saturated.update({
        velocityX = 100,
        velocityZ = 0,
        positionErrorX = 0,
        positionErrorZ = 0,
        quaternion = identity,
    }, 0.25)
    assert(output.tiltDegrees <= protocol.MAX_TILT_DEGREES + 1e-9)
end
assert(math.abs(saturated.state().integralX) < 1,
    "integrator wound up behind a saturated command")
local invalid = saturated.update({}, 0.25)
assert(invalid.valid == false and invalid.tiltDegrees == 0)
near(saturated.state().integralX, 0, 1e-9, "stale reset integral")
near(saturated.state().commandX, 0, 1e-9, "stale reset command")

local vertical = stationkeep.new()
local lastHigh
for slot = 1, 20 do
    local kind = vertical.vertical({
        rise = 1,
        verticalVelocity = -0.5,
        altitudeError = -0.5,
    }, slot)
    if kind == "high" then
        if lastHigh then assert(slot - lastHigh >= 4, "consecutive/dense high slots") end
        lastHigh = slot
    end
end
assert(lastHigh, "vertical feedback never selected high authority")
local inhibited = stationkeep.new()
local kind, reason = inhibited.vertical({
    rise = 8.1,
    verticalVelocity = -2,
    altitudeError = -2,
}, 1)
assert(kind == "low" and reason == "absolute_high_inhibit")

local function mailbox()
    local peripheral = {
        getNames = function() return {} end,
        getType = function() return nil end,
        wrap = function() return nil end,
    }
    return mailboxModule.new({ corner = "FL" }, {
        peripheral = peripheral,
        epoch = function() return 1000 end,
    })
end

local accepted = protocol.frame("stationkeep-test", 1, 1000, "high", {
    tiltDegrees = 6,
    azimuthDegrees = 359.9,
})
assert(mailbox().acceptFrame(accepted, 1000) == true,
    "stationkeep +/-6 degree boundary must be accepted")

local tooFar = protocol.frame("stationkeep-test", 1, 1000, "high", {
    tiltDegrees = 6,
    azimuthDegrees = 0,
})
tooFar.corners.FL.tiltDegrees = 6.01
assert(mailbox().acceptFrame(tooFar, 1000) == false,
    "stationkeep tilt beyond 6 degrees must be rejected")

local responseStillBounded = protocol.frame("response-test", 1, 1000, "high", {
    tiltDegrees = 2,
    azimuthDegrees = 0,
})
responseStillBounded.mode = "response_map_test"
assert(mailbox().acceptFrame(responseStillBounded, 1000) == false,
    "response_map_test proof envelope must remain +/-1 degree")

local shutdown = protocol.frame("stationkeep-test", 2, 1000, "shutdown")
assert(mailbox().acceptFrame(shutdown, 1000) == true,
    "exact-zero stationkeep shutdown must be accepted")
shutdown.corners.FL.propRpm = 64
assert(mailbox().acceptFrame(shutdown, 1000) == false,
    "nonzero shutdown RPM must be rejected")

-- The mailbox accepting a mode is not enough: prove the pod apply layer routes
-- stationkeep through the live ion/RPM/tilt path rather than the ground-zero
-- path that unknown modes intentionally receive.
local applied = {}
local entry = {
    mode = "stationkeep",
    session = "apply-test",
    sequence = 1,
    receivedAt = 1000,
    validForMs = 750,
    command = protocol.command("high", { tiltDegrees = 2, azimuthDegrees = 90 }),
}
local applyMailbox = {
    latest = function() return entry end,
    recordApply = function() end,
    recordExpired = function() end,
    recordFallback = function() end,
    recordFallbackStop = function() end,
}
local function record(name)
    return function(a, b)
        applied[name] = { a, b }
        return true
    end
end
local applyInstance = applyModule.new(applyMailbox, {}, {
    epoch = function() return 1100 end,
    sleep = function() end,
    applyIon = record("ion"),
    applyIonZero = record("ionZero"),
    applyZero = record("zero"),
    applyRpm = record("rpm"),
    applyRpmZero = record("rpmZero"),
    applyTilt = record("tilt"),
    readBearingState = function() return {} end,
    responseIonMin = 0,
    responseIonMax = 1,
    responsePropRpm = 64,
    responseBearingLimit = 1,
    bearingLimit = 1,
    bearingPropRpm = 64,
})
assert(applyInstance.applyLatest() == true)
near(applied.ion[1], protocol.HIGH_POWER, 1e-9, "stationkeep live ion")
near(applied.rpm[1], 64, 1e-9, "stationkeep live RPM")
near(applied.tilt[1], 2, 1e-9, "stationkeep live tilt")
near(applied.tilt[2], 90, 1e-9, "stationkeep live azimuth")
assert(applied.ionZero == nil, "stationkeep was routed through ground zero-ion")

-- ion_profile: ions free, props pinned near zero lift, NO lateral authority.
local function ionProfileFrame(overrides)
    local corners = {}
    for _, corner in ipairs({ "FL", "FR", "RL", "RR" }) do
        local c = {
            ionPower = 0.5, fallbackIonPower = 0.07, fallbackStopAfterMs = 5000,
            propRpm = 8, tiltDegrees = 0, azimuthDegrees = 0, shutdown = false,
        }
        for k, v in pairs(overrides or {}) do c[k] = v end
        corners[corner] = c
    end
    return {
        protocol = "helicarrier.control-frame.v1", kind = "control_frame",
        mode = "ion_profile", armed = true, session = "ion-test",
        sequence = 1, sentAt = 1000, validForMs = 750, corners = corners,
    }
end

assert(mailbox().acceptFrame(ionProfileFrame(), 1000) == true,
    "ion_profile must accept full-range ions at the bounded prop RPM")
assert(mailbox().acceptFrame(ionProfileFrame({ ionPower = 1.0 }), 1000) == true,
    "ion_profile must allow the top ion level")
assert(mailbox().acceptFrame(ionProfileFrame({ propRpm = 0 }), 1000) == true,
    "ion_profile must allow a genuinely ion-only run")
assert(mailbox().acceptFrame(ionProfileFrame({ propRpm = 64 }), 1000) == false,
    "ion_profile must reject the flight prop RPM")
assert(mailbox().acceptFrame(ionProfileFrame({ propRpm = 9 }), 1000) == false,
    "ion_profile must reject an unbounded prop RPM")
assert(mailbox().acceptFrame(ionProfileFrame({ tiltDegrees = 1 }), 1000) == false,
    "ion_profile must have no lateral authority whatsoever")
assert(mailbox().acceptFrame(ionProfileFrame({ azimuthDegrees = 90 }), 1000) == false,
    "ion_profile must reject any azimuth")
assert(mailbox().acceptFrame(ionProfileFrame({ ionPower = 1.5 }), 1000) == false,
    "ion_profile must keep ion power inside 0..1")
assert(mailbox().acceptFrame(ionProfileFrame({ fallbackIonPower = 0.9 }), 1000) == false,
    "ion_profile fallback must not exceed the commanded ion power")

-- Mailbox acceptance is NOT enough. The apply layer routes unknown modes to a
-- deliberate zero-ion path, so ion_profile must be proven to reach the LIVE ion
-- path or the thrusters simply never come on -- which is exactly what happened
-- on the first ion_profile flight.
local ionApplied = {}
local function ionRecord(name)
    return function(a, b) ionApplied[name] = { a, b }; return true end
end
local ionEntry = {
    mode = "ion_profile",
    session = "ion-apply-test",
    sequence = 1,
    receivedAt = 1000,
    validForMs = 750,
    command = {
        ionPower = 0.6050, fallbackIonPower = 0.07, fallbackStopAfterMs = 5000,
        propRpm = 8, tiltDegrees = 0, azimuthDegrees = 0, shutdown = false,
    },
}
local ionApply = applyModule.new({
    latest = function() return ionEntry end,
    recordApply = function() end,
    recordExpired = function() end,
    recordFallback = function() end,
    recordFallbackStop = function() end,
}, {}, {
    epoch = function() return 1100 end,
    sleep = function() end,
    applyIon = ionRecord("ion"),
    applyIonZero = ionRecord("ionZero"),
    applyZero = ionRecord("zero"),
    applyRpm = ionRecord("rpm"),
    applyRpmZero = ionRecord("rpmZero"),
    applyTilt = ionRecord("tilt"),
    readBearingState = function() return {} end,
    responseIonMin = 0,
    responseIonMax = 1,
    responsePropRpm = 64,
    responseBearingLimit = 1,
    bearingLimit = 1,
    bearingPropRpm = 8,
    ionProfilePropRpm = 8,
})
assert(ionApply.applyLatest() == true,
    "ion_profile must be accepted by the apply layer's own safety check")
assert(ionApplied.ionZero == nil,
    "ion_profile must NOT be routed through the ground zero-ion path")
near(ionApplied.ion[1], 0.6050, 1e-9, "ion_profile live ion power")
near(ionApplied.rpm[1], 8, 1e-9, "ion_profile prop RPM")
near(ionApplied.tilt[1], 0, 1e-9, "ion_profile tilt must be exactly zero")

-- The flight modes must be unaffected by the new boundary.
assert(mailbox().acceptFrame(accepted, 1000) == true,
    "stationkeep must still accept its own envelope after adding ion_profile")

print("stationkeep controller/protocol: PASS")
