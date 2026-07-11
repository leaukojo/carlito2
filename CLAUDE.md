# CLAUDE.md

Guidance for Claude Code sessions in this repository.

## What this is

**Carlito v2** — a ground-up rebuild of the Carlito CAN-bus driving sandbox: drive vehicles
(car/truck/tractor/boat) in a browser while exchanging live CAN signals with the sloppyCAN/RAMN
simulator over a postMessage bridge. Godot 4.6, web-first.

`docs/overview.md` is the human-readable architecture map; `prompting_guide.md` (repo root) is
the prompt-per-milestone build playbook — read the current prompt's entry before starting a
milestone task.

**`version2_plan.md` (repo root) is the plan of record.** Read the section a task references
before implementing. Milestones M0–M7 are in §5.3; **M0–M6 plus the level kit (P6) have landed** — remaining:
the level-kit authoring rework (**`level_kit_plan.md`**, phases LK0–LK8, prompts in
`level_kit_prompts.md` — runs before the island; LK0 deletes every kit level (farm, harbor,
kit_demo — clean slate, zero legacy compat), LK1 builds the permanent `kit_fixture` CI bake
level, LK8 rebuilds farm + harbor with the new tools), then island (M7/P9), perf pass +
procedural engine audio + launch (P10). Launch levels are **signal playgrounds** (level
kit plan §2): content must make contract signals visibly perform — no missions.

## v1 is a reference spec, NEVER a code source

v1 lives at `../carlito` (and its deployed build). **Zero v1 code reuse** — do not read v1 source
to copy code, patterns, or snippets. When plan §6 (the distilled v1 behavior spec) is ambiguous,
*observe* v1's behavior by running its deployed build, then re-implement cleanly here.

## Layout (plan §4.1)

```
contract/     shared signal-contract JSON (carlito_contract.json — heart of the project, plan §3)
src/shell/    game shell: boot, level select, garage menu (+ GameState autoload)
src/bridge/   Contract + Bridge autoloads (contract loader; CAN bridge lands in P3)
src/input/    InputRouter autoload + input sources; ALL input arbitration lives here
src/vehicles/ base/ (BaseVehicle, VehicleSpec, wheels, drivetrain) + car/ truck/ tractor/ boat/
src/levels/   base/ (Level scene, LevelInfo, markers) + gym/ (farm/harbor deleted in LK0, rebuilt LK8; island lands P9)
src/ui/       dashboard, touch controls, menus
src/water/    water surface + height sampling API
kit/          level-authoring kit: meshlibs, prefabs, @tool helpers, bake tool
tests/        gdUnit4 suites (tests/fixtures/ for bad-input files)
tools/        editor scripts (bake, import), CI helpers
```

Autoloads (keep this the whole set): `Contract`, `Bridge`, `InputRouter`, `GameState`.

## Vehicle framework (M1 core, landed)

- `src/vehicles/base/`: `VehicleSpec` (ALL tuning — new vehicle = new `.tres` + scene),
  `Drivetrain` (pure math: torque curve, RAMN gear byte 0/1-6/0xFF, real RPM, auto-shift —
  unit-tested in `tests/test_drivetrain.gd`), `RayWheel` (one ray/wheel suspension + slip
  tires), `BaseVehicle` (RigidBody3D; consumes `InputRouter.get_vehicle_input()` only),
  `ChaseCamera` (follows `get_global_transform_interpolated()` — never `global_transform`
  in `_process`, it stutters at the locked 60 Hz tick).
- 60 Hz stability lives in `RayWheel`'s clamps (damper ≤ one-tick reversal, suspension force
  cap, low-speed slip floors + one-tick lateral force cap). Don't remove them; don't raise
  the tick (plan §1).
- Input arbitration (key gating, brake-never-throttle, local S = brake-then-reverse,
  bridge gear-owns-direction seam) is static/pure in `input_router.gd` — tested in
  `tests/test_input_arbitration.gd`. Touch source lands M4, bridge source M3.
- Drive scene: boot loads `src/levels/gym/gym.tscn` (the dev gym, plan §4.5).
  `src/levels/dev/flat.tscn` is the older bare test plane, kept for isolated wheel checks.
  Controls: W/S accel + brake-then-reverse, A/D steer, Space handbrake, Backspace respawn.
- Feel tuning: edit `car_spec.tres` numbers only; keep the §6 hierarchy test green
  (brake > peak drive > handbrake, handbrake holds only below ~30% throttle).
- Arcade drift: `VehicleSpec.handbrake_grip` scales rear lateral grip while the handbrake is
  pulled (car: 0.45). It exists because the hierarchy test caps `handbrake_torque` too low to
  lock the rears — drift comes from the grip cut, not brake torque.

## Level framework (M1, landed — plan §4.5)

- `src/levels/base/`: `Level` (base script — reads a `LevelInfo`, spawns the default vehicle
  at the first matching `VehicleSpawn`, wires the `ChaseCamera`, handles respawn; vehicle type
  → scene registry is `Level.VEHICLE_SCENES`), `LevelInfo` (Resource: display name,
  allowed/default vehicles), `VehicleSpawn` (`Marker3D` with a vehicle-type filter + `is_water`
  for boat/drown-respawn spots), `HeightmapTerrain` (`@tool StaticBody3D`: a greyscale image →
  welded grid mesh + matching `HeightMapShape3D`, one cell = one world unit so mesh/collision
  coincide — call `rebuild()` after editing; the §2-rule-2 ground path, never trimesh).
