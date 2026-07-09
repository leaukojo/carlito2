# Level Kit v2 — prompts (LK0–LK8)

Companion to `level_kit_plan.md` (the spec — prompts reference its sections, don't paste
them). All `prompting_guide.md` ground rules apply: one prompt = one fresh session, start
in `carlito2`, zero v1 *code* reuse (LK1a reads v1 **settings JSON as data** — that's the
user's authored curation, explicitly allowed by the plan), verify before moving on, commit
at the end, update CLAUDE.md at the end of every prompt.

### /code-review protocol

| Prompt | Review | Why |
|---|---|---|
| LK0 | none | mechanical deletion, gated by CI |
| LK1a | quick (medium, same session) | data port + generator extension; regen output is inspectable |
| LK1b | none | local render pass; thumbs are inspected by eye |
| LK2 | quick | editor-only dock; bugs are visible, not silent |
| LK3 | quick | pure generation math is unit-tested; visuals verified by eye |
| LK4 | quick | editor-only brushes; worst failure is a bad stroke you undo |
| LK5 | **deep (high, fresh)** | feeds the baker — bad expansion/collision bakes *silently* into every level, exactly the P6 failure class |
| LK6 | quick | thin front-end over the reviewed LK5 core |
| LK7 | **deep (high, fresh)** | welded drivable geometry + destructive terrain writes; a subtle seam or normal bug becomes "weird feel" weeks later |
| LK8 | none | level content + docs, verified by driving |

---

### LK0 — Clean slate *(plan LK0)*

> Read level_kit_plan.md §2 (clean slate) and §4 LK0. Delete src/levels/farm,
> src/levels/harbor, and kit_demo entirely (scenes, infos, bakes, manifests, and any
> heightmap PNGs only they use) and remove their level_registry.gd entries — no kit level
> built on the old lattice survives. Remove the CI baked-smoke step
> (CARLITO_LEVEL: kit_demo) from ci.yml; LK1a reinstates it against kit_fixture. Do not
> touch gym or flat (hand-built physics regression rigs, not kit content). Sweep the repo
> for stragglers: docs links, test references, and CLAUDE.md's landed-levels claims
> (update it to say farm/harbor are rebuilt in LK8). Run the full test suite plus the
> default-boot headless smoke.

- **Run with:** Sonnet 5, default mode.
- **You verify:** level select shows Gym only; CI fully green (baked smoke absent by
  design until LK1a).

### LK1a — Clean kit re-derivation, curation, nature kit, fixture level *(plan LK1)*

> Read level_kit_plan.md §4 LK1. Extend the kit recipe schema (`kit/import/<kit>.json`)
> with a `families` block (name, regex match list, label) and per-asset overrides, then
> port the corresponding data from v1's `../carlito/auto_import_assets/asset_kit_settings.json`
> — its `classify` regexes and per-asset collision/offset overrides — for the six existing
> kits. This is a data port of user-authored settings, not code; do not read any v1 GDScript.
> Collision modes map v1→v2: convex→hull, trimesh→weld, box/multiconvex/none unchanged;
> flag anything ambiguous instead of guessing. Write the recipe for the nature kit: its
> 200 props-only GLBs (trees, rocks/stones, stumps/logs, plants/flowers/grass/mushrooms,
> crops, fences, cacti, statues — the kit's tile/water half was never copied into the
> repo) are already in kit/raw/nature/ with textures embedded. Measure with
> tools/measure_kit.gd, scale to the 1.8 m car, trees/rocks/stumps hull/box, flat
> foliage/crops none, everything as prefabs (no palette). Re-derive the kit geometry clean
> per plan §2 (clean slate): compute per-kit scales from measurement against an explicit
> lane-fit rule for the 1.8 m car (consistent across road-bearing kits, derivation noted
> in each recipe), re-measure the racing kit's y-offsets from piece AABBs instead of
> inheriting v1's numbers, delete the suburban driveway-long palette (driveway/path stay
> weld prefabs), and let meshlib ids restart clean while keeping the id-preservation
> mechanism and its test. Add the coverage gate to gen_kit_assets.gd: every GLB under
> kit/raw/<kit>/ must be matched by a palette include, a prefab pattern, or an explicit
> exclude entry carrying a reason string — the generator fails listing unaccounted assets
> — then bring all seven recipes to full coverage (today roads exposes 12/72 GLBs as
> prefabs, racing 52/112; account for every one). Build kit_fixture (src/levels/dev/kit_fixture.tscn): a minimal
> level on the new lattice — small road loop, one prefab of each collision mode, a weld
> ramp, a vehicle spawn — registered with a dev flag that hides it from the level-select
> UI. It is the scale-verification step and the permanent CI bake fixture: bake it and
> reinstate the CI baked-smoke step as CARLITO_LEVEL=kit_fixture. Regenerate everything,
> run the full test suite.

