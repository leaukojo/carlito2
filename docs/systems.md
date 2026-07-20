# Runtime systems

Per-system detail for everything that runs in the game. Editor/authoring tooling is in
`docs/level_kit.md`; rules and gotchas are consolidated in `CLAUDE.md`.

## Signal contract

`contract/carlito_contract.json` (currently v5) defines every bridge signal: name, dir,
type, unit, range, optional `warn`, enum, vehicles, optional `flavor: "isobus"`. The
`Contract` autoload loads + validates it at startup; `tests/test_contract.gd` fails if a
required signal goes missing. Signals are unique by **(name, dir)** — `battery` exists in
both directions (in = warning LED, out = voltage). `warn` is the danger threshold the
dashboard highlights (tacho redline, low fuel, coolant overheat); the dash infers low- vs
high-side from which end of `range` it sits near (`SignalDef.warn_is_low()`). No entry is
`todo`; a future planned-but-unimplemented signal would use that marker again.

Contract edits bump `version`; both sides warn on mismatch at runtime (that warning — not
CI — is the drift guard; sloppyCAN has no CI). **Sharing is a synced copy, canonical here:**
`tools/gen_js_contract.mjs` regenerates `../sloppycan/carlito_contract.js`
(`window.CARLITO_CONTRACT`, a committed JS global so it loads from `file://` with no build
step). Run it after any contract edit.

## Input pipeline

`InputRouter` (autoload) merges input sources into one normalized `VehicleInput`;
**all arbitration lives here** as static/pure functions, unit-tested in
`tests/test_input_arbitration.gd`:

- `arbitrate_local`: key gating (ignition required for throttle), brake-never-throttle,
  S = brake-then-reverse at standstill, foot brake drives `brake_lamp`.
- `arbitrate_bridge`: while the bridge is active and the gear byte is not Neutral, the
  **gear owns direction** (`throttle = accel` signed by the byte, `gear_auto = false`);
  brake never throttle; key gates throttle. Lamp/warning bits (`turnL`/`turnR`/`brakeLamp`/
  `checkEngine`/`battery`) are mirrored **verbatim** — sloppyCAN is the sole authority; any
  absent bit defaults off. ISOBUS fields (`hitch_request`, `pto`) mirror sloppyCAN verbatim
  (`hitch_pos` %→unit; absent → raised/off). The `rudder` in-signal, when present,
  **overrides `steer`** (the boat's rudder IS the steer channel; `bridge_source.gd` includes
  the key only when sent).