- `level.tscn` is the authoring template (env + sun + camera + one spawn); duplicate it to start
  a level. `src/levels/gym/gym.tscn` is the fully dressed dev gym: flat zone, two ramps, a
  heightmap hill (`hill_heightmap.png`, keep import lossless/no-mipmap so runtime `get_image()`
  works), ice/mud friction strips (PhysicsMaterial-tagged; wheels don't sample surface friction
  yet), a slalom cone line, and a walled pool basin holding a `WaterSurface` (the M6 boat/drown
  regression rig — boat is in the gym roster).
- Levels are self-contained scenes composed by the shell (plan §2 rule 6); boot instances one
  directly today, level-select UI lands M7.

## Telemetry & dashboard (M2, landed — plan §3, §4.6, §6)

- `VehicleTelemetry` (`src/vehicles/base/vehicle_telemetry.gd`) carries every contract **"out"**
  signal for ground vehicles. Motion (speed, rpm, gear, slip, yaw, accel, heading, position) is
  read straight out of the sim (plan §2 rule 3); the aux systems (fuel/coolant/battery) are simple
  *honest models*, not fakes. Each non-trivial derivation is a static pure fn (GPS `gps_lat/gps_lon`
  around the Paris origin, `heading_from_forward`, `odo_step`, `body_accel`, `impact_gate`,
  `fuel/coolant/battery` models, `pack_status`) — unit-tested in `tests/test_telemetry.gd`, same
  discipline as Drivetrain. `BaseVehicle._update_telemetry(input, delta)` holds the only per-tick
  state (prev velocity for accel/impact, accumulators) and calls them; respawn zeroes the accel
  history so a teleport isn't read as an impact. `status` bit layout is **provisional** (finalized
  P3 with sloppyCAN) but kept as named `ST_*` bits.
- Dashboard (`src/ui/`) follows §4.6's split exactly — do **not** turn it into a from-JSON gauge
  framework. `dashboard.gd` **generates** the tell-tale row (a lamp per bool "in" signal + `key`/
  `lights` enum chips) and the bars (each "out" signal that has a `range` **and** a `warn`, minus
  the two gauges) by walking the contract for the active vehicle type. The two radial gauges
  (`gauge.gd`, one bespoke widget instanced twice: speedo + tacho) are **hand-built** and only read
  scale/redline from the contract; gauge text sits in the arc's bottom 90° gap (plan §6). Gear is
  shown in the tacho gap via the contract `gear` enum; ignition/lights via the chips. `bar` widget
  is `dash_bar.gd`. Plain text + color only (plan §2 rule 10).
- HUD is composed by the shell: `boot.tscn`'s `UI` CanvasLayer holds `Dashboard` + `DebugOverlay`;
  `boot.gd` binds the dashboard to the level after it spawns the vehicle (`Dashboard.bind(level)`),
  and the dash polls `level.vehicle.telemetry` each frame so it survives respawn/vehicle swap.
- Debug overlay (`debug_overlay.gd`, plan §2 rule 9): FPS / frame ms / draw calls / primitives /
  VRAM / node count from the `Performance` monitors, toggled with **F3** (`debug_overlay` action).
  The §5.4 guardrail is < ~500 draw calls in the worst view.

## Bridge & bridge input (M3, landed — plan §4.2, §4.3, §6)

- **Transport is web-only.** The export **Head Include** (`export_presets.cfg` `html/head_include`,
  reviewable source `src/bridge/web/head_include.html`) installs `window.__carlito`: it stashes
  inbound `{type:'carlitoInput'}` values with a timestamp and exposes `publish()` for outbound
  `{type:'carlitoOutput'}`. **Edit the source file and re-paste into the preset's Head Include field
  — they must match.**
- `Bridge` autoload (`src/bridge/bridge.gd`): `OS.has_feature("web")` gates everything (inert on
  desktop — `is_active()` false, no JS touched). Polls the inbound stash each physics tick (~60 Hz),
  freshness-gated 300 ms in JS; publishes telemetry ~20 Hz, marshaling `values` **by contract name**
  from `Contract.signals_out()` × `telemetry.to_bridge_dict()` (never a hand-written field list).
  `boot.gd` calls `Bridge.bind(level)` (mirrors `Dashboard.bind`). Both sides stamp their contract
  version on outgoing messages and warn once on mismatch (plan §3).
- Bridge input arbitration is pure/static in `input_router.gd` (`arbitrate_bridge`, tested): while
  active + not Neutral the **gear owns direction** (`throttle = accel` signed by the byte,
  `gear_auto=false`), brake never throttle, key gates throttle. `_physics_process` prefers the
  bridge source when fresh, else falls back to `arbitrate_local` untouched (§6 freshness gate).
  `src/input/sources/bridge_source.gd` normalizes contract-in fields (%→unit) for it.
- `VehicleTelemetry.to_bridge_dict()` is the one place mapping telemetry fields → contract "out"
  names in contract units (throttle/steer as %, slip as ratio); a `test_telemetry` case fails if it
  stops covering a non-todo ground "out" signal.

