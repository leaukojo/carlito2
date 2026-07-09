# Level Kit v2 — plan of record for the authoring rework

The P6 level kit shipped a professional **bake pipeline** (chunk merging, welded drivable
body, hash-stamped CI gate) behind an amateur **authoring experience**. This plan fixes the
authoring layer. It supersedes nothing in `version2_plan.md` — the standing rules (§2), the
bake contract, and the perf budget (§5.4) all still bind; the island (P9) and launch (P10)
now happen *after* this rework, using its tools.

## 1. Diagnosis — what's wrong with the P6 workflow

Measured against how a professional level pipeline works (engine terrain editors, foliage
brushes, spline road tools, thumbnail content browsers):

1. **Asset discovery is filename archaeology.** The GridMap palette is a name-only list
   ("keep kenney.nl open in a browser tab" is in our own docs); the 215 prefabs are browsed
   by filename in the FileSystem dock. Godot's `MeshLibrary` supports per-item preview
   textures natively — the generator just never creates them.
2. **Placement is one hand-dragged node per object.** The farm has four trees because four
   is the most the workflow can bear. No engine expects an author to copy-paste a tree 200
   times; they all converged on the same answer — seeded procedural scatter + a paint brush.
3. **"Terrain tool" is a PNG loader.** `HeightmapTerrain` requires an externally-authored
   greyscale image and renders one flat albedo color. No generation, no sculpting, no ground
   texture variation. A sandbox island cannot be built this way.
4. **v1 curation was thrown away.** `../carlito/auto_import_assets/asset_kit_settings.json`
   holds real, hand-tuned data: family classification regexes per kit (racing-props,
   racing-buildings, …), per-asset collision overrides (14 in the racing kit alone),
   alignment modes, offsets. The v2 recipes are coarse glob→mode maps rebuilt from zero.
   The nature kit (trees/rocks — essential for the island) was never brought over.
5. **Roads are grid-locked.** GridMap painting suits city blocks; an organic coast road with
   fixed-radius kit corners does not exist. Driving-sim road tooling is spline-based.

**What we keep unchanged:** the baker (`kit/bake/level_baker.gd`), the baked/authoring split,
the export-strip plugin, the CI stale-bake gate, ground rule §2-2 (heightmap/plane ground,
welded drivable bodies, trimesh never the default), and 60 Hz locked physics.

## 2. Design principles

- **The bake is the compiler; every new tool is a source-code editor.** Terrain, scatter,
  and road nodes are authoring content. They must be deterministic (seeded), so the bake and
  the CI hash stay reproducible, and they must expand *without the editor* (game-mode tool
  scenes bake in CI — no `EditorInterface` in anything the baker touches).
- **Editor UX lives in `addons/carlito_kit/`** (the existing EditorPlugin grows docks and
  brush gizmos); **data + runtime-safe logic lives in `kit/`** (scatter core, road mesh
  generation, terrain generation are plain `@tool` scripts with pure, unit-tested cores —
  same discipline as Drivetrain/telemetry).
- **Low-poly first.** Ground variation is **color splat** (grass/dirt/sand/rock albedo
  colors blended by a painted splatmap), not 4K texture layers — matches the Kenney
  colormap aesthetic, keeps the shader trivial on gl_compatibility/web.
- **Keep the author's existing sorting.** The v1 family taxonomy is imported as data and
  becomes the visible organization of the palette dock and the meshlib groups.
- **One thumbnail pipeline, every consumer.** A single offline render pass produces
  `kit/thumbs/<kit>/<name>.png` for every prefab and palette tile; the meshlibs embed them
  (built-in GridMap palette gets pictures), the palette dock loads them, docs can link them.
- **Scoped, explicit non-goals** (§6) so no phase balloons.
- **Clean slate — the existing kit levels are throwaway.** The user's call: farm, harbor,
  and kit_demo are P6/P7-era demos, not content worth preserving, so **no legacy-compat
  constraint survives for their sake**. Farm + harbor are deleted up front (LK0); kit_demo
  stays *only* as the baker's CI regression fixture (the baked-smoke target) until LK8
  builds the real levels and deletes it. That frees LK1 to fix the inherited warts at the
  root instead of preserving them: per-kit scales are **re-derived from measurement** with
  an explicit cross-kit rule (consistent lane-width-to-car ratio where kits interoperate)
  instead of the eyeballed 8×/10×/2×; the racing y-offsets inherited from v1 are
  re-measured from AABBs, not trusted; the suburban `driveway-long` palette is deleted
  (the RoadPath gravel profile is its replacement; driveway/path pieces remain as weld
  prefabs); and meshlib item ids restart clean — the id-stability *mechanism* stays, since
  it protects every level built from LK1 onward. The **gym and flat are not kit levels**
  (hand-built physics/boat/drown regression rigs, no AuthoringRoot) and are untouched.
  The launch roster (plan §5.3: gym, island, farm, harbor) is unchanged — farm and harbor
  are rebuilt from scratch in LK8, the island in P9.

