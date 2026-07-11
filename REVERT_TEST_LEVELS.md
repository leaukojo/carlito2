# TEMPORARY — revert before launch

Test scaffolding added to load `kit_fixture` and `terrain_demo` from the main menu
(with a boat spawn in each). Delete this file once reverted.

## To revert

1. **`src/ui/level_select.gd`** — restore the `dev` skip in the level loop:
   ```gdscript
   for entry in LevelRegistry.LEVELS:
       if entry.get("dev", false):
           continue  # dev fixtures (kit_fixture) are CI/bake assets, not shipped content
       var b := Button.new()
   ```

2. **`src/shell/level_registry.gd`** — remove the `terrain_demo` entry (the last item in
   `LEVELS`, tagged with the "Temporary" comment).

3. **`tools/build_kit_fixture.gd`** — remove the boat-test rig:
   - the two `_add(root, root, _make_water())` / `_make_boat_spawn()` lines in `_ready()`,
   - the `_make_water()` and `_make_boat_spawn()` functions + the `WATER_POS` const.

4. **`src/levels/dev/kit_fixture_info.tres`** — set `allowed_vehicles` back to
   `PackedStringArray("car")`.

5. Rebuild + re-bake so the committed artifacts match again:
   ```powershell
   $GODOT = 'C:\Users\Ccamy\Desktop\Godot\Godot_v4.6.3-stable_win64_console.exe'
   & $GODOT --headless --path . res://tools/build_kit_fixture.tscn
   & $GODOT --headless --path . res://tools/bake_levels.tscn
   & $GODOT --headless --path . res://tools/check_bakes.tscn   # expect: fresh, exit 0
   ```
   (After removing `terrain_demo` from the registry it is no longer baked/checked; its
   `terrain_demo.baked.scn` / `.bake.json` can stay or be deleted — they're only used by F6.)

## NOT temporary (keep)

The scatter code-review fix is unrelated: `kit/bake/level_baker.gd`
(`chunk_local_multimesh_transforms`), `kit/helpers/scatter_region.gd` (preview collision
mirrors the baker), and `tests/test_bake.gd`.