## Lamps, horn & day/night (M4, landed — plan §6)

- **Lamp state flows through `VehicleInput`, never a side channel.** The `in` lamp/warning bits
  (`turnL`/`turnR`/`brakeLamp`/`checkEngine`/`battery`) ride the same arbitration as everything else:
  `bridge_source.gd` passes them through as bools, `arbitrate_bridge` **mirrors them verbatim**
  (plan §6 — sloppyCAN is the sole authority; any absent bit defaults **off**, incl. the warning
  LEDs). Locally only `brake_lamp` is driven (from the foot brake in `arbitrate_local`); turn
  signals + warning LEDs stay off — **there is no local blink timer** (turn lamps blink because the
  source toggles the bit).
- `LampSet` (`src/vehicles/base/lamp_set.gd`) applies §6 state to **scene-authored** lamp nodes the
  `VehicleSpec` names by NodePath (`headlight_paths` = SpotLight3D nodes with distinct energy/range
  per `lights` level; `brake_lamp_paths`/`turn_*_paths` = MeshInstance3D lenses given a private
  emissive material at setup). **Placement is scene-authored (plan §4.4); the spec only declares
  which node is which lamp** — positions live in the model scene. Rear lamps are tri-state via the
  pure `LampSet.rear_tier(brake_on, headlights)`: STOP > TAIL (headlights ≥ clearance) > OFF (dim
  housing, never invisible) — unit-tested in `tests/test_lamps.gd`. `BaseVehicle` builds one
  `LampSet` in `_ready` and calls `apply()` each tick.
- **Horn is procedural** (`horn.gd`: a looping two-partial `AudioStreamWAV` synthesized at `_ready`,
  no asset). `BaseVehicle` plays it on the horn **rising edge** and holds while pressed —
  source-agnostic (whichever source set `VehicleInput.horn`). Local horn = **H** key.
- Local headlights **cycle** OFF→CLEARANCE→LOW→HIGH on **L**. The level is owned by **InputRouter**
  (`_lights`), not a source, so keyboard and touch share one owner: sources report a per-frame
  `lights_cycle` edge and the router advances the shared level. Day/night is a `Level` concern (not a
  bridge signal): **N** toggles the level's sun + ambient between the scene-authored day values
  (captured at load) and a dim night preset (`level.gd`).

## Shell, touch controls & garage (M4, landed — plan §4.6)

