-- Edit peripheral names after running: /fcs/discover.lua

return {
    schemaVersion = 1,
    -- The loop measures ~660 ms in practice (Sable reads, rednet drain, CSV
    -- write, redraw), so asking for 10 Hz only produced a busy loop that
    -- never met its own period. 0.25 is honest about what the server gives.
    samplePeriodSeconds = 0.25,
    flushEveryRows = 10,
    logDirectory = "/fcs/logs",

    -- A CC computer has a hard disk quota (computer_space_limit, 1 MB by
    -- default) and this logger writes roughly 1 KB/s, so an unattended run
    -- fills the disk in about fifteen minutes and every write after that fails
    -- with "Out of space". Roll to a new file at maxLogBytes and keep only the
    -- newest maxLogFiles, so the logger lives within a fixed budget.
    -- 6 MB of retained log against a 16 MB computer_space_limit. The old
    -- 150 KB x 3 budget held only about five minutes of samples, which is
    -- shorter than a single RPM sweep -- the earliest and most interesting
    -- steps rotated away before the run finished.
    maxLogBytes = 600000,
    maxLogFiles = 10,

    -- Carrier body convention:
    --   +X = bow/forward
    --   +Y = up
    --   +Z = starboard/right
    -- Change signs only after completing the axis-calibration test.
    axes = {
        -- WHICH BODY AXIS IS THE BOW. Measured 2026-08-26, not assumed.
        --
        -- This file used to document "+X bow, +Y up, +Z starboard" and say to
        -- change it only after an axis-calibration test. That test finally ran
        -- (/fcs/axisresponse.lua) and the convention was WRONG: a port/starboard
        -- power split -- physically a roll -- came out on the pitch channel,
        -- 77x larger than on roll.
        --
        -- Three independent lines agree on +Z bow / +X port:
        --   1. FL is physically the bow-port corner, so the corner map is right
        --      and a port/starboard split really is roll.
        --   2. That split drove the CHEAP inertia axis. alpha ~ 1/I, and the
        --      measured response ratio 4.60 matches t[1][1]/t[3][3] = 4.49 to
        --      2.5%. Roll is about the longitudinal axis, so the bow is index 3.
        --   3. Right-handed with X x Y = Z and Y up: port x up = bow, so if
        --      X is port then Z is the bow.
        --
        -- Change these only after re-running the axis calibration.
        bowAxis = "z",    -- body axis pointing at the bow
        portAxis = "x",   -- body axis pointing to port

        rollSign = 1,
        pitchSign = 1,
        yawSign = 1,
        yawOffsetDegrees = 0,
    },

    -- Propeller controllers and bearings are NOT configured here. Each pod owns
    -- its own corner's Rotation Speed Controller and prop bearing and relays
    -- them over the wireless link -- set propController / propBearing in that
    -- pod's /pod/config.lua instead.
    --
    -- Copy exact wired-network names from /fcs/peripheral_manifest.txt.
    peripherals = {
        -- Optional existing devices.
        energyStorage = nil,
        powerMeter = nil,
        voltmeter = nil,
        ammeter = nil,
    },

    propeller = {
        minimumRpm = -256,
        maximumRpm = 256,
    },

    wireless = {
        enabled = true,
        protocol = "helicarrier.fcs.v1",
        mainHostname = "FCS-MAIN",

        -- Leave nil to use the first attached wireless modem.
        modemName = nil,

        podHostnames = {
            FL = "ENG-FL",
            FR = "ENG-FR",
            RL = "ENG-RL",
            RR = "ENG-RR",
        },

        -- Recommended: run `id` on each pod and enter its numeric ID here.
        -- This prevents discovery delays when a pod is offline.
        podIds = {
            FL = nil,
            FR = nil,
            RL = nil,
            RR = nil,
        },

        -- MINIMUM SPACING between status_requests to the SAME corner. Not a
        -- poll interval any more: a healthy corner is never polled at all.
        statusRequestPeriodMs = 2000,

        -- How long a corner may go unheard before it is probed. The pods push
        -- full telemetry every ~1 s, so this only fires when that stream has
        -- actually failed -- two missed pushes, with margin. Must stay
        -- comfortably above the pod's telemetryPeriodSeconds and below
        -- offlineAfterMs, or a healthy pod is polled forever / a dead one is
        -- declared offline before anyone asks it anything.
        quietPollAfterMs = 2500,
        -- Pods rebuild a full 32-thruster telemetry payload per message and
        -- land about every 440 ms at best, so a 1500 ms window flagged them
        -- offline on every ordinary hiccup.
        offlineAfterMs = 5000,
    },

    -- Monitor hub (/fcs-dev.lua). Read-only: the hub renders frames published
    -- by the telemetry loop and commands nothing.
    hub = {
        -- nil = use the first attached monitor.
        monitorName = nil,

        -- 0.5 gives roughly 79x38 characters on a 4x3 Advanced Monitor, which
        -- is what the zone layout is designed around.
        textScale = 0.5,

        -- Open a hub tab on boot, but only when a monitor is actually present.
        autoStart = true,

        -- Repaint ceiling, independent of how fast frames arrive. The wall is
        -- roughly 3000 cells; repainting all of it on every sample flickers
        -- and wastes server tick for no added information.
        maxRedrawHz = 5,

        -- Frame age at which the header stops saying LIVE, and at which it
        -- stops claiming to have telemetry at all. A dashboard frozen on
        -- plausible numbers is the failure mode these exist to prevent.
        staleAfterMs = 1000,
        deadAfterMs = 5000,
    },
}
