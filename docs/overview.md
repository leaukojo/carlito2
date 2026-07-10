# Carlito v2 — Architecture Overview

A ground-up rebuild of the Carlito CAN-bus driving sandbox: drive vehicles (car / truck /
tractor, boat coming in M6) in the browser while exchanging live CAN signals with the
sloppyCAN/RAMN simulator. Godot 4.6, web-first, physics locked at 60 Hz + interpolation.

`version2_plan.md` is the plan of record; `CLAUDE.md` is the working reference for tooling and
per-system detail. This document is the human-readable map.

## The big idea: one contract, everything flows through it

`contract/carlito_contract.json` defines every signal that crosses the game↔simulator boundary:
name, direction (`in` = simulator drives the game, `out` = game telemetry), type, unit, range,
warning threshold, enum, which vehicles carry it. Signals are unique by (name, dir).

Everything else is generated from or validated against it — never hand-duplicated:

- The **Contract autoload** loads and validates it at startup; tests fail if a signal disappears.
- The **dashboard** generates its tell-tale lamps and bars by walking the contract for the active
  vehicle (only the two radial gauges are hand-built widgets).
- The **bridge** marshals outbound telemetry by contract name, and both sides stamp the contract
  version on messages and warn on mismatch.
- The sloppyCAN side consumes a **generated JS copy** (`tools/gen_js_contract.mjs` →
  `../sloppycan/carlito_contract.js`) — regenerated after every contract edit.

## Runtime data flow

```
sloppyCAN (browser JS)                         Godot game (wasm)
     |  postMessage {carlitoInput}                  |
     v                                              v
window.__carlito stash  --poll 60 Hz-->  Bridge autoload
                                              |
                                        InputRouter  <-- keyboard / touch sources
                                              |   (ALL arbitration lives here, pure + tested)
                                              v
                                        one VehicleInput
                                              |
                                        BaseVehicle (RigidBody3D)
                                              |
                                        VehicleTelemetry (read from the sim, never faked)
                                              |
Bridge --publish 20 Hz--> window.__carlito.publish() --> postMessage {carlitoOutput}
```

Key rules baked into that flow:

- **One input path.** Vehicles consume exactly one normalized `VehicleInput` from `InputRouter`.
  Arbitration (bridge-active → the CAN gear byte owns direction; brake always beats throttle;
  ignition key gates throttle; lamp/ISOBUS bits ride the same struct) is static pure functions,
  unit-tested. When bridge input is fresh (< 300 ms) it wins; otherwise local input.
- **Honest telemetry.** RPM comes from the drivetrain, slip from the tires, GPS from position.
  Aux systems (fuel/coolant/battery) are simple models, not random numbers. Every non-trivial
  derivation is a pure static function with a unit test.
- **Web-only transport.** The bridge is inert on desktop; the JS shim is installed by the web
  export's Head Include (source: `src/bridge/web/head_include.html`).

## Vehicles

`src/vehicles/base/` is the framework: `VehicleSpec` (a `.tres` resource holding ALL drive
tuning — adding a vehicle is a new spec + scene, no code), `Drivetrain` (pure math), `RayWheel`
(one-ray suspension with the clamps that keep 60 Hz stable — don't touch), `BaseVehicle`,
`ChaseCamera`, `LampSet`, procedural `Horn`.

Vehicles needing per-tick systems beyond driving subclass `BaseVehicle` through exactly two
virtual seams: `_make_telemetry()` (return a telemetry subclass) and `_tick_extras(input, delta)`
(run last each physics tick). The tractor (`TractorVehicle` + cosmetic `Implement` + ISOBUS
signals) is the worked example; the boat will follow the same pattern.

## Levels and the authoring kit

Levels are self-contained scenes composed by the shell (`boot.gd`: boot → level select → play,
with a garage overlay). A level = `Level` base script + a `LevelInfo` resource (allowed vehicles)
+ `VehicleSpawn` markers. Adding one to the game = a `LevelRegistry.LEVELS` entry.

Levels are authored with the kit (`kit/`): GridMap palettes for road/tile kits, `KitPiece`
prefabs for everything else, all under one `AuthoringRoot`. The **bake tool** then merges render
meshes per chunk, harvests prop collision per chunk, and welds all drivable geometry into a
single level-wide collision body — the v1 lesson that kills chunk-seam ghost collisions. Bakes
are input-hash-stamped; CI fails on stale bakes. At runtime `Level` loads `<level>.baked.scn` and
drops the authoring subtree; an export plugin guarantees authoring content never ships.

`docs/making_a_level.md` is the step-by-step walkthrough — stale after LK0 (its `kit_demo`
worked example was deleted); rewritten around the new authoring tools in LK8.

## Testing & CI

- **gdUnit4** covers all pure logic: drivetrain, input arbitration, telemetry derivations, lamps,
  bake math. Run headless with the console Godot binary (see CLAUDE.md for exact commands).
- **CI** (`.github/workflows/ci.yml`): import → tests → stale-bake check → headless smoke (boots
  the shell, which auto-loads a level headless) → web export; pushes to `main` deploy to GitHub
  Pages with cache-busted filenames (export basename embeds the commit SHA).

## Process

The build is run as one Claude Code prompt per verification gate — see `prompting_guide.md` for
the prompt sequence (P0…P10), model/effort choices, and the code-review protocol. Milestones
M0–M5 and the level kit (P6) have landed; remaining: water/boat/harbor (P8), island (P9),
perf pass + launch (P10). Code is MIT, assets CC0; v1 is a behavior reference only, never a
code source.
