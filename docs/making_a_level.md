# Making a level

A step-by-step walkthrough for building a drivable Carlito level with **no game-design
experience**. You will duplicate a template, paint roads, drop buildings, place a spawn
point, press one Bake button, and register the level in the menu. The worked example this
doc follows is `src/levels/dev/kit_demo.tscn` — open it next to your own level whenever a
step feels abstract.

**The one core idea:** a level has two forms.

- **Authoring form** — everything you place under the level's `Authoring` node (painted
  road tiles, prefab buildings and props). Easy to edit, but it would ship as hundreds of
  separate meshes and physics bodies (slow, and body seams can snag wheels).
- **Baked form** — what actually plays: one merged mesh per ~48 m chunk, one collision
  body per chunk, and a single welded "drivable" body for every road/ramp surface (no
  seams, ever). The **Bake** button produces it in seconds.

You edit the first, the game plays the second, and CI refuses to ship a stale bake — so
you can't forget.

## 0. Prerequisites

Open the project in Godot 4.6.3. That's it. The kit palettes (`kit/palettes/`) and prefab
library (`kit/prefabs/`) are already generated and committed.

## 1. Duplicate the template

1. In the FileSystem dock, copy `src/levels/base/level.tscn` to a new folder, e.g.
   `src/levels/farm/farm.tscn` (right-click, Duplicate, then move). The template already
   contains the environment, sun, chase camera, and one spawn marker.
2. Create the level's info file: right-click your folder, **Create New > Resource**, pick
   `LevelInfo`, save as `farm_info.tres`. Fill in `display_name`, `allowed_vehicles`
   (e.g. `car`, `truck`, `tractor`) and `default_vehicle` (e.g. `car`).
3. Select the root node of your scene and point its `info` property at that `.tres`.

## 2. Ground

Every level needs ground collision under everything (plan rule: ground is a plane or a
heightmap, never mesh soup).

- **Flat ground:** add a `StaticBody3D` with a `CollisionShape3D` (BoxShape3D, e.g.
  280 x 2 x 220, top at y = 0) and a `MeshInstance3D` BoxMesh of the same size. kit_demo
  does exactly this.
