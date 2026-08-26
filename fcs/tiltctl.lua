-- Manual thrust-vectoring control, and the roll-trim preset.
--
--     /fcs/tiltctl.lua status
--     /fcs/tiltctl.lua FL 4.29 0          tilt FL 4.29 deg toward the bow
--     /fcs/tiltctl.lua all 0              level everything
--     /fcs/tiltctl.lua clear              clear every manual target
--     /fcs/tiltctl.lua rolltrim [angle]   REFUSED -- the RR deficit was repaired
--                                         2026-08-26. Needs --force.
--
-- Angles are degrees from the bearing's own normal. Azimuth 0 is toward +X
-- (bow), 90 toward +Z (starboard), matching fcs/config.lua.
--
-- ---------------------------------------------------------------------------
-- WHAT `rolltrim` IS FOR
--
-- The hull self-levels, but RR's bearing_5 is 1.121% down, and that standing
-- torque displaces the EQUILIBRIUM by deficit/stiffness = 0.0112/0.0091 =
-- 1.23 degrees of roll. A tilted craft translates:
--
--     lateral accel = g * tan(1.23 deg) = 0.236 blocks/s^2
--     -> 7.1 blocks/s and 106 blocks after 30 s
--
-- That is the strafe. It cannot be trimmed away with ion power (one level is
-- 103x the correction needed) nor with propeller RPM (1 RPM is 2.8x). Bearing
-- angle is the only continuous actuator on the craft.
--
-- Shedding the matching vertical thrust from the PORT corners rebalances roll:
--
--     4 port bearings x 55,747 x (1 - cos 4.29 deg) = 625 = the deficit
--
-- ---------------------------------------------------------------------------
-- THE SIDE EFFECT, which is bigger than the problem
--
-- Tilting also produces LATERAL thrust: 4 x 55,747 x sin(4.29 deg) = 16,683,
-- about 1.95% of craft weight. Left uncancelled that is a worse strafe than
-- the one being fixed.
--
-- So the preset tilts FL toward the BOW and RL toward the STERN: identical
-- vertical loss, opposing lateral components. The roll correction adds; the
-- lateral cancels.
--
-- ---------------------------------------------------------------------------
-- UNVERIFIED, AND IT MATTERS
--
-- Which way the resulting FORCE points is NOT established. getThrust is signed
-- by handedness rather than world direction, and getThrustVector reports each
-- bearing's own axis -- a counter-rotating pair reads {0,1,0} and {0,-1,0}
-- while physically pushing the craft the same way. So the sign of the lateral
-- force from a given azimuth is an assumption.
--
-- Verify before trusting it: apply a tilt in flight and measure the craft's
-- lateral acceleration. If the strafe gets WORSE, the azimuth convention is
-- inverted -- flip it and repeat. Nothing here closes a loop on an unmeasured
-- sign.
--
-- Bearings ignore a manual target unless they are ACTIVE. At 0 RPM the target
-- is stored and nothing moves, so `status` will show commanded but not
-- reported tilt until the props are turning.
-- ---------------------------------------------------------------------------

package.path = "/?.lua;/?/init.lua;" .. package.path

local banks = require("fcs.banks")
local actuators = require("fcs.actuators")

local CORNERS = { "FL", "FR", "RL", "RR" }

-- Measured: bearing thrust at 64 RPM, and the RR bearing_5 shortfall as it
-- was BEFORE the 2026-08-26 repair. Retained only for the rolltrim arithmetic,
-- which is now behind a refusal.
local BEARING_THRUST_64 = 55747
local RR_DEFICIT_FRACTION = 0.01121
local DEFAULT_TRIM = 4.29

local args = { ... }

local function usage()
    print("usage:")
    print("  /fcs/tiltctl.lua status")
    print("  /fcs/tiltctl.lua <corner|all> <angle> [azimuth]")
    print("  /fcs/tiltctl.lua clear")
    print("  /fcs/tiltctl.lua rolltrim [angle]   (REFUSED -- defect repaired)")
end

local function drain(seconds)
    local deadline = os.epoch("utc") + (seconds or 1.5) * 1000
    while os.epoch("utc") < deadline do
        banks.poll()
        sleep(0.1)
    end
end

local function status()
    drain(2.0)
    print(string.format("%-5s %-8s %10s %10s %10s %8s",
        "pod", "online", "cmd tilt", "reported", "azimuth", "rpm"))
    for _, corner in ipairs(CORNERS) do
        local pod = banks.getState()[corner] or {}
        local prop = pod.prop or {}
        print(string.format("%-5s %-8s %10s %10s %10s %8s",
            corner,
            pod.online and "yes" or "NO",
            pod.commandedTilt and string.format("%.2f", pod.commandedTilt) or "-",
            prop.tiltAngle and string.format("%.4f", prop.tiltAngle) or "-",
            pod.commandedTiltAzimuth and string.format("%.0f", pod.commandedTiltAzimuth) or "-",
            prop.controllerRpm and string.format("%.1f", prop.controllerRpm) or "-"))
    end
    print("")
    print("A commanded tilt with a reported tilt of 0 means the bearings are")
    print("INACTIVE -- spin the props up, or the target is stored and ignored.")
