# Project layout and local workbench

| Directory | Contents |
| --- | --- |
| `Sources/`, `Tests/` | Production modules and automated tests |
| `Helper/`, `Config/` | Privilege boundary and app configuration |
| `Assets/` | Production artwork and provenance |
| `scripts/`, `Tilvero.xcodeproj/`, `Package.swift` | Build and validation tooling |
| `docs/`, `planning/`, `Design/` | Documentation, specifications and retained evidence |
| `build/` | Canonical app output, release artifacts and protected rollback material |
| `local-lab/` | Ignored native workbench, experiments and local design work |

The laboratory has one discoverable application:
`local-lab/builds/Tilvero Lab.app`. Candidate builds belong in
`local-lab/.staging.noindex/`; retired bundles belong in verified archives.
The lab uses a distinct bundle ID, synthetic data and a dark monochrome variant
of the production icon.

Inside `local-lab/`, native source belongs in `demos/`, browser prototypes in
`pages/`, captures in `screenshots/`, saved design overrides in `designs/` and
historical experiments in `archive/`. Transfer selected components to their
focused integration branch for normal tests and review. Demo acceptance is
separate from production and hardware acceptance.

Regenerable caches are distinct from failure evidence, source snapshots, release
receipts, backups and unique experimental source. Cleanup preserves the active
production application and current work, verifies archives before removing
originals, and avoids broad `git clean` or build-directory deletion. Existing
documentation and project paths remain usable.