- **Hills:** add a `HeightmapTerrain` node instead (see the gym's `Hill`). Feed it a
  greyscale PNG imported with **lossless compression and no mipmaps**, then press its
  Rebuild button.

## 3. Add the Authoring node

Add a child node of type **AuthoringRoot**, name it `Authoring`. Everything the bake tool
processes goes under this node — road GridMaps and kit prefabs. Its `chunk_size` (default
48 m) is the render-batching knob; leave it alone unless the F3 overlay shows too many
draw calls (budget: under ~500 in the worst view).

## 4. Paint roads (GridMap)

1. Add a **GridMap** node under `Authoring`, name it `Roads`.
2. Set its `mesh_library` to `kit/palettes/roads.meshlib`, and configure the grid to the
   kit's lattice — these three settings must match the palette or tiles will float or
   overlap:

   | palette | cell_size | cell_center_y | notes |
   |---|---|---|---|
   | `roads.meshlib` | `(8, 2, 8)` | **off** | city streets; one vertical cell = one `tile-high` step |
   | `racing.meshlib` | `(10, 10, 10)` | **off** | wide race track, ramps, bridges |

   Also set `cell_octant_size` to 8. (That's dev-play collision granularity; the bake
   replaces it anyway.)
3. Select the GridMap and paint: click a tile name in the palette panel, click cells in
   the viewport. **The palette lists names, not pictures** — keep
   [kenney.nl/assets](https://kenney.nl/assets) open in a browser tab for visuals.
   Useful keys while painting: `S` rotates the tile, `Escape` cancels selection.
4. Tile crash course (roads kit): `road-straight` for streets, `road-bend` corners,
   `road-crossroad` 4-way, `road-square` plain asphalt, `road-slant` up to a raised
   `tile-high` deck (paint the deck at grid level 1 — press `Q`/`E` to change floor),
   `road-bridge` + `bridge-pillar` for overpasses. Every painted tile becomes part of the
   welded drivable body at bake time — curbs and bridges included, with zero seams.

One GridMap per palette: never mix kits in one GridMap (their lattices differ).

## 5. Place prefabs

Drag scenes from `kit/prefabs/<kit>/` under `Authoring` and move them with the normal
gizmos (enable **Snap** with `Y`, configure snap distance under Transform > Configure
Snap; 1 m works well). Each prefab already knows its collision:

- **box / hull** — solid things: buildings, fences, containers, barriers, trees.
- **multiconvex** — things you can drive under or through: grandstands, gantry signs,
  streetlight arms, dock houses, race gates.
- **weld** — drivable structures: the racing `ramp`, watercraft boat launches
  (`ramp`, `ramp-wide`), suburban driveways/paths. These join the same welded body as
  the painted roads.
- **none** — decoration (cones, buoys, awnings, distant skyline buildings).

You never set any of this per placement — it's baked into the prefab (the
`collision_mode` on its root, generated from `kit/import/<kit>.json`).

Scale sanity: the car is 1.8 m wide. City tiles are 8 m, racing tiles 10 m; suburban
houses come out around 10 x 7 m. If something looks toy-sized or gigantic, you probably
grabbed a raw GLB from `kit/raw/` — always use `kit/prefabs/`.

## 6. Spawn points

Move the template's `Spawn` marker onto a road, facing where the vehicle should look
(the editor gizmo shows a car-sized box with a nose arrow — orange for land, cyan for
water). Rules the bake tool enforces:

- the `default_vehicle` needs a spawn that accepts it;
- every type in `allowed_vehicles` needs a matching spawn (empty `vehicle_types` on a
  marker = accepts everything);
- boats need a spawn with `is_water` checked; land vehicles need a dry one.

Add more `VehicleSpawn` markers (e.g. a truck yard) by duplicating the first.

## 7. Register and playtest

1. Add your level to `src/shell/level_registry.gd`:
   ```gdscript
   { "id": "farm", "name": "Farm", "scene": "res://src/levels/farm/farm.tscn" },
   ```
2. Press F5 and pick it in the level select. **Unbaked levels are playable** — you're
   driving on per-piece dev collision, so an occasional seam bump is normal at this
   stage. Iterate freely: paint, place, F5, repeat.

## 8. Bake

When the layout settles (and always before committing):

1. **Save the scene (Ctrl+S).** The bake reads the file on disk.
2. Select the `Authoring` node and press **Bake level** in the inspector.
3. Check the Output panel: `Bake OK` plus stats (chunks, surfaces, vertices, drivable
   triangles). Surfaces ~= draw calls for the static world; the budget is <500 total.
   If validation fails (usually spawns), it tells you exactly what's missing.
4. Two files appeared next to your scene — commit **both** along with the `.tscn`:
   - `farm.baked.scn` — the merged chunks + collision the game plays;
   - `farm.bake.json` — the manifest stamping a hash of your authoring inputs.

From now on the game plays the baked geometry (the `Authoring` node is freed at load and
stripped from web exports entirely). If you edit the level again, just re-bake — and if
you forget, CI's **Stale-bake check** fails the build with the exact re-bake command.

Command-line equivalent (all registered levels, used by CI docs and batch re-bakes):

```powershell
& $GODOT --headless --path . res://tools/bake_levels.tscn
& $GODOT --headless --path . res://tools/check_bakes.tscn   # what CI runs
```

## 9. Done — checklist

- [ ] Level scene + `_info.tres`, `info` wired on the root
- [ ] Ground body under everything
- [ ] Roads painted under `Authoring`, correct cell settings from the table
- [ ] Prefabs from `kit/prefabs/` (never `kit/raw/`)
- [ ] Spawns for every allowed vehicle, facing the right way
- [ ] Registered in `level_registry.gd`, playtested
- [ ] Baked; `.tscn` + `.baked.scn` + `.bake.json` all committed
- [ ] CI green (stale-bake check + smoke)

## Appendix: extending the kit

- **New prefab / palette piece from an existing kit:** edit the kit's recipe
  (`kit/import/<kit>.json` — glob patterns map pieces to a palette or to a collision
  mode), then regenerate:
  ```powershell
  & $GODOT --headless --path . --script res://tools/gen_kit_assets.gd -- <kit>
  ```
  Palette item ids are preserved across regeneration, so painted levels never break.
  Levels using changed pieces go stale and need a re-bake (CI will say so).
- **New Kenney kit:** copy the GLBs (+ their `Textures/` folder and `License.txt`) into
  `kit/raw/<name>/`, run the editor once (or `--headless --import`), measure it with
  `--script res://tools/measure_kit.gd -- kit/raw/<name>`, write a recipe with a scale
  that fits the 1.8 m car, and regenerate. Credit the kit in `README.md`.
- **Why some pieces are missing on purpose:** race cars, boats and characters in the
  kits are vehicles/actors, not level geometry — vehicles are hand-built scenes
  (`src/vehicles/`), so those GLBs are excluded or hull-collision props only.
