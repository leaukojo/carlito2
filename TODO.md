# TODO — remaining work

Levels are **signal playgrounds** (see CLAUDE.md): no missions — every level must give
specific contract signals a place to visibly perform, verified with sloppyCAN open.


## 1. Visual polish (deferred plans)

Baseline (shared tuned env + fog, warm sun, far-sea horizon plane, night atmosphere) and
the procedural sky (gradient + sun disc + scrolling noise clouds,
`src/levels/base/sky.gdshader`) are done. Remaining: the broader pro-eye sweep — foam
line, particles, shadow tuning, color grade (`docs/plans/visual_polish_pass.md`).

## 2. Perf pass

Profile the **deployed** web build first — F3 overlay (FPS / frame ms / draw calls /
primitives / VRAM) in the worst view of each level; budget: 60 fps on a mid-range laptop,
< ~500 draw calls. Measure, change ONE thing, re-measure; no speculative optimization.
Hard constraints: physics stays 60 Hz + interpolation; never set `scaling_3d/scale.web`
below 1; the `.web` overrides (msaa_3d.web=0, soft shadows off) already exist — check they
still apply before adding new ones. If a level is heavy on draw calls, suspect its bake
(chunk count / material dedup — the bake stats predict draw calls) before touching
renderer settings.

- **Level-wide scatter MultiMeshes:** the baker currently emits one MultiMeshInstance3D
  per chunk × item (level 3: 159 MMs for 1024 instances, ~6 per MM). Merging to one MM
  per item level-wide would drop that to ~one per item mesh — the biggest win in the
  flying view, where chunk frustum culling buys nothing anyway. Cost: level-sized AABBs
  (always drawn, incl. shadow pass). Moderate `level_baker.gd` change; bump
  `BAKER_VERSION`, re-bake all. Stretch (only if budget already met): custom export template with
unused modules stripped to shrink the wasm.

## 3. Procedural engine audio (deliberately last — nothing may depend on it)

An RPM-driven procedural engine loop per vehicle: the horn already proves the pattern
(synthesized AudioStreamWAV, zero assets) and the drivetrain RPM is real, so the seam is
one audio player on BaseVehicle with pitch from `rpm` and gain from throttle/load — no
architecture change. Boat wind/engine and tractor PTO whine follow the same pattern.
Lands after the perf pass. Verify: engine pitch follows the tacho through the gears;
silent in menus.

## Drone follow-ups (from 2026-07-23 code review)

- **Map containment for flight:** boundary walls top out at y=+10; the drone flies over
  them into the collision-less far sea and only respawns below y=-20. Decide: taller
  walls, a ceiling, or an out-of-bounds volume.
- **`ST_GROUND` honesty:** the drone (no wheels) publishes "all wheels on ground" = true
  while hovering — a false CAN-side reading (the boat shares the quirk). Fold into the
  `status` bitfield finalization with sloppyCAN (see Open questions).
- **Boat/drone math duplication:** `pitch_deg`/`roll_deg` and the one-tick
  damper/inertia helpers are duplicated verbatim between boat and drone; consider
  extracting shared statics (touches boat.gd + tests).

## Plane follow-ups (from 2026-07-23 code review)

- **Plane/drone math duplication:** `plane.gd` duplicates five pure-math statics verbatim
  from `drone.gd` (`clamped_damper`, `yaw_torque`, `inertia_of`, `pitch_deg`, `roll_deg`)
  plus their unit tests — same pattern as the boat/drone duplication above; fold into the
  same shared-statics extraction decision.

## Rail follow-ups

- **`rail_track.gd` stays in `src/levels/base/`** (decided Phase 4): `level_baker.gd`
  preloading `src/levels/base/rail_track.gd` inverts the usual kit→src layering and puts a
  `src/` path in `BAKE_CODE_INPUTS`, but the node's runtime consumers (`TrainVehicle`,
  `Level`'s spawn/roster gate) all live in `src/`, and it belongs beside its sibling runtime
  level nodes (`heightmap_terrain.gd`, `vehicle_spawn.gd`). Moving it to `kit/` would restore
  the layering only to split it from everything that uses it. No failure mode either way;
  left as-is.
- **Multi-loop random spawn is deferred:** the plan sketched `_spawn_vehicle` picking a
  closed loop at random when a level has more than one. No level does (level 5 has one), and
  the train self-places on the first/only closed loop via `RailTrack.find_closed_rail`.
  Building random choice means the level passing the chosen loop into the train before its
  `_ready` — a level↔train coupling with no content behind it. Revisit if a level ever ships
  two closed loops; until then one-loop self-placement is the whole story.

## 4. Launch checklist

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

