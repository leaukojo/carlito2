# Carlito v2 — Plan

Carlito v2 is a ground-up rebuild of the CAN-bus driving sandbox: same end goal (drive vehicles in
a browser, exchange live CAN frames with sloppyCAN/RAMN), none of the v1 design debt. This document
is the plan of record: locked decisions, target architecture, development process, and the v1
behavior that must be re-implemented.

**Ground rule: zero code reuse from v1.** The v1 repo (this one) and its deployed build serve as a
*reference specification* — we read it to learn what the behavior must be (see §6), never to copy
code. Third-party MIT/permissive code may be adopted (§7).

---

## 1. Locked decisions

| Topic | Decision |
|---|---|
| Car physics | Custom **raycast suspension** (one ray/wheel, slip-based grip) + **simplified drivetrain** (engine torque curve, gear ratios, clutch-less shifts). RPM/gear/slip telemetry come out of the sim, not derived from speed. |
| Code license | MIT/permissive OK (repo stays MIT). Assets stay CC0. |
| Level authoring | Godot editor + a prepared **level kit**: inherit a `Level` base scene, paint GridMap palettes, drag prefabs, place marker helpers. No coding, no external editor. |
| Vehicle switching | **Garage menu** UI; the level declares which vehicles are allowed and where they spawn (incl. water spawns). Picking one respawns you as it. |
| Machinery | Tractor + **one attachable implement**. Hitch raise/lower, PTO on/off, engine load, implement status exposed as ISOBUS/J1939-flavored signals over the bridge. Visuals minimal. |
| Boat | **Probe buoyancy**: 4–6 float probes sample the water surface height and push the hull up; thrust + rudder. Pitch/roll are real telemetry. |
| Platforms | **Web-first** (deployed build embedded by sloppyCAN, postMessage bridge). Desktop native is dev/test only, bridge inert there. |
| Repo | **Fresh Godot project, zero v1 code reuse.** V1 stays deployed until v2 reaches parity, then is retired. |
| CAN contract | **One shared signal-contract JSON** consumed by both repos; updating sloppyCAN's `carlito.js` to read it is in scope. |
| Launch levels | Dev gym (first), then island remake, farm, harbor — all four ship at launch. |
| Terrain | **Gentle heightmap terrain** supported per level (`HeightMapShape3D` collision — cheap and ghost-collision-free by design). |
| Physics tick | **60 Hz + physics interpolation, locked.** Suspension/tire tuning starts at this rate (M1) and the tuning is rate-dependent — changing the tick later means re-tuning every vehicle, so it is not revisited casually. |
| Parity bar | **Full v1 feature parity at launch** (dashboard, touch, horn, day/night, all lamps, respawn, all bridge signals) plus the new vehicles/levels. |

Non-goals for v2 launch: multiplayer, in-game level editor, walk-around character, working farm
simulation (crops/ground effects), full wave simulation, mobile app stores.

---

## 2. Lessons from v1 → v2 rules

Each v1 problem becomes a standing rule, not a one-off fix:

