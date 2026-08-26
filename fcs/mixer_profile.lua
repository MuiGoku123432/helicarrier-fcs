-- Calibration for fcs/mixer.lua: how this particular carrier responds.
--
-- This is a NEW file with no deployed counterpart, and it must stay that way.
-- HANDOFF.md's first operational gotcha is that /fcs/config.lua on the server
-- carries values the repo template does not (podIds, peripheral names), so
-- pushing the repo copy over it destroys them and every edit has to go through
-- fetch-patch-assert. Nothing here is ever hand-entered on the server, so this
-- file can be rsync'd straight across for the life of the project. Resist the
-- temptation to fold it into config.lua.

return {
    -- Common propeller RPM. Not a mixer output in any interesting sense -- the
    -- mixer never varies it -- but it belongs with the rest of the flight
    -- configuration rather than being hardcoded at the call site.
    --
    -- 64 RPM carries 52.1% of craft weight (measured, exactly linear in RPM).
    props = {
        rpm = 64,
    },

    -- Body convention from fcs/config.lua: +Z bow, +Y up, +X port. (This said
    -- "+X bow, +Z starboard" and that was wrong -- see HANDOFF.)
    --
    -- Positive roll is starboard-low, so the port corners (FL, RL) push harder.
    -- Positive pitch is bow-high, so the FORWARD corners (FL, FR) push harder.
    --
    -- THE PITCH SIGNS WERE INVERTED. This block gave the AFT corners +1, which
    -- raises the stern and drops the bow -- the opposite of what the line above
    -- it claimed. Measured 2026-08-26: a +0.3 pitch demand produced
    -- -2.12 deg/s^2. attitude.lua was reporting correctly; the demand was.
    --
    -- This is a HULL-RELATIVE relationship and does not depend on which way
    -- the craft is pointing: the corners are bolted to the hull and roll/pitch
    -- are yaw-invariant. Turning the ship cannot reintroduce it. Rebuilding
    -- the contraption could, by redefining the body frame -- re-run the axis
    -- calibration after any disassembly.
    --
    -- bias is a constant power offset added to that corner's command.
    corners = {
        FL = { roll =  1, pitch =  1, bias = 0.0 },
        FR = { roll = -1, pitch =  1, bias = 0.0 },
        RL = { roll =  1, pitch = -1, bias = 0.0 },

        -- `bias` is a CONSTANT ion power offset for this corner, in power
        -- units. It is added, not multiplied.
        --
        -- That distinction was got wrong first time and it matters. RR's
        -- defect is gyroscopic_propeller_bearing_5 producing 13,804.41 against
        -- 13,960.98 -- a fixed 1.121% shortfall on ONE of RR's two bearings,
        -- so ~0.56% of that corner's PROPELLER thrust, which is ~0.073% of
        -- craft weight and does not change with ion collective.
        --
        -- The first version divided RR's ION command by 0.98879. That adds
        -- force PROPORTIONAL TO COLLECTIVE to cancel a constant deficit: about
        -- 0.126% of weight at hover -- over-correcting by ~1.7x -- and 0.0057
        -- power at collective 0.5, for a deficit that never moved. Wrong shape,
        -- not just wrong size.
        --
        -- Derivation of the value: props at 64 RPM carry 52.1% of weight across
        -- 8 bearings = 6.5125% each; 1.121% of that is 0.073% of weight. Ion
        -- force per corner is 0.1115 weight at power 0.195, i.e. 0.5718 weight
        -- per unit power. 0.00073 / 0.5718 = 0.001276.
        --
        -- CALIBRATED FOR props = 64 RPM. The prop deficit scales with prop
        -- thrust, so this offset must be re-derived if the prop plan changes.
        --
        -- A multiplicative per-corner term would be the right model for an ION
        -- bank that is genuinely weak. No such asymmetry has been measured, so
        -- there is deliberately no such term here.
        -- bias = 0. NOT because the RR defect is imaginary, but because a
        -- sub-quantum bias is WORSE THAN NOTHING.
        --
        -- Ion power quantises to 15 levels (1/15 = 0.0667). The bias needed to
        -- cancel RR's propeller deficit is 0.001276 -- 1.9% of one quantum. It
        -- can therefore never produce the intended correction. What it CAN do
        -- is push RR across a level boundary whenever collective happens to sit
        -- within 0.001276 below one, and then RR gets a WHOLE EXTRA LEVEL:
        --
        --     deficit to correct : 0.0730% of weight -> 0.0112 deg/s^2
        --     what it delivers   : 5.5700% of weight -> 0.852  deg/s^2
        --     overshoot          : 76x, about 2% of the time
        --
        -- The roll-drift harness caught it: fitted roll acceleration came out
        -- 0.104 deg/s^2, ~10x the deficit's own contribution, consistent with
        -- the bias firing intermittently.
        --
        -- Correcting the RR deficit needs an actuator finer than one ion
        -- level. Propellers resolve to 0.81% of weight per RPM against the
        -- ions' 5.57% per corner, so differential prop RPM is the candidate --
        -- but that is a design change, not a constant.
        RR = { roll = -1, pitch = -1, bias = 0.0 },
    },

    -- UNCALIBRATED PLACEHOLDERS.
    --
    -- These are the scalars that absorb the unmeasured moment arms. Nobody has
    -- ever measured the distance from getLogicalPose().rotationPoint to each
    -- corner's thrust centroid, and the inertia tensor does not supply it --
    -- the tensor gives angular acceleration per torque, not torque per corner
    -- force.
    --
    -- So: a demand of roll = 1.0 shifts each corner by `roll` power units, and
    -- what that produces in degrees per second is currently unknown. 0.25 is a
    -- deliberately modest starting point -- it keeps a full-scale attitude
    -- demand inside the ~80% of ion authority spare at hover.
    --
    -- Calibrate by measuring the arms, or by flying a per-axis step response
    -- and reading the result out of the flight log.
    authority = {
        roll = 0.25,
        pitch = 0.25,
    },

    ion = {
        -- Mirrors the pods' own minimumPower / maximumPower. If those change in
        -- pod/config.lua, change them here too: the mixer clamps to these, and
        -- a mixer that believes in more headroom than the pods allow will
        -- silently under-deliver attitude.
        minimumPower = 0.0,
        maximumPower = 1.0,

        -- Force in kN produced by ONE CORNER at power 1.0.
        --
        -- Left unset on purpose. The two available readings disagree: the hover
        -- point (power 0.185 -> 0.446 of a 1,158,293 weight) extrapolates to
        -- about 2.4x weight at full power, while HANDOFF.md states roughly
        -- 3.5x. The "~1:1 against mass * gravity" line is a claim about UNITS,
        -- not about power, so it does not settle it.
        --
        -- Nothing in the command path uses this. Setting it only enables the
        -- advisory `expected` field. One measurement resolves it.
        forcePerPower = nil,

        -- Advisory only. Ion thrust is quantised at 25,804.8 kN across all 128
        -- thrusters (201.6 kN each), with quarter-multiples seen during ramps.
        -- Per corner that is 32 thrusters: 6,451.2 kN per full step, 1,612.8
        -- per quarter.
        quantumKN = 1612.8,
    },

    reference = {
        -- The measured hover point, in the intended flight configuration:
        -- props at 64 RPM carry 0.521 of weight and the ions supply the rest.
        -- Reproduced across runs. Present so the hover regression test and any
        -- future controller can name one number instead of copying 0.195
        -- around.
        hoverCollective = 0.195,
    },
}