- **Run with:** Opus 4.8, default mode (the scale/offset re-derivation is judgment work —
  the eyeballed version of it is one of the warts being removed; the rest is data work).
- **Already done (earlier session):** the nature kit's 200 prop GLBs + License.txt are in
  `kit/raw/nature/`, the import cache is built, and README credits it — LK1a starts at the
  recipe.
- **You verify:** nature prefabs correctly scaled next to the car in gym; drive the
  kit_fixture road loop baked (correct lane fit is the point of the re-derivation). Then
  place one nature tree in kit_fixture, re-bake, and check the **web export** still
  renders its colors — unlike the other kits, nature GLBs carry materials internally (no
  external Textures/ folder), and raw glbs are excluded from the export, so the baked
  scene must carry those materials itself. CI green (baked smoke back on).

### LK1b — Thumbnail pipeline *(plan LK1)*

> Read level_kit_plan.md §4 LK1 (thumbnail bullet). Build the thumbnail pipeline: a
> game-mode tool scene tools/gen_thumbs.tscn (run windowed, not headless — headless can't
> render) framing each prefab and palette item in a SubViewport against a neutral backdrop
> and writing kit/thumbs/<kit>/<name>.png (128px, lossless import). Make gen_kit_assets.gd
> embed them as MeshLibrary item previews so the built-in GridMap palette shows pictures.
> Preserve meshlib item ids across regen (keep that test green). Exclude kit/thumbs from
> the web export and verify by pck byte-scan like P6 did. Regenerate everything, run the
> full test suite.

- **Run with:** Opus 4.8, default mode (a render pass with a clear spec).
- **You verify:** open a GridMap in the editor — the palette shows **pictures**; the
  thumbs folders are full and the images sensible (framed, lit, not black). CI green.

### LK2 — Palette dock *(plan LK2)*

> Read level_kit_plan.md §4 LK2. In `addons/carlito_kit`, add a bottom-panel dock: kit tabs,
> family sections from the LK1 recipe taxonomy, text search, thumbnail grid loading
> `kit/thumbs/`. Click-to-place: selected prefab instances under the level's AuthoringRoot
> on viewport click via ground raycast, with toolbar toggles for random yaw and grid snap;
> right-click/Escape cancels; placement undoable via EditorUndoRedoManager. Selecting a
> palette tile selects the matching GridMap + item instead (never reimplement GridMap
> painting). The placement ray tests physics first and falls back to the level's
> HeightmapTerrain height sample (or the Y=0 plane) on a miss — painted GridMap tiles only
> have edit-time collision if the meshlib items carry shapes, and a click must never
> dead-drop. Handle the no-AuthoringRoot case with a clear error. Keep every editor API
> inside addons/carlito_kit (the plan's editor/runtime split). think hard.

- **Run with:** Opus 4.8, `think hard`, **Plan Mode** first (editor plugin APIs have real
  degrees of freedom — placement flow, panel layout).
- **You verify:** in the editor, dress a scratch level: find a prop by thumbnail + search,
  place 10 with random yaw on uneven gym terrain, undo them all, paint a road tile via the
  dock's tile selection. It should feel faster than the FileSystem dock, or LK2 failed.

### LK3 — Terrain generation + splat material *(plan LK3)*

> Read level_kit_plan.md §4 LK3. Grow HeightmapTerrain with a FastNoiseLite generator:
> preset enum (island / rolling hills / plains / dunes), seed, amplitude, feature scale,
> octaves, and a radial falloff curve for islands; a Generate tool button writes the
> level's heightmap PNG (lossless import rules unchanged — runtime get_image(),
> HeightMapShape3D collision, and plan §2 rule 2 stay intact). Chunk the render mesh
> (fixed-size tiles, one MeshInstance3D each) so island-scale maps frustum-cull instead
> of drawing one giant always-on mesh — collision stays a single HeightMapShape3D; this
> is culling granularity, not LOD. Add the color-splat ground
> material: `kit/terrain/terrain_splat.gdshader`, 4 albedo colors blended by an RGBA
> splatmap image, gl_compatibility-safe, plus a one-click auto-splat seeded from slope +
> height. Generation is destructive-by-button, deterministic from the seed, and undoable
> (one UndoRedo action snapshotting the prior image — a stray click must not destroy
> hand-sculpted work once LK4 lands) — never per-frame. Unit-test the pure fns (falloff,
> remap, auto-splat classification) in
> tests/test_terrain_gen.gd. Demo: generate an island heightmap in a scratch scene and
> auto-splat it. think hard.

