# Level kit — authoring tools & bake pipeline

Everything used to build a level: asset kits, editor tools, terrain, scatter, roads, and
the bake that turns authoring content into what ships. Runtime systems are in
`docs/systems.md`; the walkthrough for level authors is `docs/making_a_level.md`
(currently pending a rewrite — see `TODO.md`).

**The bake is the compiler; every authoring tool is a source-code editor.** Authoring
nodes must be deterministic (seeded) so bakes and CI hashes stay reproducible, and they
must expand without the editor (game-mode tool scenes bake in CI — no `EditorInterface`
in anything the baker touches). Editor UX lives in `addons/carlito_kit/`; data +
runtime-safe logic lives in `kit/` (plain `@tool` scripts with pure, unit-tested cores).

## Kit assets & recipes

- **Layout:** `kit/raw/<kit>/` CC0 Kenney GLBs (7 kits: racing / roads / suburban /
  commercial / industrial / watercraft / nature; keep `Textures/` beside the glbs —
  relative refs; nature glbs carry materials internally, no `Textures/`),
  `kit/import/<kit>.json` recipes, `kit/palettes/*.meshlib` + `kit/prefabs/<kit>/*.tscn`
  **generated** by `tools/gen_kit_assets.gd` (`--script` mode; re-run only after
  recipe/kit edits; meshlib item ids are preserved across regens so painted GridMaps
  never break).
- **Recipes are families-driven (single source of truth):** each recipe has one ordered
  `families` list — `{name, label, match:[regex], pipeline:"palette"|"prefab"|"exclude",
  collision_mode?, reason?(exclude), assets:{<name>:{overrides}}}` — that *alone*
  classifies every GLB (first match wins; ordering resolves overlaps so patterns stay
  simple prefixes). It drives dock grouping + pipeline + collision in one pass; the
  pure/tested classify+id logic lives in `kit/helpers/kit_recipe.gd`
  (`tests/test_kit_gen.gd`). **Coverage gate:** every GLB must match one family or the
  generator *fails* listing the unaccounted; excludes need a `reason`; per-family member
  counts print (catch-alls tagged) so an oversized "box everything else" bucket is
  visible.
- **Scales are derived from measurement (lane-fit rule):** road-bearing kits target a
  ~12 m two-lane road (~6 m/lane vs the 1.8 m car). Per-kit scale and the derivation
  note live in each recipe (`kit/import/<kit>.json`) — the recipe is the source of
  truth. Palette lattices: **roads** cell `(12, 3, 12)`; **racing** cubic cell
  `(12, 12, 12)` on a corner-anchor lattice (bridge y-offsets measured from AABBs —
  corners lift 0.393 native to the span deck; re-verify when building a large racing
  layout). Suburban is prefab-only (no palette). All palette GridMaps need
  `cell_center_y = false`. NB roads: `road-curve` is a 2×2 sweeping curve; `road-bend`
  is the tight 1×1 corner — use the latter for one-cell corners.
