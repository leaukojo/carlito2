# Carlito, explained from scratch

A plain-language tour of how the game works, written for someone joining the project.
The detailed references are `docs/overview.md`, `docs/systems.md`, and `docs/level_kit.md`;
this file trades precision for readability.

## What is this?

Carlito is a driving sandbox that runs in the browser. You drive a car, truck, tractor,
or boat around small levels. There are no missions or scores — the point of the game is
the **signals**: while you drive, the game continuously exchanges CAN-bus-style messages
with a companion simulator (sloppyCAN/RAMN) running in the same web page. Press the
throttle in sloppyCAN and the car in Carlito accelerates; the car's real RPM, speed, GPS
and warning lamps stream back the other way. Levels exist to make those signals visible:
a steep grade makes `engine_load` climb, a hairpin makes the tires slip, a field gives
the tractor's hitch and PTO something to do.

It's built in Godot 4.6 and exported to WebAssembly. Physics runs at a locked 60 Hz with
interpolation for smooth rendering.

## The one idea that organizes everything: the contract

`contract/carlito_contract.json` is the heart of the project. It lists every signal that
crosses the game↔simulator boundary: its name, direction (`in` = simulator drives the
game, `out` = game reports telemetry), type, unit, valid range, warning threshold, and
which vehicles carry it.

Nothing else in the project hand-maintains a signal list. Instead:

- The `Contract` autoload loads and validates the JSON at startup.
- The **dashboard** builds its warning lamps and bar gauges by *walking the contract* for
  the current vehicle. Add a signal to the JSON and a lamp appears — no UI code.
- The **bridge** decides what telemetry to send by walking the contract too.
- The simulator side uses a *generated* JavaScript copy (`tools/gen_js_contract.mjs`).

This means adding or changing a signal is a one-file edit plus a regeneration step, and
the two sides can never silently disagree about what a signal means (both stamp a
contract version on every message and warn if they differ).

## How input flows, start to finish

```
sloppyCAN (JS in the page)
      | postMessage
      v
window.__carlito stash          <- a tiny script injected into the exported HTML
      | polled 60x/sec
      v
Bridge (autoload)               <- inert on desktop; web-only
      v
InputRouter (autoload)          <- ALSO reads keyboard + touch controls
      v
one VehicleInput struct         <- throttle, brake, steer, gear, lamps, hitch...
      v
BaseVehicle (the physics body)
```

**InputRouter is the only place input decisions are made.** It merges keyboard and touch,
and when fresh bridge data is arriving (less than 300 ms old) the bridge wins outright.
All the rules — "brake is never throttle", "the ignition key must be on to drive", "when
the simulator is in control, its gear byte decides forward vs reverse" — live here as
pure static functions with unit tests. Vehicles never know or care where their input came
from; they just consume one normalized `VehicleInput` every physics tick.

This is why the same car works with a keyboard, a phone touchscreen, and a CAN simulator
without any vehicle code changing.

## Vehicles

`src/vehicles/base/` is a small framework:

- **VehicleSpec** (a `.tres` resource) holds *all* the driving-feel numbers: mass, wheel
  positions, torque curve, gear ratios, brake strength. A new vehicle is a new spec plus
  a scene — no new code.
- **Drivetrain** is pure math (torque, gears, real RPM computed back from wheel speed).
- **RayWheel** is a one-raycast-per-wheel suspension and tire model. It contains carefully
  tuned clamps that keep the physics stable at exactly 60 Hz — this is why the physics
  tick rate is locked and the clamps must never be weakened.
- **BaseVehicle** ties it together: reads input, runs wheels and drivetrain, publishes
  telemetry, drives the lamps and horn.

Vehicles that need extra behavior (the tractor's hitch/PTO, the boat's buoyancy) subclass
BaseVehicle through exactly **two hooks**: `_make_telemetry()` (return a bigger telemetry
object) and `_tick_extras()` (run once per tick, after everything else). They never
override the main physics loop — that keeps every vehicle's core behavior identical and
testable.

