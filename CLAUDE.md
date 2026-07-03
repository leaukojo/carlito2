# CLAUDE.md

Guidance for Claude Code sessions in this repository.

## What this is

**Carlito v2** — a ground-up rebuild of the Carlito CAN-bus driving sandbox: drive vehicles
(car/truck/tractor/boat) in a browser while exchanging live CAN signals with the sloppyCAN/RAMN
simulator over a postMessage bridge. Godot 4.6, web-first.

**`version2_plan.md` (repo root) is the plan of record.** Read the section a task references
before implementing. Milestones M0–M7 are in §5.3; this repo is currently at **M0 (scaffold)**.

## v1 is a reference spec, NEVER a code source

v1 lives at `../carlito` (and its deployed build). **Zero v1 code reuse** — do not read v1 source
to copy code, patterns, or snippets. When plan §6 (the distilled v1 behavior spec) is ambiguous,
*observe* v1's behavior by running its deployed build, then re-implement cleanly here.

## Layout (plan §4.1)

```
contract/     shared signal-contract JSON (carlito_contract.json — heart of the project, plan §3)
src/shell/    game shell: boot, level select, garage menu (+ GameState autoload)
src/bridge/   Contract + Bridge autoloads (contract loader; CAN bridge lands in P3)
src/input/    InputRouter autoload + input sources; ALL input arbitration lives here
src/vehicles/ base/ (BaseVehicle, VehicleSpec, wheels, drivetrain) + car/ truck/ tractor/ boat/
src/levels/   base/ (Level scene, LevelInfo, markers) + gym/ island/ farm/ harbor/
src/ui/       dashboard, touch controls, menus
src/water/    water surface + height sampling API
kit/          level-authoring kit: meshlibs, prefabs, @tool helpers, bake tool
tests/        gdUnit4 suites (tests/fixtures/ for bad-input files)
tools/        editor scripts (bake, import), CI helpers
```

Autoloads (keep this the whole set): `Contract`, `Bridge`, `InputRouter`, `GameState`.

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

# local web export (CI does the real one)
& $GODOT --headless --path . --export-release "Web" build/web/index.html
```

- A headless run ending with only `ERROR: N resources still in use at exit` is **clean** —
  harmless leak-at-exit noise, not a failure.
- `--headless --script` only runs `extends SceneTree` scripts; EditorScripts need File ▸ Run
  in the editor.
- The editor **rewrites `export_presets.cfg`** when you export from the UI — CLI export reads
  it as-is. Keep thread_support + PWA (cross-origin-isolation headers) enabled: GitHub Pages
  sends no COOP/COEP, the PWA service worker injects them, and the threaded build needs them.

## CI / deploy

`.github/workflows/ci.yml`: every push runs import → gdUnit4 → headless smoke → web export;
pushes to `main` deploy to **https://leaukojo.github.io/carlito2/** via GitHub Pages (Actions
source). Cache-busting: the export basename embeds the commit SHA, so all heavy artifacts
(.pck/.wasm/.js/PWA worker) get unique names per deploy; `index.html` is a small copy. First
visit after a deploy may still need one reload for the new service worker to take over.

## The contract

`contract/carlito_contract.json` defines every bridge signal (name, dir, type, unit, range,
enum, vehicles, isobus flavor). The `Contract` autoload loads + validates it at startup;
tests fail if a v1-era signal goes missing. Signals are unique by **(name, dir)** — `battery`
exists in both directions (in = warning LED, out = voltage). Tractor/boat entries are marked
`"status": "todo"` until M5/M6. Contract edits bump `version`; both sides warn on mismatch.

**Open question (plan §9.1, deferred to P3):** how the contract file is shared with the
sloppycan repo (submodule vs synced copy + CI hash check). Until then this repo's copy is the
only one.

## Standing rules (from plan §2 — every v1 lesson, permanent)

1. Static world geometry ships **baked per chunk** (merged meshes, one collision body per
   chunk); GridMaps are authoring-only. A drivable structure is never split across chunks.
   Bakes are hash-stamped; CI fails on stale bakes (check lands with the P6 bake tool).
2. Ground = heightmap/plane collision; drivable structures get dedicated welded collision
   meshes; props get boxes/hulls. **Trimesh is the exception, never the default.**
3. Telemetry is read out of the sim that produced the motion — no derived fictions (RPM comes
   from the drivetrain).
4. One contract file; everything else generated from or validated against it. Never
   hand-duplicate signal lists.
5. Vehicles consume one normalized `VehicleInput` from `InputRouter`; arbitration
   (bridge-active/gear-owns-direction, brake > accel > handbrake) lives **only** there.
6. Levels, vehicles, and UI are independent scenes composed by the shell — no giant main.tscn.
7. CI does the export; deploys are cache-busted. No manual deploy.
8. Pure logic (drivetrain math, contract encode/decode, arbitration, GPS/odometer, buoyancy)
   gets gdUnit4 tests.
9. `.web` project-setting overrides + perf budget from day one (msaa_3d.web=0, soft shadows
   off on web; do **not** set `scaling_3d/scale.web` below 1 — it adds an upscale pass on
   gl_compatibility and measures worse). Physics: **60 Hz + interpolation, locked** (§1).
10. **No emoji anywhere in UI** — the web font has no emoji glyphs; plain text + color only.

## License

Code MIT, assets CC0. Third-party adoptions (plan §7) are read line-by-line before landing
and credited in README.md.