- **Thumbnails:** `tools/gen_thumbs.tscn` (game-mode tool, run **windowed** — headless
  can't render) frames every non-excluded prefab/palette GLB in a SubViewport on a
  neutral backdrop and writes `kit/thumbs/<kit>/<name>.png` (128², imported lossless).
  `gen_kit_assets.gd` then embeds each palette tile's thumb as a MeshLibrary item
  **preview** (the built-in GridMap palette shows pictures; the dock reads the PNGs).
  Full local flow: `gen_thumbs.tscn` → `--import` → `gen_kit_assets.gd`. Never CI.
  `kit/thumbs/*` is export-excluded (only the ~4 KB reference table lands in the
  meshlib, not image data); embedding a new thumb re-stales dependent bakes (re-bake
  after regen).

## Authoring model

Hybrid: **GridMap palettes** for road/tile kits only; everything else is a **`KitPiece`
prefab** (`kit/helpers/kit_piece.gd`) whose `collision_mode`
(`none|box|hull|multiconvex|weld`) rides the prefab root; its `DevCollision` body makes
unbaked levels playable. All authoring lives under one **`AuthoringRoot`** node
(`kit/helpers/authoring_root.gd`, `chunk_size` knob + editor **Bake** button). Detection
everywhere is duck-typed marker methods (`is_carlito_authoring` / `is_carlito_kit_piece`
/ `is_carlito_scatter` / `is_carlito_road`), never class_name.

## Bake (`kit/bake/level_baker.gd`)

- Merges render meshes per XZ chunk (one MeshInstance3D per chunk, one surface per
  deduped material, verts chunk-local), harvests prefab shapes into **one StaticBody3D
  per chunk**, and welds ALL drivable geometry (every palette cell + `weld` prefabs +
  road ribbons) into **one level-wide ConcavePolygonShape3D body** — vertices snapped to
  1 mm so tile borders are internal edges, never body seams.
- Outputs `<level>.baked.scn` + `<level>.bake.json` (input-hash manifest,
  timestamp-free). Pure fns (weld, chunking, hashing, spawn validation, accumulator) are
  unit-tested in `tests/test_bake.gd`. Spawn validation is a bake gate; so is the
  stale-scatter guard (below).
- **Scatter:** items with ≥ `SCATTER_MULTIMESH_THRESHOLD` (64, per-item override)
  instances bake as one MultiMeshInstance3D per chunk × item under `Scatter/` — the
  merged item mesh is stored ONCE, materials deduped like chunk merges; below the
  threshold every instance routes through the normal merge path. Collision harvest is
  identical either way (prefab shapes per instance into chunk bodies); collision-off
  items add zero physics; **weld-mode prefabs in scatter are a bake error**.
- **Roads:** the baker duck-calls `ribbon_surfaces()` / `ribbon_faces()` (they depend
  only on the serialized Path child + profile, so they work on the baker's untreed
  instance). Render is chunk-bucketed by triangle centroid (`split_arrays_by_chunk`,
  render-only — collision never splits) through `BakeContext.add_render_arrays`; every
  ribbon triangle joins the level-wide welded Drivable body via `add_weld_faces` (the
  same 1 mm snap as weld prefabs).
- Stats report chunks/surfaces/vertices/drivable triangles plus `scatter_instances`,
  `scatter_multimeshes`, and `roads`. Bake-adjacent CODE (RoadBuilder, ScatterBase) is
  governed by `BAKER_VERSION` + re-bake — it is invisible to the file-hash net.
- **Runtime seam:** `Level._setup_baked()` loads `<level>.baked.scn` by convention and
  frees the authoring subtree; unbaked levels play authoring content directly (dev).
- **Export never ships authoring:** `addons/carlito_kit/` (enabled EditorPlugin)
  registers an EditorExportPlugin whose `_customize_scene` strips AuthoringRoot from
  exported scenes; `export_presets.cfg` excludes kit glbs/palettes/prefabs/thumbs/tools
  (colormap + racing banner PNGs ship — baked materials reference them). Verified by
  byte-scanning the pck (an excluded imported texture leaves only a benign uid-cache
  path string, never its `.ctex` data).
- **CI gate:** `tools/check_bakes.tscn` recomputes each registered level's input hash
  (level .tscn + transitive `res://kit/**` deps + `.import` sidecars, CRLF-normalized
  text hashing) vs the manifest; ci.yml fails on missing/stale. The baked-level headless
  smoke (`CARLITO_LEVEL` env picks a registry id) runs against **`kit_fixture`**.

## kit_fixture — the permanent CI bake canary

`src/levels/dev/kit_fixture.tscn` (registered `dev: true`): a minimal level — a road
loop from the roads palette, one prefab of each collision mode, a weld ramp, a car
spawn — plus one permanent canary for every bake path: `TreeScatter` (80 tree_default,
MultiMesh path, collision), `GrassScatter` (20 grass, merge path, collision-off),
`GrassCanvas` (36 grass, `ScatterCanvas`, merge path), and `SplineRoad` (a RoadPath
S-curve at y = 0.05 on the south strip, profile set explicitly — headless runs never hit
the editor auto-assign). It is expanded programmatically by `tools/build_kit_fixture.gd`
(flat ground y = 0, no editor; no terrain, so the scatter ground hash `""` matches).
Rebuild it with `godot --headless res://tools/build_kit_fixture.tscn` (a game-mode tool;
hand-authoring GridMap cell/orientation data is fragile), then re-bake.

## Palette dock & click-to-place

- `plugin.gd` registers the export stripper, the bottom-panel dock, the viewport tools,
  and calls `set_input_event_forwarding_always_enabled()` so `_forward_3d_gui_input`
  receives every viewport event (placement is selection-independent). Viewport input is
  forwarded **terrain brush → scatter brush → road draw → placement tool**; each is
  inert until its target + mode are set, so the tools never fight normal editor
  navigation. Nothing in the addon ships — it is editor-only.
- **`palette_dock.gd`** (`@tool VBoxContainer`, UI only): reads all `kit/import/*.json`
  recipes, gathers each kit's emitted prefab basenames + palette meshlib item names,
  buckets them by **family via `KitRecipe.classify`** (`label` per section, `exclude`
  families skipped), and shows kit tabs → family sections → thumbnail grid from
  `kit/thumbs/<kit>/<name>.png` (basename is 1:1 across prefab/tile/thumb/GLB).
  **Search is global across all kits** (a non-empty query flattens the tabs into one
  result flow, each tile badged `<kit>/<name>`). Toolbar: Random yaw / Snap toggles +
  snap-step SpinBox.
- **`placement_tool.gd`** (`RefCounted`, holds all editor API): `arm(kit, name)`
  instances the prefab as a **non-saved ghost** (unowned, collision bodies zeroed to
  `collision_layer = 0` and excluded from the ray) that follows the ground-snapped
  cursor; left-click **commits** a real owned copy under the level's `AuthoringRoot` via
  `EditorUndoRedoManager` (add_child + set_owner + local transform, undoable);
  **sticky** (stays armed); right-click / Escape disarms. Refuses to arm with a clear
  warning when the scene has no AuthoringRoot.
- **Ground raycast fallback chain** (`addons/carlito_kit/ground_snap.gd`, shared by
  placement and road drawing — a click never dead-drops): edited-scene physics
  `intersect_ray` → miss → the level's `HeightmapTerrain.height_at(world_pos)` bilinear
  sample (runtime-safe, unit-tested in `tests/test_heightmap_terrain.gd`) → miss → the
  Y=0 plane. Editor physics isn't always populated, so the terrain/plane branches carry
  the feature.
- **Palette tiles route to the built-in GridMap workflow** (never reimplemented):
  `select_tile` finds — or creates (undoable, `cell_size` + `cell_center_y = false` from
  the recipe) — the AuthoringRoot GridMap using that kit's meshlib and selects/edits it
  so the built-in palette (with thumbnails) opens.
  `GridMapEditorPlugin.set_selected_palette_item` has no public handle to the built-in
  instance, so the exact paint item is a best-effort print of the item id — the author
  clicks the thumbnailed tile in the built-in palette.

## Terrain generation & splat ground

- **`HeightmapTerrain`'s render mesh is chunked**: one MeshInstance3D per `chunk_cells`
  tile (default 64) under an unowned `Chunks` node — the frustum-cull unit for
  island-scale maps (culling granularity, **not** LOD). Collision stays **one**
  `HeightMapShape3D`. Normals are analytic from the height grid
  (`TerrainGen.grid_normal`) because per-chunk `generate_normals()` seams chunk borders;
  UVs stay global 0..1 so the splat never seams. Brush strokes rebuild only touched
  tiles via `_build_chunk`.
- **Generator:** `TerrainGen` (`kit/terrain/terrain_gen.gd`, static pure fns, tested in
  `tests/test_terrain_gen.gd`). Preset = character (fractal type, relative amplitude,
  island radial falloff); knobs = `gen_seed` / `feature_scale` (m per feature) /
  `gen_octaves` / falloff band / **terrace plateaus** (`terrace_steps` + `terrace_flat`,
  applied last so island coasts step into concentric rings — the buildable flats
  villages/farms need; band centres are preserved so relief is unchanged). **World
  amplitude is the `height` export** — generated pixels stay normalized [0,1] (8-bit
  greyscale PNG). Two buttons: **Generate** (editor-only, destructive-by-button, never
  per-frame) writes the current texture's source PNG, else
  `<scene>_<node>_height.png` beside the scene; **Generate random** rolls a fresh seed
  into `gen_seed` (still reproducible). Both are one `EditorUndoRedoManager` action
  snapshotting the prior image + any property change (seed, material swap) — a stray
  click must not destroy sculpt work.
- **Splat ground:** `kit/terrain/terrain_splat.gdshader` (ships — `kit/terrain/` is not
  export-excluded): 4 albedo colors blended by an RGBA splatmap, **R=grass G=dirt B=sand
  A=rock**, sampled raw (no `source_color` — sRGB would bend weights),
  gl_compatibility-safe. `blend_sharpness` pow-sharpens + renormalizes the weights
  (default 8 — crisp low-poly borders, not soft fades). The **Auto-splat** button
  classifies from slope + height (`sand_height`, `dirt_slope_deg`, `rock_slope_deg`),
  swapping in a splat ShaderMaterial when needed (same undo action); the node pushes
  `splatmap` into the material param on rebuild. The below-sea ring splats sand out to
  the square map edge by design — a level's `WaterSurface` at sea level is what makes
  the beach read as a circular coast.
- **Generated-PNG import gotcha:** `TerrainGen.ensure_import_settings` writes/patches
  the `.import` sidecar — lossless, no mipmaps, **`detect_3d/compress_to=0`** (the
  splatmap is sampled by a 3D shader; the default detect_3d would silently reimport it
  VRAM-compressed and break `get_image()`) and **`process/fix_alpha_border=false`** (it
  rewrites RGB wherever alpha == 0, corrupting grass/dirt/sand weights where rock == 0).
- Demo: `src/levels/dev/terrain_demo.tscn` (a real Level, registered `dev: true`): a
  generated 256 m terraced island (seed 567998) with its auto-splat, a car spawn on the
  central plateau, a boat spawn in the surrounding `WaterSurface` sea (G swaps),
  drown-respawn included. Regenerating from the recorded knobs reproduces the committed
  PNGs.

## Terrain brushes

- **Reusable brush chassis** (`addons/carlito_kit/brush_chassis.gd`, `RefCounted`,
  shared by the terrain and scatter brushes): owns the radius/strength/falloff params,
  the circular ground cursor (an `ImmediateMesh` line loop, unowned child of the target,
  no-depth-test so it's always visible), and the input loop (LMB press → stroke,
  motion → **spacing-throttled** samples at `radius * 0.35`, release → stroke end,
  `[`/`]` resize). Brush-specific work is delegated to virtuals (`_target_valid`,
  `_project`, `_cursor_parent/_points/_color`, `_stroke_begin/apply/end`); the chassis
  is inert (returns false, doesn't touch the viewport) until a subclass reports a valid
  target.
- **`terrain_brush.gd`**: sculpt **raise/lower/smooth/flatten** on the heightmap,
  **paint** on the splatmap (4 channels). The pure per-pixel stamp math lives in
  `kit/helpers/brush_ops.gd` (radial `weight` curve, `sculpt_value`,
  `stamp_height`/`stamp_splat` returning the dirty Rect2i) — editor-free, unit-tested in
  `tests/test_brush_ops.gd`. Ground under the cursor is found by **iterating
  ray-vs-heightfield** (no physics — editor space isn't reliably populated, and we want
  the terrain surface, not a placed prop), sampling the **live working image** so the
  cursor tracks in-progress sculpting.
- **Editor-only; PNGs stay the sole artifact.** A brush never swaps the terrain's
  exported `heightmap`/`splatmap` Texture2D, so the scene always serializes the PNG
  reference. Live feedback: height remeshes only the touched chunks straight off the
  in-memory working image via `HeightmapTerrain.rebuild_region_world(img, min_x, max_x,
  min_z, max_z)` (collision deferred to stroke end via `rebuild_collision_from_image` —
  HeightMapShape3D has no partial update); paint drives a temporary splatmap
  shader-param override from a throwaway `ImageTexture`. Edits accumulate in per-terrain
  sessions and are written to the PNGs + reimported **only on scene save**
  (`EditorPlugin._save_external_data` → `TerrainBrush.flush_all`), never per stroke.
  `HeightmapTerrain.png_path_for(kind)` provides the PNG paths.
- **Undo** snapshots only the touched image region (before/after sub-images via
  `get_region`, `commit_action(false)` since edits are already live); `_apply_region`
  blits back and refreshes the visual, robust to the terrain no longer being selected
  (re-derives the session).
- **Panel** (`addons/carlito_kit/brush_panel.gd`, right dock `DOCK_SLOT_RIGHT_BL`): mode
  buttons (index-matched to the brush enum, 0 = Off), a Paint-only channel picker,
  radius/strength/falloff spinners. The plugin tracks `selection_changed` → sets the
  brush target to any selected `HeightmapTerrain`; picking a mode disarms the placement
  ghost. Terrain needs **no AuthoringRoot** for brushing (unlike prop placement).

## Scatter

- **Stored-transform contract (non-negotiable):** expansion happens exactly once, in the
  editor — pure seeded placement → ground-snap by raycast against the live edited scene
  (physics ray → `HeightmapTerrain.height_at` fallback; **no Y=0 fallback** —
  un-snappable points are *dropped*) → slope filter → **region-local transforms stored
  in the level .tscn** (`stored_transforms`, one packed array per item, stride 5:
  x, y, z, yaw, scale — `@export_storage`, one undoable action). The baker and dev-play
  only ever consume stored transforms — no expansion, no raycast, no physics outside the
  editor path — so editor and bake can never diverge and CI hashing is just the .tscn.
  (HungryProton's ProtonScatter was evaluated: its non-destructive runtime modifier
  stack is the model this design rejects; no code adopted.)
- **`ScatterBase`** (`kit/helpers/scatter_base.gd`) is the shared core of both
  front-ends: the `items` / `stored_transforms` / `stored_ground_hash` state, the
  MultiMesh preview + dev-collision subtree, the stale guard, and the pure statics the
  baker duck-calls (`stored_transform`, `stored_count`, `build_item_mesh`,
  `shape_entries`, `ground_hash`, `snap_ground`, `find_terrains_under`). GDScript
  inherits statics, so they resolve on either subclass; the baker treats a region and a
  canvas identically (both `is_carlito_scatter()`).
- **`ScatterRegion`** (`kit/helpers/scatter_region.gd`, under `Authoring`): box/polygon
  footprint (box unifies into the polygon sampling path), density / placement_seed knobs
  plus shared min_spacing / yaw+scale jitter / max_slope, `items: Array[ScatterItem]`
  (`kit/helpers/scatter_item.gd`: prefab **PackedScene** — so `gather_bake_inputs`
  tracks it — weight, collision on/off, per-item threshold override). The editor
  **Regenerate** button is the region's one expansion site. Placement statics
  (`generate_placements` — rejection sampling with a spatial-hash spacing guarantee,
  deterministic per seed — `polygon_area`) are unit-tested in `tests/test_scatter.gd`.
- **`ScatterCanvas`** (`kit/helpers/scatter_canvas.gd`, under `Authoring`): the
  hand-painted front-end — same contract, preview, dev collision, bake path and stale
  guard, but instances are **painted in** (no footprint, no Regenerate button — the
  footprint gizmo keys on `footprint_polygon`, which only the region has) plus one
  `paint_density` knob and the pure/tested `erase_within` static.
- **Scatter brush** (`addons/carlito_kit/scatter_brush.gd`, on the shared chassis;
  panel `scatter_panel.gd`, Off/Paint/Erase + radius): **Paint** seeds the region
  sampler over a world-XZ square bounding the brush disc, keeps candidates inside the
  disc, ground-snaps (`ScatterBase.snap_ground`), slope-filters, and enforces
  min_spacing against a running world-XZ spatial hash (prior dabs + existing instances,
  so density is even regardless of stroke speed); **Erase** calls
  `ScatterCanvas.erase_within`. Reuses the canvas node's jitter/spacing/slope exports.
  Strokes mutate `stored_transforms` live for feedback and commit **one** undoable
  whole-array swap (+ the ground hash) at stroke end — editor-only; no runtime or baker
  code.
- **Preview/dev-play:** unowned children rebuilt from stored data (never serialized —
  the same discipline as the terrain `Chunks` node): one MultiMeshInstance3D per item;
  **dev collision bodies only outside the editor** (unbaked play is drivable; editor
  raycasts never hit our own instances).
- **Stale-scatter guard** (warning + bake gate + CI): Regenerate/paint stores
  `ground_hash` (sha256 of every terrain heightmap image + name/position/size/height).
  On mismatch the node shows a configuration warning (3 s editor poll), **`bake()`
  fails** (like spawn validation), and **`check_level_file` reports stale** — the
  terrain PNGs live beside the level scene, outside the `res://kit/**` input-hash net,
  so without this a sculpt-after-scatter would ship floating/buried props CI-green.
  Regenerate (which re-snaps) clears it, as does the **Re-snap to ground** button on
  `ScatterBase` (re-snaps stored Ys in place, keeps XZ/yaw/scale, drops groundless
  instances, refreshes the hash — the recovery path for a canvas, which cannot
  Regenerate, after a road Conform or sculpt). Regions with zero stored instances never
  gate.

## Spline roads

- **`RoadPath`** (`kit/helpers/road_path.gd`, under `Authoring`): owns a **serialized
  `Path3D` child "Path"** (edit with the built-in path gizmo or the addon's Draw mode;
  the curve is the bake input) and extrudes a low-poly ribbon from a **`RoadProfile`**
  (`kit/helpers/road_profile.gd`; presets `kit/roads/asphalt_profile.tres` — painted
  edge line — and `gravel_profile.tres`; flat-color materials as inline SubResources so
  a color edit re-stales bakes through the one .tres hash). The ribbon derives from the
  **curve + profile alone** (never reads the terrain), so bake output depends only on
  the scene file. Preview is unowned; the **dev trimesh exists only outside the editor**
  (unbaked play drivable; editor rays never hit our own ribbon). Profile default: editor
  `_ready` assigns the asphalt preset via a **plain property set** so it serializes as
  an ExtResource the input hash sees — never a preload export default (equal-to-default
  is omitted from the .tscn, a hash hole); the baker errors on a null profile.
- **Pure math is `RoadBuilder`** (`kit/helpers/road_builder.gd`, tested in
  `tests/test_road.gd`): curvature-adaptive offsets **anchored at every interior control
  point's arc offset** (the corner miter: a kink gets a ring exactly AT the corner whose
  central-difference tangent is the angle bisector, else the edge notches even at small
  angles; then uniform coarse split + bisection while tangents disagree, incl. a
  midpoint check for S-inflections; MIN_SEG 0.5 floor), a **custom frame** (right =
  tangent×UP stays horizontal, roll ONLY from explicit curve tilt when `banking` is on —
  deliberately NOT `sample_baked_with_rotation`, whose parallel transport accumulates
  roll on climbing turns), per-strip extrusion (strips never share verts — crisp hard
  edges; U = lateral m, V = arc-length m; winding CW-from-above and invariant under
  curve reversal), and the conform flatten mask.
- **Draw mode + Drape:** `addons/carlito_kit/road_draw_tool.gd` + `road_panel.gd`
  (right dock, Off/Draw; RoadPath-selection-gated like the brushes). Each viewport click
  ground-snaps via the shared `ground_snap.gd` chain, lifts by the node's
  `draw_clearance` (0.3), and appends ONE undoable curve point **auto-smoothing the
  previous point with Catmull-Rom handles** (`RoadBuilder.smooth_handles`, pure/tested —
  a zero-handle polyline corner folds the ribbon over itself); the first click replaces
  the untouched 2-point default stub; a ghost line previews the next segment;
  RMB/Escape exits; the panel's **Close loop** button appends a point ON the first
  point with Catmull-Rom seam tangents on both sides (C1 through the seam — the
  duplicated ring welds at bake) and exits Draw. RoadPath buttons: **Drape curve onto
  terrain** (re-snaps every existing point's Y to terrain + clearance; points over no
  terrain keep their Y) and **Smooth curve (Catmull-Rom)** (handles for every interior
  point — the rescue for hand-kinked curves); each is one undoable action. Corners
  still self-overlap when the local turn radius drops below the ribbon half-width
  (~5 m asphalt) — that is geometric; space clicks/points wider.
- **Conform terrain is destructive-by-button** (the same discipline as terrain
  Generate): samples the curve every 0.5 m (deterministic,
  tessellation-independent), flattens every overlapping `HeightmapTerrain` to road
  height − `conform_epsilon`. Per pixel the target is **lerped at the projection onto
  the nearest centerline segment** (never the nearest point sample — that is off by up
  to half the sample spacing × the grade and pokes terrain through the ribbon on grades
  > ~20%; regression-tested at 8-bit precision). The flatten plateau is the **full
  ribbon half-width incl. the drop skirt** (`full_half_width()`), so terrain under the
  skirt sits at a predictable road − ε and always crosses the skirt on its slope;
  `conform_falloff` smoothsteps out beyond the ribbon. Targets are **floor-quantized to
  the 8-bit grid** so the PNG can never store terrain above the ribbon — any ε > 0 is
  z-fight-safe, but the profile's `edge_drop` must absorb **ε + height/255** (conform
  warns per terrain when it can't). One `_commit_generated` undo action per terrain
  (PNG write + reimport, same pipeline as Generate/Auto-splat). Conforming changes
  heightmap bytes, so earlier scatter **trips its stale guard by design** — authoring
  order: terrain → roads + conform → splat → scatter, with the ScatterBase **Re-snap to
  ground** button recovering out-of-order edits.
- **Non-goals (permanent):** no junctions (cross two roads over a flat GridMap pad or a
  painted plaza), no lane-marking system, no traffic data.

## Global non-goals

No runtime/procedural world streaming, no in-game level editor, no texture-layer terrain
(color splat only), no LOD system (bake + draw-call budget cover web perf), no automatic
road junctions, and no replacement of the GridMap workflow for city grids — it remains
the right tool there.
