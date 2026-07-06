# Carlito v2 — Prompting Guide

How to build v2 with Claude Code as a sequence of separate prompts instead of one mega-session.

**Why split at all (and why not context window):** Claude Code survives long sessions by
compacting context, so a "build everything" prompt wouldn't crash — it would *degrade*: every
compaction loses nuance, unverified physics stacks on unverified physics, and most token spend
goes to re-reading and re-deriving state, not writing code. The efficient unit of work is one
prompt per **verification gate** — a point where a human must drive the car, look at the browser,
or check sloppyCAN before the next step is safe to build. That is what this guide does. Bonus:
every session starts fresh and cheap if the repo's `CLAUDE.md` is good, so each prompt below ends
with "update CLAUDE.md".

## Ground rules for every prompt

1. **One prompt = one session.** Start a fresh session (or `/clear`) per prompt. Never chain two
   guide prompts in one session.
2. **Where to start Claude Code:** in the `carlito2` repo (created by P0) — with exactly two
   exceptions: P0 itself starts in the v1 repo (it copies the plan out), and P3 starts in the
   parent folder (`Desktop\EXPORTABLE`) to reach both carlito2 and sloppycan. Starting in carlito2
   is deliberate: sessions load only the new repo's small CLAUDE.md, never v1's.
3. **`version2_plan.md` is the spec.** P0 copies it into the new repo. Prompts reference its
   sections; don't paste plan content into prompts.
4. **Zero v1 code reuse.** If a prompt needs v1 behavior, it reads `version2_plan.md` §6 (the
   distilled behavior spec) — not the v1 source.
5. **Verify before moving on.** Each prompt lists "You verify" — do it (usually: play the build).
   If it fails, do a short follow-up in the *same* session, not a new prompt.
6. **Code review:** follow the `/code-review` protocol below — it defines per prompt when to
   review, at what effort, and whether to `/clear` first.
7. **Commit at the end of every prompt.** Small repo history = cheap future context.

### Choosing model / effort / mode (legend)

- **Model:** `Sonnet 5` = workhorse, cheapest of the capable tier — default for well-specified
  implementation. `Opus 4.8` = harder integration/debugging work. `Fable 5` (or the top model
  available to you) = architecture-heavy or novel-design prompts where a wrong start is expensive.
  Escalate only if a cheaper model visibly struggles; don't start high "just in case".
- **Thinking:** write `think hard` / `ultrathink` in the prompt to request extended thinking.
  Only worth paying for on design/debugging prompts, not scaffolding.
- **Mode:** **Plan Mode** (Shift+Tab) = have Claude present a plan you approve before it edits —
  use where the design has real degrees of freedom. **auto-accept edits** = fine for mechanical
  prompts you'll verify by running the result. Default (ask-per-edit) elsewhere.

### /code-review protocol

`/code-review` reviews the **current diff** (your uncommitted working tree — which survives
`/clear`; clearing wipes conversation, not files). Two modes, chosen per prompt:

- **Quick review (same session):** when the implementation finishes and tests are green, and
  *before committing*, run `/code-review medium --fix`, re-run tests, then commit. Same session
  because medium effort reports only high-confidence findings, and the session context makes the
  fixes cheap and well-informed. Session model is fine (Sonnet on Sonnet prompts).
- **Deep review (fresh session):** for the prompts where a subtle bug is expensive. Do **not**
  commit yet. `/clear`, switch the model to **Opus 4.8** if the session wasn't already on
  Opus/Fable, then `/code-review high --fix`, re-run tests, commit. The `/clear` is deliberate,
  for the same reason authors don't review their own PRs: a fresh session reviews the diff without
  inheriting the build conversation's assumptions — and it's cheaper, since the review doesn't
  drag the whole session behind it. Expect some uncertain findings at `high`; triage rather than
  auto-accepting everything.

| Prompt | Review | Why |
|---|---|---|
| P0 | quick (medium, same session) | scaffold + contract loader; CI smoke also gates it |
| P1a | **deep (high, fresh)** | physics core — subtle math bugs surface weeks later as "weird feel" |
| P1b | quick | level/terrain plumbing |
| P1c | none | data-only tuning |
| P2 | quick | telemetry derivations are unit-tested; review catches the rest |
| P3 | **deep (high, fresh)** — run it **twice**, once per repo (carlito2, then sloppycan) | async cross-repo bridge; each `/code-review` only sees the repo it runs in |
| P4a / P4b | quick | well-specified against plan §6 |
| P5a | none (quick only if framework code had to change) | data-only by design |
| P5b | quick, but run the carlito2 and sloppycan diffs separately | new signals, both repos |
| P6 | **deep (high, fresh)** | the bake tool fails *silently* (bad collision bakes) and every level depends on it |
| P7 / P9 | none | level content, verified by driving |
| P8 | **deep (high, fresh)** | buoyancy math + water/vehicle interactions |
| P10 | quick | perf tweaks, gated by re-profiling anyway |

