package.path = "./pod-template/?.lua;./pod-template/?/init.lua;" .. package.path

local mailboxModule = require("pod.control_mailbox")
local applyModule = require("pod.control_apply")

local checks, failures = 0, 0
local function check(condition, message)
    checks = checks + 1
    if not condition then
        failures = failures + 1
        io.stderr:write("FAIL: " .. message .. "\n")
    end
end

local clock = 1000
local wired = {
    isWireless = function() return false end,
    open = function() end,
    transmit = function() end,
}
local peripherals = {
    getNames = function() return { "wired" } end,
    hasType = function(name, kind) return name == "wired" and kind == "modem" end,
    wrap = function() return wired end,
}

local mailbox = mailboxModule.new({ corner = "FL" }, {
    peripheral = peripherals,
    epoch = function() return clock end,
    sleep = function() end,
    pullEventRaw = function() return "terminate" end,
})

local ionWrites, rpmWrites, tiltWrites = {}, {}, {}
local thrusters = {
    applyExact = function(power)
        ionWrites[#ionWrites + 1] = power
        return power
    end,
}
local props = {
    setRpm = function(rpm)
        rpmWrites[#rpmWrites + 1] = rpm
        return rpm
    end,
    setTilt = function(angle, azimuth, index, mirror)
        tiltWrites[#tiltWrites + 1] = {
            angle = angle,
            azimuth = azimuth,
            index = index,
            mirror = mirror,
        }
        return { angle = angle, azimuth = azimuth, mirror = mirror }
    end,
    readBearingState = function()
        local angle = tiltWrites[#tiltWrites] and tiltWrites[#tiltWrites].angle or 0
        return {
            {
                tiltDegrees = math.abs(angle),
                stabilizationStrength = 1,
                rotationSpeed = rpmWrites[#rpmWrites] or 0,
                active = (rpmWrites[#rpmWrites] or 0) ~= 0,
            },
        }
    end,
}
local worker = applyModule.new(mailbox, thrusters, {
    props = props,
    bearingLimit = mailboxModule.GROUND_BEARING_LIMIT_DEGREES,
    epoch = function() return clock end,
    sleep = function() end,
})

local function frame(session, sequence, mode, tilt, validForMs)
    return {
        protocol = mailboxModule.PROTOCOL,
        kind = "control_frame",
        mode = mode,
        armed = false,
        session = session,
        sequence = sequence,
        sentAt = clock,
        validForMs = validForMs or 500,
        corners = {
            FL = {
                ionPower = 0,
                propRpm = mode == "ground_bearing_test" and 8 or 0,
                tiltDegrees = tilt,
                azimuthDegrees = 0,
            },
        },
    }
end

check(mailbox.acceptFrame(frame("zero", 1, "ground_apply", 0), clock),
    "ground_apply exact-zero frame remains accepted")
check(worker.applyLatest(), "ground_apply exact-zero frame remains applicable")
check(#ionWrites == 1 and ionWrites[1] == 0, "ground_apply still writes exact-zero ion power")
check(#rpmWrites == 0 and #tiltWrites == 0,
    "ground_apply does not acquire new prop or bearing behavior")
check(not mailbox.acceptFrame(frame("zero", 2, "ground_apply", 0.25), clock),
    "ground_apply still rejects non-zero tilt")

clock = 2000
check(mailbox.acceptFrame(frame("bearing", 1, "ground_bearing_test", 0.5), clock),
    "bearing mode accepts a bounded positive tilt")
check(worker.applyLatest(), "positive bearing target applies")
check(ionWrites[#ionWrites] == 0, "bearing application explicitly writes ion zero")
check(rpmWrites[#rpmWrites] == (tiltWrites[#tiltWrites].angle == 0 and 0 or 8), "bearing application explicitly writes safe prop RPM 8")
check(tiltWrites[#tiltWrites].angle == 0.5 and tiltWrites[#tiltWrites].azimuth == 0,
    "bearing application calls the real tilt path with bounded target and zero azimuth")
check(tiltWrites[#tiltWrites].mirror == true,
    "bearing application preserves mirrored corner behavior")

local positiveStatus = mailbox.snapshot()
local positiveBearing = positiveStatus.appliedBearingState
    and positiveStatus.appliedBearingState[1]
check(type(positiveBearing) == "table", "status includes physical bearing readback")
check(positiveBearing and math.abs(positiveBearing.tiltDegrees - 0.5) < 0.0001,
    "status includes measured bearing tilt")
check(positiveBearing and positiveBearing.stabilizationStrength == 1,
    "status includes bearing stabilization strength")
check(positiveBearing and positiveBearing.rotationSpeed == 8,
    "status includes measured bearing rotation speed")
check(positiveStatus.appliedMode == "ground_bearing_test",
    "status identifies the applied bearing mode")
check(positiveStatus.appliedTiltDegrees == 0.5,
    "status exposes the successfully applied tilt target")
check(positiveStatus.appliedPropRpm == 8 and positiveStatus.appliedIonPower == 0,
    "status exposes zero prop and ion commands")

clock = 2100
check(not mailbox.acceptFrame(frame("bearing", 2, "ground_bearing_test", 5.01), clock),
    "bearing mode rejects tilt above the positive bound")
check(not mailbox.acceptFrame(frame("bearing", 2, "ground_bearing_test", -5.01), clock),
    "bearing mode rejects tilt below the negative bound")

clock = 2200
check(mailbox.acceptFrame(frame("bearing", 2, "ground_bearing_test", -0.5), clock),
    "bearing mode accepts a bounded negative tilt")
check(worker.applyLatest(), "negative bearing target applies")
check(tiltWrites[#tiltWrites].angle == -0.5, "negative bearing target reaches the setter")

clock = 2801
check(worker.enforceStaleFallback(), "stale bearing command triggers local fallback")
check(ionWrites[#ionWrites] == 0 and rpmWrites[#rpmWrites] == (tiltWrites[#tiltWrites].angle == 0 and 0 or 8),
    "bearing fallback keeps ions and props at zero")
check(tiltWrites[#tiltWrites].angle == 0 and tiltWrites[#tiltWrites].azimuth == 0,
    "bearing fallback returns tilt and azimuth to zero")
check(not worker.enforceStaleFallback(), "the same stale command falls back only once")
check(mailbox.snapshot().fallbackCount == 1, "fallback is counted in status")

clock = 3000
check(mailbox.acceptFrame(frame("expired", 1, "ground_bearing_test", 0.25, 100), clock),
    "fresh short-lived bearing frame is received")
clock = 3200
check(not worker.applyLatest(), "expired bearing frame is not applied")
check(mailbox.snapshot().expiredBeforeApply == 1, "expired bearing frame is counted")
check(worker.enforceStaleFallback(), "expired bearing frame still enforces zero fallback")
check(tiltWrites[#tiltWrites].angle == 0, "expired-frame fallback is zero tilt")

clock = 4000
local shadow = frame("shadow", 1, "shadow", 0.75)
check(mailbox.acceptFrame(shadow, clock), "shadow behavior remains accepted")
check(not worker.applyLatest(), "shadow frames remain actuator-free")

print(string.format("wired bearing control: %d passed, %d failed", checks - failures, failures))
if failures > 0 then os.exit(1) end