- `merge_local` (pure): combines keyboard + touch (max analog, summed steer, OR'd bits)
  before `arbitrate_local`.

`_physics_process` prefers the bridge source when fresh (< 300 ms), else falls back to
`arbitrate_local` untouched. `src/input/sources/bridge_source.gd` normalizes contract-in
fields (%→unit); `local_source.gd` reads the keyboard; the touch overlay registers itself
via `InputRouter.set_touch_source()`.

Toggle-state owners: the router owns the shared headlight level `_lights` (cycles
OFF→CLEARANCE→LOW→HIGH), the hitch toggle `_hitch_up`, and the PTO toggle `_pto`; sources
report per-frame edges (`lights_cycle`, `hitch_toggle`, `pto_toggle`) that `merge_local`
ORs, so keyboard and touch share one owner.

Local keys: W/S (or arrows) accel + brake-then-reverse, A/D steer, Space handbrake,
H horn, L lights, V next vehicle variant, I hitch, P PTO, G garage, N day/night,
Backspace respawn, F3 debug overlay, F4 force-show touch controls.
`tests/test_input_map.gd` asserts no two actions share a physical key.

## Vehicle framework

`src/vehicles/base/`:

- **`VehicleSpec`** — ALL drive tuning in one `.tres`; new vehicle = new spec + scene.
  Feel tuning is data-only: edit the spec numbers, keep the input-hierarchy test green
  (brake > peak drive > handbrake; handbrake holds only below ~30% throttle).
- **`VehicleCatalog`** (`src/vehicles/vehicle_catalog.gd`) — static registry of vehicle
  *variants* (one concrete body scene each: the four hand-built vehicles + the Kenney
  car-kit bodies + the Watercraft-pack boats) mapped onto the four contract *families*
  (car/truck/tractor/boat). The FAMILY drives bridge marshaling, dashboard cluster and
  spawn filtering; a variant carries its own spec (and, for boats, its own hull/buoyancy
  knobs), so it drives differently but signals identically. Generated one-shot by
  `tools/gen_kenney_vehicles.tscn` and `tools/gen_boat_variants.tscn` (game-mode tool
  scenes, deterministic, destructive-by-run — re-run after a scale/feel change).
  V (or the touch NEXT CAR button) cycles variants within the current
  family via `Level.set_vehicle`; `GameState.current_variant` tracks the active one.
  Unit-tested in `tests/test_vehicle_catalog.gd`. The contract never sees variants.
- **`Drivetrain`** — pure math: engine torque curve, gear ratios, RAMN gear byte
  (0x00 = N, 0x01..0x06 = D1–D6, 0xFF = R), real RPM (wheel speed through the ratio with
  idle/redline clamps), auto-shift. Unit-tested in `tests/test_drivetrain.gd`. With the
  bridge gear byte, auto-shift is bypassed and the byte is exact.
- **`RayWheel`** — one ray per wheel: spring-damper suspension + slip-based tires. The
  60 Hz stability clamps live here (damper ≤ one-tick reversal, suspension force cap,
  low-speed slip floors + one-tick lateral force cap). Tire grip scales by the painted
  ground: each contact samples `HeightmapTerrain.grip_at()` (BaseVehicle collects the
  level's grip terrains once, duck-typed `grip_at`+`contains_xz`+`height_at`); the
  multiplier rides `mu_long`/`mu_lat` — the 60 Hz clamps are untouched (they cap by
  momentum, independent of mu). The terrain used is the one whose surface is *nearest the
  contact point* and within `SURFACE_GRIP_REACH` (1 m) of it — a conformed road's deck sits
  at the flattened terrain height and still reads the paint, while a bridge or ramp passing
  over a painted patch keeps neutral grip instead of inheriting it.
- **`BaseVehicle`** (RigidBody3D) — consumes `InputRouter.get_vehicle_input()` only, runs
  wheels/drivetrain, publishes telemetry, applies lamps, plays the horn on the rising edge
  (source-agnostic). Zero-wheel-safe (the boat spec has empty `wheel_positions`). Two
  virtual seams for subclasses: `_make_telemetry()` (telemetry factory used in `_ready`)
  and `_tick_extras(input, delta)` (empty in base, run **last** in `_physics_process` so
  drivetrain RPM + telemetry motion are current). Subclasses never fork `_physics_process`.
- **`ChaseCamera`** — follows `get_global_transform_interpolated()`.
- **`LampSet`** / **`Horn`** — see Lamps & horn below.

Arcade drift: `VehicleSpec.handbrake_grip` scales rear lateral grip while the handbrake is
pulled (car: 0.45). It exists because the hierarchy test caps `handbrake_torque` too low to
lock the rears — drift comes from the grip cut, not brake torque.

## Telemetry & dashboard

- **`VehicleTelemetry`** (`src/vehicles/base/vehicle_telemetry.gd`) carries every contract
  "out" signal for ground vehicles. Motion (speed, rpm, gear, slip, yaw, accel, heading,
  position) is read straight out of the sim; the aux systems (fuel/coolant/battery) are
  simple *honest models*, not fakes. Each non-trivial derivation is a static pure fn (GPS
  `gps_lat`/`gps_lon` around the Paris origin 48.8566/2.3522, `heading_from_forward`,
  `odo_step`, `body_accel`, `impact_gate`, fuel/coolant/battery models, `pack_status`) —
  unit-tested in `tests/test_telemetry.gd`. `BaseVehicle._update_telemetry(input, delta)`
  holds the only per-tick state (prev velocity for accel/impact, accumulators); respawn
  zeroes the accel history so a teleport isn't read as an impact. The `status` bit layout
  is **provisional** (named `ST_*` bits; the final assignment is fixed with sloppyCAN when
  CAN frame packing is finalized).
- **`to_bridge_dict()`** is the one place mapping telemetry fields → contract "out" names
  in contract units (throttle/steer as %, slip as ratio); a `test_telemetry` case fails if
  it stops covering a non-todo ground "out" signal. Subclasses = `super()` + append.
- **Dashboard** (`src/ui/`): `dashboard.gd` **generates** the tell-tale row (a lamp per
  bool "in" signal + `key`/`lights` enum chips, plus a telemetry-driven lamp for each bool
  ISOBUS "out" — the PTO lamp) and the bars (each "out" signal that has a `range` **and**
  a `warn`, or `flavor == "isobus"` — the HITCH/PTO/LOAD implement panel) by walking the
  contract for the active vehicle type. The two radial gauges (`gauge.gd`, one bespoke
  widget instanced twice: speedo + tacho) are **hand-built** and only read scale/redline
  from the contract; each is built only when the vehicle declares its signal (`kmh`/`rpm`
  in `signals_for_vehicle` — the boat gets a speedo, no tacho). Gauge text sits in the
  arc's bottom 90° gap; gear shows in the tacho gap via the contract `gear` enum. Short
  captions (`BAR_LABEL`, `LAMP_TEXT`) are hand-picked. `bar` widget is `dash_bar.gd`.
  Plain text + color only.
- **Debug overlay** (`debug_overlay.gd`): FPS / frame ms / draw calls / primitives / VRAM /
  node count from the `Performance` monitors, toggled with **F3**. The perf guardrail is
  < ~500 draw calls in the worst view.

## Bridge

- **Transport is web-only.** The export **Head Include** (`export_presets.cfg`
  `html/head_include`; reviewable source `src/bridge/web/head_include.html`) installs
  `window.__carlito`: it stashes inbound `{type:'carlitoInput'}` values with a timestamp
  and exposes `publish()` for outbound `{type:'carlitoOutput'}`.
- `Bridge` autoload (`src/bridge/bridge.gd`): `OS.has_feature("web")` gates everything
  (inert on desktop — `is_active()` false, no JS touched). Polls the inbound stash each
  physics tick (~60 Hz), freshness-gated 300 ms in JS; publishes telemetry ~20 Hz,
  marshaling `values` **by contract name** from
  `Contract.signals_for_vehicle(GameState.current_vehicle, "out")` ×
  `telemetry.to_bridge_dict()` — vehicle-aware, so a car emits car signals and the tractor
  adds the ISOBUS four. Both sides stamp their contract version on outgoing messages and
  warn once on mismatch.
- `boot.gd` calls `Bridge.bind(level)` (mirrors `Dashboard.bind`); both rebind on
  `Level.vehicle_changed`.

## Lamps, horn & day/night

- **Lamp state flows through `VehicleInput`, never a side channel.** Locally only
  `brake_lamp` is driven (from the foot brake); turn signals + warning LEDs stay off —
  **there is no local blink timer** (turn lamps blink because the bridge source toggles
  the bit).
- **`LampSet`** (`src/vehicles/base/lamp_set.gd`) applies lamp state to **scene-authored**
  lamp nodes the `VehicleSpec` names by NodePath (`headlight_paths` = SpotLight3D nodes
  with distinct energy/range per `lights` level; `brake_lamp_paths`/`turn_*_paths` =
  MeshInstance3D lenses given a private emissive material at setup). Placement is
  scene-authored; the spec only declares which node is which lamp. Rear lamps are
  tri-state via the pure `LampSet.rear_tier(brake_on, headlights)`: STOP > TAIL
  (headlights ≥ clearance) > OFF (dim housing, never invisible) — unit-tested in
  `tests/test_lamps.gd`. `BaseVehicle` builds one `LampSet` in `_ready` and calls
  `apply()` each tick.
- **Horn is procedural** (`horn.gd`: a looping two-partial `AudioStreamWAV` synthesized at
  `_ready`, no asset). Plays on the horn **rising edge** and holds while pressed.
- **Day/night is a `Level` concern** (not a bridge signal): **N** toggles the level's sun +
  ambient between the scene-authored day values (captured at load) and a dim night preset
  (`level.gd`).

## Shell, touch controls & garage

- **Shell flow** lives in `boot.gd` (the `boot.tscn` root — there is no giant main.tscn):
  boot → level select → load level → play, with an in-play garage overlay. The persistent
  HUD (dashboard, debug overlay, touch controls) is authored in `boot.tscn`;
  `LevelSelect`/`GarageMenu` are transient Control overlays the shell creates/frees. Under
  `--headless` the shell **auto-loads the first registry level** (the CI smoke can't
  click) so load→spawn→play stays covered.
- **Level select** (`src/ui/level_select.gd`) reads `LevelRegistry.LEVELS`
  (`src/shell/level_registry.gd`) — `{id, name, scene}` entries; `dev: true` entries are
  test fixtures that bake/check/smoke still cover but level-select normally hides.
  (Currently dev entries are shown for playtesting — see TODO.md's launch checklist.)
- **Garage menu** (`src/ui/garage_menu.gd`) reads `LevelInfo.allowed_vehicles` (passed in
  by the shell, never touches the tree) and emits `vehicle_chosen(type)`; the shell calls
  `Level.set_vehicle(variant)`, which respawns at a `VehicleSpawn` matching the variant's
  FAMILY and emits `Level.vehicle_changed(type)` so the shell rebinds the
  dashboard/bridge. `Dashboard.bind` reads `GameState.current_vehicle` (the spawned
  family), falling back to `LevelInfo.default_vehicle`. Open with **G** or the touch
  GARAGE button. Adding a vehicle = a `VehicleCatalog.VARIANTS` entry + its family in a
  level's `allowed_vehicles`.
- **Garage showroom level** (`src/levels/garage/`, registered id `garage`): a real Level
  whose spawned vehicle is frozen KINEMATIC hovering above the floor — `_physics_process`
  still runs, so wheels steer/spin, the engine revs and lamps toggle while the orbit
  camera (`orbit_camera.gd`) inspects from any angle, including underneath; a wall
  screen shows the active variant's spec. Input, dashboard and bridge flow through
  Level unchanged.
- **Touch controls** (`src/ui/touch_controls.gd`) are a second local `InputSource`:
  steering joystick (bottom-left), gas/brake pedals (bottom-right), right-edge button
  stack (HORN/LIGHTS/HAND + GARAGE/RESPAWN). Widgets take touch **and** mouse. Visible
  only on touch/web (`_should_show()`); **F4** force-toggles for desktop tests. The
  bridge-conflicting buttons (HORN/LIGHTS/HAND — sloppyCAN owns those) hide while
  `Bridge.is_active()`.

## Tractor, implement & ISOBUS

- The six tractor ISOBUS signals: `hitch_pos`/`pto` in, `hitch_pos_actual`/`pto_state`/
  `pto_rpm`/`engine_load` out (all `flavor: "isobus"`).
- **`TractorVehicle extends BaseVehicle`** (`src/vehicles/tractor/tractor.gd`) — a real
  subclass because it owns per-tick hitch/PTO state; all of it runs in `_tick_extras`.
- **`TractorTelemetry extends VehicleTelemetry`** adds the four ISOBUS "out" fields (named
  exactly the contract names). `engine_load` is a **modeled honest value**
  (`engine_load_pct` — throttle demand + a PTO parasitic term, pure/unit-tested, same
  latitude as fuel/coolant); the rest are read straight out of the sim.
- **The `Implement` is cosmetic** (`src/vehicles/tractor/implement.{gd,tscn}`, `Node3D` —
  **no CollisionShape, no joint**). It rides a `HitchSocket` `Marker3D` on the tractor;
  `set_hitch(pos01)` swings the `LiftArm` pivot, `set_pto(on, rpm)` spins the `Rotor` in
  `_process`. Swap the instance to swap implements. Hitch **geometry** is scene-authored
  (like lamp placement); the three behaviour knobs (`hitch_travel_time`, `pto_ratio`,
  `pto_load`) are `@export` on `TractorVehicle` — node behaviour, not a spec (drive tuning
  stays in the plain `tractor_spec.tres`). Spawn default: raised, PTO off (respawn
  re-raises).
- **Uniform wheel radius:** RayWheel is single-radius, so the tractor's big-rear/
  small-front wheels are **visual only** (two cylinder meshes in the scene; physics uses
  one `wheel_radius`).

## Boat & water

- **`WaterSurface`** (`src/water/water_surface.gd`, `@tool Area3D`, group `"water"`) is
  one node = three things: the **height API** (`get_height(pos)` returns the node's global
  Y — **flat**; the vertex waves in `src/water/water.gdshader` are visual-only and must
  never feed physics), the visual plane, and the **non-boat kill/respawn volume**: its box
  top sits `kill_margin` below the surface so a shoreline splash isn't death;
  `body_entered` → `call_deferred("respawn")` on any non-boat `BaseVehicle` (deferred —
  physics flush). The region is an **axis-aligned rect** around the node origin
  (`contains_xz`) — don't rotate it. Water is a direct child of the level (like terrain),
  **never under `Authoring`** (not bakeable kit content).
- **Depth-fade shading** (`water.gdshader`, fragment-only — physics untouched): the shader
  samples `hint_depth_texture`, reconstructs the opaque scene's view distance behind each
  water fragment, and fades `shallow_alpha`→`deep_alpha` / `water_color`→`deep_color` over
  `depth_fade_m` of water column. Shallow water stays translucent (free shore gradient),
  deep water goes opaque so the seafloor and the square map edge behind it disappear. NDC
  z is reconstructed for **gl_compatibility** (`depth * 2.0 - 1.0`; Forward+ leaves depth
  as-is) — the whole project runs Compatibility.
- **`BoatVehicle extends BaseVehicle`** (`src/vehicles/boat/`) follows the tractor
  template exactly: only the two seams (`_make_telemetry()` → `BoatTelemetry`,
  `_tick_extras` = buoyancy/drag/thrust/rudder), `respawn()` = `super()` + trim reset.
  `boat_spec.tres` is a plain VehicleSpec with **empty `wheel_positions`** (the drivetrain
  still ticks harmlessly — keep its 6 `gear_ratios`; `auto_shift` indexes up to byte 6).
  Boat node knobs (probes, float_depth, thrust, rudder, drag, prop/keel offsets) are
  `@export` on BoatVehicle, like the tractor's hitch knobs.
- **Buoyancy = 4 probes with the RayWheel clamp discipline**: per-probe spring k is
  **derived** (`m*g / (probes * float_depth)` — floats by construction), damper clamped to
  the one-tick reversal impulse, total clamped `[0, max_probe_force_factor × weight
  share]`; hull drag/yaw damping use `damped_force` (may at most zero the velocity it
  opposes in one tick). All pure statics on BoatVehicle, unit-tested in
  `tests/test_boat.gd`. Feel comes from the levers: thrust at `prop_offset` below COM =
  bow-up under throttle; lateral drag at `keel_offset` below COM = heel in turns.
- **`BoatTelemetry extends VehicleTelemetry`** adds `pitch`/`roll` (straight from the
  basis: `pitch_deg`/`roll_deg`, + = bow up / starboard down), `rudder_actual` (the slewed
  `_steer` as %), and `trim` (**modeled honest value** like engine_load: `trim_step`
  chases forward throttle). The boat's PITCH/ROLL bars are pure contract metadata (`warn`
  30/45); `rudder_actual`/`trim` are bridge-only (no honest warn).
- Every island level's sea is a `WaterSurface` — the boat/drown-respawn rig (drive the
  car in → drown respawn); the boat is in every island roster.

## Level framework

- `src/levels/base/`: **`Level`** (base script — reads a `LevelInfo`, spawns the default
  vehicle at the first matching `VehicleSpawn`, wires the `ChaseCamera`, handles respawn;
  variant → scene comes from `VehicleCatalog`), **`LevelInfo`** (Resource:
  display name, allowed/default vehicles), **`VehicleSpawn`** (`Marker3D` with a
  vehicle-type filter + `is_water` for boat/drown-respawn spots), **`HeightmapTerrain`**
  (see `docs/level_kit.md` — the runtime side is a greyscale image → chunked welded grid
  mesh + one matching `HeightMapShape3D`, one cell = one world unit so mesh and collision
  coincide; also the per-surface grip source: per-channel `channel_grip` (clamped to
  [0, 1]) blended by `grip_at(world_pos)` over the bilinear splat weights — the decoded
  splat + height Images are cached once, never `get_image()`/decompressed per tick.
  `grip_at` sharpens the weights with the material's `blend_sharpness` exactly as the splat
  shader does, so friction follows the border you can see instead of fading well past it;
  `get_splat_weights` still returns the raw weights).
- `level.tscn` is the authoring template (env + sun + camera + one spawn); duplicate it to
  start a level.
- `src/levels/island/level_1/` .. `level_5/` are the five playable islands: generated
  terraced terrain + auto-splat + sea, roster car/truck/tractor/boat. `level_1` is
  dressed (roads, props, scatter) and is the CI baked-level smoke target; 2-5 are blank
  canvases with an empty `AuthoringRoot`, one per independent experiment.
- `src/levels/dev/flat.tscn` is a bare test plane for isolated wheel checks.
- Loading a stranger's level is arbitrary code execution (a `.tscn` can embed scripts) —
  third-party level sharing stays out of scope until there is a validation/sandboxing
  story.