The **train** is the same idea taken furthest. It's an electric multiple-unit consist that
runs on rails, not roads: rails are drawn with the ordinary road tool (there's a "Rail"
checkbox that gives the road a track profile instead of asphalt), and the level's rail loop
becomes the line the train rides. Instead of steering, its motion is a small 1D physics sim
— each carriage is a weight sliding along the spline, connected by spring couplers, feeling
the grade and the brakes — and the locomotive body is moved to match that sim each tick (so
the speed/acceleration readouts stay honest). You raise the pantograph to draw power (drop
it and traction cuts, like a real overhead line), open the doors only at a standstill, and
the reverser (forward/neutral/reverse) rides the same gear byte every other vehicle uses.
Its extra gauges — line voltage, motor current, brake-pipe pressure, coupler force — are
honest simple models, labelled as such, borrowing rail terminology (the descriptions credit
real rail practice) without pretending to be a real train's electronics.

On top of the four *families* (car/truck/tractor/boat — these are what the contract and
dashboard know about), a **VehicleCatalog** lists cosmetic *variants* (Kenney model
bodies like taxi, firetruck, ambulance) that map onto a family. The garage lets you cycle
through them; the contract never sees variants, only families.

**Telemetry is honest.** RPM comes from the drivetrain that actually moved the car; slip
comes from the tire model; GPS from the position. The few things a driving sim doesn't
naturally produce (fuel level, coolant temperature, battery voltage, engine load) are
simple physically-plausible models, clearly labelled as such — never random numbers.

## Levels

A level is a self-contained scene: terrain, props, spawn points, and a `LevelInfo`
resource saying which vehicles are allowed. The shell (`boot.gd`) shows a level-select
menu, loads the chosen level, spawns the default vehicle, and wires up the camera,
dashboard and bridge. Nothing is hardwired — levels, vehicles and UI are independent
scenes composed at runtime.

Levels are *authored* with an in-editor kit (terrain brushes, GridMap tile palettes,
prefab placement dock, vegetation scatter brushes, spline-based roads that flatten the
terrain under them). But what *ships* is a **bake**: a tool merges all the static
authoring content into a few big meshes per chunk and welds every drivable surface into
one collision body (which prevents phantom bumps at chunk seams). Each bake is stamped
with a hash of its inputs, and CI fails if a level's bake is stale — you literally cannot
ship an out-of-date bake by accident.

Water is its own system: a flat height API for the boat's buoyancy (the visual waves are
shader-only and never touch physics), plus a "you drove into the lake" respawn volume for
land vehicles.

## Testing and CI

All the pure logic — drivetrain math, input arbitration, telemetry derivations, buoyancy,
terrain/road/scatter/bake math — is covered by gdUnit4 unit tests (~300 test functions).
The trick that makes this possible: anything with logic worth testing is written as a
static pure function, so tests don't need a running game.

Every push runs CI: import → tests → stale-bake check → two headless boot smokes (the
shell auto-loads a level when it detects headless mode, since CI can't click menus) → web
export. Pushes to `main` auto-deploy to GitHub Pages with cache-busted filenames.
`tools/preflight.ps1` runs the same gates locally, and a pre-commit hook catches the most
common footguns (stale bakes, stale contract copy, editor-only type annotations that
would silently break the web build).

## House rules worth knowing (and why)

- **Physics is 60 Hz, forever.** The suspension tuning depends on the tick length;
  changing it means re-tuning every vehicle.
- **One contract file, everything generated.** Never hand-copy a signal list.
- **All input arbitration lives in InputRouter.** If you're writing an input rule
  anywhere else, stop.
- **Telemetry is read out of the simulation, never invented.**
- **Lamp state rides the input struct.** Turn signals blink because the simulator toggles
  the bit — there is deliberately no local blink timer (the simulator is the authority).
- **Baked geometry ships, authoring content doesn't.** An export plugin strips it.
- **Trimesh collision is the exception.** Ground is a heightmap shape, props get boxes or
  convex hulls.
- **No emoji in UI** — the web font has no emoji glyphs.
- **Loading a stranger's level file is code execution** (Godot scenes can embed scripts),
  so level sharing is out of scope.

Most of the sharp edges you'll hit are already written down in `CLAUDE.md`'s gotchas
section — read it before touching wheels, bakes, or the web export.
