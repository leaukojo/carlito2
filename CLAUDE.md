# CLAUDE.md

Guidance for Claude Code sessions in this repository.

## What this is

**Carlito** — a browser-based CAN-bus driving sandbox: drive vehicles (car / truck /
tractor / boat) while exchanging live CAN signals with the sloppyCAN/RAMN simulator over a
postMessage bridge. Godot 4.6, web-first, physics locked at **60 Hz + interpolation**.
Levels are **signal playgrounds** — no missions; content exists to make contract signals
visibly perform (grades for `engine_load`, hairpins for slip, fields for hitch/PTO, water
for pitch/roll).

Docs map:

- `docs/overview.md` — human-readable architecture map.
- `docs/systems.md` — runtime systems detail (contract, input, vehicles, telemetry,
  dashboard, bridge, lamps, shell, tractor, boat, levels).
- `docs/level_kit.md` — authoring kit, editor tools, terrain/scatter/roads, bake pipeline.
- `docs/making_a_level.md` — author walkthrough (**stale — rewrite pending**, see TODO.md).
- `TODO.md` — remaining work (farm/harbor/island levels, docs rewrite, perf pass, engine
  audio, launch checklist).

The previous generation of the game lives at `../carlito` (and its deployed build).
**Never read or copy its code** — observe its deployed build only, as a behavior/layout
reference.

## Working style (user preferences — learned the hard way)

- **Act as a senior Godot dev, no workarounds.** Push back on questionable requests; use
  the engine's real tools (GridMap/palette for tiling, never hand-placed piles of nodes;
  if headless blocks the right approach, script it correctly). Measure asset footprints
  against the 1.8 m car before placing — never guess scale/orientation.
- **Never commit or push unless explicitly asked** (violated before; firm rule).
- The user verifies **by driving**: any demo/verification scene must be a real Level with
  a VehicleSpawn (F6-runnable, unregistered), never camera-only. Visual bar: crisp
  high-contrast splat borders (low-poly style), plateaued buildable terrain, coasts made
  circular by water at sea level — never the square map edge.
- "Quickly / do not verify" = skip ceremony, make the small change, stop.
- **Before ending any authoring/kit/level change**: re-bake + `check_bakes` (stale bakes
  are the #1 repeat CI failure). After contract edits: `gen_js_contract.mjs`. Always sweep
  new GDScript warnings (shadowed identifiers like `load`/`basis`/`range`, integer division).
- If stuck after ~2 failed attempts on a bug, stop and write a concise symptom + hypotheses
  handoff instead of thrashing.
- Token economy: subagents only Haiku/Sonnet, max 3, no nested subagents; keep docs/memory
  present-state only (no phase history).

## Layout

```
contract/     shared signal-contract JSON (carlito_contract.json — heart of the project)
src/shell/    game shell: boot, level select, garage menu (+ GameState autoload)
src/bridge/   Contract + Bridge autoloads (contract loader; web CAN bridge)
src/input/    InputRouter autoload + input sources; ALL input arbitration lives here
src/vehicles/ base/ (BaseVehicle, VehicleSpec, wheels, drivetrain) + car/ truck/ tractor/ boat/
src/levels/   base/ (Level scene, LevelInfo, markers, HeightmapTerrain) + gym/ + dev/ fixtures
src/ui/       dashboard, touch controls, menus
src/water/    water surface + height sampling API
kit/          level-authoring kit: recipes, meshlibs, prefabs, @tool helpers, bake tool
addons/carlito_kit/  editor-only plugin: export stripper, palette dock, brushes, road tools
tests/        gdUnit4 suites (tests/fixtures/ for bad-input files)
tools/        editor scripts (kit gen, thumbs, bake, check, fixture builder), CI helpers
```

Autoloads (keep this the whole set): `Contract`, `Bridge`, `InputRouter`, `GameState`.

## Standing rules (permanent)

1. Static world geometry ships **baked per chunk** (merged meshes, one collision body per
   chunk); GridMaps are authoring-only. A drivable structure is never split across chunks —
   all drivable geometry welds into one level-wide body. Bakes are hash-stamped; CI fails
   on stale bakes.
2. Ground = heightmap/plane collision; drivable structures get dedicated welded collision
   meshes; props get boxes/hulls. **Trimesh is the exception, never the default.**
3. Telemetry is read out of the sim that produced the motion — no derived fictions (RPM
   comes from the drivetrain). Aux systems (fuel/coolant/battery, engine_load, trim) are
   simple *honest models*, clearly labelled.
4. One contract file; everything else generated from or validated against it. Never
   hand-duplicate signal lists.
5. Vehicles consume one normalized `VehicleInput` from `InputRouter`; arbitration
   (bridge-active/gear-owns-direction, brake > accel > handbrake) lives **only** there.
6. Levels, vehicles, and UI are independent scenes composed by the shell — no giant
   main.tscn.
7. CI does the export; deploys are cache-busted. No manual deploy.
8. Pure logic (drivetrain math, contract encode/decode, arbitration, GPS/odometer,
   buoyancy, terrain/scatter/road/bake math) gets gdUnit4 tests.
9. `.web` project-setting overrides + perf budget: msaa_3d.web=0, soft shadows off on web;
   do **not** set `scaling_3d/scale.web` below 1 (it adds an upscale pass on
   gl_compatibility and measures worse). Physics: **60 Hz + interpolation, locked** — the
   suspension tuning is rate-dependent; changing the tick means re-tuning every vehicle.
10. **No emoji anywhere in UI** — the web font has no emoji glyphs; plain text + color only.

Perf guardrail: < ~500 draw calls in the worst view (F3 overlay). Editor UX lives in
`addons/carlito_kit/` only; data + runtime-safe logic in `kit/` — nothing the baker touches
may use editor APIs (CI bakes headless). Authoring tools are deterministic (seeded) and
destructive-by-button, never per-frame. Third-party level sharing is out of scope: a
`.tscn` can embed scripts, so loading a stranger's level is arbitrary code execution.

Non-goals: multiplayer, in-game level editor, walk-around character, crop/farm simulation,
real wave physics, mobile app stores, world streaming, texture-layer terrain, LOD, road
junctions, lane markings, traffic.

## Gotchas & hard-won rules

**Physics & vehicles**

- 60 Hz stability lives in `RayWheel`'s clamps (damper ≤ one-tick reversal, suspension
  force cap, low-speed slip floors + one-tick lateral force cap) and the boat's probe
  clamps (derived spring k, one-tick damper, total force cap, `damped_force` for drag).
  **Don't remove or weaken any clamp; don't raise the tick.**
