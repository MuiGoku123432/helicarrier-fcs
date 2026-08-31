# Helicarrier FCS

A ComputerCraft flight-control system for a Create-powered Minecraft helicarrier, using one FCS computer and four independently safe actuator pods.

```text
FCS-DEV  Computer 1, sensing and whole-craft control
ENG-FL   Computer 2, front-left actuator pod
ENG-FR   Computer 3, front-right actuator pod
ENG-RL   Computer 4, rear-left actuator pod
ENG-RR   Computer 5, rear-right actuator pod
```

The operational controller gathers CC:Sable state on FCS-DEV, computes bounded vertical and X/Z stationkeeping commands, and sends one complete four-corner frame over the shared wired modem network. Each pod validates the same frame, extracts its corner, stores only the newest fresh command, applies peripherals in an independent worker, reports cumulative status, and retains local stale-command fallback.

Legacy wireless telemetry and manual tools remain available, but the operational actuator command path is direct wired protocol `helicarrier.control-frame.v1` on channels 42042 and 42043.

## Critical safety warning

Create Propulsion switches an ion thruster to ComputerCraft throttle while a computer is attached to its peripheral. Connecting the wired network may therefore replace its existing redstone command.

Configure and test every pod while grounded. Do not attach the pod computers to an airborne carrier until each pod's approved manifest and fallback power have been verified.

## Main FCS computer installation

Run `id` on the main Advanced Computer and record the number. Copy these package paths into that computer:

```text
fcs-cc/startup.lua  -> /startup.lua
fcs-cc/fcs/         -> /fcs/
```

Its filesystem should contain:

```text
/
├── startup.lua
└── fcs/
    ├── actuators.lua
    ├── attitude.lua
    ├── bankctl.lua
    ├── banks.lua
    ├── config.lua
    ├── csv.lua
    ├── discover.lua
    ├── main.lua
    ├── network.lua
    ├── peripherals.lua
    ├── propctl.lua
    ├── protocol.lua
    └── sensors.lua
```

Attach one wireless modem. Enter the four pod computer IDs in `/fcs/config.lua` after creating the pods. On reboot, telemetry launches in a background multishell tab and the normal shell remains usable.

## Monitor hub

`fcs-dev` renders live telemetry to an attached monitor. It is read-only: it
draws frames published by the telemetry loop and commands nothing.

Attach a monitor to FCS-DEV -- a 4x3 Advanced Monitor at text scale 0.5 gives
roughly 79x38 characters, which is the size the layout is designed around. On
reboot the hub opens in its own tab automatically when a monitor is present.

    fcs-dev                    render to the configured or first monitor
    fcs-dev --term             render to the terminal instead
    fcs-dev --monitor <name>   render to a named monitor
    fcs-dev --scale <n>        override the text scale

Settings live in the `hub` block of `/fcs/config.lua`. Set `autoStart = false`
to stop it opening on boot.

The header is the thing to read first: `LIVE` means the frame is under a second
old, `STALE` means the telemetry loop has gone quiet, and `NO TELEMETRY` means
it has been quiet for over five seconds -- the numbers on screen are the last
ones received, not current ones.

A zone that cannot fit all its rows says so in its title (`3 hidden`) rather
than dropping rows silently.

See `docs/fcs-dev-hub.md` for the design invariants.

## Pod installation

Copy the complete contents of `pod-template/` into each of the four pod computer directories:

```text
pod-template/startup.lua -> /startup.lua
pod-template/pod/        -> /pod/
```

Its filesystem should contain `/startup.lua` plus `/pod/` holding `config.lua`,
`discover.lua`, `main.lua`, `props.lua`, `protocol.lua`, and `thrusters.lua`.

On each pod, edit `/pod/config.lua` before rebooting:

```lua
corner = "FL",          -- change for each pod
hostname = "ENG-FL",   -- must match the corner
mainComputerId = 12,    -- numeric ID of FCS-DEV
expectedThrusterCount = 20,
fallbackPower = 0.0,    -- grounded first; later use tested hover fallback
manifestApproved = false,
```

Use `FR`, `RL`, and `RR` on the other three copies.

Each pod needs:

- One wireless modem for FCS communication.
- A local wired modem/network connected only to that corner's own devices: its
  ion thrusters, its Rotation Speed Controller, and its prop bearing.
- Nothing from another corner on its local network.

## Approving a pod's thrusters

With the carrier grounded and the local ion network connected, run:

```text
/pod/discover.lua
```

This writes `/pod/thruster_manifest.lua` and prints an `OTHER DEVICES` list of
every non-thruster peripheral on the local network -- copy the Rotation Speed
Controller and prop bearing names from there into `propController` and
`propBearing`.

