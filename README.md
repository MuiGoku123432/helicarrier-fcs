# Helicarrier FCS: wireless pod data foundation

This package uses five Advanced Computers:

```text
FCS-DEV  Main telemetry/FCS computer
ENG-FL   Front-left ion pod
ENG-FR   Front-right ion pod
ENG-RL   Rear-left ion pod
ENG-RR   Rear-right ion pod
```

The main computer gathers CC:Sable data, logs propeller and pod telemetry, and provides manual test commands. Each pod owns everything on its own corner -- the ion thrusters, the Rotation Speed Controller, and the prop bearing -- on one short local wired network, and relays the propellers to FCS-DEV over the wireless link.

FCS-DEV holds no propeller peripherals of its own. It needs only a wireless modem (plus a wired modem if you attach optional energy/power meters).

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

No automatic hover controller is enabled yet. The next stage uses the same wireless `banks` interface to send four bank powers from the attitude and altitude controllers.