Optional splurge: after P1a or P3 pass their deep review, commit to a branch and run
`/code-review ultra` on it — a billed, cloud multi-agent review. Only worth it on those two;
skip if budget is tight.

---

## The prompts

### P0 — Repo scaffold, CI, contract skeleton  *(plan M0)*

> Create a new Godot 4.x project in a sibling folder `../carlito2` (git init, own repo). Copy
> `version2_plan.md` from this repo into it, then implement plan §4.1 (folder layout, autoload
> stubs), §3 (contract/carlito_contract.json v2 draft covering every v1 signal plus rpm as a real
> signal — leave tractor/boat signals as TODO entries), a contract-loader autoload with gdUnit4
> tests, project settings per plan (Compatibility renderer, Jolt, .web overrides from day one),
> and the GitHub Actions workflow from §5.1 (headless web export + cache-busted deploy + headless
> smoke job). Write the new repo's CLAUDE.md: project purpose, layout, how to run/test/export,
> the standing rules from plan §2, and a note that v1 lives at `../carlito` as a *reference spec
> only* (observe its behavior when plan §6 is ambiguous — never read it to copy code). Finish by
> running the tests and the headless smoke locally.

- **Run with:** Fable 5 (or Opus 4.8), `think hard`, **Plan Mode** first.
- **Start in:** this (v1) repo, since it needs `version2_plan.md`.
- **You verify:** CI is green on GitHub; the deployed empty scene loads in your browser; `gdUnit4`
  suite passes. Decide open question §9.1 (submodule vs synced copy) when it asks.

### P1a — Vehicle physics core (car on a flat plane)  *(plan M1, part 1)*

> Read version2_plan.md §4.4 and §6 ("Input & gear logic"). Implement BaseVehicle, VehicleSpec,
> raycast suspension wheels, slip-based tires, and the simplified drivetrain (torque curve, gear
> ratios, real RPM), plus InputRouter with the keyboard/gamepad source only. The physics tick is
> locked at 60 Hz + interpolation (plan §1) — architect the suspension for that rate; if it can't
> be made stable at 60 Hz, stop and say so rather than silently raising the tick. Test scene: flat
> plane + one car. Unit-test the drivetrain math and gear-byte semantics. Before writing the
> suspension/tire code, review the MIT projects in plan §7 for approach (verify their licenses;
> credit anything adapted). Chase camera + respawn included. ultrathink.

- **Run with:** Fable 5, `ultrathink`, **Plan Mode** first. This is the highest-risk prompt in the
  project — a wrong tire/suspension architecture poisons everything after it.
- **You verify:** drive it (desktop). It should accelerate, shift, brake to a stop with both
  pedals floored, and not flip on a lane change. Feel will be rough — that's P1c.

### P1b — Dev gym level + terrain  *(plan M1, part 2)*

> Read version2_plan.md §4.5. Implement the Level base scene + LevelInfo resource + spawn markers,
> heightmap terrain support (image import → mesh + HeightMapShape3D), and build the dev gym level:
> flat zone, ramps, a hill from the terrain system, friction strips, slalom cones, and an empty
> pool basin for later water tests. Wire the shell minimally: boot straight into the gym with the
> car.

