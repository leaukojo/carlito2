# carlito2

Carlito v2 — a browser-based CAN-bus driving sandbox built with Godot 4.6. Drive vehicles
(car, truck, tractor, boat) while exchanging live CAN signals with the
[sloppyCAN](../sloppycan)/RAMN simulator through a postMessage bridge. Ground-up rebuild of
Carlito v1 with real vehicle physics (raycast suspension + simplified drivetrain), a single
shared signal contract (`contract/carlito_contract.json`), and CI-deployed web builds.

- **Plan of record:** [`version2_plan.md`](version2_plan.md) — architecture, milestones, rules.
- **Status:** M1 core — raycast-suspension car + real drivetrain drivable on a flat dev scene
  (keyboard/gamepad, chase camera, respawn). Gym level, dashboard, and bridge input still ahead.
- **Deployed build:** https://leaukojo.github.io/carlito2/
- **Dev docs:** [`CLAUDE.md`](CLAUDE.md) (how to run, test, export).

## License

Code is MIT (see [LICENSE](LICENSE)); bundled art/audio assets are CC0 (Kenney kits).

### Credits

- [gdUnit4](https://github.com/MikeSchulze/gdUnit4) (MIT) — vendored test framework at
  `addons/gdUnit4/`.
- [Dechode/Godot-Advanced-Vehicle](https://github.com/Dechode/Godot-Advanced-Vehicle) (MIT) and
  [Tobalation/GDCustomRaycastVehicle](https://github.com/Tobalation/GDCustomRaycastVehicle) (MIT)
  — studied as approach references for the raycast suspension / slip tires / drivetrain in
  `src/vehicles/base/` (plan §7); no code copied.
