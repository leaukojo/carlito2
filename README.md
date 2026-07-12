# carlito2

Carlito — a browser-based CAN-bus driving sandbox built with Godot 4.6. Drive vehicles
(car, truck, tractor, boat) while exchanging live CAN signals with the
[sloppyCAN](../sloppycan)/RAMN simulator through a postMessage bridge. Real vehicle
physics (raycast suspension + simplified drivetrain), a single shared signal contract
(`contract/carlito_contract.json`), and CI-deployed web builds.

- **What works:** car/truck/tractor/boat with a contract-driven telemetry dashboard, the
  web CAN bridge, ISOBUS implement signals, water + probe buoyancy, and a full
  level-authoring kit (thumbnail palette dock, generated/sculpted terrain with color
  splat, seeded + painted scatter, spline roads, and a chunk bake tool with a CI
  stale-bake gate). Remaining work is content and polish — see [`TODO.md`](TODO.md).
- **Deployed build:** https://leaukojo.github.io/carlito2/
- **Dev docs:** [`CLAUDE.md`](CLAUDE.md) (how to run, test, export),
  [`docs/overview.md`](docs/overview.md) (architecture map).

## License

Code is MIT (see [LICENSE](LICENSE)); bundled art/audio assets are CC0 (Kenney kits).

### Credits

- [Kenney](https://kenney.nl) (CC0) — the level-kit source models under `kit/raw/`:
  City Kit (Roads / Suburban / Commercial / Industrial), Racing Kit, Watercraft Pack, and
  Nature Kit (standalone props only). Per-kit `License.txt` files are kept alongside the
  models.
- [gdUnit4](https://github.com/MikeSchulze/gdUnit4) (MIT) — vendored test framework at
  `addons/gdUnit4/`.
- [Dechode/Godot-Advanced-Vehicle](https://github.com/Dechode/Godot-Advanced-Vehicle) (MIT) and
  [Tobalation/GDCustomRaycastVehicle](https://github.com/Tobalation/GDCustomRaycastVehicle) (MIT)
  — studied as approach references for the raycast suspension / slip tires / drivetrain in
  `src/vehicles/base/`; no code copied.