- `ChaseCamera` follows `get_global_transform_interpolated()` — never `global_transform`
  in `_process`; it stutters at the locked 60 Hz tick.
- Feel tuning is data-only (`*_spec.tres`); keep the hierarchy test green (brake > peak
  drive > handbrake; handbrake holds only below ~30% throttle). Drift comes from
  `handbrake_grip` (rear grip cut), not brake torque — the hierarchy test caps
  `handbrake_torque` too low to lock the rears.
- Vehicle subclasses use ONLY the two seams (`_make_telemetry()`, `_tick_extras()` — run
  last so drivetrain RPM + telemetry motion are current). Never fork `_physics_process`.
- BaseVehicle is zero-wheel-safe (boat spec: empty `wheel_positions`; keep its 6
  `gear_ratios` — `auto_shift` indexes up to byte 6).
- RayWheel is single-radius: the tractor's big-rear/small-front wheels are visual only.

**Input, lamps, bridge**

- Lamp and ISOBUS state ride `VehicleInput`, never a side channel. Bridge lamp/warning
  bits are mirrored **verbatim** (sloppyCAN is the sole authority; absent bit = off);
  **there is no local blink timer** — turn lamps blink because the source toggles the bit.
- Toggle owners (`_lights`, `_hitch_up`, `_pto`) live in InputRouter; sources report
  per-frame edges — so keyboard and touch share one owner.
- The `rudder` in-signal overrides `steer` when present; the boat's rudder IS the steer
  channel (no new VehicleInput field).
- The web export Head Include is pasted into `export_presets.cfg`; the reviewable source
  is `src/bridge/web/head_include.html` — **edit the source and re-paste into the preset;
  they must match.**
- The web export uses a **custom HTML shell** (`html/custom_html_shell` →
  `src/bridge/web/shell.html`) — a vendored copy of Godot's `godot.html` template with one
  Carlito patch: the PWA service-worker branch reloads once (guarded by
  `sessionStorage.carlitoCoiReloaded`) instead of rejecting with "Service worker already
  exists", so first-load cross-origin isolation on GitHub Pages self-heals without a manual
  reload. **On a Godot upgrade, re-extract `godot.html` from the web export template and
  re-apply this patch** (keep the `$GODOT_*` placeholders, esp. `$GODOT_HEAD_INCLUDE`).
- Bridge publish walks `Contract.signals_for_vehicle(...)` × `to_bridge_dict()` — never a
  hand-written field list. A `test_telemetry` case fails if `to_bridge_dict()` stops
  covering a ground "out" signal.
- `status` bitfield layout is provisional (named `ST_*` bits) until CAN frame packing is
  finalized with sloppyCAN.
- Respawn zeroes the telemetry accel history so a teleport isn't read as an impact.

**Dashboard & UI**