- **Shell flow** lives in `boot.gd` (still the `boot.tscn` root, no giant main.tscn): boot → level
  select → load level → play, with an in-play garage overlay. The persistent HUD (dashboard, debug
  overlay, **touch controls**) is authored in `boot.tscn`; `LevelSelect`/`GarageMenu` are transient
  Control overlays the shell creates/frees. Under `--headless` the shell **auto-loads the first
  registry level** (the CI smoke can't click) so load→spawn→play stays covered.
- **Level select** (`src/ui/level_select.gd`) reads `LevelRegistry.LEVELS` (`src/shell/level_registry.gd`)
  — the shell's list of `{id, name, scene}`; adding a level = a new entry + its `.tscn`. Emits
  `level_chosen(scene_path)`.
- **Garage** (`src/ui/garage_menu.gd`) reads `LevelInfo.allowed_vehicles` (passed in by the shell,
  never touches the tree) and emits `vehicle_chosen(type)`; the shell calls `Level.set_vehicle(type)`,
  which respawns at a matching `VehicleSpawn` and emits `Level.vehicle_changed(type)` so the shell
  rebinds the dashboard/bridge to the new type. `Dashboard.bind` now reads `GameState.current_vehicle`
  (the spawned type), falling back to `LevelInfo.default_vehicle`. Open with **G** (or the touch
  GARAGE button). The gym roster is now `car`/`truck`/`tractor`/`boat`; adding a vehicle = a
  `VEHICLE_SCENES` entry + the type in a level's `allowed_vehicles`.
- **Touch controls** (`src/ui/touch_controls.gd`) are a second **local `InputSource`** registered via
  `InputRouter.set_touch_source()`: a steering joystick (bottom-left, horizontal axis), gas/brake
  pedals (bottom-right), and a right-edge button stack (HORN/LIGHTS/HAND + GARAGE/RESPAWN). It
  reports the same raw dict as `local_source.gd`; `InputRouter.merge_local()` (pure, tested) combines
  keyboard + touch (max analog, summed steer, OR'd bits) before `arbitrate_local`. Widgets take touch
  **and** mouse. Visible only on touch/web (`_should_show()`); **F4** force-toggles for desktop tests.
  The bridge-conflicting buttons (HORN/LIGHTS/HAND — sloppyCAN owns those, plan §6) hide while
  `Bridge.is_active()`.

## Machinery — tractor + implement + ISOBUS (M5, landed — plan §1, §3, §4.4)

- **Contract is v5.** The six tractor ISOBUS signals are live (no longer `todo`): `hitch_pos`/`pto`
  in, `hitch_pos_actual`/`pto_state`/`pto_rpm`/`engine_load` out (all `flavor: "isobus"`). The five
  boat signals landed at M6/v5 — **nothing is `todo` anymore**. Regen the sloppyCAN copy after any
  contract edit (`node tools/gen_js_contract.mjs`).
- **`TractorVehicle extends BaseVehicle`** (`src/vehicles/tractor/tractor.gd`) — a real subclass
  because it owns per-tick hitch/PTO state. It never forks `_physics_process`; the base grew **two
  tiny virtual seams**: `_make_telemetry()` (factory, `_ready` builds `telemetry` from it — tractor
  returns `TractorTelemetry`) and `_tick_extras(input, delta)` (empty in base, run **last** in
  `_physics_process` so drivetrain rpm + telemetry motion are current). All tractor per-tick work is
  in `_tick_extras`.
- **`TractorTelemetry extends VehicleTelemetry`** adds the four ISOBUS **out** fields (named exactly
  the contract names) and overrides `to_bridge_dict()` = `super()` + append, so the name-keyed bridge
  marshaling and the dashboard's `t.get(name)` reads work unchanged. `engine_load` is a **modeled
  honest value** (`engine_load_pct` — throttle demand + a PTO parasitic term, pure/unit-tested, same
  latitude as fuel/coolant); the rest are read straight out of the sim (plan §2 rule 3).
- **ISOBUS inputs ride `VehicleInput`, never a side channel** (same rule as lamps): `hitch_request`
  (0..1) + `pto` (bool). `arbitrate_bridge` mirrors sloppyCAN verbatim (`hitch_pos` %→unit, absent →
  raised/off); `arbitrate_local` fills them from **InputRouter-owned** toggles `_hitch_up`/`_pto`
  (same owner pattern as `_lights`), advanced by per-frame `hitch_toggle`/`pto_toggle` edges the
  sources report and `merge_local` ORs. Local keys: **V** = hitch raise/lower, **P** = PTO. All pure
  and unit-tested.
- **The `Implement` is cosmetic** (`src/vehicles/tractor/implement.{gd,tscn}`, `Node3D` — **no
  CollisionShape, no joint**, plan §1/§8 scope guard). It rides a `HitchSocket` `Marker3D` on the
  tractor; `set_hitch(pos01)` swings the `LiftArm` pivot, `set_pto(on, rpm)` spins the `Rotor` in
  `_process`. Swap the instance to swap implements. Hitch **geometry** is scene-authored (like lamp
  placement); the **three behaviour knobs** (`hitch_travel_time`, `pto_ratio`, `pto_load`) are
  `@export` on `TractorVehicle` — node behaviour, not a `TractorSpec` (drive tuning stays in the
  plain `tractor_spec.tres`). Spawn default: **raised**, PTO off (respawn re-raises).
- **Bridge publish is vehicle-aware:** `Bridge._publish` walks
  `Contract.signals_for_vehicle(GameState.current_vehicle, "out")`, so a car emits car signals and a
  tractor adds the ISOBUS four (walking all `signals_out()` would warn on a car for the missing hitch/
  PTO values now that they're not `todo`).
- **Dashboard implement panel is contract-`flavor`-driven** (not hardcoded names): `_build_bars`
  includes an "out" signal with a range when it's warn'd **or** `flavor == "isobus"` (→ HITCH/PTO/LOAD
  bars); `_build_telltale_row` adds a telemetry-driven lamp for each bool isobus "out" (→ the PTO
  lamp). Short captions (`BAR_LABEL`, `LAMP_TEXT["pto_state"]`) are hand-picked like the other lamp
  labels. Car/truck dashes are unchanged (they declare no isobus signals).
- **Uniform wheel radius:** RayWheel is single-radius, so the tractor's big-rear/small-front wheels
  are **visual only** (the scene authors two cylinder meshes; physics uses one `wheel_radius`).

## Level-authoring kit & bake tool (P6, landed — plan §2 rules 1-2, §4.5)

- **Layout:** `kit/raw/<kit>/` CC0 Kenney GLBs (7 kits: racing/roads/suburban/commercial/industrial/
  watercraft + **nature**; keep `Textures/` beside the glbs — relative refs; nature glbs carry
  materials internally, no `Textures/`), `kit/import/<kit>.json` recipes, `kit/palettes/*.meshlib` +
  `kit/prefabs/<kit>/*.tscn` **generated** by `tools/gen_kit_assets.gd` (`--script` mode; re-run only
  after recipe/kit edits; meshlib item ids preserved across regens so painted GridMaps never break).
- **Thumbnails (LK1b):** `tools/gen_thumbs.tscn` (game-mode tool, run **windowed** — headless can't
  render) frames every non-excluded prefab/palette GLB in a SubViewport on a neutral backdrop and
  writes `kit/thumbs/<kit>/<name>.png` (128², imported lossless). `gen_kit_assets.gd` then embeds each
  palette tile's thumb as a MeshLibrary item **preview** (built-in GridMap palette shows pictures; the
  LK2 dock reads the PNGs). Full local flow: `gen_thumbs.tscn` -> `--import` -> `gen_kit_assets.gd`.
  Never CI. `kit/thumbs/*` is export-excluded (only the ~4KB reference table lands in the meshlib, not
  image data); embedding a new thumb re-stales dependent bakes (re-bake after regen).
- **Recipe schema is families-driven (LK1, single source of truth):** each recipe has one ordered
  `families` list — `{name, label, match:[regex], pipeline:"palette"|"prefab"|"exclude",
  collision_mode?, reason?(exclude), assets:{<name>:{overrides}}}` — that *alone* classifies every
  GLB (first match wins, ordering resolves overlaps so patterns stay simple prefixes). It drives dock
  grouping + pipeline + collision in one pass; the pure/tested classify+id logic lives in
  `kit/helpers/kit_recipe.gd` (`tests/test_kit_gen.gd`). **Coverage gate:** every GLB must match one
  family or the generator *fails* listing the unaccounted; excludes need a `reason`; per-family
  member counts print (catch-alls tagged) so an oversized "box everything else" bucket is visible.
- **Scales re-derived from measurement (LK1, lane-fit):** road-bearing kits target ~12 m two-lane
  (~6 m/lane vs the 1.8 m car): **roads 12x** cell `(12,3,12)`, **racing 12x** cubic cell
  `(12,12,12)` (corner-anchor lattice; bridge y-offsets re-measured from AABBs — corners lift 0.393
  native to the span deck, re-verify at island). suburban/commercial/industrial **8x**, watercraft
  **2x**, **nature 2.5x** (tree ~4.3 m). suburban is prefab-only (v1 driveway-long palette deleted).
  All palette GridMaps need `cell_center_y = false`. NB roads `road-curve` is a 2x2 sweeping curve;
  `road-bend` is the tight 1x1 corner (use the latter for one-cell corners).
- **Authoring model (hybrid):** GridMap palettes for road/tile kits only; everything else is a
  `KitPiece` prefab (`kit/helpers/kit_piece.gd`) whose `collision_mode`
  (`none|box|hull|multiconvex|weld`) rides the prefab root; its `DevCollision` body makes unbaked
  levels playable. All authoring lives under one `AuthoringRoot` node
  (`kit/helpers/authoring_root.gd`, `chunk_size` + editor **Bake** button).
- **Bake (`kit/bake/level_baker.gd`):** merges render meshes per XZ chunk (one MeshInstance3D per
  chunk, one surface per deduped material, verts chunk-local), harvests prefab shapes into **one
  StaticBody3D per chunk**, and welds ALL drivable geometry (every palette cell + `weld` prefabs)
  into **one level-wide ConcavePolygonShape3D body** — vertices snapped to 1 mm so tile borders are
  internal edges, never body seams. Outputs `<level>.baked.scn` + `<level>.bake.json` (input-hash
  manifest, timestamp-free). Pure fns (weld, chunking, hashing, spawn validation, accumulator) are
  unit-tested in `tests/test_bake.gd`. Spawn validation is a bake gate.
- **Runtime seam:** `Level._setup_baked()` loads `<level>.baked.scn` by convention and frees the
  authoring subtree; unbaked levels play authoring content directly (dev). Detection everywhere is
  duck-typed marker methods (`is_carlito_authoring` / `is_carlito_kit_piece`), never class_name.
- **Export never ships authoring:** `addons/carlito_kit/` (enabled EditorPlugin) registers an
  EditorExportPlugin whose `_customize_scene` strips AuthoringRoot from exported scenes;
  `export_presets.cfg` excludes kit glbs/palettes/prefabs/thumbs/tools (colormap + racing banner PNGs
  ship — baked materials reference them). Verified by byte-scanning the pck (an excluded imported
  texture leaves only a benign uid-cache path string, never its `.ctex` data).
- **CI gate:** `tools/check_bakes.tscn` recomputes each registered level's input hash (level .tscn
  + transitive `res://kit/**` deps + `.import` sidecars, CRLF-normalized text hashing) vs the
  manifest; ci.yml fails on missing/stale. The baked-level headless smoke
  (`CARLITO_LEVEL` env picks a registry id) runs against the permanent **`kit_fixture`**
  (`src/levels/dev/kit_fixture.tscn`, LK1): a minimal level — road loop from the roads palette, one
  prefab of each collision mode, a weld ramp, a car spawn — registered with `dev: true` (level-select
  hides `dev` entries; bake/check/smoke still cover them). Rebuild it with
  `godot --headless res://tools/build_kit_fixture.tscn` (game-mode tool; hand-authoring GridMap
  cell/orientation data is fragile), then re-bake.
- **Gotchas that cost time:** (1) **`--script`-mode tools cannot load level scenes** — autoload
  identifiers (InputRouter via BaseVehicle) don't compile there; bake/check run as **game-mode tool
  scenes** (`godot --headless res://tools/bake_levels.tscn`), and `level.gd` fetches GameState via
  `get_node("/root/GameState")` for the same reason. (2) A **freed node compares equal to null** —
  read results before `free()`. (3) 4.6 renamed the decomposition helper to
  `create_multiple_convex_collisions` (plural). (4) SurfaceTool.append_from leaves scaled normals
  unnormalized — the baker's SurfaceAccumulator merges at array level instead.
- **Docs:** `docs/making_a_level.md` is the non-designer walkthrough — **stale after LK0**
  (its worked example, kit_demo, was deleted); it is rewritten around the new tools in LK8.
  Gym predates the kit and stays hand-built (no AuthoringRoot: check skips it).

## Palette dock & click-to-place (LK2, landed — level_kit_plan.md §4 LK2)

- **All editor UX lives in `addons/carlito_kit/`** (plan's editor/runtime split): the P6 plugin
  grew a **bottom-panel dock** + a viewport placement tool. `plugin.gd` still registers the
  export stripper, and now also adds the dock, wires it to the tool, and calls
  `set_input_event_forwarding_always_enabled()` so `_forward_3d_gui_input` receives every
  viewport event (placement is selection-independent). Nothing here ships — the addon is
  editor-only.
- **`palette_dock.gd`** (`@tool VBoxContainer`, UI only — no viewport/editor logic): reads all
  `kit/import/*.json` recipes, gathers each kit's emitted prefab basenames (`kit/prefabs/<kit>/
  *.tscn`) + palette meshlib item names, buckets them by **family via `KitRecipe.classify`**
  (the LK1 taxonomy — `label` per section, `exclude` families skipped), and shows kit tabs →
  family sections → thumbnail grid from `kit/thumbs/<kit>/<name>.png` (basename is 1:1 across
  prefab/tile/thumb/GLB). **Search is global across all kits** (non-empty query flattens the
  tabs into one result flow, each tile badged `<kit>/<name>`). Toolbar: **Random yaw** / **Snap**
  toggles + snap-step SpinBox → `settings_changed`; prefab click → `prefab_armed`, tile click →
  `tile_selected`.
- **`placement_tool.gd`** (`RefCounted`, holds all editor API): `arm(kit,name)` instances the
  prefab as a **non-saved ghost** (unowned, its collision bodies zeroed to `collision_layer=0`
  and excluded from the ray) that follows the ground-snapped cursor; left-click **commits** a
  real owned copy under the level's `AuthoringRoot` via `EditorUndoRedoManager`
  (add_child + set_owner + local transform, undoable); **sticky** (stays armed); right-click /
  Escape disarms. Refuses to arm with a clear warning when the scene has **no AuthoringRoot**
  (found by the `is_carlito_authoring()` duck-type walk).
- **Ground raycast fallback chain** (a click never dead-drops): edited-scene physics
  `intersect_ray` first → miss → the level's **`HeightmapTerrain.height_at(world_pos)`** sample
  (new bilinear world-space query on `heightmap_terrain.gd`, plus `contains_xz`; runtime-safe,
  reused by LK5 scatter — unit-tested in `tests/test_heightmap_terrain.gd`) → miss → the `Y=0`
  plane. Editor physics isn't always populated, so the terrain/plane branches carry the feature.
- **Palette tiles route to the built-in GridMap workflow** (never reimplemented): `select_tile`
  finds — or creates (undoable, `cell_size` + `cell_center_y=false` from the recipe) — the
  AuthoringRoot GridMap using that kit's meshlib and selects/edits it so the built-in palette
  (LK1b thumbnails) opens. `GridMapEditorPlugin.set_selected_palette_item` has no public handle
  to the built-in instance, so the exact paint item is a **best-effort** print of the item id —
  the author clicks the (thumbnailed) tile in the built-in palette.

## Terrain generation & splat ground (LK3, landed — level_kit_plan.md §4 LK3)

- **`HeightmapTerrain`'s render mesh is chunked**: one MeshInstance3D per `chunk_cells` tile
  (default 64) under an unowned `Chunks` node — the frustum-cull unit for island-scale maps
  (culling granularity, **not** LOD). Collision stays **one** `HeightMapShape3D` (§2 rule 2).
  Normals are analytic from the height grid (`TerrainGen.grid_normal`) because per-chunk
  `generate_normals()` seams chunk borders; UVs stay global 0..1 so the splat never seams.
  LK4 strokes rebuild only touched tiles via `_build_chunk`.
- **Generator**: `TerrainGen` (`kit/terrain/terrain_gen.gd`, static pure fns, tested in
  `tests/test_terrain_gen.gd`). Preset = character (fractal type, relative amplitude, island
  radial falloff); knobs = `gen_seed` / `feature_scale` (m per feature) / `gen_octaves` /
  falloff band / **terrace plateaus** (`terrace_steps`+`terrace_flat`, applied last so island
  coasts step into concentric rings — the buildable flats villages/farms need; band centres
  are preserved so relief is unchanged). **World amplitude is the existing `height` export** —
  generated pixels stay normalized [0,1] (8-bit greyscale PNG, pipeline unchanged). Two
  buttons: **Generate** (editor-only, destructive-by-button, never per-frame) writes the
  current texture's source PNG, else `<scene>_<node>_height.png` beside the scene;
  **Generate random** rolls a fresh seed into `gen_seed` (still reproducible). Both are one
  `EditorUndoRedoManager` action snapshotting the prior image + any property change (seed,
  material swap) — a stray click must not destroy LK4 sculpt work.
- **Splat ground**: `kit/terrain/terrain_splat.gdshader` (ships — `kit/terrain/` is not
  export-excluded): 4 albedo colors blended by an RGBA splatmap, **R=grass G=dirt B=sand
  A=rock**, sampled raw (no `source_color` — sRGB would bend weights), gl_compatibility-safe.
  `blend_sharpness` pow-sharpens + renormalizes the weights (default 8 — crisp low-poly
  borders, not soft fades). The Auto-splat button classifies from slope + height
  (`sand_height`, `dirt_slope_deg`, `rock_slope_deg`), swapping in a splat ShaderMaterial when
  needed (same undo action); the node pushes `splatmap` into the material param on rebuild.
  The below-sea ring splats sand out to the square map edge by design — a level's
  `WaterSurface` at sea level is what makes the beach read as a circular coast.
- **Generated-PNG import gotcha**: `TerrainGen.ensure_import_settings` writes/patches the
  `.import` sidecar — lossless, no mipmaps, **`detect_3d/compress_to=0`** (the splatmap is
  sampled by a 3D shader; the default detect_3d would silently reimport it VRAM-compressed and
  break `get_image()`) and **`process/fix_alpha_border=false`** (it rewrites RGB wherever
  alpha == 0, corrupting grass/dirt/sand weights where rock == 0).
- Demo: `src/levels/dev/terrain_demo.tscn` (a real Level, **unregistered** — run it with F6):
  a generated 256 m terraced island (seed 567998) with its auto-splat, a car spawn on the central
  plateau, a boat spawn in the surrounding `WaterSurface` sea (G swaps), drown-respawn included.
  Regenerating from the recorded knobs reproduces the committed PNGs.

## Water & boat — M6 (P8, landed — plan §1, §4.4, §8)

- **`WaterSurface`** (`src/water/water_surface.gd`, `@tool Area3D`, group `"water"`) is one node
  = three things: the **height API** (`get_height(pos)` returns the node's global Y — **flat**;
  the vertex waves in `src/water/water.gdshader` are visual-only and must never feed physics,
  plan §8), the visual plane, and the **non-boat kill/respawn volume** (plan §8): its box top
  sits `kill_margin` below the surface so a shoreline splash isn't death; `body_entered` →
  `call_deferred("respawn")` on any non-boat `BaseVehicle` (deferred — physics flush). The
  region is an **axis-aligned rect** around the node origin (`contains_xz`) — don't rotate it.
  Water is a direct child of the level (like terrain), **never under `Authoring`** (not bakeable
  kit content).
- **`BoatVehicle extends BaseVehicle`** (`src/vehicles/boat/`) follows the tractor template
  exactly: only the two seams (`_make_telemetry()` → `BoatTelemetry`, `_tick_extras` = buoyancy/
  drag/thrust/rudder), `respawn()` = `super()` + trim reset. `boat_spec.tres` is a plain
  VehicleSpec with **empty `wheel_positions`** (BaseVehicle is zero-wheel-safe; the drivetrain
  still ticks harmlessly — keep its 6 `gear_ratios`, `auto_shift` indexes up to byte 6). Boat
  node knobs (probes, float_depth, thrust, rudder, drag, prop/keel offsets) are `@export` on
  BoatVehicle, like the tractor's hitch knobs.
- **Buoyancy = 4 probes with the RayWheel clamp discipline** (plan §1, 60 Hz locked): per-probe
  spring k is **derived** (`m*g / (probes * float_depth)` — floats by construction), damper
  clamped to the one-tick reversal impulse, total clamped `[0, max_probe_force_factor × weight
  share]`; hull drag/yaw damping use `damped_force` (may at most zero the velocity it opposes in
  one tick). All pure statics on BoatVehicle, unit-tested in `tests/test_boat.gd`. DO NOT weaken
  the clamps. Feel comes from the levers: thrust at `prop_offset` below COM = bow-up under
  throttle; lateral drag at `keel_offset` below COM = heel in turns.
- **`BoatTelemetry extends VehicleTelemetry`** adds `pitch`/`roll` (straight from the basis:
  `pitch_deg`/`roll_deg`, + = bow up / starboard down), `rudder_actual` (the slewed `_steer` as
  %), and `trim` (**modeled honest value** like engine_load: `trim_step` chases forward
  throttle). `to_bridge_dict()` = `super()` + the four; the boat is in test_telemetry's
  coverage gate.
- **Rudder = the steer channel** (M6 decision, recorded in the contract desc): the contract `in`
  signal `rudder`, when sloppyCAN sends it, **overrides `steer`** in `arbitrate_bridge`
  (bridge_source includes the key only when present); locally A/D steer the rudder. No new
  VehicleInput field. The boat reads `input.steer`/`input.throttle` — reverse works through the
  normal gear-owns-direction / S-at-standstill paths.
- **Dashboard:** the two gauges are now built only when the vehicle declares their signal
  (`kmh`/`rpm` in `signals_for_vehicle`) — the boat gets a speedo, no tacho. Its PITCH/ROLL bars
  are pure contract metadata (`warn` 30/45); `rudder_actual`/`trim` are bridge-only (no honest
  warn).
- **Levels:** `boat` is in `Level.VEHICLE_SCENES` and the gym roster; gym's pool holds a
  `WaterSurface` (drive the car in → drown respawn regression). The **harbor** (a P8 quay +
  seabed + 160×140 water level dressed with watercraft prefabs) was **deleted in LK0** with
  the rest of the old-lattice kit levels; it is rebuilt from scratch with the new tools in LK8.

## Running / testing / exporting

Godot binaries (4.6.3-stable): `C:\Users\Ccamy\Desktop\Godot\`. **Use
`Godot_v4.6.3-stable_win64_console.exe` for ALL CLI/headless runs** (it streams
print/push_error back); the non-console exe is for visually running the game.

```powershell
$GODOT = 'C:\Users\Ccamy\Desktop\Godot\Godot_v4.6.3-stable_win64_console.exe'

# one-time / after adding assets: build the .godot import cache
& $GODOT --headless --path . --import

# run the gdUnit4 suite (CI can't use runtest.sh — it launches Godot without
# --headless and dies on the display-less runner; ci.yml calls GdUnitCmdTool
# directly with --headless --ignoreHeadlessMode, safe for pure-logic suites)
$env:GODOT_BIN = $GODOT; .\addons\gdUnit4\runtest.cmd -a tests

# headless smoke (boots boot.tscn; --quit-after counts frames)
& $GODOT --headless --path . --quit-after 120

# level kit: regenerate palettes/prefabs (after kit/import recipe edits only)
& $GODOT --headless --path . --script res://tools/gen_kit_assets.gd
# kit thumbnails (WINDOWED — no --headless; then re-import + regen to embed palette previews)
& $GODOT --path . res://tools/gen_thumbs.tscn ; & $GODOT --headless --path . --import
& $GODOT --headless --path . --script res://tools/gen_kit_assets.gd
# bake all registered levels / CI stale-bake check (game-mode tool scenes — see kit section)
& $GODOT --headless --path . res://tools/bake_levels.tscn
& $GODOT --headless --path . res://tools/check_bakes.tscn

# local web export (CI does the real one)
& $GODOT --headless --path . --export-release "Web" build/web/index.html
```

- A headless run ending with only `ERROR: N resources still in use at exit` is **clean** —
  harmless leak-at-exit noise, not a failure.
- `--headless --script` only runs `extends SceneTree` scripts; EditorScripts need File ▸ Run
  in the editor.
- The editor **rewrites `export_presets.cfg`** when you export from the UI — CLI export reads
  it as-is. Keep thread_support + PWA (cross-origin-isolation headers) enabled: GitHub Pages
  sends no COOP/COEP, the PWA service worker injects them, and the threaded build needs them.

## CI / deploy

`.github/workflows/ci.yml`: every push runs import → gdUnit4 → headless smoke → web export;
pushes to `main` deploy to **https://leaukojo.github.io/carlito2/** via GitHub Pages (Actions
source). Cache-busting: the export basename embeds the commit SHA, so all heavy artifacts
(.pck/.wasm/.js/PWA worker) get unique names per deploy; `index.html` is a small copy. First
visit after a deploy may still need one reload for the new service worker to take over.

## The contract

`contract/carlito_contract.json` defines every bridge signal (name, dir, type, unit, range,
optional `warn`, enum, vehicles, isobus flavor). The `Contract` autoload loads + validates it at
startup; tests fail if a v1-era signal goes missing. Signals are unique by **(name, dir)** —
`battery` exists in both directions (in = warning LED, out = voltage). `warn` (added **v3**) is the
danger threshold the dashboard highlights (tacho redline, low fuel, coolant overheat); the dash
infers low- vs high-side from which end of `range` it sits near (`SignalDef.warn_is_low()`). The
tractor ISOBUS signals landed at **M5 (v4)**, the boat signals (`rudder` in;
`pitch`/`roll`/`rudder_actual`/`trim` out) at **M6 (v5)** — no entry is `todo` anymore. Contract
edits bump `version`; both sides warn on mismatch.

**Contract sharing (plan §9.1, decided):** **synced copy**, canonical here. `tools/gen_js_contract.mjs`
regenerates the sloppyCAN-side copy `../sloppycan/carlito_contract.js` (`window.CARLITO_CONTRACT`,
a committed JS global so it loads from `file://` with no build step). **Run it after any contract
edit.** Drift guard is the runtime version-mismatch console warning both sides emit (plan §3), not
CI — sloppyCAN has none.

## Standing rules (from plan §2 — every v1 lesson, permanent)

1. Static world geometry ships **baked per chunk** (merged meshes, one collision body per
   chunk); GridMaps are authoring-only. A drivable structure is never split across chunks.
   Bakes are hash-stamped; CI fails on stale bakes (check lands with the P6 bake tool).
2. Ground = heightmap/plane collision; drivable structures get dedicated welded collision
   meshes; props get boxes/hulls. **Trimesh is the exception, never the default.**
3. Telemetry is read out of the sim that produced the motion — no derived fictions (RPM comes
   from the drivetrain).
4. One contract file; everything else generated from or validated against it. Never
   hand-duplicate signal lists.
5. Vehicles consume one normalized `VehicleInput` from `InputRouter`; arbitration
   (bridge-active/gear-owns-direction, brake > accel > handbrake) lives **only** there.
6. Levels, vehicles, and UI are independent scenes composed by the shell — no giant main.tscn.
7. CI does the export; deploys are cache-busted. No manual deploy.
8. Pure logic (drivetrain math, contract encode/decode, arbitration, GPS/odometer, buoyancy)
   gets gdUnit4 tests.
9. `.web` project-setting overrides + perf budget from day one (msaa_3d.web=0, soft shadows
   off on web; do **not** set `scaling_3d/scale.web` below 1 — it adds an upscale pass on
   gl_compatibility and measures worse). Physics: **60 Hz + interpolation, locked** (§1).
10. **No emoji anywhere in UI** — the web font has no emoji glyphs; plain text + color only.

## License

Code MIT, assets CC0. Third-party adoptions (plan §7) are read line-by-line before landing
and credited in README.md.