- **Run with:** Sonnet 5, no extended thinking, auto-accept edits.
- **You verify:** drive every gym feature; specifically confirm **no ghost collisions** on
  ramp/terrain transitions (that's the point of the v2 collision rules).

### P1c — Feel tuning (interactive, repeatable)

> The car currently feels [describe: e.g. "floaty on bumps, spins out at low speed"]. Read the
> VehicleSpec and suspension/tire code, propose 2–3 parameter changes at a time, and iterate with
> me: I will drive after each change and report back.

- **Run with:** Sonnet 5, no extended thinking, default mode. Short sessions, run as often as
  needed — now and after every new vehicle. Cheap because it's data-only (`VehicleSpec`) changes.
- **You verify:** you're the instrument here. Stop when it's fun; plan's tiebreaker is fun > accurate.

### P2 — Telemetry + contract-driven dashboard  *(plan M2)*

> Read version2_plan.md §3, §4.4, §4.6 and §6 ("UI & platform"). Implement the VehicleTelemetry
> struct published by BaseVehicle (all contract "out" signals: real rpm/gear/slip, GPS mapping per
> §6, odometer, fuel/coolant, status bitfield), and the dashboard cluster per §4.6's split:
> tell-tale row and bars *generated* from contract metadata; the two radial gauges *hand-built*
> (text in the arc's bottom gap) but reading range/redline from the contract — do not build a
> generic dashboard-from-JSON framework. Gear/ignition flags too. Plain text only, no emoji.
> Unit-test telemetry derivations. Add a debug overlay (FPS, draw calls) toggle.

- **Run with:** Sonnet 5, `think hard` (the contract-driven UI generation deserves it), default mode.
- **You verify:** dashboard values track what the car is doing; edit a range in the contract JSON
  and confirm the gauge follows without code changes.

### P3 — Web bridge + sloppyCAN contract consumption  *(plan M3)*

> Two repos are involved: carlito2 (Godot) and sloppycan (JS). Read version2_plan.md §3, §4.2 and
> §6 ("Input & gear logic"). Godot side: implement the bridge autoload (postMessage in/out via the
> export head-include, freshness gate ~300 ms, poll ~60 Hz / publish ~20 Hz, is_active()), the
> bridge InputSource with the arbitration rules from §6, all field names from the contract. JS
> side: update carlito.js to consume the shared contract file (message fields + CAN packing
> checked against it), including the version-mismatch console warning. Decide with me how the
> contract file is shared between repos if P0 left it open. think hard.

- **Run with:** Opus 4.8 or Fable 5, `think hard`, **Plan Mode** first. Cross-repo + async browser
  debugging = the second-riskiest prompt.
- **Start in:** the common parent folder (`Desktop/EXPORTABLE`) so both repos are reachable; name
  both paths in your first message.
- **You verify:** end-to-end with the sloppyCAN emulator in the browser: RAMN controls drive the
  car (gear owns direction, brake beats accel), telemetry frames appear in sloppyCAN, and real RPM
  moves with the drivetrain.

### P4a — Lamps, horn, day/night  *(plan M4, part 1)*

> Read version2_plan.md §6 ("Lamps & LEDs") — implement it exactly: scene-authored head/brake/turn
> lamps driven by VehicleSpec-declared positions, tri-state brake lamps, verbatim blink mirroring
> (no local blink timer), warning LEDs defaulting off. Plus the procedural horn (rising-edge from
> any input source) and day/night toggle.

- **Run with:** Sonnet 5, no extended thinking, default mode.
- **You verify:** with sloppyCAN driving lamp state: turn signals blink at the source rate, brake
  lamps show STOP/TAIL/OFF correctly, lamps never fully disappear.

### P4b — Touch controls + garage menu + level select shell  *(plan M4, part 2)*

> Read version2_plan.md §4.6. Implement touch controls (joystick, pedals, right-edge button stack)
> as an InputSource; the garage menu reading LevelInfo.allowed_vehicles and respawning the player
> at a matching spawn marker; and the shell's level-select screen reading the level registry.
> Plain-text labels, no emoji. Hide bridge-conflicting buttons while the bridge is active.

- **Run with:** Sonnet 5, no extended thinking, default mode.
- **You verify:** web build on a phone/touch device; parity checklist from plan §6 — after this
  prompt, everything v1 does should work in v2 (with only the gym level).

### P5a — Truck  *(plan M5, part 1)*

> Add the truck: new VehicleSpec + model scene (CC0 Kenney asset), heavier tuning, slower
> steering. No new systems — if the vehicle framework requires code changes to add it, flag that
> as a framework bug and fix the framework instead.

- **Run with:** Sonnet 5 (Haiku 4.5 is plausible if the framework is clean), auto-accept edits.
  This prompt doubles as the *test* that vehicles are data-driven.
- **You verify:** truck drives, dashboard/bridge/garage all work with it unchanged. Follow with a
  P1c-style tuning session.

### P5b — Tractor + implement + ISOBUS signals  *(plan M5, part 2)*

> Read version2_plan.md §1 (Machinery), §3 (ISOBUS flavor), §4.4 (Tractor implement). Implement
> the tractor spec, the Implement node + hitch socket (raise/lower animation, PTO on/off, engine
> load), the isobus-flavored contract signals, and their carlito.js side (per the P3 sharing
> mechanism). Dashboard shows implement state via contract metadata.

- **Run with:** Opus 4.8, `think hard`, **Plan Mode** first (new signal territory + touches both repos).
- **You verify:** hitch/PTO controllable from sloppyCAN, state visible on dash and in CAN frames.

### P6 — Level kit + bake tool + authoring doc  *(plan §4.5)*

> Read version2_plan.md §4.5 and, for asset-kit knowledge only (not code), v1's CLAUDE.md
> MeshLibrary registry [paste the registry table into the prompt]. Build the level-authoring kit:
> GridMap palettes from the CC0 Kenney kits, prefab library, @tool marker helpers, the bake tool
> per plan §2 rule 1 and §4.5 (merge static meshes per chunk with a tunable chunk size; one
> collision body per chunk, but any drivable structure — bridge, ramp, pier — welded into a
> single body even when it spans chunk borders; spawn validation; stamp each bake with an input
> hash and add the CI stale-bake check from §5.1), and write docs/making_a_level.md as a
> step-by-step walkthrough for a non-designer.

- **Run with:** Fable 5 or Opus 4.8, `think hard`, **Plan Mode** first. Editor tooling +
  import-pipeline judgment; the GodotPrompter tools-engineer agent is a good fit if offered.
- **You verify:** follow `making_a_level.md` yourself, end to end, and produce a small drivable
  level without asking Claude anything. That *is* the acceptance test. Make your test level
  include a ramp or bridge that spans a chunk border and drive across it — chunk-seam ghost
  collisions are exactly the failure mode the bake tool exists to prevent. Also repaint one
  GridMap cell *without* re-baking and confirm CI (or the local check) fails on the stale bake.

### P7 — Farm level  *(plan M5 close-out)*

> Using the level kit per docs/making_a_level.md, build the farm level: heightmap fields, dirt
> roads, barn, fences, tractor + implement spawns, car/truck spawns. Then run the bake tool and
> fix anything the kit made awkward — kit fixes matter more than this level's art.

- **Run with:** Sonnet 5, no extended thinking, auto-accept edits. (Or build it yourself with the
  doc — that's the better test — and only prompt for what annoyed you.)
- **You verify:** tractor showcase works end-to-end from sloppyCAN.

### P8 — Water + boat + harbor level  *(plan M6)*

> Read version2_plan.md §4.4 (Boat), §4.5, §8 (water risks), then CLAUDE.md's "Machinery" section —
> the tractor is the template for adding a vehicle subclass, follow it exactly. Implement:
> 1. Water height API in `src/water/` — flat `get_height(pos) = const` at launch; visual waves are
>    shader-only and must NOT feed physics.
> 2. `BoatVehicle extends BaseVehicle` using ONLY the two existing virtual seams
>    (`_make_telemetry()` returning a `BoatTelemetry extends VehicleTelemetry`, and
>    `_tick_extras(input, delta)` for buoyancy/thrust/rudder). Do not fork `_physics_process` and
>    do not add new seams to BaseVehicle without flagging it first. Buoyancy = 4–6 probes, pure
>    static math fns (per-probe force from depth), unit-tested in `tests/test_boat.gd` like
>    Drivetrain. Respect the 60 Hz locked tick: clamp per-probe force per tick the same way
>    RayWheel clamps suspension (no unclamped spring forces).
> 3. Contract v5: fill the boat `todo` signals (they already exist as entries — edit, don't add
>    duplicates; signals are unique by (name, dir)). Bump `version`, then run
>    `node tools/gen_js_contract.mjs` to regen the sloppyCAN copy.
> 4. `BoatTelemetry.to_bridge_dict()` = `super()` + boat fields named exactly as the contract —
>    the existing `test_telemetry` coverage gate must stay green. Dashboard needs no new code if
>    boat signals carry proper range/warn metadata (bars/lamps are contract-generated).
> 5. Wiring: `boat` entry in `Level.VEHICLE_SCENES`; spawns use the existing
>    `VehicleSpawn.is_water` flag; non-boat entering water = kill/respawn volume (reuse the
>    respawn path, which already zeroes accel history). Give the gym pool water for regression.
> 6. Harbor level: author per docs/making_a_level.md with the watercraft kit (2x scale), bake with
>    `res://tools/bake_levels.tscn` (game-mode tool scene, NOT --script), register in
>    `LevelRegistry.LEVELS`, and confirm `res://tools/check_bakes.tscn` passes.
> Drive tuning goes in `boat_spec.tres` (a plain VehicleSpec); boat-node behaviour knobs are
> `@export` on BoatVehicle, like the tractor's hitch knobs. think hard.

- **Run with:** Opus 4.8 or Fable 5, `think hard`, **Plan Mode** first (buoyancy is the one
  genuinely novel physics piece left).
- **You verify:** boat floats, pitches under throttle, rolls in turns — and does NOT explode or
  jitter at rest (the clamp check); car driven off the dock respawns; gym pool now holds water;
  boat gauges/bars appear on the dash with no dashboard code changes; sloppyCAN shows the boat
  signals and warns on neither side (contract versions match after the regen).

### P9 — Island remake  *(plan M7, part 1)*

> Follow docs/making_a_level.md exactly (kit_demo is the worked example) to rebuild the v1 island
> as a v2 level: city grid, racing circuit, suburbs, mainland skyline backdrop. Match v1's layout
> spirit (run the deployed v1 for reference — never read its source), not its geometry exactly.
> Kit rules that bite here: everything lives under ONE AuthoringRoot; GridMap palettes only for
> road/tile kits (all palette GridMaps need `cell_center_y = false`; roads cell is (8,2,8),
> racing is (10,10,10)); everything else is a KitPiece prefab with the right `collision_mode` —
> drivable structures (the circuit's bridges/ramps) must be `weld`, props box/hull, never trimesh.
> The racing kit's v1 corner-anchor profile and bridge y-offsets were flagged "re-verify at
> island" — check corner tiles line up before painting the whole circuit. Do NOT regenerate
> palettes/prefabs (`gen_kit_assets.gd`) unless a recipe actually changes. All vehicle types
> spawnable except boat unless a coastline water region fits naturally. Finish: bake with
> `res://tools/bake_levels.tscn`, register in `LevelRegistry.LEVELS`, confirm
> `res://tools/check_bakes.tscn` and a headless smoke of the level (`CARLITO_LEVEL=<id>`) pass.

- **Run with:** Sonnet 5, auto-accept edits. Art-labor, not design.
- **You verify:** side-by-side with deployed v1: everything you can do there works here, but
  faster (check the FPS/draw-call overlay against plan §5.4's budget).

### P10 — Perf pass + launch + retire v1  *(plan M7, part 2)*

> Read version2_plan.md §5.4 and CLAUDE.md. Profile the DEPLOYED web build first — use the F3
> debug overlay (FPS / frame ms / draw calls / primitives / VRAM) in the worst view of each level;
> the guardrail is < ~500 draw calls. Only fix what a measurement shows missing the budget —
> measure, change ONE thing, re-measure; no speculative optimization. Hard constraints: physics
> stays 60 Hz + interpolation (never touch the tick); do NOT set `scaling_3d/scale.web` below 1
> (it adds an upscale pass on gl_compatibility and measures WORSE); `.web` overrides
> (msaa_3d.web=0, soft shadows off) already exist — check they still apply before adding new ones.
> If a level is heavy on draw calls, suspect its bake (chunk count / material dedup) before
> touching renderer settings. Then launch: deploy via CI (never manual — plan §2 rule 7), update
> both repos' READMEs, set up the v1 URL redirect to v2. Stretch (only if budget already met):
> custom export template with unused modules stripped to shrink the wasm.

- **Run with:** Opus 4.8, `think hard`, default mode. Profiling-driven work; the
  performance-profiler agent is a good fit if offered.
- **You verify:** all four levels playable at 60 fps on your machine in the deployed build; v1
  URL redirects; hard-reload not required after redeploys (the P0 cache-busting proves itself).

---

## Cost picture

Roughly: 4 expensive prompts (P0, P1a, P3, P6 — top model + Plan Mode + extended thinking), 3
medium (P2, P5b, P8, P10), the rest cheap Sonnet sessions, plus unbounded-but-tiny P1c tuning
loops. The expensive ones are expensive because being wrong there costs multiples later. If a
budget week hits, everything marked Sonnet also *works* on Sonnet with Plan Mode added — you trade
your review time for tokens.

Sequencing is mostly strict (P0 → P1a → P1b → P2 → P3 → P4x), but after P4: P5a/P5b/P6 can
interleave, P7 needs P5b+P6, P8 needs P6, P9 needs P6, P10 is last.