- The dashboard is contract-informed, not a UI generator: lamps/bars are **generated**
  from contract metadata (bars = range + warn, or `flavor == "isobus"`); the two radial
  gauges are **hand-built** and only read scale/redline from the contract. Do not build a
  from-JSON gauge framework. Gauges are built only when the vehicle declares their signal
  (the boat gets a speedo, no tacho). Gauge text sits in the arc's bottom 90° gap.

**Contract**

- Signals are unique by **(name, dir)** — `battery` exists in both directions. `warn` is
  the dashboard danger threshold (`SignalDef.warn_is_low()` infers the side). Contract
  edits bump `version`; **run `node tools/gen_js_contract.mjs` after any contract edit**
  (regenerates the synced sloppyCAN copy; the runtime version-mismatch warning — not CI —
  is the drift guard).

**Levels & water**

- `HeightmapTerrain`: one cell = one world unit so mesh/collision coincide; heightmap +
  splat PNGs must import **lossless / no mipmaps** so runtime `get_image()` works.
  Generated PNGs additionally need `detect_3d/compress_to=0` (else silent VRAM
  recompression breaks `get_image()`) and `process/fix_alpha_border=false` (it corrupts
  splat weights where rock == 0) — `TerrainGen.ensure_import_settings` writes these.
- Water: `get_height()` is flat; shader waves are visual-only and **must never feed
  physics**. The kill volume is an axis-aligned rect — don't rotate the node. Water and
  terrain are direct children of the level, never under `Authoring`.