## 3. Phase overview

| Phase | Delivers | Depends on |
|---|---|---|
| LK0 | Clean slate: farm + harbor deleted, registry/CI trimmed (kit_demo kept as CI bake fixture) | — |
| LK1 | Clean kit re-derivation (scales, offsets, palettes) + curation import + nature kit + thumbnails | LK0 |
| LK2 | Palette dock: browse by family, search, click-to-place with ground snap | LK1 |
| LK3 | Terrain generation: noise presets + island falloff + color-splat ground material | — |
| LK4 | Terrain editing: sculpt brushes (raise/lower/smooth/flatten) + splat paint brush | LK3 |
| LK5 | Scatter regions: seeded procedural fill node, bake integration | LK1 |
| LK6 | Scatter brush: paint/erase front-end on the LK5 core | LK5, LK4's brush chassis |
| LK7 | Spline road: extruded ribbon, terrain conform, welds into drivable body | LK3 |
| LK8 | Build farm + harbor from scratch with the new tools; delete kit_demo; docs rewrite; perf check | all |

LK0→LK1 and LK3 are independent starts. If budget forces merges, LK0+LK1, LK3+LK4, and
LK5+LK6 are the safe pairs to combine; never merge LK7 into anything.

## 4. Phase details

### LK0 — Clean slate

- Delete `src/levels/farm/` and `src/levels/harbor/` entirely (scenes, infos, bakes,
  manifests, heightmap PNGs they alone use) and their `level_registry.gd` entries.
