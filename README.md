# carlito2

Carlito v2 — a browser-based CAN-bus driving sandbox built with Godot 4.6. Drive vehicles
(car, truck, tractor, boat) while exchanging live CAN signals with the
[sloppyCAN](../sloppycan)/RAMN simulator through a postMessage bridge. Ground-up rebuild of
Carlito v1 with real vehicle physics (raycast suspension + simplified drivetrain), a single
shared signal contract (`contract/carlito_contract.json`), and CI-deployed web builds.

- **Plan of record:** [`version2_plan.md`](version2_plan.md) — architecture, milestones, rules.
- **Status:** M5 + level kit — car/truck/tractor with telemetry dashboard, web CAN bridge,
  ISOBUS implement signals, and the level-authoring kit (Kenney palettes/prefabs + chunk bake
  tool with CI stale-bake gate). See [`docs/making_a_level.md`](docs/making_a_level.md) to
  build a level without design skills.
- **Deployed build:** https://leaukojo.github.io/carlito2/
- **Dev docs:** [`CLAUDE.md`](CLAUDE.md) (how to run, test, export).

## License

Code is MIT (see [LICENSE](LICENSE)); bundled art/audio assets are CC0 (Kenney kits).

### Credits

- [Kenney](https://kenney.nl) (CC0) — the level-kit source models under `kit/raw/`:
  City Kit (Roads / Suburban / Commercial / Industrial), Racing Kit, and Watercraft Pack.
  Per-kit `License.txt` files are kept alongside the models.
- [gdUnit4](https://github.com/MikeSchulze/gdUnit4) (MIT) — vendored test framework at
  `addons/gdUnit4/`.
- [Dechode/Godot-Advanced-Vehicle](https://github.com/Dechode/Godot-Advanced-Vehicle) (MIT) and
  [Tobalation/GDCustomRaycastVehicle](https://github.com/Tobalation/GDCustomRaycastVehicle) (MIT)
  — studied as approach references for the raycast suspension / slip tires / drivetrain in
  `src/vehicles/base/` (plan §7); no code copied.