end

local function applyTilt(corner, angle, azimuth)
    local ok, result = pcall(actuators.setTilt, corner, angle, azimuth)
    if ok then
        print(string.format("  %s -> %.2f deg azimuth %.0f  (reported %s)",
            corner, result.requested, result.azimuth,
            result.reportedTilt and string.format("%.4f", result.reportedTilt) or "not yet"))
        return true
    end
    print("  " .. corner .. " FAILED: " .. tostring(result))
    return false
end

local function rollTrim(angle)
    angle = tonumber(angle) or DEFAULT_TRIM

    local shed = 4 * BEARING_THRUST_64 * (1 - math.cos(math.rad(angle)))
    local lateral = 4 * BEARING_THRUST_64 * math.sin(math.rad(angle))
    local deficit = RR_DEFICIT_FRACTION * BEARING_THRUST_64

    print("roll trim: tilting the PORT corners to match RR's deficit")
    print(string.format("  RR bearing_5 deficit     : %.0f", deficit))
    print(string.format("  vertical shed at %.2f deg : %.0f  (%.0f%% of the deficit)",
        angle, shed, shed / deficit * 100))
    print(string.format("  lateral produced         : %.0f per side, CANCELLED by opposing azimuths",
        lateral / 2))
    print("")
    print("  FL toward the bow (azimuth 0), RL toward the stern (azimuth 180).")
    print("  Same vertical loss, opposite lateral -- roll adds, strafe cancels.")
    print("")

    local ok = applyTilt("FL", angle, 0)
    ok = applyTilt("RL", angle, 180) and ok

    print("")
    if ok then
        print("Applied. VERIFY IN FLIGHT before trusting it:")
        print("  the sign of the lateral force is UNVERIFIED, so if the strafe")
        print("  gets worse, swap the two azimuths and repeat.")
    else
        print("At least one corner did not take the trim -- do not fly on it.")
    end
end

-- ---------------------------------------------------------------------------

local function main()
    local command = args[1]

    if not command or command == "help" then
        usage()
        return
    end

    drain(1.5)

    if command == "status" then
        status()
    elseif command == "clear" then
        for _, corner in ipairs(CORNERS) do
            local ok, err = pcall(actuators.clearTilt, corner)
            print("  " .. corner .. (ok and " cleared" or (" FAILED: " .. tostring(err))))
        end
    elseif command == "rolltrim" then
        -- The preset corrects a defect that no longer exists.
        --
        -- bearing_5 was repaired and verified 2026-08-26; rolldrift then
        -- measured the equilibrium offset at +0.311 deg, down from 1.23. This
        -- preset tilts the PORT bearings 4.29 deg to cancel a standing torque
        -- the craft no longer has, so running it now INJECTS the roll error it
        -- was written to remove.
        --
        -- Refused rather than deleted: the arithmetic below is the only worked
        -- example of trimming a small moment with the bearings, which is
        -- exactly what yaw vectoring will need.
        if args[2] ~= "--force" then
            print("REFUSED: rolltrim corrects the RR bearing_5 deficit,")
            print("which was REPAIRED and verified 2026-08-26.")
            print("")
            print("The craft is symmetric. Applying this preset now would tilt")
            print("the port bearings 4.29 deg against no standing torque and")
            print("CREATE the strafe it exists to remove.")
            print("")
            print("Manual vectoring is unaffected and is what you want:")
            print("  /fcs/tiltctl.lua <corner|all> <angle> [azimuth]")
            print("  /fcs/tiltctl.lua clear")
            print("")
            print("Override with:  /fcs/tiltctl.lua rolltrim --force [angle]")
            return
        end
        print("WARNING: applying a trim for a REPAIRED defect.")
        rollTrim(args[3])
    else
        local angle = tonumber(args[2])
        if not angle then
            usage()
            return
        end
        local azimuth = tonumber(args[3]) or 0
        if command == "all" then
            for _, corner in ipairs(CORNERS) do
                applyTilt(corner, angle, azimuth)
            end
        else
            applyTilt(command, angle, azimuth)
        end
    end
end

-- The listener exists for the usual reason: CC delivers an event to a
-- coroutine only when it matches that coroutine's filter and DROPS it
-- otherwise, and every wait here is filtered.
local function listenLoop()
    while true do
        banks.listen(1)
    end
end

parallel.waitForAny(main, listenLoop)
