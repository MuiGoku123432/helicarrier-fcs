return {
    -- Set exactly one of: FL, FR, RL, RR.
    corner = "SET_ME",
    hostname = "ENG-SET_ME",

    protocol = "helicarrier.fcs.v1",
    mainHostname = "FCS-MAIN",

    -- Strongly recommended: enter the numeric ID shown by `id` on FCS-DEV.
    mainComputerId = nil,

    -- Leave nil to use the first attached wireless modem.
    wirelessModemName = nil,

    -- Propellers for this corner, relayed to FCS-DEV over the wireless link.
    -- Copy the exact wired-network names from /pod/discover.lua output.
    -- Leave nil if this corner has no propeller.
    propController = nil,

    -- One name, or a list when the corner carries more than one propeller:
    --   propBearing = "create:prop_bearing_3",
    --   propBearing = { "create:prop_bearing_3", "create:prop_bearing_4" },
    -- Thrust, airflow and sail power are summed across them; RPM is averaged.
    propBearing = nil,
    propMinimumRpm = -256,
    propMaximumRpm = 256,

    manifestPath = "/pod/thruster_manifest.lua",
    deviceReportPath = "/pod/device_report.txt",
    manifestApproved = false,
    expectedThrusterCount = 32,

    -- IMPORTANT: configure and ground-test this before connecting in flight.
    --
    -- fallbackPower means EVERYTHING IS OFF. It is applied on boot, on an
    -- explicit disarm, when applying a command fails, and when the program
    -- exits. Keep it at 0.0. Raising it would mean a booting pod produces lift
    -- with nobody commanding it, and "disarm" would stop meaning "off" -- which
    -- ionsweep.lua relies on as its safe resting state on exit.
    fallbackPower = 0.0,

    -- commsLossPower means WE WERE FLYING AND THE LINK DROPPED. It is applied
    -- by watchdogLoop, and nowhere else.
    --
    -- These two used to be one constant, which conflated the two situations.
    -- Under the 64 RPM plan that conflation is a fall: props carry only 52% of
    -- weight and hold their RPM with no watchdog, so the ions are the other
    -- half AND the layer that fails to zero.
    --
    -- 0.195 is the measured hover ion power. With props at 64 RPM that totals
    -- 0.967 of weight -- deliberately just under hover, so the craft descends
    -- gently rather than holding or climbing. The descent then arrests itself:
    -- air pressure rises as it falls, prop thrust rises with it, and the craft
    -- settles at an equilibrium altitude. A failsafe that terminates is better
    -- than one that holds perfectly.
    --
    -- CALIBRATED FOR props = 64 RPM. It is wrong at any other prop setting.
    -- If the prop plan changes, re-measure this.
    commsLossPower = 0.195,

    minimumPower = 0.0,
    maximumPower = 1.0,
    maximumChangePerCommand = 0.05,
    commandTimeoutMs = 750,
    telemetryPeriodSeconds = 0.20,
}
