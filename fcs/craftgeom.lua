-- Craft geometry derived from the inertia tensor, and the control authority
-- that follows from it.
--
-- WHY THIS EXISTS. `mixer_profile.lua` says of its uncalibrated placeholders:
--
--     "Calibrate by measuring the arms, or by flying a per-axis step response"
--
-- The project took the second branch and spent nineteen flights on it. The
-- first branch does not need a flight at all: CC:Sable hands us the inertia
-- tensor and the mass, and three diagonals OVER-DETERMINE the hull box. Solve
-- it once and the moment arms -- the only unknown standing between measured
-- ion force and a predicted angular acceleration -- come out with them.
--
-- WHAT THIS REPLACES. axisresponse.lua checked its measured roll/pitch ratio
-- against t[1][1]/t[3][3] = 4.49, which is the ratio you get if the lateral
-- and longitudinal moment arms are EQUAL -- a square craft. This craft is
-- 2.35x longer than wide, so the expected ratio is 1.91 and 4.49 is not a
-- bound anyone should be measured against. Run 18 reported 4.07 and PASSED
-- that check while being roughly twice too high.
--
-- That is the fourth time in this project that a check encoded what the code
-- believed rather than what the craft is. The others are listed in HANDOFF
-- under "Bugs found and fixed"; this one belongs with them.

local craftgeom = {}

-- Body convention from fcs/config.lua: +X port, +Y up, +Z bow. The tensor is
-- BODY-FRAME (confirmed on five flights across tilts to 20 deg), so these
-- indices are fixed for the life of the hull.
local AXIS_INDEX = { x = 1, y = 2, z = 3 }

-- Read t[i][j] out of whatever shape Sable handed back. It arrives as a table
-- of rows with `rows`/`columns` counts alongside, so a plain t[i][j] works --
-- but a nil here would otherwise surface as an arithmetic error three
-- functions away.
local function component(tensor, i, j)
    if type(tensor) ~= "table" then return nil end
    local row = tensor[i]
    if type(row) ~= "table" then return nil end
    local value = row[j]
    if type(value) ~= "number" then return nil end
    return value
end

-- Which tensor index carries rotation about each control axis.
--
-- Roll is rotation about the BOW, so I_roll is the bow index -- which is the
-- SMALLEST diagonal here, and that is why roll is the responsive axis. Pitch
-- is rotation about the PORT axis. Getting these two backwards is exactly the
-- transposition that cost this project weeks, so derive them from the same
-- config the attitude code uses rather than writing 1 and 3 as literals.
function craftgeom.axisIndices(axes)
    axes = axes or {}
    local bow = AXIS_INDEX[axes.bowAxis or "z"]
    local port = AXIS_INDEX[axes.portAxis or "x"]
    if not bow or not port or bow == port then return nil end

    -- Up is whichever of the three is left over.
    local up
    for _, index in ipairs({ 1, 2, 3 }) do
        if index ~= bow and index ~= port then up = index end
    end
    return { roll = bow, pitch = port, yaw = up }
end

-- Solve the hull box from the three tensor diagonals.
--
-- For a uniform box of mass M with sides (a, b, c) along (x, y, z):
--     I_xx = M(b^2 + c^2)/12,  I_yy = M(a^2 + c^2)/12,  I_zz = M(a^2 + b^2)/12
--
-- Three equations, three unknowns, and the system is linear in the SQUARES --
-- so it inverts exactly rather than needing a fit.
--
-- The uniformity assumption is the load-bearing one, and it is not free: a
-- real hull carries mass unevenly. The check that it is not badly wrong is
-- that all three squares come out POSITIVE. A non-physical mass distribution
-- generally drives one of them negative, and this returns nil rather than a
-- plausible-looking imaginary edge.
function craftgeom.solveBox(tensor, mass, axes)
    if type(mass) ~= "number" or mass <= 0 then return nil, "mass" end

    local txx = component(tensor, 1, 1)
    local tyy = component(tensor, 2, 2)
    local tzz = component(tensor, 3, 3)
    if not txx or not tyy or not tzz then return nil, "tensor" end

    local A = 12 * txx / mass    -- b^2 + c^2
    local B = 12 * tyy / mass    -- a^2 + c^2
    local C = 12 * tzz / mass    -- a^2 + b^2

    local a2 = (B - A + C) / 2
    local b2 = C - a2
    local c2 = A - b2
    if a2 <= 0 or b2 <= 0 or c2 <= 0 then return nil, "not a physical box" end

    local box = { x = math.sqrt(a2), y = math.sqrt(b2), z = math.sqrt(c2) }

    local indices = craftgeom.axisIndices(axes)
    if indices then
        local byIndex = { box.x, box.y, box.z }
        -- Name the edges by what they mean for control, not by axis letter.
        box.beam = byIndex[indices.pitch]   -- across the hull, port to starboard
        box.length = byIndex[indices.roll]  -- along the hull, stern to bow
        box.height = byIndex[indices.yaw]
    end
    return box