- **Run with:** Opus 4.8, `think hard`, **Plan Mode** first (shader + generator API design).
- **You verify:** generate each preset in the editor — the island preset reads as an island
  (beaches at water level, interior hills); auto-splat puts sand low, rock on slopes; drive
  the car over a generated hill in the gym; web export still renders the shader.

### LK4 — Terrain brushes *(plan LK4)*

> Read level_kit_plan.md §4 LK4. In addons/carlito_kit, build the viewport brush chassis
> (design it for reuse — LK6's scatter brush rides the same chassis): while a
> HeightmapTerrain is selected, _forward_3d_gui_input drives a circular brush cursor with
> radius/strength/falloff controls. Sculpt modes raise/lower/smooth/flatten-to-height edit
> the in-memory heightmap Image, rebuilding only the LK3 terrain chunks the stroke touched
> (plus the shape's region) per stroke; paint
> mode edits the LK3 splatmap. Strokes undoable (snapshot touched region); PNGs saved on
> scene save, never reimported per stroke. Editor-only: brushes change image content only
> — no new data formats, no new runtime or baker code paths; the heightmap/splat PNGs
> stay the sole artifact. think hard.

- **Run with:** Opus 4.8, `think hard`. Plan Mode optional; the chassis/undo design is the
  part worth planning.
- **You verify:** sculpt a hill and a flattened building pad on a 256×256 terrain — strokes
  feel interactive (no full-second hitches); undo works mid-stroke-history; save, reopen,
  edits persisted; drive the sculpted terrain.

### LK5 — Scatter regions *(plan LK5)*

> Read level_kit_plan.md §4 LK5 and §2 (build vs. adopt). Before designing the API, skim
> HungryProton's Scatter addon for prior art — design reference only, our stored-transform
> bake contract is the non-negotiable; plan §7 credit rules apply if any code is adopted.
> Implement ScatterRegion (kit/helpers, @tool, placed under
> Authoring): box/polygon footprint, item table (prefab, weight, collision on/off), density,
> min spacing, seed, yaw/scale jitter, max slope. Placement is a pure static
> generate_placements(params) with rejection-sampled spacing, unit-tested in
> tests/test_scatter.gd for determinism (same seed = identical output) and spacing
> guarantees. The Regenerate button is the only place expansion happens: it runs the pure
> placement, ground-snaps each instance by raycast against the live edited scene, and
> stores the final transforms in the scene as compact packed arrays per item type. The
> baker and dev-play consume stored transforms only — no raycast, no expansion, no physics
> in the baker, so editor and bake can never diverge. Each region stores a hash of the
> heightmap it snapped against and shows an editor configuration warning on mismatch —
> sculpt-after-scatter must never silently bake floating or buried props. Editor/dev-play
> renders one MultiMeshInstance3D per item plus dev collision when unbaked; the baker
> detects scatter nodes by duck-typed marker — items above an instance-count threshold
> (default ~64, per-item override) bake as one MultiMeshInstance3D per chunk × item type
> (geometry stored once; an island-scale forest must not duplicate its verts into merged
> chunk meshes), items below it route through the existing prefab merge path, and
> collision harvest is identical either way — report instance and shape counts in bake
> stats. Collision-off items add zero physics. Everything the baker touches must run
> editor-free (game-mode tool scene, the P6 CLI lesson). Re-bake and keep CI green.
> ultrathink.

- **Run with:** Fable 5, `ultrathink`, **Plan Mode** first. This phase feeds the baker —
  the same silent-failure class that made P6 a deep-review prompt.
- **After tests pass:** deep review — `/clear`, `/code-review high --fix`, re-run tests,
  then commit.
- **You verify:** scatter 500 trees on gym terrain from a region; regenerate twice — the
  forest is identical; bake; drive into a tree (collides), through grass tufts (doesn't);
  F3 draw calls sane; bake stats show the counts.

### LK6 — Scatter brush *(plan LK6)*

> Read level_kit_plan.md §4 LK6. Add ScatterCanvas (@tool, under Authoring) storing
> hand-painted instances as data, and a paint/erase brush front-end in addons/carlito_kit
> reusing the LK4 brush chassis and the LK5 scatter core (jitter, ground conform) and bake
> path (MultiMesh preview, merge/harvest on bake). Density-per-stroke painting, radius
> erase, undoable strokes. Re-bake, CI green.

- **Run with:** Opus 4.8, default mode (two reviewed subsystems already define the seams).
- **You verify:** paint a hedgerow and a scattered-junk corner in the gym, erase half,
  undo, save/reopen — instances persist; bake and drive it.

### LK7 — Spline road *(plan LK7)*

> Read level_kit_plan.md §4 LK7 including its non-goals (no junctions, no lane-marking
> system). Implement RoadPath (kit/helpers, @tool, owns a Path3D child, under Authoring):
> extrudes a low-poly ribbon along the curve from a profile resource (lane width, shoulder,
> edge drop, material — default asphalt with painted edge line, plus a gravel profile),
> curvature-adaptive segment length, arc-length UVs, optional banking from curve tilt.
> Conform-terrain is a destructive button: flatten the heightmap under the ribbon with a
> side falloff blend, one deterministic write, undoable, saved with the PNG; the ribbon
> mesh derives from the curve alone so bake output depends only on the scene file. At bake
> the ribbon joins the level-wide welded drivable body (same 1 mm snap path as weld
> prefabs); unbaked play gets a dev trimesh. Unit-test extrusion, adaptive sampling, and
> the flatten mask in tests/test_road.gd. Baker changes stay editor-free. ultrathink.

- **Run with:** Fable 5, `ultrathink`, **Plan Mode** first — the riskiest phase of the
  rework (drivable geometry + destructive terrain writes).
- **After tests pass:** deep review — `/clear`, `/code-review high --fix`, re-run tests,
  then commit.
- **You verify:** draw an S-curve road over LK3 island terrain, conform, bake, then drive
  it at speed — no seam bumps, no z-fighting at the blend edges, banking reads correctly;
  reverse the curve direction and re-bake to check winding; CI green.

### LK8 — Build farm + harbor from scratch, docs *(plan LK8)*

> Read level_kit_plan.md §4 LK8. Build the farm from scratch using only the new tools:
> generated rolling-hills terrain with splat fields, a RoadPath gravel lane, crop rows and
> tree lines/orchard as ScatterRegions, clutter via the scatter brush, buildings/fences
> placed from the dock. Build the harbor from scratch: quay + seabed + WaterSurface, boat
> launches and hulls from the watercraft prefabs, shoreline rock/vegetation scatter.
> Both levels are signal playgrounds (plan §2): the farm must include a field where
> lowering the hitch and running the PTO along crop rows feels like plowing; the harbor
> a course — wake ramp off the boat launch, tight buoy turns — that makes pitch/roll
> perform. Register and bake both; add a second CI baked-smoke run with CARLITO_LEVEL=farm
> (kit_fixture stays the permanent minimal canary); keep CI green and F3 under the §5.4
> budget in the worst view. Rewrite docs/making_a_level.md around the new workflow
> (generate terrain →
> roads → splat paint → scatter → dress → bake) with the farm as the worked example, and
> update the CLAUDE.md kit section. If any step still feels like manual labor, stop and
> report it rather than pushing through — that's a tool defect, not a content problem.

- **Run with:** Sonnet 5, default mode.
- **You verify:** play both levels start to finish; the farm should finally look *dressed*
  (not four trees); with sloppyCAN open, plow a farm row and run the harbor course — the
  ISOBUS and pitch/roll signals should visibly perform; the doc walkthrough should be
  followable by a non-designer. This is the acceptance gate before the island (P9).