- Day/night is a Level concern (N key), not a bridge signal.
- Under `--headless` the shell auto-loads the first registry level (CI smoke can't click).
- The gym is hand-built physics test equipment (no AuthoringRoot; the bake check skips
  it). Its pool is the boat/drown-respawn regression rig.

**Kit, bake & editor tools** (detail: `docs/level_kit.md`)

- Regenerate palettes/prefabs (`gen_kit_assets.gd`) only after recipe/kit edits; meshlib
  item ids are preserved across regens so painted GridMaps never break. Every GLB must
  match a recipe family or the generator fails; excludes need a reason.
- Per-kit scales live in `kit/import/<kit>.json` (lane-fit rule: ~12 m two-lane vs the
  1.8 m car) — the recipe is the source of truth. Roads palette cell `(12,3,12)`; racing
  `(12,12,12)` corner-anchor. All palette GridMaps need `cell_center_y = false`. Roads:
  `road-curve` is a 2×2 sweep; `road-bend` is the 1×1 corner.
- Thumbnails render **windowed only** (headless can't render); never CI. Embedding a new
  thumb re-stales dependent bakes.
- **`--script`-mode tools cannot load level scenes** — autoload identifiers (InputRouter
  via BaseVehicle) don't compile there; bake/check run as **game-mode tool scenes**
  (`godot --headless res://tools/bake_levels.tscn`), and `level.gd` fetches GameState via
  `get_node("/root/GameState")` for the same reason.
- A **freed node compares equal to null** — read results before `free()`.
- Vector2/3 component math is **float32**: `Vector2.angle()` carries ~1e-7 noise against
  float64 `PI`, so exact-boundary tests (`ceil(sweep / (PI/2))` etc.) need a ~1e-5
  tolerance — 1e-9 is not enough (bit the road-arc segment count).
- Godot 4.6 renamed the decomposition helper to `create_multiple_convex_collisions`
  (plural).
- SurfaceTool.append_from leaves scaled normals unnormalized — the baker's
  SurfaceAccumulator merges at array level instead.
- A runtime-loaded `@tool` script must never use an editor-only class
  (`EditorUndoRedoManager`, `EditorFileSystem`, …) as a **type annotation** — annotations
  resolve at parse time regardless of `Engine.is_editor_hint()` guards, so the script
  silently fails to load in exported builds (the node does nothing). Fetch editor
  singletons via `Engine.get_singleton(&"EditorInterface")` into **untyped** vars.
  Scripts under `addons/carlito_kit/` are editor-only and may type editor APIs freely.
- Duck-typed markers (`is_carlito_authoring` / `is_carlito_kit_piece` /
  `is_carlito_scatter` / `is_carlito_road`) everywhere, never class_name checks.
- Terrain render mesh is chunked for frustum culling (not LOD); collision stays ONE
  `HeightMapShape3D`. Normals are analytic (per-chunk `generate_normals()` seams
  borders); UVs global. Splatmap sampled raw (no `source_color` — sRGB bends weights).
- Scatter: stored transforms in the .tscn are the only artifact (no expansion at
  bake/runtime). Ground snap drops un-snappable points (no Y=0 fallback). The
  stale-scatter ground-hash guard is a config warning + bake gate + CI check; **Re-snap
  to ground** is the recovery. Weld-mode prefabs in scatter are a bake error.
- Roads: ribbon derives from curve + profile alone (never reads terrain); custom frame
  (NOT `sample_baked_with_rotation` — parallel transport accumulates roll). Profile
  default is a plain property set in editor `_ready`, never a preload export default
  (equal-to-default is omitted from the .tscn = input-hash hole). Conform flattens the
  **full half-width incl. skirt**, projects targets onto the nearest centerline
  **segment** (nearest-sample is wrong on grades), floor-quantizes to 8-bit; `edge_drop`
  must absorb ε + height/255 (conform warns). Tight turns fold-clamp the inside edge
  (never self-overlaps); closed loops share one bisector end frame. Full detail incl. the
  draw panel's "Smooth corners" behavior: `docs/level_kit.md`.
- Authoring order: terrain → roads + conform → splat → scatter (conform trips the scatter
  stale guard by design).
- Bake-adjacent CODE (RoadBuilder, ScatterBase) is invisible to the file-hash net — bump
  `BAKER_VERSION` + re-bake when its output changes.
- Rebuild `kit_fixture` with `godot --headless res://tools/build_kit_fixture.tscn`
  (hand-authoring GridMap cell data is fragile), then re-bake.

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
# bake all registered levels / CI stale-bake check (game-mode tool scenes, NOT --script)
& $GODOT --headless --path . res://tools/bake_levels.tscn
& $GODOT --headless --path . res://tools/check_bakes.tscn

# regen the sloppyCAN contract copy (after ANY contract edit)
node tools/gen_js_contract.mjs

# local web export (CI does the real one)
& $GODOT --headless --path . --export-release "Web" build/web/index.html

# "am I safe to push?" — all CI gates locally (editor-type gate, import, tests,
# stale-bake check, smoke, contract sync)
powershell -File tools/preflight.ps1
```

A pre-commit hook (`tools/git-hooks/`, installed via `core.hooksPath`) blocks editor-type
annotations, stale contract copies, and stale bakes at commit time. The recurring GDScript
warning classes (shadowing, integer division) are escalated to **errors** in project.godot
— intentional integer division needs `@warning_ignore("integer_division")`.

- A headless run ending with only `ERROR: N resources still in use at exit` is **clean** —
  harmless leak-at-exit noise, not a failure.
- `--headless --script` only runs `extends SceneTree` scripts; EditorScripts need
  File ▸ Run in the editor.
- **Parse-checking `addons/` code**: `& $GODOT --headless --path . --editor --quit-after 30`
  loads the enabled plugins and prints real `SCRIPT ERROR: Parse Error` lines — the only
  cheap gate for editor-only scripts (`--script` mode can't load them, `--import` doesn't
  compile them). Caveat: it does **not** catch integer division between two *constants*
  (`48 / 4` is folded silently), so a clean run is not proof the warnings-as-errors gate saw
  everything — still eyeball division on variables.
- **gdUnit4 float asserts vs. image formats**: `assert_float(img.get_pixel(..).r).is_equal(0.2)`
  FAILS ("Expecting 0.200000 but was 0.200000") — `FORMAT_RF`/`RGBAF` store float32, the
  literal is float64. Only binary-exact values (0.0, 0.25, 0.5, 0.75) compare with
  `is_equal`; anything else needs `is_equal_approx`.
- The editor **rewrites `export_presets.cfg`** when you export from the UI — CLI export
  reads it as-is. Keep thread_support + PWA (cross-origin-isolation headers) enabled:
  GitHub Pages sends no COOP/COEP, the PWA service worker injects them, and the threaded
  build needs them.
- Debugging web-only breakage: reproduce on the actual web build and read the browser
  devtools console — a runtime-only bug that no local `--headless` run reproduces often
  shows up there as `SCRIPT ERROR: Parse Error: Could not find type "…"`.

## CI / deploy

`.github/workflows/ci.yml`: every push runs import → gdUnit4 → stale-bake check → headless
smoke (default boot + a baked-level run with `CARLITO_LEVEL: kit_fixture`) → web export;
pushes to `main` deploy to **https://leaukojo.github.io/carlito2/** via GitHub Pages
(Actions source). Cache-busting: the export basename embeds the commit SHA, so all heavy
artifacts (.pck/.wasm/.js/PWA worker) get unique names per deploy; `index.html` is a small
copy. First visit after a deploy may still need one reload for the new service worker to
take over.

## The contract

`contract/carlito_contract.json` (v5) defines every bridge signal; the `Contract` autoload
loads + validates it at startup, and everything (bridge marshaling, dashboard generation)
is driven by it. Canonical copy lives here; `tools/gen_js_contract.mjs` regenerates the
synced sloppyCAN copy. See `docs/systems.md` for the full protocol.

## License

Code MIT, assets CC0. Third-party adoptions are read line-by-line before landing and
credited in README.md.
