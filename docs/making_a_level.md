# Making a level

> **PENDING REWRITE** (see `TODO.md`). The previous walkthrough described tools and
> levels that no longer exist and an obsolete kit lattice, so it has been removed
> rather than left to mislead (git history has it). Until the rewrite, use
> `docs/level_kit.md` as the tool reference and `src/levels/dev/kit_fixture.tscn` /
> `src/levels/dev/terrain_demo.tscn` as small worked examples.

The shape of the workflow the rewrite will document:

1. Duplicate `src/levels/base/level.tscn`; create a `LevelInfo` `.tres` and wire it on
   the root.
2. Ground: a `HeightmapTerrain` (Generate / sculpt with the terrain brushes, then
   Auto-splat + splat paint) — or a plain box body for flat levels. Water, if any, is a
   `WaterSurface` sibling.
3. Add one `AuthoringRoot` node ("Authoring"); everything the bake processes goes under
   it.
4. Roads: `RoadPath` splines (Draw mode, then **Conform terrain**) for organic routes;
   GridMap palettes (via the palette dock) for city grids.
5. Splat-paint, then scatter vegetation (`ScatterRegion` Regenerate for mass fill, the
   scatter brush on a `ScatterCanvas` for hand-dressing) — scatter comes **after**
   terrain/road edits, or use **Re-snap to ground** to recover.
6. Dress with prefabs from the palette dock (click-to-place).
7. `VehicleSpawn` markers for every allowed vehicle (`is_water` for boats).
8. Register in `src/shell/level_registry.gd`, playtest unbaked (dev collision), then
   **Bake** on the AuthoringRoot and commit `.tscn` + `.baked.scn` + `.bake.json`.
   CI fails on stale bakes.