1. **Map-wide GridMaps with default octants** → draw calls scaled with the whole map and every
   octant boundary was a physics-body seam (ghost collisions).
   *Rule:* static world geometry is **baked per chunk** — merged meshes, **one collision body per
   chunk**. GridMaps are an *authoring* surface; a bake step (tool script) produces what ships.
   Two corollaries, because chunks inherit octants' failure modes: **(a) chunk borders are still
   body borders** (Jolt's internal-edge removal never works across bodies), so a drivable
   structure — bridge, ramp, pier — is **never split across chunks**: its collision is welded
   into one body even when it spans chunk borders (drivable *ground* is already seamless via the
   heightmap/plane rule below); **(b)** merging trades frustum culling for batching, so the bake
   tool exposes a **chunk-size knob** and the §5.4 draw-call budget is the guardrail. And **stale
   bakes are the new stale build**: bake output is stamped with a hash of its authoring inputs,
   and CI fails when they diverge (§5.1) — "repainted the GridMap, forgot to re-bake" must be
   impossible to ship.
2. **Collision = whatever the importer baked per render mesh** → trimesh everywhere, seams, ghost
   collisions. *Rule:* ground is heightmap or plane collision; drivable structures get dedicated
   simplified collision meshes (welded, no interior edges); buildings/props get boxes/convex hulls.
   Trimesh is the exception, never the default.
3. **Sphere-cast arcade physics** → RPM, gear, slip were *derived fictions*, weakening the CAN
   story. *Rule:* telemetry values are read out of the simulation that actually produced the
   motion.
4. **CAN contract hand-duplicated** in `web_input.gd`, `carlito.js`, and the dashboard → drift
   risk, three places to edit. *Rule:* one contract file, everything else generated from or
   validated against it (§4.2).
5. **`vehicle.gd` read input autoloads directly** with priority logic tangled inline. *Rule:*
   vehicles consume one normalized input struct from an input-router; priority/arbitration lives in
   exactly one place (§4.4).
6. **One giant `main.tscn`** owning world + vehicle + UI. *Rule:* levels, vehicles, and UI are
   independent scenes composed at runtime by a small game shell (§4.6).
7. **Manual export/deploy + hard browser cache** → stale-build confusion. *Rule:* CI does the
   export; deploys are cache-busted (§5.1).
8. **No tests** → every regression found by driving around. *Rule:* pure logic (drivetrain math,
   contract encode/decode, gear/input arbitration) is unit-tested with gdUnit4 (§5.2).
9. **Web perf discovered late** (fillrate, MSAA/HiDPI). *Rule:* `.web` project-setting overrides
   and a perf budget exist from M0; the FPS/draw-call overlay is always available.
10. **Emoji in UI rendered as tofu on web.** *Rule:* plain text + color only in all UI (§6).

---

## 3. The signal contract (heart of the project)

A single `contract/carlito_contract.json` (its own small repo or a folder synced into both repos)
defines every signal crossing the bridge:

```json
{
  "version": 2,
  "signals": [
    { "name": "rpm",       "dir": "out", "type": "u16", "unit": "rev/min", "range": [0, 8000], "vehicles": ["car","truck","tractor"] },
    { "name": "hitch_pos", "dir": "in",  "type": "u8",  "unit": "%",       "range": [0, 100],  "vehicles": ["tractor"], "flavor": "isobus" },
    { "name": "gear",      "dir": "in",  "type": "u8",  "unit": "enum",    "enum": { "0": "N", "1-6": "D1-D6", "255": "R" } }
  ]
}
```

- **Godot side:** an autoload loads the JSON at startup; the bridge marshals messages from it, the
  dashboard builds its tell-tales/gauges from it, and a gdUnit4 test fails if code references a
  signal the contract doesn't define.
- **sloppyCAN side:** `carlito.js` imports the same file for message field names; CAN frame
  packing (IDs, byte layout) stays defined there but is generated/checked from the contract too.
- **Change protocol:** contract edits bump `version`; both sides log a console warning on
  version mismatch instead of failing silently (the v1 "old bridge omits field → default off"
  behavior becomes systematic).
- **ISOBUS flavor:** tractor/implement signals are tagged `"flavor": "isobus"` and named after
  their ISO 11783/J1939 concepts (hitch position, PTO state/RPM, engine load). Whether sloppyCAN
  emits them as 29-bit extended-ID frames is an open sloppyCAN-side question (§9) — the Godot side
  only cares about the signal list.

Vehicle telemetry set (superset of v1): speed, **real** rpm/gear, throttle/brake/steer as applied,
per-axle slip, pitch/roll (boat!), heading, GPS-mapped position, odometer, fuel, coolant, status
bitfield, impact events, plus per-vehicle-type extras (hitch/PTO for tractor, rudder/trim for boat).

---

## 4. Architecture

### 4.1 Project layout

```
carlito2/
  project.godot
  contract/            # the shared JSON (submodule or synced copy)
  src/
    shell/             # game shell: boot, level select, garage menu
    bridge/            # CAN bridge autoload + contract loader
    input/             # InputRouter + sources (keyboard, touch, bridge)
    vehicles/
      base/            # BaseVehicle, VehicleSpec resource, wheel/suspension, drivetrain
      car/  truck/  tractor/  boat/
    levels/
      base/            # Level base scene, markers, level metadata resource
      gym/  island/  farm/  harbor/
    ui/                # dashboard, touch controls, menus
    water/             # water surface + height sampling API
  kit/                 # level-authoring kit: meshlibs, prefabs, @tool helpers, bake tool
  tests/               # gdUnit4
  tools/               # editor scripts (bake, import), CI helpers
```

Autoloads stay minimal: `Contract`, `Bridge`, `InputRouter`, `GameState` (current level/vehicle).
Everything else is scene-composed.

### 4.2 Bridge

Same transport as v1 (postMessage in, postMessage out, values stashed on a JS global read via
`JavaScriptBridge`), re-implemented cleanly:

- Web-only; on desktop the bridge reports "inactive" and the game runs on local input.
- Freshness-gated (~300 ms) so stale data never clobbers local input; `is_active()` drives UI
  (e.g. hiding the manual lights button).
- Throttled crossings (poll in ≈60 Hz, publish out ≈20 Hz) — v1 got this right; keep the numbers.
- All field names come from the contract; no hand-written string lists.

### 4.3 Input pipeline

`InputRouter` merges three `InputSource`s — keyboard/gamepad, touch, bridge — into one normalized
`VehicleInput` struct (throttle, brake, steer, handbrake, gear request, key position, aux buttons).
Arbitration rules (bridge-active + in-gear ⇒ bridge owns direction; brake > accel > handbrake feel
hierarchy — see §6) live *only* here. Vehicles never know which source is active.

### 4.4 Vehicle framework

- **`BaseVehicle`** (RigidBody3D root): consumes `VehicleInput`, publishes a `VehicleTelemetry`
  struct each physics tick, owns lamp state application and common gear/key logic. Camera targets
  and spawn/respawn logic are part of the base contract.
- **`VehicleSpec`** (custom Resource): all tuning — mass, wheel positions, suspension
  spring/damper, tire grip curves, engine torque curve, gear ratios, lamp positions. New vehicle =
  new spec + model scene; **lamp placement is scene-authored** (v1's late win, kept as design).
- **Wheels:** raycast suspension per wheel (spring-damper on ray length), longitudinal/lateral
  slip-based friction. Tractor = same system, different spec (big soft wheels, low gearing, speed
  cap); truck = heavier spec, slower steering.
- **Drivetrain:** engine torque curve → gearbox (ratio per gear, RAMN gear byte semantics) → drive
  axle. RPM follows wheel speed through the ratio with idle/redline clamps and load response.
  Deliberately clutch-less and diff-less at launch.
- **Tractor implement:** an `Implement` node attachable to the tractor's hitch socket; exposes
  hitch position (animated), PTO on/off, and status through tractor telemetry.
- **Boat:** same `BaseVehicle` contract, different locomotion module — buoyancy probes query the
  `water/` height API, thrust at stern, rudder torque. Water height API starts flat (visual waves
  stay visual); feeding real wave height into the probes is a post-launch option.

### 4.5 Levels

- **`Level` base scene + `LevelInfo` resource:** display name, allowed vehicles, spawn markers
  (`VehicleSpawn` with type filter, incl. water spawns), optional terrain node, environment
  (day/night settings), water region.
- **Authoring workflow (the "minimum game-design skills" promise):** duplicate the level template →
  sculpt/import a heightmap (optional) → paint roads/props from the kit's GridMap palettes and
  prefab library → drop spawn markers → fill in `LevelInfo` → run the **bake tool** (merges static
  meshes per chunk with a tunable chunk size, builds one collision body per chunk — keeping any
  drivable structure in a single body even across chunk borders — validates spawns, and stamps the
  output with an input hash for the CI freshness check, per §2 rule 1). A `docs/making_a_level.md`
  walkthrough with screenshots is part of the deliverable.
- **Kit content:** re-import the CC0 Kenney kits with the v1 importer's *lessons* (alignment
  profiles, per-kit cell sizes, collision modes are documented in v1's CLAUDE.md registry — reuse
  the knowledge, re-run the process cleanly).
- **Loading:** the shell loads level scenes by path from a registry; levels are self-contained, so
  *your own* extra levels are just `.tscn` + baked resources dropped into a folder. **Third-party
  level sharing is out of scope for launch:** a `.tscn` can embed scripts, so loading a stranger's
  level is arbitrary code execution — don't advertise "community levels" until there's a
  validation/sandboxing story.

### 4.6 Game shell & UI

- Shell: boot → level select → load level → spawn default vehicle → play. Garage menu (allowed
  vehicles from `LevelInfo`) respawns the player as the chosen vehicle at a matching spawn marker.
- **Dashboard is contract-informed, not a UI generator:** the tell-tale row and the bars are
  *generated* from contract signal metadata (name, range, warn thresholds) — a new simple signal
  appears on the dash by editing JSON. The two radial gauges are **hand-built** widgets (there are
  two of them, not a family) that *read* their range/redline from the contract. Building a generic
  dashboard-from-JSON framework for one game is over-engineering; generate the repetitive parts,
  hand-craft the bespoke ones.
- Touch controls: joystick + pedals + right-edge button stack, as v1, rebuilt on the InputRouter.
- Rendering: Compatibility renderer, `.web` overrides (MSAA off, reduced shadow atlas, HiDPI cap)
  present from M0.

---

## 5. Process

### 5.1 Repo, CI, deploy

- New repo (`carlito2` or similar), Godot 4.x (latest stable at kickoff), Jolt physics,
  `gl_compatibility`.
- GitHub Actions from M0: headless web export on every push to main; deploy to the Pages site with
  **cache-busted filenames** (hash in the pck/wasm names or the PWA service worker) so "stale
  deployed build" can't happen; a smoke job that boots the game headless and fails on script errors.
  Once the bake tool exists, the same job also fails on **stale level bakes** (compares each bake's
  input hash against the current authoring scenes — §2 rule 1).
- The contract folder is shared with the sloppycan repo (git submodule, or a copy checked by CI
  hash comparison — decide at M0).

### 5.2 Testing

- **gdUnit4** for pure logic: drivetrain math (torque/ratio/RPM), gear-byte semantics, input
  arbitration rules, contract loading/validation, GPS/odometer mapping, buoyancy math.
- **Feel** is verified by driving (dev gym has ramps, friction strips, a wet pool, slalom cones —
  built for this) — manual, but scripted: each milestone lists the drive checks.
- **Contract conformance:** a test on each side fails if code references undefined signals.

### 5.3 Milestones

Each milestone ends with a verifiable state; don't start the next until verified.

- **M0 — Scaffold.** New project, folder layout, autoload stubs, CI export+deploy+smoke, contract
  v2 draft file + loader + tests, `.web` overrides. *Verify: CI-deployed empty scene loads in
  browser; contract test suite green.*
- **M1 — Car on gym (local input).** Raycast car + drivetrain, keyboard/gamepad via InputRouter,
  dev gym level with terrain patch, chase camera, respawn. *Verify: drives ramps/slopes without
  ghost collisions; unit tests for drivetrain; feels controllable at 60 fps desktop.*
- **M2 — Telemetry + dashboard.** Full telemetry struct, contract-driven dashboard cluster.
  *Verify: dash shows real RPM/gear/slip; values match sim state in tests.*
- **M3 — Bridge + sloppyCAN.** Web bridge both directions; `carlito.js` updated to consume the
  contract; RAMN controls drive the car; telemetry appears as CAN frames. *Verify: end-to-end with
  sloppyCAN emulator — every v1 signal works, plus real RPM.*
- **M4 — Parity.** Lamps (head/brake/turn per §6 rules), horn, day/night, touch controls, garage
  menu shell, fuel/coolant accumulation. *Verify: v1 parity checklist (§6) all green in the web
  build; v1 can be retired once island ships.*
- **M5 — Truck + tractor.** Two new specs; implement + hitch/PTO ISOBUS signals; farm level
  (first real level, exercises the level kit + authoring doc). *Verify: a non-programmer follows
  `making_a_level.md` and produces a drivable level; ISOBUS signals visible in sloppyCAN.*
- **M6 — Boat + harbor.** Water height API, buoyancy boat, water spawns, harbor level. *Verify:
  boat floats/pitches/rolls, telemetry sane; car falls in water and respawns.*
- **M7 — Island remake + launch.** Island rebuilt with the kit — the road deliberately routed to
  make telemetry perform (a long grade for engine_load, hairpins for slip, a crest for the impact
  bit, a dark stretch for lights; no missions — the sandbox is the CAN telemetry, and the level's
  job is to make it visible and fun) — level select UI, perf pass against budget, docs, retire v1
  (redirect). *Verify: all four levels playable in deployed web build; perf budget met; v1 URL
  redirects.*
- **Launch polish — engine audio (deliberately last).** An RPM-driven procedural engine loop per
  vehicle: the horn already proves the pattern (synthesized AudioStreamWAV, zero assets) and the
  drivetrain RPM is real (§2 rule 3), so the seam is one audio player on BaseVehicle with pitch
  from rpm and gain from throttle/load — no architecture change, which is why it can safely wait.
  Boat wind/engine and tractor PTO whine follow the same pattern. Nothing may depend on this
  item; it lands after the perf pass. *Verify: engine pitch follows the tacho through the gears;
  silent in menus.*

### 5.4 Perf budget (checked from M1, hard-gated at M7)

Web build on a mid-range laptop: 60 fps, < ~500 draw calls in the worst view, physics tick 60 Hz
with interpolation (**locked**, §1 — the tuning depends on it), initial download smaller than v1
(custom export template with unused modules stripped is an M7 stretch item).

---

## 6. V1 behavior spec (re-implement, don't port)

Debugged rules from v1 that must survive the rewrite — the "reference spec" distilled. When in
doubt, run v1 and observe.

**Input & gear logic**
- Gear byte: `0x00`=N, `0x01..0x06`=D1–D6, `0xFF`=R. While bridge is active and not Neutral, the
  gear **owns direction**: throttle is signed by gear, local reverse inputs ignored.
- Throttle comes only from the accelerator; **brake is never throttle**. Full accel + full brake
  must come to a stop (brake slightly stronger than accel). Handbrake is weaker than accel: holds
  only below ~25% throttle. Key must be in Ignition for throttle.
- Bridge input is freshness-gated (~300 ms); no fresh data ⇒ local input works untouched.

**Lamps & LEDs**
- sloppyCAN is the **sole authority on lamp state**; the RAMN `0x1BB` status bitfield is the sole
  source of blinking. Turn signals blink *at the source* — the game mirrors bits verbatim and
  **never adds its own blink timer**.
- Rear lamps are tri-state: STOP (bright, from brake bit) > TAIL (mid, when headlights ≥ clearance)
  > OFF (dim housing, never invisible). Turn lamps: lens visible when off (dark amber), independent
  left/right materials. Headlights: off/clearance/low/high with distinct energy/range.
- Warning LEDs (check-engine, battery) default **off** when the bridge doesn't send them.

**UI & platform**
- **No emoji anywhere in UI** (web font has no emoji glyphs); plain text + color.
- Dashboard mirrors every input the bridge can send, so state (e.g. parking brake) is always
  visible. Gauge text sits in the arc's bottom gap so the needle never overlaps it.
- Telemetry GPS maps world XZ to lat/lon around the Paris origin (48.8566, 2.3522).
- Browsers cache the web build hard — solved structurally this time (§5.1), but hard-reload remains
  the debugging reflex.

---

## 7. Third-party code to evaluate (MIT — verify license & Godot-4 compatibility at kickoff)

- **Dechode / Godot-Advanced-Vehicle** — raycast suspension + drivetrain in GDScript; closest
  existing shape to our target. Study or adapt.
- **tobalation / GDSim** — semi-realistic vehicle sim; reference for drivetrain/tire math.
- **Godot "Truck Town" demo** — feel reference for `VehicleBody3D`-style handling (not adopting
  the node, but useful for tuning expectations).
- **gdUnit4** — test framework (MIT).
- Buoyancy: simple enough to write from the standard probe pattern; no dependency needed.

Rule: anything adopted gets read and understood line-by-line before it lands (same standard as
LLM-generated code in v1), and credited in the README.

---

## 8. Risks

| Risk | Mitigation |
|---|---|
| Vehicle feel worse than v1's (tuned) arcade sphere | Dev gym + feel checks at every milestone; keep v1 deployed for A/B until M7. |
| Physics tuning rabbit hole (biggest schedule risk) | Timebox tuning per vehicle; VehicleSpec makes iteration data-only; "fun > accurate" tiebreaker. |
| Two-repo contract coordination stalls | Contract versioned + warning-on-mismatch; either side can ship ahead safely. |
| Heightmap terrain + web perf | Terrain is per-level optional; gym proves it early (M1) at web budget. |
| Boat/water interactions edge cases (car drives into sea) | Water region defines kill/respawn volume for non-boats from M6. |
| Scope creep on farm sim / ISOBUS depth | §1 non-goals; implement = signals + minimal animation, nothing else at launch. |
| Four levels at launch is a lot of content | Descope order is fixed in advance: cut **harbor**, then **farm**, before ever cutting level-kit rework — levels are content, the kit is the product. The M5 authoring gate (non-programmer builds a level) is the decision point. |

---

## 9. Open questions (decide during M0–M3, none block kickoff)

1. Contract sharing mechanism: git submodule vs synced copy with CI hash check.
2. ISOBUS framing on the sloppyCAN side: 29-bit extended IDs (proper J1939) vs stuffing into the
   existing 11-bit scheme — sloppyCAN/RAMN decision; Godot side is agnostic.
3. ~~Physics tick rate~~ — **decided (2026-07): 60 Hz + interpolation, locked** (§1). Decided
   *before* tuning starts because suspension tuned at one tick rate feels different at another;
   re-opening this after M1 means re-tuning every vehicle.
4. Terrain authoring: hand-sculpt @tool brush vs image import only (start with image import).
5. Whether the RAMN firmware itself gains tractor/boat frames or they stay emulator-only.
