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
- Add a second CI baked-smoke run with `CARLITO_LEVEL: farm` (`level_1` stays the
  primary baked-smoke target).
- Acceptance on both axes: if dressing feels like manual labor, that is a tool defect —
  fix the tool, don't push through; if driving doesn't make the signals perform, the
  content failed.

## 2. `docs/making_a_level.md` — done (revisit with Farm)

Rewritten around the current workflow (new-scene → terrain → Authoring → roads + conform →
splat → scatter → dress → spawns → register/bake). When the Farm level lands, swap its
worked example in as the followable-by-a-non-designer end-to-end reference.

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

Baseline (shared tuned env + fog, warm sun, far-sea horizon plane, night atmosphere) and
the procedural sky (gradient + sun disc + scrolling noise clouds,
`src/levels/base/sky.gdshader`) are done. Remaining: the broader pro-eye sweep — foam
line, particles, shadow tuning, color grade (`docs/plans/visual_polish_pass.md`).

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

- [ ] Levels 2-5 authored (they ship as blank generated islands today) — or trimmed from
      the registry if the shipped set is smaller.
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

The largest authored scene is `level_1.tscn` (~78 KB — the scatter `stored_transforms`
arrays dominate). Nothing is near a size that hurts the editor, git, or
tooling, and no tool in the repo emits a "scene too large" warning at these sizes — if
that warning reappears, record which tool printed it. Converting authoring scenes to
binary `.scn` was considered and **rejected for now**: binary scenes are unreadable to
git diffs and to AI sessions (both load-bearing here — scatter/GridMap data is reviewed
in diffs), and the CI stale-bake check hashes level files as CRLF-normalized *text*, so a
binary conversion would need pipeline changes for zero present benefit. Revisit only if
the island's stored scatter transforms push its `.tscn` into the multi-MB range; the
cheaper first lever is MultiMesh-heavy ScatterRegions (density) over hand-painted
canvases, since a region's data is just as compact but regenerable.