- **kit_demo survives on purpose**: it is CI's baked-smoke target (`CARLITO_LEVEL:
  kit_demo`) and the only coverage of the load→baked-swap→spawn path while LK5/LK7 are
  rewiring the baker. It dies in LK8 when the new farm takes over that role.
- Sweep for stragglers (docs links, test fixtures, CLAUDE.md's landed-levels claims);
  full test suite + both CI smokes stay green.

### LK1 — Clean kit re-derivation, curation, nature kit, thumbnails

- **Recipe schema grows** (per kit `kit/import/<kit>.json`): a `families` block —
  `{name, match (regex list), label}` — imported from v1's `classify` data for the six
  existing kits, plus **per-asset overrides** (collision mode, offsets) ported from v1's
  `asset_kit_settings.json` where the kits overlap. This is a *data* port (reading v1's
  JSON settings the user authored), not a code port — the zero-v1-code rule is untouched.
  Collision modes map v1→v2 as: `convex`→`hull`, `trimesh`→`weld` (drive-on surfaces),
  `box`/`multiconvex`/`none` unchanged; anything ambiguous is flagged, not guessed.
- **Kit geometry re-derived clean** (the §2 clean-slate warrant): per-kit scales computed
  from measurement against an explicit rule (the 1.8 m car's lane fit, consistent across
  every road-bearing kit) and written into the recipes with the derivation noted; the
  racing kit's v1-inherited y-offset overrides re-measured from the pieces' AABBs; the
  suburban `driveway-long` palette deleted (driveway/path pieces stay weld prefabs).
  Meshlib ids restart clean; the id-preservation mechanism and its test remain for
  everything painted after this point. kit_demo's small road loop is repainted to the new
  lattice as the scale-verification step and re-baked.
- **Nature kit is in the repo, props-only (already copied).** Across the six original kits
  the vegetation inventory was four tree models, one grass tuft, and zero rocks — seeded
  scatter amplifies asset variety, and an island dressed from four items reads as
  copy-paste. `kit/raw/nature/` now holds the kit's **200 standalone props** (trees incl.
  6 palm variants, rocks/stones, stumps/logs, plants/flowers/grass/mushrooms, crops incl.
  dirt-row slabs for the farm fields, fences, cacti, statues — self-contained GLBs,
  textures embedded, `License.txt` alongside, credited in README). The kit's tile-based
  half — `cliff_*`, `ground_*`, `path_*`, bridges, water lilies, camp clutter — was
  **excluded at copy time and never entered the repo**: that half is why it felt unusable
  at scale in v1 (building terrain from 1 m tiles) and where its water tiles live; our
  terrain is generated/sculpted heightmap and water is `WaterSurface`. LK1 only writes the
  recipe: measure with `tools/measure_kit.gd`, scale to the 1.8 m car, trees/rocks/stumps
  as `hull`/`box`, flat foliage/crops as `none`.
- **Thumbnail pipeline**: a game-mode tool scene (`tools/gen_thumbs.tscn`, run **windowed**
  — headless can't render) frames each prefab/palette mesh in a SubViewport against a
  neutral backdrop and writes `kit/thumbs/<kit>/<name>.png` (128², import as lossless).
  `gen_kit_assets.gd` then embeds them as MeshLibrary item previews, so the **built-in
  GridMap palette shows pictures immediately**. Thumbs regenerate only with the gen tool
  (local, like palette regen — never CI).
- Gallery scenes are **not** built — the LK2 dock supersedes them.
- Meshlib item ids remain stable across regen (existing guarantee, keep it tested).
- Export: `kit/thumbs/**` excluded from the web export like the rest of the kit sources.

### LK2 — Palette dock

- An `addons/carlito_kit` **bottom-panel dock** (bottom panel fits a wide thumbnail grid
  better than the narrow side dock): kit tabs → family sections (the LK1 taxonomy, i.e. the
  user's v1 sorting), text search, thumbnail grid from `kit/thumbs/`.
- **Click-to-place**: select a prefab, click in the 3D viewport → instance lands under the
  level's `AuthoringRoot` (auto-found; error toast if absent), positioned by a physics
  raycast to the ground, with optional **random yaw** and **snap-to-grid** toggles in the
  dock toolbar. Escape/right-click cancels. Placement is undoable (`EditorUndoRedoManager`).
- Palette *tiles* shown in the dock too, but selecting one just selects the right GridMap
  and item (painting stays the built-in GridMap workflow — never reimplement it).
- Non-goal: no transform gizmo replacement — after placement, editing is normal editor work.

### LK3 — Terrain generation + ground material

- `HeightmapTerrain` grows a **generator**: `FastNoiseLite`-driven, with `@export` knobs
  (preset enum: *island / rolling hills / plains / dunes*, seed, amplitude, feature scale,
  octaves) and a **radial falloff curve** for island shapes (edges → sea level). A
  **Generate** tool button writes the heightmap image; **Rebuild** stays as-is. Generated
  heightmaps save as the level's PNG (lossless import rules unchanged), so the runtime
  path, `HeightMapShape3D` collision, and the §2-2 rule are untouched.
- **Color-splat ground material** (`kit/terrain/terrain_splat.gdshader` + a small material
  resource): 4 albedo colors (grass/dirt/sand/rock) blended by an RGBA **splatmap image**;
  a one-click **auto-splat** seeds it from slope + height (sand near water level, rock on
  steep slopes). No texture layers — low-poly color fields, gl_compatibility-safe.
- Pure fns (falloff, noise→height remap, auto-splat classification) unit-tested in
  `tests/test_terrain_gen.gd`.
- Generation is **destructive-by-button** (writes the image once, deterministic from seed),
  never per-frame — bake hashing and git diffs stay sane.

### LK4 — Terrain brushes

- A viewport **brush chassis** in `addons/carlito_kit` (shared with LK6): while a
  `HeightmapTerrain` is selected, `EditorPlugin._forward_3d_gui_input` drives a circular
  brush cursor (radius/strength/falloff in an inspector-side panel); strokes edit the
  in-memory `Image` and rebuild mesh+shape incrementally (region-limited rebuild — full
  rebuild per stroke would crawl on big maps).
- **Sculpt modes**: raise / lower / smooth / flatten-to-height. **Paint mode**: splat
  channel painting on the LK3 splatmap.
- Strokes are undoable (snapshot the touched image region); **saving the scene saves the
  PNGs** (explicit save hook — never reimport per stroke).
- Editor-only by construction: nothing the baker or runtime reads changes shape.

### LK5 — Scatter regions

- **`ScatterRegion`** (`kit/helpers/scatter_region.gd`, `@tool Node3D`, placed under
  `Authoring`): a box or polygon footprint; an item table `[{prefab, weight, collision:
  on/off}]`; knobs for density, min spacing, seed, yaw jitter, scale jitter range, and
  max slope.
- **Deterministic seeded placement** is a pure static (`generate_placements(params) →`
  per-item XZ positions + yaw/scale, blue-noise-ish rejection sampling) unit-tested in
  `tests/test_scatter.gd` — same seed, same forest, forever.
- **Regenerate is an editor action that stores its result** (the road-conform philosophy):
  the button runs the pure placement, ground-snaps each instance by raycast (terrain,
  roads, anything — the full scene is present at edit time), and **stores the final
  transforms in the scene** (one compact packed array per item type; 500 trees ≈ a few
  KB of .tscn). The baker and dev-play only ever consume stored transforms — **no physics,
  no expansion in the baker**, so editor and bake can never diverge, and the CI hash story
  is just "transforms live in the .tscn".
- **Editor/dev-play**: renders as one `MultiMeshInstance3D` per item type (cheap preview),
  plus dev collision only when the level is played unbaked.
- **Bake**: the baker detects scatter nodes (duck-typed marker, like `is_carlito_kit_piece`)
  and feeds each stored instance through the existing prefab path — meshes merge into
  chunks, `hull`/`box` shapes harvest into chunk bodies. Bake stats report instance +
  shape counts so a 5 000-tree mistake is visible before it ships. Collision-off items
  (grass tufts, small rocks) cost zero physics.
- Non-goal: no runtime re-scatter, no painting-on-region masks (that's LK6's job).

### LK6 — Scatter brush

- Second front-end on the LK5 core, using the LK4 brush chassis: **`ScatterCanvas`**
  (`@tool` node under `Authoring`) stores hand-painted instances (item, transform) as data;
  brush **paints** (density-per-stroke, same jitter knobs) and **erases** (radius). Renders
  and bakes exactly like a region (MultiMesh preview → baked merge/harvest).
- Undoable strokes; instances persist in the scene file (they're authored content, hashed
  by CI like everything else).

### LK7 — Spline road

The riskiest phase; keep it on rails:

- **`RoadPath`** (`kit/helpers/road_path.gd`, `@tool`, owns a `Path3D` child, placed under
  `Authoring`): extrudes a low-poly **ribbon mesh** along the curve from a small profile
  resource (lane width, shoulder width, edge drop, material — default asphalt + painted
  edge line matching the Kenney look). Segment length adapts to curvature; UVs follow arc
  length. Optional banking from curve tilt.
- **Terrain conform is destructive-by-button** (like LK3 generation): a **Conform terrain**
  button flattens the heightmap under the ribbon with a blend falloff to the sides —
  one deterministic write, undoable, saved with the PNG. The ribbon itself is generated
  from the curve alone, so **bake output depends only on the scene file**, never on the
  terrain image — the CI hash story stays exactly as it is.
- **Bake**: ribbon triangles join the level-wide **welded drivable body** (same path as
  `weld` prefabs — 1 mm snap, zero seams); dev-play gets the usual dev trimesh so unbaked
  levels drive.
- Pure geometry fns (profile extrusion, curvature-adaptive sampling, flatten mask)
  unit-tested in `tests/test_road.gd`.
- **Explicit non-goals**: no automatic junctions (cross two roads over a flat GridMap pad
  or a painted plaza), no lane markings system, no traffic data. Say it in the docs.

### LK8 — Build the launch levels fresh + docs

- **Build the farm from scratch** with the real tools: generated rolling-hills terrain
  with splat fields, a `RoadPath` gravel lane, crop rows and tree lines/orchard via
  scatter regions, hand-dressed clutter via the brush, buildings/fences placed from the
  dock. **Build the harbor from scratch**: quay + seabed + `WaterSurface` as before, but
  shoreline dressed with rock/vegetation scatter and watercraft prefabs from the dock.
  Both registered and baked; CI green.
- **kit_demo is deleted** and the CI baked smoke retargets `CARLITO_LEVEL: farm`; the new
  farm also replaces kit_demo as the docs' worked example.
- This is the acceptance gate: if farm-quality dressing still feels like labor, the tools
  failed — fix them now, before the island.
- **`docs/making_a_level.md` rewritten** around the new workflow (generate terrain → roads
  → paint splat → scatter → dress → bake); CLAUDE.md kit section updated.
- **Perf check** stays the §5.4 guardrail: F3 in the worst view, < ~500 draw calls, on the
  new farm (scatter merges into chunks, so draw calls track chunk × material count — the
  bake stats predict it).

## 5. Risks

| Risk | Mitigation |
|---|---|
| Brush editing feels laggy on big heightmaps | Region-limited mesh/shape rebuild (LK4); if still slow, rebuild shape on stroke-end only |
| Scatter collision explodes physics (1000s of static hulls) | Per-item collision toggle, bake-stat visibility, hull→cylinder simplification if Jolt broadphase ever measures hot |
| Road ribbon vs. terrain z-fighting at the blend edges | Ribbon sits at flattened height + small epsilon; conform button owns the terrain under it |
| Editor-tool code leaking into CI/headless paths | Hard split: expansion/generation logic is `@tool`-safe and editor-free; only `addons/carlito_kit` touches editor APIs (existing P6 rule, now load-bearing) |
| Thumbnail pass needs a window | Local-only tool like palette regen (CI never renders thumbs; it only hashes them) |
| Scope creep in LK7 | Non-goals written into the phase and the docs; junctions explicitly out |
| No shipped level exercises the bake between LK0 and LK8 | kit_demo is retained as the CI bake fixture through exactly that window, repainted to the new lattice in LK1, deleted only when LK8's farm replaces it |

## 6. Global non-goals

No runtime/procedural world streaming, no in-game level editor, no texture-layer terrain,
no automatic road junctions, no LOD system (bake + budget already cover web perf), no
replacement of the GridMap workflow for city grids — it remains the right tool there.
