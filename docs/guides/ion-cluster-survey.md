<!-- GSD:project-docs -->
# Ion Cluster Survey

`/pod/ion_cluster_survey.lua` collects the hardware data needed to design a
pod-local allocator for the 32 individually addressable ion thrusters in each
pod. It is isolated from the operational stationkeeping controller and does
not change the direct-wired control protocol.

This is a pod-local hardware characterization utility, not an airborne flight
controller. The future allocator will continue to receive compact per-corner
commands through the proven direct-wired sequence, validity, fallback, and
acknowledged-shutdown path. Do not turn the survey into a second operational
communications path.

## Safety boundary

- Running the script without a recognized command performs no actuation.
- `inventory` reads peripherals and creates an unapproved layout template.
- `validate` reads and validates the edited layout.
- `timing` writes exact zero only and requires `ZERO-WRITE-TIMING`.
- `restrained` is powered, requires an approved balanced layout, requires
  `RESTRAINED-ION-SURVEY`, and must only run with the craft physically
  restrained and the normal FCS and pod controller stopped.
- The powered survey uses level `2/15` as its base and level `3/15` only on the
  selected balanced pattern. It writes and verifies exact zero between every
  pattern and again during finalization.
- Run one pod at a time. Do not use `restrained` in free flight.

## Install location

Copy the repository file
`pod-template/pod/ion_cluster_survey.lua` to
`/pod/ion_cluster_survey.lua` on the pod being characterized. The script uses
the pod's already-approved `/pod/thrusters-manifest.lua`; it never replaces
that manifest.

No operational pod file is modified by running `inventory` or `validate`.
The first inventory run creates `/pod/ion-layout.lua` only when that file does
not already exist.

## Collection sequence

### 1. Inventory

```text
/pod/ion_cluster_survey.lua inventory
```

The report contains all 32 peripheral names, advertised methods, current
power, thrust, energy, capacity, and obstruction readings. It also creates an
unapproved `/pod/ion-layout.lua` template if one does not exist.

### 2. Map the physical layout

Edit `/pod/ion-layout.lua` and, for every thruster:

- set `mapped=true`;
- record its `x`, `y`, and `z` offset from the pod cluster's thrust center;
- name its physically opposite `mirror` thruster;
- assign an allocation `bank`;
- define at least two complementary balanced patterns, such as checkerboards
  A and B.

Mirror relationships must be reciprocal, and mirror `x/z` coordinates must
cancel. Every powered pattern must also have a zero summed `x/z` center of
thrust. Set `approved=true` only after checking the physical map.

### 3. Validate the layout

```text
/pod/ion_cluster_survey.lua validate
```

Validation is read-only. It rejects missing or duplicate thrusters,
unmapped entries, invalid mirrors, unknown pattern members, duplicate pattern
members, and patterns with an off-center calculated thrust center.

### 4. Measure zero-write timing

Stop the normal pod controller, then run:

```text
/pod/ion_cluster_survey.lua timing
```

Type `ZERO-WRITE-TIMING` when prompted. This stage sends only zero and compares
sequential, all-32 parallel, and batches-of-eight setter timing. It reads every
thruster afterward and requires exact-zero confirmation.

### 5. Run the restrained pattern survey

With the normal FCS and pod controller stopped and the craft physically
restrained, run one pod at a time:

```text
/pod/ion_cluster_survey.lua restrained
```

Type `RESTRAINED-ION-SURVEY` when prompted. Each approved pattern raises only
its selected members from `2/15` to `3/15`, records per-thruster applied power,
thrust, energy, obstruction, and write latency, then returns and verifies all
32 thrusters at exact zero before the next pattern.

## Reports

Reports are serialized Lua tables at:

```text
/pod/ion-cluster-survey-<computer-id>-<stage>-<utc-epoch>.txt
```

Pull the inventory, layout-validation, timing, and restrained reports from
each pod. Also preserve the final approved `/pod/ion-layout.lua` for each
corner. Together they provide:

- the address-to-position map;
- balanced and complementary actuator masks;
- individual health and obstruction data;
- sequential, parallel, and batched write latency;
- per-pattern applied power and thrust;
- exact-zero finalization evidence.

These results are inputs to the future pod-local allocator. The allocator
should accept one precise average ion demand per pod from the existing FCS
frame, expand it into balanced per-thruster levels locally, and add only
compact aggregate allocation telemetry to the current status frame.

## Local verification

```bash
luajit tools/test_ion_cluster_survey.lua
luajit -b pod-template/pod/ion_cluster_survey.lua /tmp/ion_cluster_survey.luac
```