Confirm that every listed device physically belongs to that corner and that the count matches. Then change:

```lua
manifestApproved = true
```

Reboot the pod. It immediately applies `fallbackPower`, hosts its wireless name, starts its command watchdog, and broadcasts summarized telemetry.

## Main-computer configuration

Run `id` on all four pods and enter their IDs in `/fcs/config.lua`:

```lua
podIds = {
    FL = 21,
    FR = 22,
    RL = 23,
    RR = 24,
},
```

Propellers need no configuration on FCS-DEV -- each pod reports its own. Run
`/fcs/discover.lua` there only if you are wiring the optional energy, power,
voltage, or current meters. Reboot FCS-DEV after saving the configuration.

## Checking pod status

From the FCS-DEV shell:

```text
/fcs/bankctl.lua status
```

The telemetry tab should show:

```text
Pods: FL:UP FR:UP RL:UP RR:UP
```

## Safe manual ion-bank pulse

While grounded, pulse one corner with an absolute normalized power for at most five seconds:

```text
/fcs/bankctl.lua pulse FL 0.05 1.0
```

The command requires typing `YES`. The main computer refreshes the command every 0.1 seconds. At the end, it disarms the pod and the pod returns to `fallbackPower`.

If wireless commands stop for more than 750 ms while armed, the pod independently returns to `fallbackPower`.

## Propeller testing

Propeller commands are relayed to the corner's pod, which applies them to its
Rotation Speed Controller:

```text
/fcs/propctl.lua status FL
/fcs/propctl.lua set FL 180
```

Unlike an ion bank, propeller RPM is **set-and-hold**: there is no arm step and
no watchdog revert. A wireless dropout leaves the props spinning at their last
commanded RPM, because dropping a lift rotor to a fallback on a comms hiccup
would drop the carrier. RPM is clamped pod-side to `propMinimumRpm` /
`propMaximumRpm`.

Both computers must run the same protocol version (now **2**). A pod still
running the older files is rejected with `unsupported protocol version` -- push
the update to FCS-DEV and all four pods together.

## Logs

FCS-DEV writes combined Sable, propeller, power, and pod telemetry to:

```text
/fcs/logs/flight_<UTC milliseconds>.csv
```

## Operational stationkeeping baseline

The direct-wired controller is operational on the current carrier. Run 3 (`flight-logs/wiredframe_stationkeep_run3.txt`) is the frozen baseline:

- 521 complete frames sent and 521 applied by every pod;
- zero missing, duplicate, reordered, invalid, expired, apply-error, fallback, or fallback-stop events;
- maximum horizontal speed 0.750938 blocks/s;
- maximum captured-position error 18.832382 blocks while arresting the inherited drift;
- maximum commanded tilt 1.327737 degrees; and
- clean operator stop followed by exact-zero shutdown.

The baseline controller uses `velocityGain=0.80`, `positionGain=0.0225`, `integralGain=0.010`, a 0.15 degree/s command slew, and a 6 degree tilt cap. Do not change its plant sign, gains, protocol, pod validation, or fallback behavior without retaining the run-3 configuration and producing a saved comparison run.

On FCS-DEV, run the deployed stationkeeping script with its `--stationkeep` flag. Press Ctrl+T for an operator stop; the runner records `termination=operator`, sends the exact-zero shutdown burst, and writes `/fcs/wiredframe_stationkeep_result.txt`.

Adding `--drift-test` to that flag runs a lateral-drift measurement instead: vertical authority is pegged at the high ion pulse (3/15) rather than duty-cycled, the lift and brake phases are skipped, and the altitude limits stand down behind a 200-block ceiling backstop. The craft climbs for the whole run and does not hold altitude, which is what keeps it off the ground and the X/Z data clean. The horizontal, hull tilt, and angular speed stops stay armed. Do not use this mode to judge altitude hold; plain `--stationkeep` is the proven run-3 configuration.

## Development and verification

Run the complete host-side Lua suite with LuaJIT:

```bash
for f in tools/test_*.lua; do luajit "$f" || exit 1; done
```

The stationkeeping controller and direct protocol regression can be run alone with:

```bash
luajit tools/test_stationkeep.lua
```

See:

- `HANDOFF.md` for the current operational state and rollback hashes;
- `docs/architecture/overview.md` for the system map;
- `docs/communication-architecture.md` for frame, mailbox, acknowledgement, and fallback contracts;
- `docs/stationkeeping-control-contract.md` for controller bounds and live acceptance evidence;
- `docs/guides/getting-started.md` for installation and first-run steps; and
- `docs/testing/overview.md` for the test strategy.