end

-- Moment arms from the rotation point to each corner's thrust centroid.
--
-- getCenterOfMass() and getLogicalPose().rotationPoint read IDENTICAL to about
-- 1e-5, so the craft rotates about its centre of mass and the arms measure
-- from there. That is checked, not assumed -- see flight-logs/airprofile.txt.
--
-- These are HALF-EDGES, which makes them an UPPER BOUND: a pod cannot sit
-- further out than the hull it is bolted to. Everything downstream inherits
-- that, and says so. The bound turns out to be tight on this craft -- roll
-- measured 97% and 102% of it on runs 10 and 9 -- which is what you would
-- expect of engine pods mounted at the corners.
function craftgeom.armBound(box)
    if not box or not box.beam or not box.length then return nil end
    return {
        lateral = box.beam / 2,        -- the lever roll acts on
        longitudinal = box.length / 2, -- the lever pitch acts on
    }
end

-- Angular acceleration per unit demand, in deg/s^2, at the ceiling the hull
-- allows.
--
-- alpha = torque / I. A demand of 1.0 shifts each corner by `authority` power
-- units; four corners sit at (+/-lateral, +/-longitudinal) and push in
-- opposite pairs, so the torque is 4 * arm * dF.
--
-- ionForceFull is the TOTAL across all four pods at power 1.0, measured at
-- 0.0% residual and reconfirmed on every run since. Dividing by 4 gives the
-- per-pod force, and the unit system closes: ionForceFull / (mass * gravity)
-- reproduces the documented 3.342x weight, so torque/I lands in rad/s^2
-- without a fudge factor.
function craftgeom.authorityBound(opts)
    local tensor, mass = opts.tensor, opts.mass
    local box = craftgeom.solveBox(tensor, mass, opts.axes)
    if not box then return nil, "box" end

    local arms = craftgeom.armBound(box)
    local indices = craftgeom.axisIndices(opts.axes)
    if not arms or not indices then return nil, "axes" end

    local authority = opts.authority or 0.25
    local perPodForce = (opts.ionForceFull / 4) * authority

    local function alpha(arm, index)
        local inertia = component(tensor, index, index)
        if not inertia or inertia <= 0 then return nil end
        return math.deg((4 * arm * perPodForce) / inertia)
    end

    local roll = alpha(arms.lateral, indices.roll)
    local pitch = alpha(arms.longitudinal, indices.pitch)
    if not roll or not pitch then return nil, "inertia" end

    return {
        roll = roll,
        pitch = pitch,
        ratio = pitch > 0 and (roll / pitch) or nil,
        box = box,
        arms = arms,
    }
end

-- The roll/pitch response ratio the geometry predicts.
--
-- Unit-free, and therefore the most trustworthy number here: the ion force,
-- the authority scalar and the mass all cancel, leaving
--
--     ratio = (lateral arm / longitudinal arm) x (I_pitch / I_roll)
--
-- so it survives even if the absolute force calibration is off. It is also
-- independent of where the pods sit ALONG each axis only to the extent that
-- they sit proportionally -- see armBound.
function craftgeom.expectedRatio(tensor, mass, axes)
    local box = craftgeom.solveBox(tensor, mass, axes)
    local arms = craftgeom.armBound(box)
    local indices = craftgeom.axisIndices(axes)
    if not arms or not indices then return nil end

    local rollInertia = component(tensor, indices.roll, indices.roll)
    local pitchInertia = component(tensor, indices.pitch, indices.pitch)
    if not rollInertia or not pitchInertia or rollInertia <= 0 then return nil end

    return (arms.lateral / arms.longitudinal) * (pitchInertia / rollInertia), box
end

return craftgeom
