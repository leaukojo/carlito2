# TODO — remaining work

Levels are **signal playgrounds** (see CLAUDE.md): no missions — every level must give
specific contract signals a place to visibly perform, verified with sloppyCAN open.

## 1. Rebuild farm + harbor (level design done by hand, not by Claude)

Build both from scratch with the authoring tools (`docs/level_kit.md`):

- **Farm:** generated rolling-hills terrain with splat fields, a `RoadPath` gravel lane,
  crop rows and tree lines/orchard as ScatterRegions, clutter via the scatter brush,
  buildings/fences placed from the dock. Signal spec: a field where lowering the hitch
  and running the PTO along crop rows feels like plowing (the implement already animates
  — the field layout is what sells it).
- **Harbor:** quay + seabed + `WaterSurface`, boat launches and hulls from the watercraft
  prefabs, shoreline rock/vegetation scatter. Signal spec: a course — wake ramp off the
  boat launch, tight buoy turns — that makes `pitch`/`roll` perform.
- Register both, bake, CI green, F3 under the ~500 draw-call budget in the worst view.
- Add a second CI baked-smoke run with `CARLITO_LEVEL: farm` (kit_fixture stays the
  permanent minimal canary, so shipped levels can change freely without retargeting CI).
- Acceptance on both axes: if dressing feels like manual labor, that is a tool defect —
  fix the tool, don't push through; if driving doesn't make the signals perform, the
  content failed.

## 2. Rewrite `docs/making_a_level.md`

Around the current workflow: generate terrain → roads + conform → splat paint → scatter →
dress from the dock → bake. Farm as the worked example. Must be followable by a
non-designer end to end. The current doc describes deleted tools/levels and a defunct
lattice — treat it as unusable, not as a base.

## 3. Island level

The flagship level: city grid, racing circuit, suburbs, mainland skyline backdrop.
Observe the previous game's deployed build for layout spirit (never its code/geometry).

- Signal-playground routing: a long grade for `engine_load`, hairpins for slip, a crest
  for the impact bit, a dark stretch for lights.
- Racing-kit note: the corner-anchor lattice and bridge y-offsets were measured but
  flagged "re-verify at island scale" — check corner tiles line up before painting the
  whole circuit.
- All vehicle types spawnable except boat, unless a coastline water region fits naturally.
- Register, bake, `check_bakes` + `CARLITO_LEVEL=<id>` headless smoke green.

## 3b. Visual polish (deferred plans)

Baseline (shared tuned env + fog, warm sun, far-sea horizon plane, night atmosphere) is
done. Remaining: clouds/better sky (`docs/plans/sky_clouds.md`) and the broader pro-eye
sweep — foam line, particles, shadow tuning, color grade (`docs/plans/visual_polish_pass.md`).

## 4. Perf pass

Profile the **deployed** web build first — F3 overlay (FPS / frame ms / draw calls /
primitives / VRAM) in the worst view of each level; budget: 60 fps on a mid-range laptop,
< ~500 draw calls. Measure, change ONE thing, re-measure; no speculative optimization.
Hard constraints: physics stays 60 Hz + interpolation; never set `scaling_3d/scale.web`
below 1; the `.web` overrides (msaa_3d.web=0, soft shadows off) already exist — check they
still apply before adding new ones. If a level is heavy on draw calls, suspect its bake
(chunk count / material dedup — the bake stats predict draw calls) before touching
renderer settings. Stretch (only if budget already met): custom export template with
unused modules stripped to shrink the wasm.

## 5. Procedural engine audio (deliberately last — nothing may depend on it)

An RPM-driven procedural engine loop per vehicle: the horn already proves the pattern
(synthesized AudioStreamWAV, zero assets) and the drivetrain RPM is real, so the seam is
one audio player on BaseVehicle with pitch from `rpm` and gain from throttle/load — no
architecture change. Boat wind/engine and tractor PTO whine follow the same pattern.
Lands after the perf pass. Verify: engine pitch follows the tacho through the gears;
silent in menus.

## 6. Launch checklist

- [ ] **Revert the dev-level test scaffolding** (temporary debug access to kit_fixture /
      terrain_demo from the main menu):
      1. `src/ui/level_select.gd` — restore the `dev` skip in the level loop
         (`if entry.get("dev", false): continue`).
      2. `src/shell/level_registry.gd` — remove the `terrain_demo` entry (tagged
         "Temporary").
      3. `tools/build_kit_fixture.gd` — remove the boat-test rig: the
         `_make_water()` / `_make_boat_spawn()` calls in `_ready()`, both functions, and
         `WATER_POS`.
      4. `src/levels/dev/kit_fixture_info.tres` — `allowed_vehicles` back to
         `PackedStringArray("car")`.
      5. Rebuild + re-bake: `build_kit_fixture.tscn`, then `bake_levels.tscn`, then
         `check_bakes.tscn` (expect fresh). After deregistering terrain_demo its
         `.baked.scn`/`.bake.json` are only used by F6 — keep or delete.
      6. `tests/test_shell_menus.gd` — restore the assertion that dev entries are hidden.
- [ ] All levels playable at 60 fps in the deployed build; hard-reload not required after
      redeploys (cache-busting proves itself).
- [ ] Update README status; credit any new assets.
- [ ] Retire the previous game's deployment: redirect its URL here.

## Open questions (decide when they block something)

- ISOBUS framing on the sloppyCAN side: 29-bit extended IDs (proper J1939) vs the
  existing 11-bit scheme — sloppyCAN/RAMN decision; this side is agnostic.
- Whether the RAMN firmware itself gains tractor/boat frames or they stay emulator-only.
- `status` bitfield final bit layout (fixed together with sloppyCAN frame packing).
- Per-axle split of the `slip` signal (telemetry already sims per-axle slip; the contract
  carries one value).
- Feeding real wave height into the boat's buoyancy probes (post-launch option; the
  height API is the seam).

## Scene-file size (investigated 2026-07-12 — no action needed yet)

The largest authored scene is `kit_fixture.tscn` (~25 KB, 351 lines, longest line
~3.9 K chars — the 80-tree scatter `stored_transforms` array); `gym.tscn` ~14 KB;
`terrain_demo.tscn` ~5 KB. Nothing is near a size that hurts the editor, git, or
tooling, and no tool in the repo emits a "scene too large" warning at these sizes — if
that warning reappears, record which tool printed it. Converting authoring scenes to
binary `.scn` was considered and **rejected for now**: binary scenes are unreadable to
git diffs and to AI sessions (both load-bearing here — scatter/GridMap data is reviewed
in diffs), and the CI stale-bake check hashes level files as CRLF-normalized *text*, so a
binary conversion would need pipeline changes for zero present benefit. Revisit only if
the island's stored scatter transforms push its `.tscn` into the multi-MB range; the
cheaper first lever is MultiMesh-heavy ScatterRegions (density) over hand-painted
canvases, since a region's data is just as compact but regenerable.
